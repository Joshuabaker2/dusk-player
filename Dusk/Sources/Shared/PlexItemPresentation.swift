import Foundation

extension PlexItem {
    /// Series identity across Plex's mixed show/season/episode recent hubs.
    var recentTVShowKey: String? {
        switch type {
        case .show: ratingKey
        case .season: parentRatingKey
        case .episode: grandparentRatingKey
        default: nil
        }
    }

    var posterProgress: Double? {
        MediaTextFormatter.progress(durationMs: duration, offsetMs: viewOffset)
    }

    var continueWatchingDisplayTitle: String {
        if type == .episode, let show = grandparentTitle {
            return show
        }
        return title
    }

    var continueWatchingDisplaySubtitle: String? {
        if isClip {
            return clipPosterSubtitle
        }
        if type == .episode {
            return MediaTextFormatter.seasonEpisodeLabel(season: parentIndex, episode: index) ?? title
        }
        return year.map(String.init)
    }

    /// Clip cards show their full upload date plus compact duration. Videos
    /// from the last week also include relative date context.
    var clipPosterSubtitle: String? {
        MediaTextFormatter.clipCardSubtitle(
            originallyAvailableAt: originallyAvailableAt,
            duration: duration,
            fallbackYear: year
        )
    }

    var standardPosterSubtitle: String? {
        if isClip {
            return clipPosterSubtitle
        }
        switch type {
        case .movie:
            return year.map(String.init)
        case .show:
            if let childCount {
                return MediaTextFormatter.seasonCount(childCount)?.lowercased()
            }
            return year.map(String.init)
        case .episode:
            return MediaTextFormatter.seasonEpisodeLabel(season: parentIndex, episode: index) ?? grandparentTitle
        default:
            return year.map(String.init)
        }
    }

    var filmographyPosterSubtitle: String? {
        switch type {
        case .movie:
            return year.map(String.init)
        case .show:
            let parts = [
                year.map(String.init),
                childCount.flatMap { MediaTextFormatter.seasonCount($0) },
            ]
            .compactMap { $0 }

            return parts.joined(separator: " · ").nilIfEmpty
        default:
            return nil
        }
    }

    @MainActor
    func posterImageURL(plexService: PlexService, width: Int, height: Int) -> URL? {
        plexService.imageURL(for: preferredPosterPath, width: width, height: height)
    }

    @MainActor
    func landscapeImageURL(plexService: PlexService, width: Int, height: Int) -> URL? {
        plexService.imageURL(for: preferredLandscapePath, width: width, height: height)
    }
}

/// Shared "video row" decision for hub-shaped rows (Home hubs, search result
/// groups, hub item grids): a non-empty row consisting entirely of clips
/// renders as a 16:9 carousel/grid; anything mixed or non-clip keeps the 2:3
/// poster layout.
extension Collection where Element == PlexItem {
    /// Keep the hub's recently-added order and retain show/season directories
    /// while their next episode to watch is being resolved.
    var groupedRecentTVItems: [PlexItem] {
        var seenShows: Set<String> = []
        return filter { item in
            guard [.show, .season, .episode].contains(item.type) else { return false }
            if item.type == .episode && item.isWatched { return false }
            return seenShows.insert(item.recentTVShowKey ?? item.ratingKey).inserted
        }
    }

    /// The episode to offer for one show's episodes (`/allLeaves`): the first
    /// unwatched episode after the one watched most recently, or that episode
    /// itself while it is still in progress. Nothing unwatched after it wraps
    /// to the earliest unwatched episode (something skipped); nil means the
    /// show is fully watched. A show with no watch history starts at its first
    /// episode. Specials (season 0) stay out of the order unless the show has
    /// nothing else.
    var nextEpisodeToWatch: PlexItem? {
        let allEpisodes = filter { $0.type == .episode }
        let regularEpisodes = allEpisodes.filter { $0.parentIndex != 0 }
        let episodes = (regularEpisodes.isEmpty ? allEpisodes : regularEpisodes).sorted { lhs, rhs in
            if (lhs.parentIndex ?? 0) != (rhs.parentIndex ?? 0) {
                return (lhs.parentIndex ?? 0) < (rhs.parentIndex ?? 0)
            }
            if (lhs.index ?? 0) != (rhs.index ?? 0) {
                return (lhs.index ?? 0) < (rhs.index ?? 0)
            }
            return lhs.ratingKey < rhs.ratingKey
        }

        // Ties go to the later episode: marking a whole season watched gives
        // every episode the same timestamp. Without any timestamp, fall back
        // to the furthest watched episode.
        let mostRecentIndex = episodes.indices
            .filter { episodes[$0].lastViewedAt != nil }
            .max { lhs, rhs in
                let lhsViewed = episodes[lhs].lastViewedAt ?? 0
                let rhsViewed = episodes[rhs].lastViewedAt ?? 0
                return lhsViewed != rhsViewed ? lhsViewed < rhsViewed : lhs < rhs
            }
            ?? episodes.lastIndex(where: \.isWatched)

        guard let mostRecentIndex else { return episodes.first { !$0.isWatched } }

        let mostRecent = episodes[mostRecentIndex]
        if !mostRecent.isWatched, (mostRecent.viewOffset ?? 0) > 0 {
            return mostRecent
        }
        return episodes[episodes.index(after: mostRecentIndex)...].first { !$0.isWatched }
            ?? episodes.first { !$0.isWatched }
    }

    var isAllClips: Bool {
        !isEmpty && allSatisfy(\.isClip)
    }
}
