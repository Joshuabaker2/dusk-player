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
    var requestsFocus = false
    var usesDirectionalSelection = false

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
        .focusable(!usesDirectionalSelection)
        .duskDirectionalFocusHighlight(requestsFocus, shape: shape)
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
    var displayTitle: (PlexItem) -> String = { $0.title }
    var subtitle: (PlexItem) -> String?
    var posterURL: (PlexItem, Int, Int) -> URL?
    var progress: (PlexItem) -> Double? = { _ in nil }
    var directionalSelectionID: PlexItem.ID? = nil
    var directionalShowAllIsSelected = false
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
                        artworkRequest: CinemetaArtworkRequest.make(
                            for: item, kind: imageAspectRatio > 1 ? .background : .poster
                        ),
                        title: displayTitle(item),
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
                        imageAspectRatio: imageAspectRatio,
                        requestsFocus: directionalShowAllIsSelected,
                        usesDirectionalSelection: usesDirectionalSelection
                    )
                    .id("show-all")
                }
            }
            .onChange(of: directionalSelectionID) { _, itemID in
                guard let itemID else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(itemID, anchor: .center)
                }
            }
            .onChange(of: directionalShowAllIsSelected) { _, selected in
                if selected {
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("show-all", anchor: .center) }
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
        displayTitle: @escaping (PlexItem) -> String = { $0.title },
        subtitle: @escaping (PlexItem) -> String?,
        posterURL: @escaping (PlexItem, Int, Int) -> URL?,
        progress: @escaping (PlexItem) -> Double? = { _ in nil },
        directionalSelectionID: PlexItem.ID? = nil,
        directionalShowAllIsSelected: Bool = false,
        usesDirectionalSelection: Bool = false
    ) {
        self.title = title
        self.items = items
        self.posterWidth = posterWidth
        self.imageAspectRatio = imageAspectRatio
        self.horizontalPadding = horizontalPadding
        self.showAllRoute = showAllRoute
        self.displayTitle = displayTitle
        self.subtitle = subtitle
        self.posterURL = posterURL
        self.progress = progress
        self.directionalSelectionID = directionalSelectionID
        self.directionalShowAllIsSelected = directionalShowAllIsSelected
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
                        artworkRequest: CinemetaArtworkRequest.make(
                            for: item, kind: imageAspectRatio > 1 ? .background : .poster
                        ),
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
    @Environment(\.duskScrollToDirectionalFocus) private var scrollToFocus
    let items: [PlexItem]
    let layout: AdaptivePosterGridLayout
    var rowSpacing: CGFloat = DuskPosterMetrics.detailGridRowSpacing
    var imageAspectRatio: CGFloat = 2.0 / 3.0
    var posterURL: (PlexItem, Int, Int) -> URL?
    var displayTitle: (PlexItem) -> String = { $0.title }
    var subtitle: (PlexItem) -> String?
    var progress: (PlexItem) -> Double? = { _ in nil }
    var onItemAppear: (PlexItem) -> Void = { _ in }
    var usesExternalDirectionalSelection = false
    var externalDirectionalSelectionID: PlexItem.ID?
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
            isEnabled: supportsDirectionalSelection && !usesExternalDirectionalSelection,
            onActivate: activateFocusedItem
        ) {
            LazyVGrid(columns: layout.columns, alignment: .leading, spacing: rowSpacing) {
                ForEach(items) { item in
                    PosterNavigationCard(
                        route: AppNavigationRoute.destination(for: item),
                        imageURL: posterURL(item, imageWidth, imageHeight),
                        artworkRequest: CinemetaArtworkRequest.make(
                            for: item, kind: imageAspectRatio > 1 ? .background : .poster
                        ),
                        title: displayTitle(item),
                        subtitle: subtitle(item),
                        progress: progress(item),
                        width: layout.posterWidth,
                        imageAspectRatio: imageAspectRatio,
                        requestsFocus: supportsDirectionalSelection &&
                            (usesExternalDirectionalSelection ? externalDirectionalSelectionID : focusedItemID) == item.id,
                        usesDirectionalSelection: supportsDirectionalSelection
                    ) {
                        contextMenuContent(item)
                    }
                    .id(item.id)
                    .onAppear {
                        onItemAppear(item)
                    }
                }
            }
        }
        .onChange(of: focusedItemID) { _, id in
            if let id { scrollToFocus(id) }
        }
        .onAppear {
            if let focusedItemID { scrollToFocus(focusedItemID) }
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
    let onInputCancelled: () -> Void

    func makeUIView(context: Context) -> DuskDirectionalInputView {
        let view = DuskDirectionalInputView()
        view.onDirectionalInput = onDirectionalInput
        view.onDirectionalInputChanged = onDirectionalInputChanged
        view.onActivate = onActivate
        view.onBack = onBack
        view.onInputCancelled = onInputCancelled
        return view
    }

    func updateUIView(_ uiView: DuskDirectionalInputView, context: Context) {
        uiView.onDirectionalInput = onDirectionalInput
        uiView.onDirectionalInputChanged = onDirectionalInputChanged
        uiView.onActivate = onActivate
        uiView.onBack = onBack
        uiView.onInputCancelled = onInputCancelled
        uiView.isInputEnabled = true
        uiView.refreshFirstResponderStatus()
    }

    static func dismantleUIView(_ view: DuskDirectionalInputView, coordinator: ()) {
        view.isInputEnabled = false
        DuskControllerInputRouter.shared.unregister(view)
    }
}

final class DuskDirectionalInputView: DuskControllerInputView {
    var onDirectionalInput: ((KeyEquivalent) -> Bool)?
    var onDirectionalInputChanged: ((KeyEquivalent, Bool) -> Bool)?
    var onActivate: (() -> Bool)?
    var onBack: (() -> Bool)?
    private var heldKey: KeyEquivalent?
    private var heldChangeHandler: ((KeyEquivalent, Bool) -> Bool)?
    private var heldInputUsesChangeHandler = false
    private var repeatTask: Task<Void, Never>?
    private var focusRestoreTask: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(inputSurfaceDidChange), name: .duskInputSurfaceDidChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(inputSurfaceDidChange), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFirstResponder: Bool { isAvailableForInput }

    override func didMoveToWindow() {
        inputPriority = 100
        super.didMoveToWindow()
        if window == nil {
            focusRestoreTask?.cancel()
            focusRestoreTask = nil
        }
        refreshFirstResponderStatus()
    }

    override func receive(_ input: DuskControllerInput, pressed: Bool) -> Bool {
        switch input {
        case .direction(let key):
            return handleDirection(key, pressed: pressed)
        case .primary:
            return pressed && onActivate?() == true
        case .back:
            return pressed && onBack?() == true
        default:
            return false
        }
    }

    override func cancelInput() {
        focusRestoreTask?.cancel()
        focusRestoreTask = nil
        stopHeldInput(commit: false)
        super.cancelInput()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let key = directionalKey(in: presses), handleDirection(key, pressed: true) { return }
        if presses.contains(where: { $0.type == .menu }), onBack?() == true { return }
        if presses.contains(where: { $0.type == .select }), onActivate?() == true { return }
        if let key = presses.compactMap(\.key?.keyCode).first {
            switch key {
            case .keyboardReturnOrEnter, .keypadEnter, .keyboardSpacebar:
                if receive(.primary, pressed: true) { return }
            case .keyboardDeleteOrBackspace, .keyboardEscape:
                if onBack?() == true { return }
            default: break
            }
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let key = directionalKey(in: presses), handleDirection(key, pressed: false) { return }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let key = directionalKey(in: presses), key == heldKey {
            cancelInput()
            return
        }
        super.pressesCancelled(presses, with: event)
    }

    private func handleDirection(_ key: KeyEquivalent, pressed: Bool) -> Bool {
        if !pressed {
            guard key == heldKey else { return false }
            stopHeldInput(commit: true)
            return true
        }
        guard key != heldKey else { return true }
        stopHeldInput(commit: true)
        let changeHandler = onDirectionalInputChanged
        let usesChangeHandler = changeHandler?(key, true) == true
        guard usesChangeHandler || onDirectionalInput?(key) == true else { return false }
        heldKey = key
        heldChangeHandler = changeHandler
        heldInputUsesChangeHandler = usesChangeHandler
        repeatTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            while !Task.isCancelled {
                guard let self, self.heldKey == key else { return }
                guard self.isAvailableForInput else {
                    self.cancelInput()
                    return
                }
                // Transport owns its acceleration; navigation repeats here.
                if !self.heldInputUsesChangeHandler { _ = self.onDirectionalInput?(key) }
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            }
        }
        return true
    }

    private func stopHeldInput(commit: Bool) {
        let key = heldKey
        let handler = heldChangeHandler
        let usesChangeHandler = heldInputUsesChangeHandler
        repeatTask?.cancel()
        repeatTask = nil
        heldKey = nil
        heldChangeHandler = nil
        heldInputUsesChangeHandler = false
        if commit, usesChangeHandler, let key { _ = handler?(key, false) }
    }

    @objc private func inputSurfaceDidChange() {
        refreshFirstResponderStatus()
    }

    func refreshFirstResponderStatus() {
        guard isInputEnabled, window != nil else { return }
        // SwiftUI may update or reattach a representable during a transition.
        // Registration and first-responder ownership are separate lifetimes.
        DuskControllerInputRouter.shared.register(self)
        DuskControllerInputRouter.shared.contextChanged(self)
        guard !isFirstResponder, focusRestoreTask == nil else { return }
        focusRestoreTask = Task { @MainActor [weak self] in
            // A paused player needn't produce another Observation update after
            // the sheet animation. Retry the actual UIKit surface, not playback.
            for _ in 0..<40 {
                await Task.yield()
                guard !Task.isCancelled, let self, self.isInputEnabled, self.window != nil else { return }
                if self.isAvailableForInput,
                   UIApplication.shared.applicationState == .active {
                    self.becomeFirstResponder()
                    if self.isFirstResponder {
                        self.focusRestoreTask = nil
                        return
                    }
                }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            }
            self?.focusRestoreTask = nil
        }
    }

    private func directionalKey(in presses: Set<UIPress>) -> KeyEquivalent? {
        if presses.contains(where: { $0.type == .leftArrow }) { return .leftArrow }
        if presses.contains(where: { $0.type == .rightArrow }) { return .rightArrow }
        if presses.contains(where: { $0.type == .upArrow }) { return .upArrow }
        if presses.contains(where: { $0.type == .downArrow }) { return .downArrow }
        guard let key = presses.compactMap(\.key?.keyCode).first else { return nil }
        switch key {
        case .keyboardLeftArrow: return .leftArrow
        case .keyboardRightArrow: return .rightArrow
        case .keyboardUpArrow: return .upArrow
        case .keyboardDownArrow: return .downArrow
        default: return nil
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
        displayTitle: @escaping (PlexItem) -> String = { $0.title },
        subtitle: @escaping (PlexItem) -> String?,
        progress: @escaping (PlexItem) -> Double? = { _ in nil },
        onItemAppear: @escaping (PlexItem) -> Void = { _ in }
    ) {
        self.items = items
        self.layout = layout
        self.rowSpacing = rowSpacing
        self.imageAspectRatio = imageAspectRatio
        self.posterURL = posterURL
        self.displayTitle = displayTitle
        self.subtitle = subtitle
        self.progress = progress
        self.onItemAppear = onItemAppear
        self.contextMenuContent = { _ in EmptyView() }
    }
}
