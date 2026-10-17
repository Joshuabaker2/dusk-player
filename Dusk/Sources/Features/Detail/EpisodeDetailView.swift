import SwiftUI

struct EpisodeDetailView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(SonarrService.self) private var sonarrService
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(PlaybackCoordinator.self) private var playback
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @State private var viewModel: EpisodeDetailViewModel
    @State private var directionalFocus: EpisodeDirectionalFocusTarget?
    @State private var filePickerRequest: MediaVersionPickerRequest?
    @State private var alternativeFileRequest: MediaVersionPickerRequest?
    @State private var showsDownloadStatus = false

    init(
        ratingKey: String,
        plexService: PlexService,
        downloadManager: DownloadManager? = nil,
        offlinePlaybackSyncManager: OfflinePlaybackSyncManager? = nil
    ) {
        _viewModel = State(initialValue: EpisodeDetailViewModel(
            ratingKey: ratingKey,
            plexService: plexService,
            downloadManager: downloadManager,
            offlinePlaybackSyncManager: offlinePlaybackSyncManager
        ))
    }

    var body: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            if viewModel.isLoading && viewModel.details == nil {
                FeatureLoadingView()
            } else if let error = viewModel.error, viewModel.details == nil {
                FeatureErrorView(message: error) {
                    Task { await viewModel.load() }
                }
            } else if let details = viewModel.details {
                contentView(details)
            }
        }
        .duskMediaVersionPicker(request: $filePickerRequest, alternativeRequest: $alternativeFileRequest)
        #if !os(tvOS)
        .duskSonarrDownloadStatus(acquisition: viewModel.acquisition, isPresented: $showsDownloadStatus)
        #endif
        .duskNavigationBarTitleDisplayModeInline()
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            await viewModel.load()
        }
        #if os(iOS)
        .task(id: sonarrService.observationContext + (viewModel.showRatingKey ?? "") + String(viewModel.isUsingCachedData)) {
            guard !viewModel.isUsingCachedData, let showKey = viewModel.showRatingKey else { return }
            await viewModel.acquisition.observe(service: sonarrService, showKey: showKey)
        }
        #endif
        .onChange(of: playback.showPlayer) { _, isShowing in
            if !isShowing {
                Task { await viewModel.refresh() }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, viewModel.details != nil else { return }
            Task { await viewModel.refresh() }
        }
        .onChange(of: plexService.metadataRevision) { _, _ in
            Task { await viewModel.refresh() }
        }
    }

    @ViewBuilder
    private func contentView(_ details: PlexMediaDetails) -> some View {
        GeometryReader { geometry in
            let heroBackgroundWidth: CGFloat = {
                #if os(tvOS)
                geometry.size.width + geometry.safeAreaInsets.leading + geometry.safeAreaInsets.trailing
                #else
                geometry.size.width
                #endif
            }()
            let heroBackgroundLeadingInset: CGFloat = {
                #if os(tvOS)
                geometry.safeAreaInsets.leading
                #else
                0
                #endif
            }()

            DuskDirectionalFocusScope(
                focusedID: $directionalFocus,
                groups: episodeDirectionalFocusGroups,
                defaultFocus: .play,
                isEnabled: supportsDirectionalSelection,
                onActivate: { activateDirectionalFocus($0, details: details) },
                onSecondaryActivate: { selectFile(for: $0, details: details) }
            ) {
                ScrollViewReader { verticalProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                    heroSection(
                        details,
                        topInset: geometry.safeAreaInsets.top,
                        containerWidth: heroBackgroundWidth,
                        containerHeight: geometry.size.height,
                        backgroundLeadingInset: heroBackgroundLeadingInset
                    )
#if os(tvOS)
                    .focusSection()
#endif

                    #if os(iOS)
                    seasonEpisodesSection()
                        .padding(.top, 28)
                    seasonsPreviewSection()
                        .padding(.top, 28)
                    #endif

                    if detailShowsSynopsisBelowHero(for: sizeClass), let summary = details.summary, !summary.isEmpty {
                        ExpandableSummaryText(
                            text: summary,
                            collapsedLineLimit: episodeSummaryCollapsedLineLimit,
                            foregroundStyle: episodeSummaryForegroundStyle,
                            allowsExpansion: episodeSummaryAllowsExpansion
                        )
                            .padding(.horizontal, DuskPosterMetrics.detailHorizontalPadding)
                            .padding(.top, 24)
#if os(tvOS)
                            .focusSection()
#endif
                    }

                    if let offlineBannerText = viewModel.offlineBannerText {
                        OfflineMetadataBanner(message: offlineBannerText)
                            .padding(.horizontal, DuskPosterMetrics.detailHorizontalPadding)
                            .padding(.top, 24)
                    }

                    if let roles = details.roles, !roles.isEmpty {
                        DetailCastSection(roles: roles, plexService: plexService)
                            .padding(.top, 24)
                    }
                        }
                        .padding(.top, -geometry.safeAreaInsets.top)
                        .frame(width: geometry.size.width, alignment: .topLeading)
                        .padding(.bottom, 40)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .scrollIndicators(.hidden)
                    .duskTVOSPageBackground()
                    .onChange(of: directionalFocus) { _, target in
                        guard let target else { return }
                        withAnimation(.easeOut(duration: 0.16)) {
                            verticalProxy.scrollTo(target.verticalScrollID, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    #if os(iOS)
    @ViewBuilder
    private func seasonEpisodesSection() -> some View {
        if viewModel.selectedSeasonNumber != nil {
            let cardWidth = DuskPosterMetrics.episodeStripCardWidth
            let imageScale = supportsDirectionalSelection ? displayScale : 1
            let imageWidth = Int((cardWidth * imageScale).rounded(.up))
            let imageHeight = Int((cardWidth * imageScale / (16.0 / 9.0)).rounded(.up))

            VStack(alignment: .leading, spacing: supportsDirectionalSelection ? 20 : 14) {
                HStack(spacing: 16) {
                    Text("\(viewModel.selectedSeasonTitle) Episodes")
                        .font(supportsDirectionalSelection ? .title2.bold() : .headline)
                        .foregroundStyle(Color.duskTextPrimary)

                    SonarrDownloadStatusButton(acquisition: viewModel.acquisition, requestsFocus: directionalFocus == .downloadStatus,
                                               usesDirectionalSelection: supportsDirectionalSelection) { showsDownloadStatus = true }
                    if viewModel.isLoadingSeasonEpisodes || viewModel.isLoading {
                        ProgressView().tint(Color.duskAccent)
                    }
                    Spacer()
                    if let number = viewModel.selectedSeasonNumber, viewModel.acquisition.snapshot?.canEnrich == true {
                        Button("Download season", systemImage: "arrow.down.circle") {
                            Task { await viewModel.acquisition.acquire(season: number) }
                        }
                        .detailHeroNativeSecondaryButtonStyle()
                        .focusable(!supportsDirectionalSelection)
                        .duskDirectionalFocusHighlight(directionalFocus == .downloadSeason, shape: Capsule())
                        .disabled(viewModel.acquisition.activity(season: number)?.blocksRequest == true)
                    }
                }
                .padding(.horizontal, DuskPosterMetrics.detailHorizontalPadding)

                if viewModel.seasonEpisodeItems.isEmpty {
                    if let error = viewModel.seasonEpisodesError {
                        FeatureErrorView(message: error) {
                            Task { await viewModel.retrySeasonEpisodes() }
                        }
                        .duskDirectionalFocusHighlight(directionalFocus == .retryEpisodes, shape: RoundedRectangle(cornerRadius: 16))
                    } else if viewModel.isLoadingSeasonEpisodes {
                        ProgressView().tint(Color.duskAccent)
                            .frame(maxWidth: .infinity, minHeight: cardWidth / (16.0 / 9.0))
                    } else {
                        FeatureEmptyStateView(systemImage: "tv", title: "No episodes in this season")
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: DuskPosterMetrics.episodeStripItemSpacing) {
                                ForEach(viewModel.seasonEpisodeItems) { item in
                                    Group {
                                        if let episode = item.plex {
                                            seasonEpisodeCard(episode, id: item.id, width: cardWidth, imageWidth: imageWidth, imageHeight: imageHeight)
                                        } else if let episode = item.sonarr {
                                            SonarrMissingEpisodeCard(episode: episode, acquisition: viewModel.acquisition, width: cardWidth,
                                                                     requestsFocus: directionalFocus == .episode(item.id), usesDirectionalSelection: supportsDirectionalSelection)
                                        }
                                    }
                                    .id(item.id)
                                }
                            }
                            .padding(.horizontal, DuskPosterMetrics.detailHorizontalPadding)
                            .padding(.vertical, 10)
                        }
                        .scrollClipDisabled()
                        .onChange(of: directionalFocus) { _, target in
                            guard case .episode(let episodeID) = target else { return }
                            withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(episodeID, anchor: .center) }
                        }
                    }
                }
            }
            .id(EpisodeDirectionalFocusTarget.episodeStripScrollID)
        }
    }

    @ViewBuilder
    private func seasonsPreviewSection() -> some View {
        if !viewModel.seasonItems.isEmpty {
            let cardWidth = DuskPosterMetrics.episodeStripCardWidth
            let imageScale = supportsDirectionalSelection ? displayScale : 1
            let imageWidth = Int((cardWidth * imageScale).rounded(.up))
            let imageHeight = Int((cardWidth * imageScale / (16.0 / 9.0)).rounded(.up))

            VStack(alignment: .leading, spacing: supportsDirectionalSelection ? 20 : 14) {
                Text("Seasons")
                    .font(supportsDirectionalSelection ? .title2.bold() : .headline)
                    .foregroundStyle(Color.duskTextPrimary)
                    .padding(.horizontal, DuskPosterMetrics.detailHorizontalPadding)

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: DuskPosterMetrics.episodeStripItemSpacing) {
                            ForEach(viewModel.seasonItems) { season in
                                seasonPreviewCard(season, width: cardWidth, imageWidth: imageWidth, imageHeight: imageHeight)
                                    .id(season.id)
                            }
                        }
                        .padding(.horizontal, DuskPosterMetrics.detailHorizontalPadding)
                        .padding(.vertical, 10)
                    }
                    .scrollClipDisabled()
                    .task {
                        await Task.yield()
                        if let selected = viewModel.selectedSeasonID { proxy.scrollTo(selected, anchor: .center) }
                    }
                    .onChange(of: directionalFocus) { _, target in
                        guard case .season(let id) = target else { return }
                        withAnimation(.easeOut(duration: 0.16)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            .id(EpisodeDirectionalFocusTarget.seasonsStripScrollID)
        }
    }

    private func seasonPreviewCard(_ item: EpisodeDetailViewModel.SeasonItem, width: CGFloat, imageWidth: Int, imageHeight: Int) -> some View {
        let isSelected = item.number == viewModel.selectedSeasonNumber
        let isFocused = directionalFocus == .season(item.id)
        let activity = viewModel.acquisition.activity(season: item.number)

        return Button { selectSeason(item) } label: {
            VStack(alignment: .leading, spacing: DuskPosterMetrics.cardSpacing) {
                Group {
                    if let season = item.plex {
                        PosterArtwork(
                            imageURL: viewModel.seasonImageURL(season, width: imageWidth, height: imageHeight),
                            artworkRequest: viewModel.seasonArtworkRequest(season),
                            width: width,
                            imageAspectRatio: 16.0 / 9.0,
                            requestsDirectionalFocus: isFocused
                        )
                    } else {
                        SonarrSeasonArtwork(seasonNumber: item.number, acquisition: viewModel.acquisition)
                            .frame(width: width, height: width * 9 / 16)
                            .clipped()
                            .opacity(0.42)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .duskDirectionalFocusHighlight(isFocused, shape: RoundedRectangle(cornerRadius: 16))
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let activity { SonarrProgressOverlay(activity: activity) }
                }
                .overlay(alignment: .topLeading) {
                    if isSelected {
                        Label("Selected", systemImage: "checkmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.duskBackground)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.duskAccent, in: Capsule())
                            .padding(8)
                    }
                }
                Text(item.title)
                    .font(supportsDirectionalSelection ? .headline : DuskPosterMetrics.titleFont)
                    .foregroundStyle(Color.duskTextPrimary)
                    .lineLimit(2, reservesSpace: supportsDirectionalSelection)
                if let available = activity?.message {
                    Text(available).font(.subheadline).foregroundStyle(Color.duskTextSecondary)
                } else if let count = item.plex?.leafCount {
                    Text(count == 1 ? "1 episode" : "\(count) episodes")
                        .font(supportsDirectionalSelection ? .subheadline : DuskPosterMetrics.subtitleFont)
                        .foregroundStyle(Color.duskTextSecondary)
                }
            }
            .frame(width: width, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(!supportsDirectionalSelection)
        .accessibilityLabel(item.title)
        .accessibilityValue(isSelected ? "Selected" : "")
        .accessibilityHint("Show this season's episodes")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .contextMenu {
            if viewModel.acquisition.snapshot?.canEnrich == true {
                Button("Download season to server", systemImage: "arrow.down.circle") {
                    Task { await viewModel.acquisition.acquire(season: item.number) }
                }
                .disabled(activity?.blocksRequest == true)
            }
        }
        .task(id: item.plex?.ratingKey) {
            if let season = item.plex { await viewModel.loadSeasonPreview(season) }
        }
    }

    private func selectSeason(_ season: EpisodeDetailViewModel.SeasonItem) {
        directionalFocus = .season(season.id)
        Task {
            await viewModel.selectSeason(season)
            guard viewModel.selectedSeasonNumber == season.number else { return }
            // Reveal the same standard shelf for both present and missing seasons.
            // Focus changes also drive the existing vertical/horizontal scroll readers.
            if let item = viewModel.seasonEpisodeItems.first {
                directionalFocus = .episode(item.id)
            } else if viewModel.seasonEpisodesError != nil {
                directionalFocus = .retryEpisodes
            } else if viewModel.acquisition.snapshot?.canEnrich == true {
                directionalFocus = .downloadSeason
            }
        }
    }

    private func seasonEpisodeCard(
        _ episode: PlexEpisode,
        id: String,
        width: CGFloat,
        imageWidth: Int,
        imageHeight: Int
    ) -> some View {
        let isFocused = directionalFocus == .episode(id)
        let isCurrent = episode.ratingKey == viewModel.ratingKey

        return Button { _ = playEpisode(episode) } label: {
            VStack(alignment: .leading, spacing: DuskPosterMetrics.cardSpacing) {
                ZStack(alignment: .topLeading) {
                    PosterArtwork(
                        imageURL: viewModel.episodeImageURL(
                            episode,
                            width: imageWidth,
                            height: imageHeight
                        ),
                        progress: viewModel.progress(for: episode),
                        width: width,
                        imageAspectRatio: 16.0 / 9.0,
                        requestsDirectionalFocus: isFocused
                    )

                    if isCurrent {
                        Text("Current")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.duskBackground)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.duskAccent, in: Capsule())
                            .padding(8)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let activity = viewModel.acquisition.replacementActivity(ratingKey: episode.ratingKey) {
                        SonarrProgressOverlay(activity: activity)
                    }
                }

                PlexAudioLanguageBadge(media: episode.ratingKey == viewModel.ratingKey ? viewModel.details?.media : nil,
                                       ratingKey: episode.ratingKey, offlineOnly: viewModel.isUsingCachedData)

                if supportsDirectionalSelection {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(episode.title)
                                .font(.headline)
                                .foregroundStyle(Color.duskTextPrimary)
                                .lineLimit(2, reservesSpace: true)
                            if viewModel.isEpisodeWatched(episode) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.duskAccent)
                            }
                        }
                        if let summary = episode.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
                            Text(summary)
                                .font(.subheadline)
                                .foregroundStyle(Color.duskTextSecondary)
                                .lineLimit(3, reservesSpace: true)
                        }
                        if let label = viewModel.episodeLabel(episode) {
                            Text(label).font(.subheadline).foregroundStyle(Color.duskTextSecondary)
                        }
                        if let subtitle = viewModel.episodeSubtitle(episode) {
                            Text(subtitle).font(.footnote).foregroundStyle(Color.duskTextSecondary).lineLimit(2)
                        }
                    }
                } else {
                    PosterCardText(
                        title: episode.title,
                        subtitle: viewModel.episodeLabel(episode),
                        width: width,
                        isWatched: viewModel.isEpisodeWatched(episode)
                    )

                    if let subtitle = viewModel.episodeSubtitle(episode) {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(Color.duskTextSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: width, alignment: .topLeading)
        }
        .buttonStyle(.plain)
        .focusable(!supportsDirectionalSelection)
        .disabled(!viewModel.canPlayEpisode(episode))
        .contextMenu {
            let request = MediaVersionPickerRequest(episode: episode, offlineOnly: viewModel.isUsingCachedData)
            MediaFileContextMenu(request: request, onSelectFile: { filePickerRequest = request }, onAlternative: { alternativeFileRequest = request })
            NavigationLink(value: AppNavigationRoute.media(type: .episode, ratingKey: episode.ratingKey)) {
                Label("Episode Details", systemImage: "info.circle")
            }
        }
        .accessibilityHint("Play episode")
        .accessibilityAddTraits(isFocused ? [.isSelected] : [])
        .accessibilityLabel(
            [viewModel.episodeLabel(episode), episode.title]
                .compactMap { $0 }
                .joined(separator: ", ")
        )
    }

    #endif

    @ViewBuilder
    private func heroSection(
        _ details: PlexMediaDetails,
        topInset: CGFloat,
        containerWidth: CGFloat,
        containerHeight: CGFloat,
        backgroundLeadingInset: CGFloat = 0
    ) -> some View {
        let heroBase = min(max(containerHeight * 0.72, 520), 760)
        let heroHeight = heroBase + topInset
        DetailHeroSection(
            backdropURL: viewModel.backdropURL(
                width: Int(containerWidth.rounded(.up)), height: Int(heroHeight.rounded(.up)),
                preservesFullImage: supportsDirectionalSelection
            ),
            title: details.title,
            descriptionText: details.summary,
            topInset: topInset,
            containerWidth: containerWidth,
            backgroundLeadingInset: backgroundLeadingInset,
            heroBaseHeight: heroBase,
            backdropImageAlignment: supportsDirectionalSelection ? .top : .center,
            // The season·episode marker rides directly under the title (so on iPad
            // it heads the right column), while the rest of the metadata stays in
            // the left column with the show logo and the actions.
            titleAccessory: AnyView(
                episodeMarkerRow()
                    .multilineTextAlignment(detailHeroTextAlignment(for: sizeClass))
            ),
            supertitle: {
                if let showTitle = viewModel.showTitle {
                    DetailHeroShowTitleLink(
                        title: showTitle,
                        logoURL: viewModel.showTitleLogoURL(
                            width: Int((containerWidth * 0.5).rounded(.up)),
                            height: 128
                        ),
                        showRoute: viewModel.showRatingKey.map {
                            AppNavigationRoute.media(type: .show, ratingKey: $0)
                        }
                    )
                }
            },
            subtitle: {
                VStack(alignment: detailHeroContentAlignment(for: sizeClass), spacing: 6) {
                    metadataTagline(details)
                    heroMetadata(details)
                    PlexAudioLanguageBadge(media: details.media)
                }
                .multilineTextAlignment(detailHeroTextAlignment(for: sizeClass))
            },
            actions: {
                actionButtons(details)
            }
        )
    }

    @ViewBuilder
    private func episodeMarkerRow() -> some View {
        let seasonLabel = viewModel.seasonLabel
        let episodeLabel = viewModel.episodeLabel

        if seasonLabel != nil || episodeLabel != nil {
            HStack(spacing: 0) {
                if let seasonLabel {
                    seasonMetadataLink(seasonLabel)
                }

                if seasonLabel != nil, episodeLabel != nil {
                    metadataSeparator
                }

                if let episodeLabel {
                    metadataMarkerText(episodeLabel)
                }
            }
        }
    }

    @ViewBuilder
    private func seasonMetadataLink(_ title: String) -> some View {
#if os(tvOS)
        metadataMarkerText(title)
#else
        if let seasonRatingKey = viewModel.seasonRatingKey {
            NavigationLink(value: AppNavigationRoute.media(type: .season, ratingKey: seasonRatingKey)) {
                metadataMarkerText(title)
            }
            .buttonStyle(.plain)
            .duskSuppressTVOSButtonChrome()
        } else {
            metadataMarkerText(title)
        }
#endif
    }

    private func metadataMarkerText(_ title: String) -> some View {
        Text(title)
            .font(markerFont)
            .foregroundStyle(markerColor)
    }

    private var metadataSeparator: some View {
        Text(" · ")
            .font(markerFont)
            .foregroundStyle(Color.primary.opacity(0.56))
    }

    // On iPad the season·episode marker sits under the episode title in the
    // right column as a quiet subtitle, so it reads smaller and greyer there.
    // (tvOS is also `.regular`, so guard to iOS to leave it untouched.)
    private var usesQuietMarker: Bool {
        #if os(iOS)
        sizeClass == .regular
        #else
        false
        #endif
    }

    private var markerFont: Font {
        usesQuietMarker ? .footnote.weight(.medium) : .subheadline.weight(.medium)
    }

    private var markerColor: Color {
        usesQuietMarker ? Color.duskTextSecondary : Color.primary.opacity(0.82)
    }

    @ViewBuilder
    private func metadataTagline(_ details: PlexMediaDetails) -> some View {
        let parts = [
            details.contentRating,
            viewModel.formattedDuration,
        ].compactMap { $0 }

        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.primary.opacity(0.78))
        }
    }

    @ViewBuilder
    private func heroMetadata(_ details: PlexMediaDetails) -> some View {
        if let originalDate = MediaTextFormatter.localizedAirDate(details.originallyAvailableAt) {
            Text(originalDate)
                .font(.caption)
                .foregroundStyle(Color.primary.opacity(0.72))
        }

        if let rating = details.rating {
            HStack(spacing: 4) {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                Text(String(format: "%.1f", rating))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Color.primary.opacity(0.84))
            }
        }
    }

    @ViewBuilder
    private func actionButtons(_ details: PlexMediaDetails) -> some View {
        #if os(tvOS)
        HStack(spacing: detailHeroActionSpacing) {
            playButton(details)
            downloadButton(details)
            episodeNavigationButton()
            watchedButton()
        }
        #else
        // Primary fills the stack width; secondary row is centered beneath it.
        VStack(alignment: .center, spacing: detailHeroActionSpacing) {
            playButton(details)
            if viewModel.hasResumeProgress {
                restartButton(details)
            }

            HStack(spacing: detailHeroActionSpacing) {
                downloadButton(details)
                watchedButton()
            }
        }
        .detailHeroActionStackFrame(isCompactPhone: usesFullWidthActionButtons)
        #endif
    }

    private func playButton(_ details: PlexMediaDetails) -> some View {
        Button {
            play(details)
        } label: {
            DetailHeroPrimaryActionButtonLabel(
                title: "Play Episode",
                systemImage: "play.fill",
                fillsWidth: fillsActionWidth
            )
        }
        .detailHeroNativePrimaryButtonStyle()
        .focusable(!supportsDirectionalSelection)
        .duskDirectionalFocusHighlight(directionalFocus == .play, shape: Capsule())
        .id(EpisodeDirectionalFocusTarget.playScrollID)
        .disabled(viewModel.isUsingCachedData && !viewModel.isPlayableOffline)
        .contextMenu {
            let request = MediaVersionPickerRequest(details: details, offlineOnly: viewModel.isUsingCachedData)
            MediaFileContextMenu(request: request, onSelectFile: { filePickerRequest = request }, onAlternative: { alternativeFileRequest = request })
            if !viewModel.isUsingCachedData || viewModel.isPlayableOffline {
                PlayVersionContextMenu(versions: details.media) { version in
                    Task {
                        await playback.playVersion(
                            ratingKey: details.ratingKey,
                            mediaID: version.id,
                            resumeOffsetMilliseconds: details.viewOffset,
                            placeholder: PlaybackPlaceholder(details: details)
                        )
                    }
                }
            }
        }
    }

    private func restartButton(_ details: PlexMediaDetails) -> some View {
        Button {
            restart(details)
        } label: {
            DetailHeroSecondaryActionButtonLabel(
                title: "Restart Episode",
                systemImage: "arrow.counterclockwise",
                fillsWidth: fillsActionWidth
            )
        }
        .detailHeroNativeSecondaryButtonStyle()
        .focusable(!supportsDirectionalSelection)
        .duskDirectionalFocusHighlight(directionalFocus == .restart, shape: Capsule())
        .id(EpisodeDirectionalFocusTarget.restartScrollID)
        .disabled(viewModel.isUsingCachedData && !viewModel.isPlayableOffline)
    }

    private var supportsDirectionalSelection: Bool {
        #if os(iOS)
        ProcessInfo.processInfo.isiOSAppOnMac
        #else
        false
        #endif
    }

    private var episodeDirectionalFocusGroups: [DuskDirectionalFocusGroup<EpisodeDirectionalFocusTarget>] {
        let actionTargets: [EpisodeDirectionalFocusTarget] = viewModel.hasResumeProgress
            ? [.play, .restart]
            : [.play]

        var groups: [DuskDirectionalFocusGroup<EpisodeDirectionalFocusTarget>] = [.grid(actionTargets, columnCount: 1)]
        if viewModel.acquisition.downloadIssue != nil { groups.append(.single(.downloadStatus)) }
        if !viewModel.isUsingCachedData, viewModel.acquisition.snapshot?.canEnrich == true, viewModel.selectedSeasonNumber != nil {
            groups.append(.single(.downloadSeason))
        }
        if viewModel.seasonEpisodesError != nil, viewModel.seasonEpisodeItems.isEmpty { groups.append(.single(.retryEpisodes)) }
        groups.append(.row(viewModel.seasonEpisodeItems.map { .episode($0.id) }))
        groups.append(.row(viewModel.seasonItems.map { .season($0.id) }))
        return groups
    }

    private func activateDirectionalFocus(
        _ target: EpisodeDirectionalFocusTarget,
        details: PlexMediaDetails
    ) -> Bool {
        switch target {
        case .downloadStatus:
            guard viewModel.acquisition.downloadIssue != nil else { return false }
            showsDownloadStatus = true
            return true
        case .play:
            guard !viewModel.isUsingCachedData || viewModel.isPlayableOffline else { return false }
            play(details)
            return true
        case .restart:
            guard viewModel.hasResumeProgress,
                  !viewModel.isUsingCachedData || viewModel.isPlayableOffline else { return false }
            restart(details)
            return true
        case .downloadSeason:
            guard !viewModel.isUsingCachedData, viewModel.acquisition.snapshot?.canEnrich == true,
                  let number = viewModel.selectedSeasonNumber,
                  viewModel.acquisition.activity(season: number)?.blocksRequest != true else { return false }
            Task { await viewModel.acquisition.acquire(season: number) }
            return true
        case .season(let id):
            guard let season = viewModel.seasonItems.first(where: { $0.id == id }) else { return false }
            #if os(iOS)
            selectSeason(season)
            return true
            #else
            return false
            #endif
        case .retryEpisodes:
            Task { await viewModel.retrySeasonEpisodes() }
            return true
        case .episode(let episodeID):
            guard let item = viewModel.seasonEpisodeItems.first(where: { $0.id == episodeID }) else { return false }
            if let episode = item.plex { return playEpisode(episode) }
            guard let episode = item.sonarr, !viewModel.acquisition.activity(episode).blocksRequest else { return false }
            Task { await viewModel.acquisition.acquire(episode: episode) }
            return true
        }
    }

    private func selectFile(_ episode: PlexEpisode) -> Bool {
        guard viewModel.canPlayEpisode(episode) else { return false }
        filePickerRequest = MediaVersionPickerRequest(episode: episode, offlineOnly: viewModel.isUsingCachedData)
        return true
    }

    private func selectFile(for target: EpisodeDirectionalFocusTarget, details: PlexMediaDetails) -> Bool {
        switch target {
        case .play:
            guard !viewModel.isUsingCachedData || viewModel.isPlayableOffline else { return false }
            filePickerRequest = MediaVersionPickerRequest(details: details, offlineOnly: viewModel.isUsingCachedData)
            return true
        case .episode(let id):
            guard let episode = viewModel.seasonEpisodeItems.first(where: { $0.id == id })?.plex else { return false }
            return selectFile(episode)
        default:
            return false
        }
    }

    private func playEpisode(_ episode: PlexEpisode) -> Bool {
        guard viewModel.canPlayEpisode(episode) else { return false }
        Task {
            await playback.play(
                ratingKey: episode.ratingKey,
                resumeOffsetMilliseconds: episode.viewOffset,
                placeholder: PlaybackPlaceholder(episode: episode)
            )
        }
        return true
    }

    private func play(_ details: PlexMediaDetails) {
        guard !viewModel.isUsingCachedData || viewModel.isPlayableOffline else { return }
        Task {
            await playback.play(
                ratingKey: details.ratingKey,
                resumeOffsetMilliseconds: details.viewOffset,
                placeholder: PlaybackPlaceholder(details: details)
            )
        }
    }

    private func restart(_ details: PlexMediaDetails) {
        guard !viewModel.isUsingCachedData || viewModel.isPlayableOffline else { return }
        Task {
            await playback.playFromStart(
                ratingKey: details.ratingKey,
                placeholder: PlaybackPlaceholder(details: details)
            )
        }
    }

    private func downloadButton(_ details: PlexMediaDetails) -> some View {
        DownloadActionButton(
            ratingKey: details.ratingKey,
            type: .episode,
            iconOnly: true
        )
    }

    @ViewBuilder
    private func episodeNavigationButton() -> some View {
        #if os(tvOS)
        if let seasonRatingKey = viewModel.seasonRatingKey {
            NavigationLink(value: AppNavigationRoute.media(type: .season, ratingKey: seasonRatingKey)) {
                DetailHeroSecondaryIconLabel(systemImage: "rectangle.stack.fill")
            }
            .detailHeroNativeSecondaryButtonStyle()
            .accessibilityLabel("Go to Season")
        }
        #else
        EmptyView()
        #endif
    }

    private func watchedButton() -> some View {
        Button {
            Task { await viewModel.toggleWatched() }
        } label: {
            DetailHeroSecondaryIconLabel(systemImage: viewModel.isWatched ? "eye.slash" : "eye")
        }
        .detailHeroNativeSecondaryButtonStyle()
        .accessibilityLabel(viewModel.isWatched ? "Mark Unwatched" : "Mark Watched")
    }

    private var usesFullWidthActionButtons: Bool {
        usesFullWidthDetailActionButtons(for: sizeClass)
    }

    // The primary label fills its container on all iOS layouts (the action stack
    // owns the final width); tvOS keeps content-sized buttons in an inline row.
    private var fillsActionWidth: Bool {
        #if os(tvOS)
        false
        #else
        true
        #endif
    }

    private var episodeSummaryCollapsedLineLimit: Int {
        #if os(iOS)
        2
        #else
        9
        #endif
    }

    private var episodeSummaryForegroundStyle: Color {
        #if os(iOS)
        Color.primary.opacity(0.78)
        #else
        Color.primary.opacity(0.76)
        #endif
    }

    private var episodeSummaryAllowsExpansion: Bool {
        #if os(iOS)
        false
        #else
        true
        #endif
    }

}

private enum EpisodeDirectionalFocusTarget: Hashable {
    case play
    case restart
    case season(String)
    case retryEpisodes
    case downloadSeason
    case downloadStatus
    case episode(String)

    static let playScrollID = "episode-play-action"
    static let restartScrollID = "episode-restart-action"
    static let episodeStripScrollID = "episode-season-strip"
    static let seasonsStripScrollID = "episode-seasons-preview-strip"

    var verticalScrollID: String {
        switch self {
        case .play:
            Self.playScrollID
        case .restart:
            Self.restartScrollID
        case .episode, .retryEpisodes, .downloadSeason, .downloadStatus:
            Self.episodeStripScrollID
        case .season:
            Self.seasonsStripScrollID
        }
    }
}
