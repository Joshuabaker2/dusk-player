import SwiftUI
#if os(iOS)
import UIKit
#endif

struct LibraryRecommendationsView: View {
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.duskNavigate) private var navigate
    @State private var viewModel: LibraryRecommendationsViewModel
    @State private var directionalFocus: LibraryRecommendationsDirectionalFocusTarget?

    private let navigationTitle: String
    private let isSelected: Bool

    private let continueWatchingCardWidth: CGFloat = DuskPosterMetrics.continueWatchingWidth
    private let continueWatchingAspectRatio: CGFloat = 16.0 / 9.0

    init(
        library: PlexLibrary,
        plexService: PlexService,
        navigationTitle: String,
        isSelected: Bool = true
    ) {
        self.navigationTitle = navigationTitle
        self.isSelected = isSelected
        _viewModel = State(initialValue: LibraryRecommendationsViewModel(
            library: library,
            plexService: plexService
        ))
    }

    var body: some View {
        DuskDirectionalFocusScope(
            focusedID: $directionalFocus,
            groups: directionalFocusGroups,
            defaultFocus: defaultDirectionalFocus,
            isEnabled: isDirectionalSelectionActive,
            onActivate: activateDirectionalFocus
        ) {
            ZStack {
                Color.duskBackground.ignoresSafeArea()

                if !viewModel.hasLoadedOnce,
                   viewModel.error == nil,
                   !viewModel.hasAnyContent {
                    FeatureLoadingView()
                } else {
                    contentView
                }
            }
        }
        .task {
            await viewModel.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit)
        }
        .onChange(of: playback.showPlayer) { _, isShowing in
            if !isShowing {
                Task { await viewModel.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit) }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, viewModel.hasLoadedOnce else { return }
            Task { await viewModel.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit) }
        }
        #if os(iOS)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                SearchToolbarLink()

                browseLibraryButton(labelText: "Browse Library")
            }
        }
        #endif
        .duskNavigationTitle(navigationTitle)
        .duskNavigationBarTitleDisplayModeLarge()
    }

    private var contentView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                #if os(tvOS)
                HStack {
                    Spacer()
                    browseLibraryButton(labelText: "Browse")
                }
                .padding(.horizontal, DuskPosterMetrics.carouselHorizontalPadding)
                .padding(.top, DuskPosterMetrics.carouselHeaderSpacing)
                .padding(.bottom, DuskPosterMetrics.carouselHeaderSpacing)
                #endif

                if let error = viewModel.error,
                   !viewModel.hasAnyContent {
                    FeatureErrorView(message: error) {
                        Task { await viewModel.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit) }
                    }
                    .padding(.top, 40)
                } else if !viewModel.hasAnyContent {
                    emptyView
                        .padding(.top, 40)
                } else {
                    LazyVStack(alignment: .leading, spacing: DuskPosterMetrics.pageSectionSpacing) {
                        if !viewModel.continueWatching.isEmpty {
                            continueWatchingSection
                                .id(continueWatchingDirectionalRowID)
                        }

                        ForEach(viewModel.prioritizedHubs) { hub in
                            let items = viewModel.inlineItems(in: hub)

                            if !items.isEmpty {
                                hubSection(hub, items: items)
                                    .id(directionalRowID(for: hub))
                            }
                        }

                        if viewModel.isVideoLibrary {
                            ForEach(viewModel.secondaryHubs) { hub in
                                let items = viewModel.inlineItems(in: hub)

                                if !items.isEmpty {
                                    hubSection(hub, items: items)
                                        .id(directionalRowID(for: hub))
                                }
                            }

                            ForEach(viewModel.channelShelves) { shelf in
                                if !shelf.items.isEmpty {
                                    channelShelfSection(shelf)
                                        .id(directionalRowID(for: shelf))
                                }
                            }

                            if !viewModel.rediscoverItems.isEmpty {
                                rediscoverSection
                                    .id(rediscoverDirectionalRowID)
                            }
                        } else {
                            ForEach(viewModel.personalizedShelves) { shelf in
                                if !shelf.items.isEmpty {
                                    personalizedShelfSection(shelf)
                                        .id(directionalRowID(for: shelf))
                                }
                            }

                            ForEach(viewModel.secondaryHubs) { hub in
                                let items = viewModel.inlineItems(in: hub)

                                if !items.isEmpty {
                                    hubSection(hub, items: items)
                                        .id(directionalRowID(for: hub))
                                }
                            }
                        }
                    }
                    .padding(.bottom, 48)
                }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Color.clear
                    .frame(height: 88)
            }
            .refreshable {
                await viewModel.load(maxRecentlyAddedItems: recentlyAddedInlineItemLimit)
            }
            #if os(tvOS)
            .scrollClipDisabled()
            #endif
            .duskTVOSPageBackground()
            .onChange(of: directionalFocus) { oldTarget, newTarget in
                guard oldTarget != newTarget, let scrollID = newTarget?.verticalScrollID else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    proxy.scrollTo(scrollID, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func browseLibraryButton(labelText: String) -> some View {
        #if os(tvOS)
        NavigationLink(value: AppNavigationRoute.library(viewModel.library)) {
            Text(labelText)
                .font(.subheadline.weight(.semibold))
        }
        .controlSize(.small)
        .buttonBorderShape(.capsule)
        .buttonStyle(.glass)
        .tint(Color.primary)
        #else
        NavigationLink(value: AppNavigationRoute.library(viewModel.library)) {
            Label(labelText, systemImage: "square.grid.2x2")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.plain)
        .focusable(!isDirectionalSelectionActive)
        .duskDirectionalFocusHighlight(
            directionalFocus == .browseLibrary,
            shape: Capsule()
        )
        #endif
    }

    private var continueWatchingSection: some View {
        PlexItemActionCarouselSection(
            title: viewModel.continueWatchingTitle,
            items: viewModel.continueWatching,
            action: { play($0) },
            posterWidth: continueWatchingCardWidth,
            imageAspectRatio: continueWatchingAspectRatio,
            horizontalPadding: DuskPosterMetrics.libraryPageHorizontalPadding,
            subtitle: { viewModel.displaySubtitle(for: $0) },
            posterURL: { item, width, height in
                viewModel.landscapeImageURL(for: item, width: width, height: height)
            },
            progress: { viewModel.progress(for: $0) },
            directionalSelectionID: selectedItemID(for: continueWatchingDirectionalRowID),
            usesDirectionalSelection: isDirectionalSelectionActive
        ) { item in
            PlexItemContextMenuContent(
                item: item,
                onMarkWatched: {
                    Task { await viewModel.setWatched(true, for: item) }
                },
                onMarkUnwatched: {
                    Task { await viewModel.setWatched(false, for: item) }
                },
                detailsRoute: AppNavigationRoute.destination(for: item),
                detailsLabel: detailsLabel(for: item)
            )
        }
    }

    @ViewBuilder
    private func personalizedShelfSection(_ shelf: LibraryPersonalizedShelf) -> some View {
        PlexItemPosterCarouselSection(
            title: shelf.title,
            items: shelf.items,
            horizontalPadding: DuskPosterMetrics.libraryPageHorizontalPadding,
            showAllRoute: AppNavigationRoute.libraryGenre(library: viewModel.library, genre: shelf.genre),
            subtitle: { viewModel.subtitle(for: $0) },
            posterURL: { item, width, height in
                viewModel.posterURL(for: item, width: width, height: height)
            },
            directionalSelectionID: selectedItemID(for: directionalRowID(for: shelf)),
            usesDirectionalSelection: isDirectionalSelectionActive
        ) { item in
            PlexItemContextMenuContent(
                item: item,
                onMarkWatched: {
                    Task { await viewModel.setWatched(true, for: item) }
                },
                onMarkUnwatched: {
                    Task { await viewModel.setWatched(false, for: item) }
                }
            )
        }
    }

    @ViewBuilder
    private func hubSection(_ hub: PlexHub, items: [PlexItem]) -> some View {
        let showsShowAll = viewModel.shouldShowAll(for: hub)

        PlexItemPosterCarouselSection(
            title: viewModel.normalizedTitle(for: hub),
            items: items,
            posterWidth: shelfPosterWidth,
            imageAspectRatio: shelfImageAspectRatio,
            horizontalPadding: DuskPosterMetrics.libraryPageHorizontalPadding,
            showAllRoute: showsShowAll ? AppNavigationRoute.hub(hub) : nil,
            subtitle: { viewModel.subtitle(for: $0) },
            posterURL: { item, width, height in
                viewModel.posterURL(for: item, width: width, height: height)
            },
            directionalSelectionID: selectedItemID(for: directionalRowID(for: hub)),
            usesDirectionalSelection: isDirectionalSelectionActive
        ) { item in
            PlexItemContextMenuContent(
                item: item,
                onMarkWatched: {
                    Task { await viewModel.setWatched(true, for: item) }
                },
                onMarkUnwatched: {
                    Task { await viewModel.setWatched(false, for: item) }
                }
            )
        }
    }

    @ViewBuilder
    private func channelShelfSection(_ shelf: LibraryVideoChannelShelf) -> some View {
        PlexItemPosterCarouselSection(
            title: shelf.collection.title,
            items: shelf.items,
            posterWidth: shelfPosterWidth,
            imageAspectRatio: shelfImageAspectRatio,
            horizontalPadding: DuskPosterMetrics.libraryPageHorizontalPadding,
            showAllRoute: AppNavigationRoute.libraryCollection(
                library: viewModel.library,
                collection: shelf.collection
            ),
            subtitle: { viewModel.subtitle(for: $0) },
            posterURL: { item, width, height in
                viewModel.posterURL(for: item, width: width, height: height)
            },
            directionalSelectionID: selectedItemID(for: directionalRowID(for: shelf)),
            usesDirectionalSelection: isDirectionalSelectionActive
        ) { item in
            PlexItemContextMenuContent(
                item: item,
                onMarkWatched: {
                    Task { await viewModel.setWatched(true, for: item) }
                },
                onMarkUnwatched: {
                    Task { await viewModel.setWatched(false, for: item) }
                }
            )
        }
    }

    private var rediscoverSection: some View {
        PlexItemPosterCarouselSection(
            title: "Rediscover",
            items: viewModel.rediscoverItems,
            posterWidth: shelfPosterWidth,
            imageAspectRatio: shelfImageAspectRatio,
            horizontalPadding: DuskPosterMetrics.libraryPageHorizontalPadding,
            subtitle: { viewModel.subtitle(for: $0) },
            posterURL: { item, width, height in
                viewModel.posterURL(for: item, width: width, height: height)
            },
            directionalSelectionID: selectedItemID(for: rediscoverDirectionalRowID),
            usesDirectionalSelection: isDirectionalSelectionActive
        ) { item in
            PlexItemContextMenuContent(
                item: item,
                onMarkWatched: {
                    Task { await viewModel.setWatched(true, for: item) }
                },
                onMarkUnwatched: {
                    Task { await viewModel.setWatched(false, for: item) }
                }
            )
        }
    }

    /// Video-library shelves render 16:9 clip cards; movie/show shelves keep
    /// the standard 2:3 posters.
    private var shelfPosterWidth: CGFloat {
        viewModel.isVideoLibrary ? DuskPosterMetrics.videoCarouselWidth : DuskPosterMetrics.carouselPosterWidth
    }

    private var shelfImageAspectRatio: CGFloat {
        viewModel.isVideoLibrary ? 16.0 / 9.0 : 2.0 / 3.0
    }

    private var emptyView: some View {
        FeatureEmptyStateView(
            systemImage: viewModel.library.libraryType?.systemImage ?? "rectangle.stack",
            title: "No recommendations right now"
        )
    }

    private var recentlyAddedInlineItemLimit: Int {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? 15 : 10
        #else
        10
        #endif
    }

    private var isDirectionalSelectionActive: Bool {
        #if os(iOS)
        isSelected && ProcessInfo.processInfo.isiOSAppOnMac
        #else
        false
        #endif
    }

    private var directionalRows: [LibraryRecommendationsDirectionalRow] {
        var rows: [LibraryRecommendationsDirectionalRow] = []

        if !viewModel.continueWatching.isEmpty {
            rows.append(
                LibraryRecommendationsDirectionalRow(
                    id: continueWatchingDirectionalRowID,
                    items: viewModel.continueWatching,
                    activation: .play
                )
            )
        }

        rows.append(contentsOf: viewModel.prioritizedHubs.compactMap(directionalRow(for:)))

        if viewModel.isVideoLibrary {
            rows.append(contentsOf: viewModel.secondaryHubs.compactMap(directionalRow(for:)))
            rows.append(contentsOf: viewModel.channelShelves.compactMap { shelf in
                guard !shelf.items.isEmpty else { return nil }
                return LibraryRecommendationsDirectionalRow(
                    id: directionalRowID(for: shelf),
                    items: shelf.items,
                    activation: .showDetails
                )
            })

            if !viewModel.rediscoverItems.isEmpty {
                rows.append(
                    LibraryRecommendationsDirectionalRow(
                        id: rediscoverDirectionalRowID,
                        items: viewModel.rediscoverItems,
                        activation: .showDetails
                    )
                )
            }
        } else {
            rows.append(contentsOf: viewModel.personalizedShelves.compactMap { shelf in
                guard !shelf.items.isEmpty else { return nil }
                return LibraryRecommendationsDirectionalRow(
                    id: directionalRowID(for: shelf),
                    items: shelf.items,
                    activation: .showDetails
                )
            })
            rows.append(contentsOf: viewModel.secondaryHubs.compactMap(directionalRow(for:)))
        }

        return rows
    }

    private var directionalFocusGroups: [DuskDirectionalFocusGroup<LibraryRecommendationsDirectionalFocusTarget>] {
        [.single(.browseLibrary)] + directionalRows.map { row in
            .row(row.items.map { .poster(rowID: row.id, itemID: $0.id) })
        }
    }

    private var defaultDirectionalFocus: LibraryRecommendationsDirectionalFocusTarget? {
        guard let row = directionalRows.first, let item = row.items.first else {
            return .browseLibrary
        }
        return .poster(rowID: row.id, itemID: item.id)
    }

    private var continueWatchingDirectionalRowID: String {
        "library-continue-watching"
    }

    private var rediscoverDirectionalRowID: String {
        "library-rediscover"
    }

    private func directionalRowID(for hub: PlexHub) -> String {
        "library-hub:\(hub.id)"
    }

    private func directionalRowID(for shelf: LibraryPersonalizedShelf) -> String {
        "library-shelf:\(shelf.id)"
    }

    private func directionalRowID(for shelf: LibraryVideoChannelShelf) -> String {
        "library-channel:\(shelf.id)"
    }

    private func directionalRow(for hub: PlexHub) -> LibraryRecommendationsDirectionalRow? {
        let items = viewModel.inlineItems(in: hub)
        guard !items.isEmpty else { return nil }
        return LibraryRecommendationsDirectionalRow(
            id: directionalRowID(for: hub),
            items: items,
            activation: .showDetails
        )
    }

    private func selectedItemID(for rowID: String) -> PlexItem.ID? {
        guard case .poster(let selectedRowID, let itemID) = directionalFocus,
              selectedRowID == rowID else { return nil }
        return itemID
    }

    private func activateDirectionalFocus(
        _ target: LibraryRecommendationsDirectionalFocusTarget
    ) -> Bool {
        switch target {
        case .browseLibrary:
            navigate(AppNavigationRoute.library(viewModel.library))
            return true
        case .poster(let rowID, let itemID):
            guard let row = directionalRows.first(where: { $0.id == rowID }),
                  let item = row.items.first(where: { $0.id == itemID }) else {
                return false
            }

            switch row.activation {
            case .play:
                play(item)
            case .showDetails:
                navigate(AppNavigationRoute.destination(for: item))
            }
            return true
        }
    }

    private func play(_ item: PlexItem) {
        Task {
            await playback.play(
                ratingKey: item.ratingKey,
                resumeOffsetMilliseconds: item.viewOffset,
                placeholder: PlaybackPlaceholder(item: item)
            )
        }
    }

    private func detailsLabel(for item: PlexItem) -> String {
        if item.isClip {
            return "Go to Video"
        }

        switch item.type {
        case .episode:
            return "Go to Episode"
        case .movie:
            return "Go to Movie"
        default:
            return "View Details"
        }
    }
}

private struct LibraryRecommendationsDirectionalRow {
    enum Activation {
        case play
        case showDetails
    }

    let id: String
    let items: [PlexItem]
    let activation: Activation
}

private enum LibraryRecommendationsDirectionalFocusTarget: Hashable {
    case browseLibrary
    case poster(rowID: String, itemID: PlexItem.ID)

    var verticalScrollID: String? {
        switch self {
        case .browseLibrary:
            nil
        case .poster(let rowID, _):
            rowID
        }
    }
}
