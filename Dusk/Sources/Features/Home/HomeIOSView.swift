#if os(iOS)
import SwiftUI
import UIKit

struct HomeIOSView: View {
    @Binding var path: NavigationPath

    let isSelected: Bool
    let viewModel: HomeViewModel
    let serverName: String?
    let recentlyAddedInlineItemLimit: Int
    let heroSelectionResetRevision: Int
    let liveTVViewModel: LiveTVViewModel
    let showsLiveTV: Bool
    let playLiveTV: (PlexLiveChannel, PlexLiveProgram, PlexLiveTVLineup) -> Void
    let play: (PlexItem) -> Void
    @State private var directionalFocus: HomeDirectionalFocusTarget?
    @State private var currentHeroItemID: PlexItem.ID?
    @State private var heroDirectionalNavigationRequest: HomeHeroDirectionalNavigationRequest?

    var body: some View {
        applyNavigationChrome(to: content, showsHero: showsCinematicHero)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    SearchToolbarLink()
                }
            }
    }

    private var content: some View {
        GeometryReader { geometry in
            let heroItems = viewModel.heroItems()

            DuskDirectionalFocusScope(
                focusedID: $directionalFocus,
                groups: directionalFocusGroups(heroItems: heroItems),
                defaultFocus: defaultDirectionalFocus(heroItems: heroItems),
                isEnabled: isDirectionalSelectionActive,
                onActivate: activateDirectionalFocus,
                onDirectionalBoundary: handleDirectionalBoundary
            ) {
                ScrollViewReader { verticalProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                    if !heroItems.isEmpty {
                        HomeCinematicHero(
                            items: heroItems,
                            viewModel: viewModel,
                            containerSize: geometry.size,
                            topInset: geometry.safeAreaInsets.top,
                            layout: .ios,
                            autoRotates: true,
                            supportsDragNavigation: true,
                            selectionResetRevision: heroSelectionResetRevision,
                            primaryAction: { item, callbacks in
                                AnyView(
                                    Button {
                                        callbacks.restartRotation()
                                        play(item)
                                    } label: {
                                        HomeHeroActionButtonLabel(
                                            title: viewModel.heroPrimaryActionTitle(for: item),
                                            systemImage: "play.fill",
                                            fillsWidth: true
                                        )
                                    }
                                    .homeHeroNativeButtonStyle()
                                    .focusable(!isDirectionalSelectionActive)
                                    .duskDirectionalFocusHighlight(
                                        directionalFocus == .heroPlay,
                                        shape: Capsule()
                                    )
                                    .frame(
                                        maxWidth: UIDevice.current.userInterfaceIdiom == .pad ? 300 : 240,
                                        alignment: .leading
                                    )
                                    .simultaneousGesture(
                                        DragGesture(minimumDistance: 0)
                                            .onChanged { _ in callbacks.pauseRotation() }
                                    )
                                    .contextMenu {
                                        HomeItemContextMenu(
                                            item: item,
                                            detailsLabel: heroDetailsLabel(for: item),
                                            onMarkWatched: {
                                                Task { await viewModel.setWatched(true, for: item) }
                                            },
                                            onMarkUnwatched: {
                                                Task { await viewModel.setWatched(false, for: item) }
                                            },
                                            onSelectRoute: { route in
                                                path.append(route)
                                            },
                                            onRemoveFromContinueWatching: {
                                                Task { await viewModel.removeFromContinueWatching(item) }
                                            }
                                        )
                                    }
                                    .accessibilityAddTraits(.isButton)
                                )
                            },
                            detailsAction: { item in
                                path.append(AppNavigationRoute.destination(for: item))
                            },
                            onCurrentItemChange: { item in
                                currentHeroItemID = item.id
                            },
                            directionalNavigationRequest: heroDirectionalNavigationRequest
                        )
                        .id(HomeDirectionalFocusTarget.heroScrollID)
                    } else if showsHomeServerSubtitle, let serverName {
                        homeSubtitle(serverName)
                            .padding(.bottom, 12)
                    }

                        LazyVStack(alignment: .leading, spacing: 18) {
                            if showsLiveTV {
                                LiveTVHomeShelf(viewModel: liveTVViewModel, play: playLiveTV)
                            }

                            ForEach(viewModel.hubs) { hub in
                                hubSection(hub)
                            }

                            ForEach(viewModel.personalizedShelves) { shelf in
                                personalizedSection(shelf)
                            }
                        }
                        .padding(.top, heroItems.isEmpty ? 0 : 24)
                        }
                        .padding(.top, heroItems.isEmpty ? (showsHomeServerSubtitle ? -10 : 16) : -geometry.safeAreaInsets.top)
                        .padding(.bottom, 24)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: directionalFocus) { oldTarget, newTarget in
                        guard oldTarget != newTarget, let scrollID = newTarget?.verticalScrollID else { return }
                        withAnimation(.easeOut(duration: 0.16)) {
                            verticalProxy.scrollTo(scrollID, anchor: .center)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: 88)
        }
        .task(id: showsLiveTV) {
            guard showsLiveTV else { return }
            await liveTVViewModel.loadNowPlaying(force: true)
        }
    }

    @ViewBuilder
    private func hubSection(_ hub: PlexHub) -> some View {
        let items = viewModel.inlineItems(
            in: hub,
            maxRecentlyAddedItems: recentlyAddedInlineItemLimit
        )

        if !items.isEmpty {
            let isVideoHub = viewModel.isVideoHub(hub)

            PlexItemPosterCarouselSection(
                title: hub.title,
                items: items,
                posterWidth: isVideoHub ? DuskPosterMetrics.videoCarouselWidth : 130,
                imageAspectRatio: isVideoHub ? 16.0 / 9.0 : 2.0 / 3.0,
                showAllRoute: viewModel.shouldShowAll(
                    for: hub,
                    maxRecentlyAddedItems: recentlyAddedInlineItemLimit
                ) ? AppNavigationRoute.hub(hub) : nil,
                subtitle: { isVideoHub ? $0.standardPosterSubtitle : $0.year.map(String.init) },
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
            .id(directionalRowID(for: hub))
        }
    }

    @ViewBuilder
    private func personalizedSection(_ shelf: HomePersonalizedShelf) -> some View {
        if !shelf.items.isEmpty {
            PlexItemPosterCarouselSection(
                title: shelf.title,
                items: shelf.items,
                posterWidth: 130,
                showAllRoute: viewModel.showAllRoute(for: shelf),
                subtitle: { item in
                    viewModel.subtitle(for: item)
                },
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
            .id(directionalRowID(for: shelf))
        }
    }

    @ViewBuilder
    private func applyNavigationChrome<Content: View>(to content: Content, showsHero: Bool) -> some View {
        if showsHero {
            content
                .duskNavigationTitle("")
                .duskNavigationBarTitleDisplayModeInline()
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbarBackground(.hidden, for: .navigationBar)
        } else {
            content
                .duskNavigationTitle("Home")
                .duskNavigationBarTitleDisplayModeLarge()
                .toolbarBackground(.visible, for: .navigationBar)
        }
    }

    private func homeSubtitle(_ serverName: String) -> some View {
        Text(serverName)
            .font(.subheadline)
            .foregroundStyle(Color.primary)
            .lineLimit(1)
            .padding(.horizontal, 20)
    }

    private var showsHomeServerSubtitle: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    private var showsCinematicHero: Bool {
        !viewModel.heroItems().isEmpty
    }

    private var isDirectionalSelectionActive: Bool {
        isSelected && path.isEmpty && ProcessInfo.processInfo.isiOSAppOnMac
    }

    private var directionalRows: [HomeDirectionalRow] {
        let hubRows = viewModel.hubs.compactMap { hub -> HomeDirectionalRow? in
            let items = viewModel.inlineItems(
                in: hub,
                maxRecentlyAddedItems: recentlyAddedInlineItemLimit
            )
            guard !items.isEmpty else { return nil }
            return HomeDirectionalRow(id: directionalRowID(for: hub), items: items)
        }

        let shelfRows = viewModel.personalizedShelves.compactMap { shelf -> HomeDirectionalRow? in
            guard !shelf.items.isEmpty else { return nil }
            return HomeDirectionalRow(id: directionalRowID(for: shelf), items: shelf.items)
        }

        return hubRows + shelfRows
    }

    private func directionalRowID(for hub: PlexHub) -> String {
        "home-hub:\(hub.id)"
    }

    private func directionalRowID(for shelf: HomePersonalizedShelf) -> String {
        "home-shelf:\(shelf.id)"
    }

    private func selectedItemID(for rowID: String) -> PlexItem.ID? {
        guard case .poster(let selectedRowID, let itemID) = directionalFocus,
              selectedRowID == rowID else { return nil }
        return itemID
    }

    private func directionalFocusGroups(
        heroItems: [PlexItem]
    ) -> [DuskDirectionalFocusGroup<HomeDirectionalFocusTarget>] {
        var groups: [DuskDirectionalFocusGroup<HomeDirectionalFocusTarget>] = []
        if !heroItems.isEmpty {
            groups.append(.single(.heroPlay))
        }

        groups.append(contentsOf: directionalRows.map { row in
            .row(row.items.map { .poster(rowID: row.id, itemID: $0.id) })
        })
        return groups
    }

    private func defaultDirectionalFocus(
        heroItems: [PlexItem]
    ) -> HomeDirectionalFocusTarget? {
        if !heroItems.isEmpty {
            return .heroPlay
        }

        guard let row = directionalRows.first, let item = row.items.first else { return nil }
        return .poster(rowID: row.id, itemID: item.id)
    }

    private func activateDirectionalFocus(_ target: HomeDirectionalFocusTarget) -> Bool {
        switch target {
        case .heroPlay:
            let heroItems = viewModel.heroItems()
            guard let item = heroItems.first(where: { $0.id == currentHeroItemID }) ?? heroItems.first else {
                return false
            }
            play(item)
            return true
        case .poster(let rowID, let itemID):
            guard let row = directionalRows.first(where: { $0.id == rowID }),
                  let item = row.items.first(where: { $0.id == itemID }) else {
                return false
            }
            path.append(AppNavigationRoute.destination(for: item))
            return true
        }
    }

    private func handleDirectionalBoundary(
        _ key: KeyEquivalent,
        target: HomeDirectionalFocusTarget
    ) -> Bool {
        guard target == .heroPlay, viewModel.heroItems().count > 1 else { return false }

        let direction: HomeHeroDirectionalNavigation
        switch key {
        case .leftArrow:
            direction = .previous
        case .rightArrow:
            direction = .next
        default:
            return false
        }

        heroDirectionalNavigationRequest = HomeHeroDirectionalNavigationRequest(
            direction: direction,
            revision: (heroDirectionalNavigationRequest?.revision ?? 0) + 1
        )
        return true
    }

    private func heroDetailsLabel(for item: PlexItem) -> String {
        switch item.type {
        case .episode:
            return "Go to Episode"
        case .season:
            return "Go to Season"
        case .show:
            return "Go to Show"
        case .movie:
            return "Go to Movie"
        default:
            return "View Details"
        }
    }
}

private struct HomeDirectionalRow {
    let id: String
    let items: [PlexItem]
}

private enum HomeDirectionalFocusTarget: Hashable {
    case heroPlay
    case poster(rowID: String, itemID: PlexItem.ID)

    static let heroScrollID = "home-hero"

    var verticalScrollID: String {
        switch self {
        case .heroPlay:
            Self.heroScrollID
        case .poster(let rowID, _):
            rowID
        }
    }
}
#endif
