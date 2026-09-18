import SwiftUI
#if os(iOS)
import GameController
import UIKit
#endif

/// Trailing shelf affordance that opens the carousel's full list.
///
/// Every platform renders it as a dashed card sized like the shelf's artwork and
/// placed after the last item, so the destination reads as part of the content
/// instead of a cramped button next to the section title.
struct ShowAllCarouselTile: View {
    let route: AppNavigationRoute
    let width: CGFloat
    var imageAspectRatio: CGFloat = 2.0 / 3.0

    #if os(tvOS)
    @FocusState private var isFocused: Bool
    #endif

    var body: some View {
        #if os(tvOS)
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)

        NavigationLink(value: route) {
            label
                .foregroundStyle(isFocused ? Color.duskBackground : Color.duskTextPrimary)
                .background {
                    shape
                        .fill(isFocused ? Color.duskTextPrimary : Color.duskSurface)

                    shape
                        .strokeBorder(
                            isFocused
                                ? Color.duskTextPrimary
                                : Color.duskTextSecondary.opacity(0.5),
                            style: StrokeStyle(lineWidth: 2, dash: [10, 8])
                        )
                }
        }
        .duskSuppressTVOSButtonChrome()
        .focused($isFocused)
        .duskTVOSFocusEffectShape(shape, scales: false)
        .frame(width: width, alignment: .topLeading)
        .duskTVOSFocusedScale(isFocused)
        .zIndex(isFocused ? 1 : 0)
        .accessibilityLabel("Show all")
        #else
        let shape = RoundedRectangle(
            cornerRadius: PosterArtwork.cornerRadius,
            style: .continuous
        )

        NavigationLink(value: route) {
            label
                .foregroundStyle(Color.primary)
                .background {
                    shape
                        .fill(Color.duskSurface)

                    shape
                        .strokeBorder(
                            Color.duskTextSecondary.opacity(0.45),
                            style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])
                        )
                }
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: .topLeading)
        .accessibilityLabel("Show all")
        #endif
    }

    private var label: some View {
        VStack(spacing: labelSpacing) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: iconSize, weight: .medium))

            Text("Show all")
                .font(labelFont)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(width: width, height: width / max(imageAspectRatio, 0.01))
    }

    private var isHorizontalArtwork: Bool {
        imageAspectRatio > 1
    }

    private var labelSpacing: CGFloat {
        #if os(tvOS)
        isHorizontalArtwork ? 12 : 18
        #else
        isHorizontalArtwork ? 6 : 10
        #endif
    }

    private var iconSize: CGFloat {
        #if os(tvOS)
        min(width * 0.16, 54)
        #else
        min(width * 0.18, 34)
        #endif
    }

    private var labelFont: Font {
        #if os(tvOS)
        .headline.weight(.semibold)
        #else
        .subheadline.weight(.semibold)
        #endif
    }
}

struct PlexItemPosterCarouselSection<ContextMenuContent: View>: View {
    let title: String
    let items: [PlexItem]
    var posterWidth: CGFloat = DuskPosterMetrics.carouselPosterWidth
    var imageAspectRatio: CGFloat = 2.0 / 3.0
    var horizontalPadding: CGFloat = DuskPosterMetrics.carouselHorizontalPadding
    var showAllRoute: AppNavigationRoute? = nil
    var subtitle: (PlexItem) -> String?
    var posterURL: (PlexItem, Int, Int) -> URL?
    var progress: (PlexItem) -> Double? = { _ in nil }
    var directionalSelectionID: PlexItem.ID? = nil
    var usesDirectionalSelection = false
    @ViewBuilder let contextMenuContent: (PlexItem) -> ContextMenuContent

    var body: some View {
        let imageWidth = Int(posterWidth.rounded(.up))
        let imageHeight = Int((posterWidth / imageAspectRatio).rounded(.up))

        ScrollViewReader { proxy in
            MediaCarousel(
                title: title,
                horizontalPadding: horizontalPadding
            ) {
                ForEach(items) { item in
                    PosterNavigationCard(
                        route: AppNavigationRoute.destination(for: item),
                        imageURL: posterURL(item, imageWidth, imageHeight),
                        title: item.title,
                        subtitle: subtitle(item),
                        progress: progress(item),
                        width: posterWidth,
                        imageAspectRatio: imageAspectRatio,
                        requestsFocus: directionalSelectionID == item.id,
                        usesDirectionalSelection: usesDirectionalSelection
                    ) {
                        contextMenuContent(item)
                    }
                    .id(item.id)
                }

                if let showAllRoute {
                    ShowAllCarouselTile(
                        route: showAllRoute,
                        width: posterWidth,
                        imageAspectRatio: imageAspectRatio
                    )
                }
            }
            .onChange(of: directionalSelectionID) { _, itemID in
                guard let itemID else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(itemID, anchor: .center)
                }
            }
        }
    }
}

extension PlexItemPosterCarouselSection where ContextMenuContent == EmptyView {
    init(
        title: String,
        items: [PlexItem],
        posterWidth: CGFloat = DuskPosterMetrics.carouselPosterWidth,
        imageAspectRatio: CGFloat = 2.0 / 3.0,
        horizontalPadding: CGFloat = DuskPosterMetrics.carouselHorizontalPadding,
        showAllRoute: AppNavigationRoute? = nil,
        subtitle: @escaping (PlexItem) -> String?,
        posterURL: @escaping (PlexItem, Int, Int) -> URL?,
        progress: @escaping (PlexItem) -> Double? = { _ in nil },
        directionalSelectionID: PlexItem.ID? = nil,
        usesDirectionalSelection: Bool = false
    ) {
        self.title = title
        self.items = items
        self.posterWidth = posterWidth
        self.imageAspectRatio = imageAspectRatio
        self.horizontalPadding = horizontalPadding
        self.showAllRoute = showAllRoute
        self.subtitle = subtitle
        self.posterURL = posterURL
        self.progress = progress
        self.directionalSelectionID = directionalSelectionID
        self.usesDirectionalSelection = usesDirectionalSelection
        self.contextMenuContent = { _ in EmptyView() }
    }
}

struct PlexItemActionCarouselSection<ContextMenuContent: View>: View {
    let title: String
    let items: [PlexItem]
    let action: (PlexItem) -> Void
    var posterWidth: CGFloat
    var imageAspectRatio: CGFloat
    var horizontalPadding: CGFloat = DuskPosterMetrics.carouselHorizontalPadding
    var showAllRoute: AppNavigationRoute? = nil
    var subtitle: (PlexItem) -> String?
    var posterURL: (PlexItem, Int, Int) -> URL?
    var progress: (PlexItem) -> Double? = { _ in nil }
    var directionalSelectionID: PlexItem.ID? = nil
    var usesDirectionalSelection = false
    @ViewBuilder let contextMenuContent: (PlexItem) -> ContextMenuContent

    var body: some View {
        let imageWidth = Int(posterWidth.rounded(.up))
        let imageHeight = Int((posterWidth / imageAspectRatio).rounded(.up))

        ScrollViewReader { proxy in
            MediaCarousel(
                title: title,
                horizontalPadding: horizontalPadding
            ) {
                ForEach(items) { item in
                    PosterActionCard(
                        action: { action(item) },
                        imageURL: posterURL(item, imageWidth, imageHeight),
                        title: item.continueWatchingDisplayTitle,
                        subtitle: subtitle(item),
                        progress: progress(item),
                        width: posterWidth,
                        imageAspectRatio: imageAspectRatio,
                        showsPlayOverlay: true,
                        requestsFocus: directionalSelectionID == item.id,
                        usesDirectionalSelection: usesDirectionalSelection
                    ) {
                        contextMenuContent(item)
                    }
                    .id(item.id)
                }

                if let showAllRoute {
                    ShowAllCarouselTile(
                        route: showAllRoute,
                        width: posterWidth,
                        imageAspectRatio: imageAspectRatio
                    )
                }
            }
            .onChange(of: directionalSelectionID) { _, itemID in
                guard let itemID else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(itemID, anchor: .center)
                }
            }
        }
    }
}

struct PlexItemPosterGrid<ContextMenuContent: View>: View {
    @Environment(\.duskNavigate) private var navigate
    let items: [PlexItem]
    let layout: AdaptivePosterGridLayout
    var rowSpacing: CGFloat = DuskPosterMetrics.detailGridRowSpacing
    var imageAspectRatio: CGFloat = 2.0 / 3.0
    var posterURL: (PlexItem, Int, Int) -> URL?
    var subtitle: (PlexItem) -> String?
    var progress: (PlexItem) -> Double? = { _ in nil }
    var onItemAppear: (PlexItem) -> Void = { _ in }
    @ViewBuilder let contextMenuContent: (PlexItem) -> ContextMenuContent
    @State private var focusedItemID: PlexItem.ID?

    var body: some View {
        let imageWidth = Int(layout.posterWidth.rounded(.up))
        let imageHeight = Int((layout.posterWidth / imageAspectRatio).rounded(.up))

        DuskDirectionalFocusScope(
            focusedID: $focusedItemID,
            groups: [
                .grid(items.map(\.id), columnCount: layout.columns.count),
            ],
            defaultFocus: items.first?.id,
            isEnabled: supportsDirectionalSelection,
            onActivate: activateFocusedItem
        ) {
            LazyVGrid(columns: layout.columns, alignment: .leading, spacing: rowSpacing) {
                ForEach(items) { item in
                    PosterNavigationCard(
                        route: AppNavigationRoute.destination(for: item),
                        imageURL: posterURL(item, imageWidth, imageHeight),
                        title: item.title,
                        subtitle: subtitle(item),
                        progress: progress(item),
                        width: layout.posterWidth,
                        imageAspectRatio: imageAspectRatio,
                        requestsFocus: supportsDirectionalSelection && focusedItemID == item.id,
                        usesDirectionalSelection: supportsDirectionalSelection
                    ) {
                        contextMenuContent(item)
                    }
                    .onAppear {
                        onItemAppear(item)
                    }
                }
            }
        }
    }

    private var supportsDirectionalSelection: Bool {
        #if os(iOS)
        ProcessInfo.processInfo.isiOSAppOnMac
        #else
        false
        #endif
    }

    private func activateFocusedItem(_ itemID: PlexItem.ID) -> Bool {
        guard let item = items.first(where: { $0.id == itemID }) else { return false }
        navigate(AppNavigationRoute.destination(for: item))
        return true
    }
}

#if os(iOS)
struct DuskDirectionalInputBridge: UIViewRepresentable {
    let onDirectionalInput: (KeyEquivalent) -> Bool
    let onDirectionalInputChanged: ((KeyEquivalent, Bool) -> Bool)?
    let onActivate: () -> Bool
    let onBack: (() -> Bool)?

    func makeUIView(context: Context) -> DuskDirectionalInputView {
        let view = DuskDirectionalInputView()
        view.onDirectionalInput = onDirectionalInput
        view.onDirectionalInputChanged = onDirectionalInputChanged
        view.onActivate = onActivate
        view.onBack = onBack
        return view
    }

    func updateUIView(_ uiView: DuskDirectionalInputView, context: Context) {
        uiView.onDirectionalInput = onDirectionalInput
        uiView.onDirectionalInputChanged = onDirectionalInputChanged
        uiView.onActivate = onActivate
        uiView.onBack = onBack
        uiView.refreshFirstResponderStatus()
    }
}

final class DuskDirectionalInputView: UIView {
    var onDirectionalInput: ((KeyEquivalent) -> Bool)?
    var onDirectionalInputChanged: ((KeyEquivalent, Bool) -> Bool)?
    var onActivate: (() -> Bool)?
    var onBack: (() -> Bool)? {
        didSet {
            configureControllerInputs()
        }
    }

    private var observesControllerConnections = false

    override var canBecomeFirstResponder: Bool {
        window != nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            startObservingControllers()
            configureControllerInputs()
        } else {
            stopObservingControllers()
        }
        refreshFirstResponderStatus()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let key = directionalKey(in: presses),
           onDirectionalInputChanged?(key, true) == true {
            return
        }

        if presses.contains(where: { $0.type == .menu }) {
            if onBack?() == true { return }
            super.pressesBegan(presses, with: event)
            return
        }

        if presses.contains(where: { $0.type == .select }) {
            if onActivate?() == true { return }
            super.pressesBegan(presses, with: event)
            return
        }

        if presses.contains(where: { $0.type == .leftArrow }) {
            if onDirectionalInput?(.leftArrow) == true { return }
            super.pressesBegan(presses, with: event)
            return
        }

        if presses.contains(where: { $0.type == .rightArrow }) {
            if onDirectionalInput?(.rightArrow) == true { return }
            super.pressesBegan(presses, with: event)
            return
        }

        if presses.contains(where: { $0.type == .upArrow }) {
            if onDirectionalInput?(.upArrow) == true { return }
            super.pressesBegan(presses, with: event)
            return
        }

        if presses.contains(where: { $0.type == .downArrow }) {
            if onDirectionalInput?(.downArrow) == true { return }
            super.pressesBegan(presses, with: event)
            return
        }

        guard let keyCode = presses.compactMap(\.key?.keyCode).first else {
            super.pressesBegan(presses, with: event)
            return
        }

        switch keyCode {
        case .keyboardLeftArrow:
            guard onDirectionalInput?(.leftArrow) == true else {
                super.pressesBegan(presses, with: event)
                return
            }
        case .keyboardRightArrow:
            guard onDirectionalInput?(.rightArrow) == true else {
                super.pressesBegan(presses, with: event)
                return
            }
        case .keyboardUpArrow:
            guard onDirectionalInput?(.upArrow) == true else {
                super.pressesBegan(presses, with: event)
                return
            }
        case .keyboardDownArrow:
            guard onDirectionalInput?(.downArrow) == true else {
                super.pressesBegan(presses, with: event)
                return
            }
        case .keyboardReturnOrEnter, .keypadEnter:
            guard onActivate?() == true else {
                super.pressesBegan(presses, with: event)
                return
            }
        case .keyboardDeleteOrBackspace, .keyboardEscape:
            guard onBack?() == true else {
                super.pressesBegan(presses, with: event)
                return
            }
        default:
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let key = directionalKey(in: presses),
           onDirectionalInputChanged?(key, false) == true {
            return
        }

        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let key = directionalKey(in: presses),
           onDirectionalInputChanged?(key, false) == true {
            return
        }

        super.pressesCancelled(presses, with: event)
    }

    func refreshFirstResponderStatus() {
        configureControllerInputs()
        guard window != nil, !isFirstResponder else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.becomeFirstResponder()
        }
    }

    private func directionalKey(in presses: Set<UIPress>) -> KeyEquivalent? {
        if presses.contains(where: { $0.type == .leftArrow }) { return .leftArrow }
        if presses.contains(where: { $0.type == .rightArrow }) { return .rightArrow }
        if presses.contains(where: { $0.type == .upArrow }) { return .upArrow }
        if presses.contains(where: { $0.type == .downArrow }) { return .downArrow }

        guard let keyCode = presses.compactMap(\.key?.keyCode).first else { return nil }
        switch keyCode {
        case .keyboardLeftArrow: return .leftArrow
        case .keyboardRightArrow: return .rightArrow
        case .keyboardUpArrow: return .upArrow
        case .keyboardDownArrow: return .downArrow
        default: return nil
        }
    }

    private func startObservingControllers() {
        guard !observesControllerConnections else { return }
        observesControllerConnections = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controllerDidConnect(_:)),
            name: .GCControllerDidConnect,
            object: nil
        )
    }

    private func stopObservingControllers() {
        guard observesControllerConnections else { return }
        observesControllerConnections = false
        NotificationCenter.default.removeObserver(
            self,
            name: .GCControllerDidConnect,
            object: nil
        )
    }

    @objc
    private func controllerDidConnect(_ notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        configureInputs(on: controller)
    }

    private func configureControllerInputs() {
        guard window != nil else { return }
        for controller in GCController.controllers() {
            configureInputs(on: controller)
        }
    }

    private func configureInputs(on controller: GCController) {
        guard let gamepad = controller.extendedGamepad else { return }

        gamepad.dpad.left.pressedChangedHandler = directionalHandler(for: .leftArrow)
        gamepad.dpad.right.pressedChangedHandler = directionalHandler(for: .rightArrow)
        gamepad.dpad.up.pressedChangedHandler = directionalHandler(for: .upArrow)
        gamepad.dpad.down.pressedChangedHandler = directionalHandler(for: .downArrow)

        gamepad.leftThumbstick.left.pressedChangedHandler = directionalHandler(for: .leftArrow)
        gamepad.leftThumbstick.right.pressedChangedHandler = directionalHandler(for: .rightArrow)
        gamepad.leftThumbstick.up.pressedChangedHandler = directionalHandler(for: .upArrow)
        gamepad.leftThumbstick.down.pressedChangedHandler = directionalHandler(for: .downArrow)

        gamepad.buttonA.pressedChangedHandler = { [weak self] _, _, isPressed in
            guard isPressed else { return }
            Task { @MainActor [weak self] in
                _ = self?.onActivate?()
            }
        }
        if onBack != nil {
            gamepad.buttonB.pressedChangedHandler = { [weak self] _, _, isPressed in
                guard isPressed else { return }
                Task { @MainActor [weak self] in
                    _ = self?.onBack?()
                }
            }
        }
    }

    private func directionalHandler(
        for key: KeyEquivalent
    ) -> GCControllerButtonValueChangedHandler {
        { [weak self] _, _, isPressed in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.onDirectionalInputChanged?(key, isPressed) == true {
                    return
                }
                guard isPressed else { return }
                _ = self.onDirectionalInput?(key)
            }
        }
    }

}
#endif

extension PlexItemPosterGrid where ContextMenuContent == EmptyView {
    init(
        items: [PlexItem],
        layout: AdaptivePosterGridLayout,
        rowSpacing: CGFloat = DuskPosterMetrics.detailGridRowSpacing,
        imageAspectRatio: CGFloat = 2.0 / 3.0,
        posterURL: @escaping (PlexItem, Int, Int) -> URL?,
        subtitle: @escaping (PlexItem) -> String?,
        progress: @escaping (PlexItem) -> Double? = { _ in nil },
        onItemAppear: @escaping (PlexItem) -> Void = { _ in }
    ) {
        self.items = items
        self.layout = layout
        self.rowSpacing = rowSpacing
        self.imageAspectRatio = imageAspectRatio
        self.posterURL = posterURL
        self.subtitle = subtitle
        self.progress = progress
        self.onItemAppear = onItemAppear
        self.contextMenuContent = { _ in EmptyView() }
    }
}
