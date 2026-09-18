import Foundation

@MainActor
@Observable
final class EpisodeDetailViewModel {
    private let plexService: PlexService
    private let downloadManager: DownloadManager?
    private let offlinePlaybackSyncManager: OfflinePlaybackSyncManager?
    let ratingKey: String

    private(set) var details: PlexMediaDetails?
    private(set) var seasonEpisodes: [PlexEpisode] = []
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var isUsingCachedData = false
    private(set) var offlineStateVersion = 0

    init(
        ratingKey: String,
        plexService: PlexService,
        downloadManager: DownloadManager? = nil,
        offlinePlaybackSyncManager: OfflinePlaybackSyncManager? = nil
    ) {
        self.ratingKey = ratingKey
        self.plexService = plexService
        self.downloadManager = downloadManager
        self.offlinePlaybackSyncManager = offlinePlaybackSyncManager
    }

    func load() async {
        guard details == nil else { return }
        await refresh()
    }

    func refresh() async {
        await reload()
    }

    func toggleWatched() async {
        guard let details else { return }
        let targetWatched = !isWatched

        if isUsingCachedData || isPlayableOffline {
            offlinePlaybackSyncManager?.recordWatchState(
                serverID: serverID,
                ratingKey: details.ratingKey,
                watched: targetWatched
            )
            offlineStateVersion += 1
            await offlinePlaybackSyncManager?.syncPendingActions(force: true)
            return
        }

        do {
            try await plexService.setWatched(targetWatched, ratingKey: details.ratingKey)
            await reload()
        } catch {
            if isPlayableOffline {
                offlinePlaybackSyncManager?.recordWatchState(
                    serverID: serverID,
                    ratingKey: details.ratingKey,
                    watched: targetWatched
                )
                offlineStateVersion += 1
            } else {
                self.error = error.localizedDescription
            }
        }
    }

    var seasonLabel: String? {
        MediaTextFormatter.seasonEpisodeLabel(season: details?.parentIndex, episode: nil)
    }

    var seasonRatingKey: String? {
        details?.parentRatingKey
    }

    var episodeLabel: String? {
        MediaTextFormatter.seasonEpisodeLabel(season: nil, episode: details?.index)
    }

    var showTitle: String? {
        details?.grandparentTitle
    }

    var showRatingKey: String? {
        details?.grandparentRatingKey
    }

    var formattedDuration: String? {
        MediaTextFormatter.shortDuration(milliseconds: details?.duration)
    }

    var isWatched: Bool {
        guard let details else { return false }
        _ = offlineStateVersion
        let fallback = isWatched(details)
        return offlinePlaybackSyncManager?.effectiveWatched(
            serverID: serverID,
            ratingKey: details.ratingKey,
            fallback: fallback
        ) ?? fallback
    }

    var isPlayableOffline: Bool {
        downloadManager?.isPlayableOffline(ratingKey: ratingKey) == true
    }

    var hasResumeProgress: Bool {
        _ = offlineStateVersion
        let offset = offlinePlaybackSyncManager?.effectiveViewOffsetMs(
            serverID: serverID,
            ratingKey: ratingKey,
            fallback: details?.viewOffset
        ) ?? details?.viewOffset
        return (offset ?? 0) > 0
    }

    var offlineBannerText: String? {
        guard DownloadsFeature.isVisible, isUsingCachedData else { return nil }
        return isPlayableOffline
            ? "Showing saved episode metadata. This episode is available offline."
            : "Showing saved episode metadata. This episode is not downloaded on this device."
    }

    func backdropURL(width: Int, height: Int) -> URL? {
        let path = details?.thumb ?? details?.art
        return downloadManager?.localArtworkURL(for: path)
            ?? plexService.imageURL(for: path, width: width, height: height)
    }

    func posterURL(width: Int, height: Int) -> URL? {
        let path = details?.parentThumb ?? details?.grandparentThumb ?? details?.thumb
        return downloadManager?.localArtworkURL(for: path)
            ?? plexService.imageURL(for: path, width: width, height: height)
    }

    /// The show's title logo (clear-logo art) inherited onto the episode metadata.
    /// Used in place of the show-name text in the iOS episode hero; nil when Plex
    /// didn't attach a clear logo, in which case the hero falls back to text.
    func showTitleLogoURL(width: Int, height: Int) -> URL? {
        downloadManager?.localArtworkURL(for: details?.clearLogo)
            ?? plexService.imageURL(for: details?.clearLogo, width: width, height: height)
    }

    func episodeImageURL(_ episode: PlexEpisode, width: Int, height: Int) -> URL? {
        let path = episode.thumb ?? episode.grandparentThumb
        return downloadManager?.localArtworkURL(for: path)
            ?? plexService.imageURL(for: path, width: width, height: height)
    }

    func episodeLabel(_ episode: PlexEpisode) -> String? {
        MediaTextFormatter.seasonEpisodeLabel(
            season: nil,
            episode: episode.index,
            separator: " "
        )
    }

    func episodeSubtitle(_ episode: PlexEpisode) -> String? {
        [
            MediaTextFormatter.shortDuration(milliseconds: episode.duration),
            MediaTextFormatter.localizedAirDate(episode.originallyAvailableAt),
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
        .nilIfEmpty
    }

    func progress(for episode: PlexEpisode) -> Double? {
        MediaTextFormatter.progress(
            durationMs: episode.duration,
            offsetMs: offlinePlaybackSyncManager?.effectiveViewOffsetMs(
                serverID: serverID(for: episode),
                ratingKey: episode.ratingKey,
                fallback: episode.viewOffset
            ) ?? episode.viewOffset
        )
    }

    func isEpisodeWatched(_ episode: PlexEpisode) -> Bool {
        offlinePlaybackSyncManager?.effectiveWatched(
            serverID: serverID(for: episode),
            ratingKey: episode.ratingKey,
            fallback: episode.isWatched
        ) ?? episode.isWatched
    }

    private func reload() async {
        isLoading = true
        error = nil

        if let cachedDetails = downloadManager?.cachedMediaDetails(ratingKey: ratingKey) {
            details = cachedDetails
            isUsingCachedData = true
        }

        do {
            details = try await plexService.getMediaDetails(ratingKey: ratingKey)
            isUsingCachedData = false
        } catch {
            if details == nil {
                self.error = error.localizedDescription
            }
        }

        await loadSeasonEpisodes()

        isLoading = false
    }

    private func loadSeasonEpisodes() async {
        guard let seasonRatingKey = details?.parentRatingKey else {
            seasonEpisodes = []
            return
        }

        if let cachedEpisodes = downloadManager?.cachedEpisodes(seasonKey: seasonRatingKey) {
            seasonEpisodes = cachedEpisodes.sorted(by: episodeOrder)
        }

        do {
            seasonEpisodes = try await plexService.getEpisodes(seasonKey: seasonRatingKey)
                .sorted(by: episodeOrder)
        } catch {
            // The episode detail itself remains useful when sibling loading fails.
            // Preserve any cached siblings and avoid replacing the page-level error.
        }
    }

    private func episodeOrder(_ lhs: PlexEpisode, _ rhs: PlexEpisode) -> Bool {
        let leftIndex = lhs.index ?? .max
        let rightIndex = rhs.index ?? .max
        if leftIndex != rightIndex {
            return leftIndex < rightIndex
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private func isWatched(_ details: PlexMediaDetails) -> Bool {
        guard let viewCount = details.viewCount else { return false }
        return viewCount > 0
    }

    private var serverID: String? {
        downloadManager?.serverID(for: ratingKey) ?? plexService.currentServerIdentifier
    }

    private func serverID(for episode: PlexEpisode) -> String? {
        downloadManager?.serverID(for: episode.ratingKey)
            ?? downloadManager?.serverID(for: ratingKey)
            ?? plexService.currentServerIdentifier
    }
}
