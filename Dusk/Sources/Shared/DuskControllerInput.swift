#if os(iOS)
import GameController
import SwiftUI
import UIKit

enum DuskControllerInput: Equatable {
    case direction(KeyEquivalent)
    case primary, back, menu, settings, previous, next
}

extension Notification.Name {
    /// Hardware activity, including controls that have no navigation mapping.
    static let duskGamepadDidReceiveInput = Notification.Name("DuskGamepadDidReceiveInput")

    /// Posted after UIKit completes a modal dismissal, rather than when the
    /// SwiftUI presentation binding first becomes false.
    static let duskInputSurfaceDidChange = Notification.Name("DuskInputSurfaceDidChange")
}

/// Views register an input context; only this router touches hardware handlers.
/// A sheet owns its entire input surface, including buttons it doesn't handle.
@MainActor
final class DuskControllerInputRouter: NSObject {
    static let shared = DuskControllerInputRouter()

    private struct Context {
        weak var view: DuskControllerInputView?
        let order: Int
    }

    private struct Axes {
        var dpad: KeyEquivalent?
        var stick: KeyEquivalent?
        var effective: KeyEquivalent? { dpad ?? stick }
    }

    private var contexts: [ObjectIdentifier: Context] = [:]
    private var nextOrder = 0
    private var axes: [ObjectIdentifier: Axes] = [:]
    private var blockedControllers: Set<ObjectIdentifier> = []
    private weak var heldView: DuskControllerInputView?
    private var heldController: ObjectIdentifier?
    private var heldKey: KeyEquivalent?
    private var holdWatchdog: Task<Void, Never>?
    private var isMonitoring = false

    func register(_ view: DuskControllerInputView) {
        let id = ObjectIdentifier(view)
        if contexts[id] == nil {
            nextOrder += 1
            contexts[id] = Context(view: view, order: nextOrder)
        }
        if !isMonitoring {
            isMonitoring = true
            NotificationCenter.default.addObserver(self, selector: #selector(connected(_:)), name: .GCControllerDidConnect, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(disconnected(_:)), name: .GCControllerDidDisconnect, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(suspend), name: UIApplication.willResignActiveNotification, object: nil)
            for controller in GCController.controllers() { configure(controller) }
        }
        validateHold()
    }

    func unregister(_ view: DuskControllerInputView) {
        if heldView === view { cancelHold() }
        view.cancelInput()
        if view.isFirstResponder { view.resignFirstResponder() }
        contexts.removeValue(forKey: ObjectIdentifier(view))
    }

    func contextChanged(_ view: DuskControllerInputView) {
        if !view.isInputEnabled { view.cancelInput() }
        validateHold()
    }

    func restoreInputFocus() {
        contexts = contexts.filter { $0.value.view?.window != nil }
        validateHold()
        NotificationCenter.default.post(name: .duskInputSurfaceDidChange, object: nil)
    }

    @objc private func connected(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        configure(controller)
    }

    @objc private func disconnected(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        let id = ObjectIdentifier(controller)
        if heldController == id { cancelHold() }
        axes.removeValue(forKey: id)
        blockedControllers.remove(id)
    }

    @objc private func suspend() {
        cancelHold()
        for context in contexts.values { context.view?.cancelInput() }
    }

    private func configure(_ controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }
        gamepad.valueDidChangeHandler = { _, _ in
            Task { @MainActor in
                guard UIApplication.shared.applicationState == .active else { return }
                NotificationCenter.default.post(name: .duskGamepadDidReceiveInput, object: nil)
            }
        }
        gamepad.buttonA.pressedChangedHandler = buttonHandler(.primary)
        gamepad.buttonB.pressedChangedHandler = buttonHandler(.back)
        gamepad.buttonMenu.pressedChangedHandler = buttonHandler(.menu)
        gamepad.buttonX.pressedChangedHandler = buttonHandler(.settings)
        gamepad.leftShoulder.pressedChangedHandler = buttonHandler(.previous)
        gamepad.rightShoulder.pressedChangedHandler = buttonHandler(.next)
        gamepad.dpad.valueChangedHandler = { [weak self, weak controller] _, x, y in
            Task { @MainActor in
                guard let self, let controller else { return }
                self.updateAxes(controller, x: x, y: y, isStick: false)
            }
        }
        gamepad.leftThumbstick.valueChangedHandler = { [weak self, weak controller] _, x, y in
            Task { @MainActor in
                guard let self, let controller else { return }
                self.updateAxes(controller, x: x, y: y, isStick: true)
            }
        }
    }

    private func buttonHandler(_ input: DuskControllerInput) -> GCControllerButtonValueChangedHandler {
        { [weak self] _, _, pressed in
            guard pressed else { return }
            Task { @MainActor in
                guard let self else { return }
                self.validateHold()
                _ = self.dispatch(input, pressed: true)
                self.validateHold()
            }
        }
    }

    private func updateAxes(_ controller: GCController, x: Float, y: Float, isStick: Bool) {
        let id = ObjectIdentifier(controller)
        var state = axes[id] ?? Axes()
        let old = state.effective
        let previous = isStick ? state.stick : state.dpad
        let threshold: Float = isStick ? (previous == nil ? 0.55 : 0.35) : 0.5
        var direction: KeyEquivalent?
        if max(abs(x), abs(y)) >= threshold {
            // Retain the dominant axis near a diagonal, preventing stick jitter
            // from alternating horizontal and vertical navigation.
            let wasHorizontal = previous == .leftArrow || previous == .rightArrow
            let horizontal = previous == nil ? abs(x) > abs(y) :
                (wasHorizontal ? abs(x) * 1.2 >= abs(y) : abs(x) > abs(y) * 1.2)
            direction = horizontal ? (x < 0 ? .leftArrow : .rightArrow) : (y < 0 ? .downArrow : .upArrow)
        }
        if isStick { state.stick = direction } else { state.dpad = direction }
        axes[id] = state
        let current = state.effective
        if blockedControllers.contains(id) {
            if current == nil { blockedControllers.remove(id) }
            return
        }
        guard old != current else { return }
        if heldController == id { finishHold() }
        guard let current else { return }
        if heldController != nil { cancelHold() }
        guard let view = dispatch(.direction(current), pressed: true) else { return }
        heldView = view
        heldController = id
        heldKey = current
        holdWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self else { return }
                self.validateHold()
            }
        }
    }

    private func dispatch(_ input: DuskControllerInput, pressed: Bool) -> DuskControllerInputView? {
        guard UIApplication.shared.applicationState == .active else { return nil }
        let candidates = contexts.values.filter { $0.view?.isAvailableForInput == true }.sorted {
            guard let left = $0.view, let right = $1.view else { return false }
            if left.inputPriority != right.inputPriority { return left.inputPriority > right.inputPriority }
            if left.isFirstResponder != right.isFirstResponder { return left.isFirstResponder }
            return $0.order > $1.order
        }
        for context in candidates {
            if let view = context.view, view.receive(input, pressed: pressed) { return view }
        }
        return nil
    }

    private func validateHold() {
        guard heldKey != nil else { return }
        guard UIApplication.shared.applicationState == .active,
              let heldView, heldView.isAvailableForInput else {
            cancelHold()
            return
        }
        // A newly opened scope must not inherit a direction still held in the
        // previous one. Wait for neutral before accepting it on the new screen.
        if contexts.values.contains(where: {
            guard let view = $0.view else { return false }
            return view !== heldView && view.isAvailableForInput && view.inputPriority > heldView.inputPriority
        }) {
            cancelHold()
        }
    }

    private func finishHold() {
        let view = heldView
        let key = heldKey
        clearHold()
        if let key { _ = view?.receive(.direction(key), pressed: false) }
    }

    private func cancelHold() {
        if let heldController { blockedControllers.insert(heldController) }
        let view = heldView
        clearHold()
        view?.cancelInput()
    }

    private func clearHold() {
        holdWatchdog?.cancel()
        holdWatchdog = nil
        heldView = nil
        heldController = nil
        heldKey = nil
    }
}

/// The registration follows the real UIView lifetime, including sheet covers.
@MainActor
class DuskControllerInputView: UIView {
    var isInputEnabled = true {
        didSet { DuskControllerInputRouter.shared.contextChanged(self) }
    }
    var inputPriority = 0
    var onInput: ((DuskControllerInput, Bool) -> Bool)?
    var onInputCancelled: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { DuskControllerInputRouter.shared.register(self) }
        else { DuskControllerInputRouter.shared.unregister(self) }
    }

    func receive(_ input: DuskControllerInput, pressed: Bool) -> Bool {
        onInput?(input, pressed) ?? false
    }

    func cancelInput() { onInputCancelled?() }

    var isAvailableForInput: Bool {
        guard isInputEnabled, let window, !window.isHidden else { return false }
        var ancestor: UIView? = self
        while let view = ancestor {
            if view.isHidden || view.alpha == 0 { return false }
            ancestor = view.superview
        }
        // UIKit can leave a presenter mounted underneath a sheet. Global
        // GameController callbacks must yield just as native focus does.
        if let presented = topPresentedController(window.rootViewController) {
            return isDescendant(of: presented.view)
        }
        return true
    }

    private func topPresentedController(_ controller: UIViewController?) -> UIViewController? {
        guard let controller else { return nil }
        if let presented = controller.presentedViewController, !presented.isBeingDismissed {
            return topPresentedController(presented) ?? presented
        }
        if let navigation = controller as? UINavigationController {
            return topPresentedController(navigation.visibleViewController)
        }
        if let tabs = controller as? UITabBarController {
            return topPresentedController(tabs.selectedViewController)
        }
        for child in controller.children {
            if let presented = topPresentedController(child) { return presented }
        }
        return nil
    }
}

struct DuskControllerInputBridge: UIViewRepresentable {
    var isEnabled: Bool
    var priority: Int
    var onInput: (DuskControllerInput, Bool) -> Bool
    var onCancel: () -> Void = {}

    func makeUIView(context: Context) -> DuskControllerInputView {
        let view = DuskControllerInputView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ view: DuskControllerInputView, context: Context) {
        view.inputPriority = priority
        view.onInput = onInput
        view.onInputCancelled = onCancel
        view.isInputEnabled = isEnabled
        if view.window != nil { DuskControllerInputRouter.shared.register(view) }
    }

    static func dismantleUIView(_ view: DuskControllerInputView, coordinator: ()) {
        view.isInputEnabled = false
        DuskControllerInputRouter.shared.unregister(view)
    }
}
#endif
