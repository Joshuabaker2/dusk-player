import SwiftUI

/// Transient pages (choices, pickers, player controls) use the same path as
/// ordinary destinations, so native Back and controller B unwind one page.
struct DuskPanelRoute: Hashable {
    let id: UUID
    let destination: @MainActor () -> AnyView

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct DuskPanelNavigationAction {
    let present: @MainActor (UUID, @escaping @MainActor () -> AnyView, @escaping @MainActor () -> Void) -> Void
    let dismiss: @MainActor (UUID) -> Void
}

private struct DuskPanelNavigationKey: EnvironmentKey {
    static let defaultValue: DuskPanelNavigationAction? = nil
}

private struct DuskIsNavigationPanelKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var duskPanelNavigation: DuskPanelNavigationAction? {
        get { self[DuskPanelNavigationKey.self] }
        set { self[DuskPanelNavigationKey.self] = newValue }
    }

    var duskIsNavigationPanel: Bool {
        get { self[DuskIsNavigationPanelKey.self] }
        set { self[DuskIsNavigationPanelKey.self] = newValue }
    }
}

@MainActor
final class DuskPanelNavigationStore {
    private struct Entry {
        let owner: AnyHashable
        let depth: Int
        let onDismiss: @MainActor () -> Void
    }

    private var entries: [UUID: Entry] = [:]

    func action(owner: AnyHashable, path: Binding<NavigationPath>) -> DuskPanelNavigationAction {
        DuskPanelNavigationAction(
            present: { [weak self] id, destination, onDismiss in
                guard let self, entries[id] == nil else { return }
                entries[id] = Entry(owner: owner, depth: path.wrappedValue.count, onDismiss: onDismiss)
                duskWithoutNavigationAnimation {
                    path.wrappedValue.append(DuskPanelRoute(id: id, destination: destination))
                }
            },
            dismiss: { [weak self] id in
                guard let self, let entry = entries[id], entry.owner == owner else { return }
                duskWithoutNavigationAnimation {
                    let count = path.wrappedValue.count
                    if count > entry.depth {
                        path.wrappedValue.removeLast(count - entry.depth)
                    }
                    reconcile(owner: owner, count: path.wrappedValue.count)
                }
            }
        )
    }

    /// Remove entries before callbacks: clearing a presentation binding can
    /// otherwise re-enter dismissal while the old page is still registered.
    func reconcile(owner: AnyHashable, count: Int) {
        let removed = entries.filter { $0.value.owner == owner && $0.value.depth >= count }
        for id in removed.keys { entries.removeValue(forKey: id) }
        for entry in removed.values.sorted(by: { $0.depth > $1.depth }) {
            entry.onDismiss()
        }
    }
}

@MainActor
func duskWithoutNavigationAnimation(_ action: () -> Void) {
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction, action)
}

/// Standalone surfaces such as playback own a path independent of the tabs.
struct DuskPanelNavigationStack<Content: View>: View {
    @State private var path = NavigationPath()
    @State private var panels = DuskPanelNavigationStore()
    private let content: Content
    private let keepsContentMounted: Bool
    private let resetID: UUID?

    init(keepsContentMounted: Bool = false, resetID: UUID? = nil, @ViewBuilder content: () -> Content) {
        self.keepsContentMounted = keepsContentMounted
        self.resetID = resetID
        self.content = content()
    }

    private var pathBinding: Binding<NavigationPath> {
        Binding(get: { path }, set: { newPath in
            duskWithoutNavigationAnimation {
                path = newPath
                panels.reconcile(owner: 0, count: newPath.count)
            }
        })
    }

    var body: some View {
        ZStack {
            if keepsContentMounted {
                // Playback owns timers, subtitle state, and an engine surface.
                // Pushing a control page must not tear down that session.
                content
                    .allowsHitTesting(path.isEmpty)
                    .accessibilityHidden(!path.isEmpty)
                NavigationStack(path: pathBinding) {
                    Color.clear
                        .duskPanelNavigationDestinations()
                }
                .opacity(path.isEmpty ? 0 : 1)
                .allowsHitTesting(!path.isEmpty)
                .accessibilityHidden(path.isEmpty)
            } else {
                NavigationStack(path: pathBinding) {
                    content
                        .duskPanelNavigationDestinations()
                }
            }
        }
        .environment(\.duskPanelNavigation, panels.action(owner: 0, path: pathBinding))
        .onChange(of: resetID) { _, _ in
            // An engine/session replacement retires pages bound to the old VM.
            pathBinding.wrappedValue = NavigationPath()
        }
        #if os(iOS)
        .overlay(alignment: .topLeading) {
            if ProcessInfo.processInfo.isiOSAppOnMac {
                DuskControllerInputBridge(isEnabled: !path.isEmpty, priority: 1) { input, pressed in
                    guard pressed, input == .back else { return false }
                    pop()
                    return true
                }
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

                Button(action: pop) { Color.clear.frame(width: 1, height: 1) }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(path.isEmpty)
                    .accessibilityHidden(true)
            }
        }
        #endif
    }

    private func pop() {
        guard !path.isEmpty else { return }
        var nextPath = path
        nextPath.removeLast()
        pathBinding.wrappedValue = nextPath
    }
}

/// A page already pushed into a stack must not install another stack or hide
/// the native Back button. Account bootstrap and tvOS can still use it alone.
struct DuskPanelContent<Content: View>: View {
    @Environment(\.duskIsNavigationPanel) private var isPushed
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        if isPushed {
            content
        } else {
            #if os(tvOS)
            NavigationStack { content }
            #else
            DuskPanelNavigationStack { content }
            #endif
        }
    }
}

private struct DuskNavigationPanelModifier<Destination: View>: ViewModifier {
    @Environment(\.duskPanelNavigation) private var navigation
    @Binding var isPresented: Bool
    @State private var id = UUID()
    let onDismiss: (() -> Void)?
    let destination: () -> Destination

    func body(content: Content) -> some View {
        #if os(tvOS)
        content.sheet(isPresented: $isPresented, onDismiss: onDismiss, content: destination)
        #else
        if let navigation {
            content.onChange(of: isPresented, initial: true) { _, presented in
                if presented {
                    let presentation = $isPresented
                    let dismissed = onDismiss
                    navigation.present(id, { [destination] in AnyView(destination()) }, {
                        presentation.wrappedValue = false
                        dismissed?()
                    })
                } else {
                    navigation.dismiss(id)
                }
            }
        } else {
            // System browser presentation during sign-in has no app stack yet.
            content.sheet(isPresented: $isPresented, onDismiss: onDismiss, content: destination)
        }
        #endif
    }
}

extension View {
    func duskPanelNavigationDestinations() -> some View {
        navigationDestination(for: DuskPanelRoute.self) { route in
            DuskPanelDestinationView(route: route)
                .environment(\.duskIsNavigationPanel, true)
                .background(Color.duskBackground.ignoresSafeArea())
        }
    }

    func duskNavigationPanel<Destination: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Destination
    ) -> some View {
        modifier(DuskNavigationPanelModifier(isPresented: isPresented, onDismiss: onDismiss, destination: content))
    }

    func duskNavigationPanel<Item, Destination: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Destination
    ) -> some View {
        duskNavigationPanel(isPresented: Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        ), onDismiss: onDismiss) {
            if let value = item.wrappedValue { content(value) }
        }
    }
}

private struct DuskPanelDestinationView: View {
    let route: DuskPanelRoute

    var body: some View {
        route.destination()
    }
}
