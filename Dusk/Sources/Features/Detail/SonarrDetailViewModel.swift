import Foundation

struct SonarrDownloadIssue {
    let title: String
    let summary: String
    let technicalDetails: String
}

@MainActor
@Observable
final class SonarrDetailViewModel {
    private(set) var service: SonarrService?
    private(set) var showKey: String?

    var snapshot: SonarrShowSnapshot? {
        guard let showKey else { return nil }
        return service?.snapshots[showKey]
    }
    var prefersSonarr: Bool { snapshot != nil }
    var message: String? {
        snapshot?.mappingError ?? snapshot?.connectionError ?? showKey.flatMap { service?.errors[$0] }
    }
    var downloadIssue: SonarrDownloadIssue? {
        if let error = snapshot?.connectionError {
            return SonarrDownloadIssue(title: "Download status unavailable",
                summary: "Dusk couldn’t refresh download information. Your available episodes can still be played.", technicalDetails: error)
        }
        if let error = showKey.flatMap({ service?.errors[$0] }) {
            return SonarrDownloadIssue(title: "Downloads need attention",
                summary: "The last download request or status check didn’t finish. Refresh its status to try again.", technicalDetails: error)
        }
        if let error = snapshot?.mappingError {
            return SonarrDownloadIssue(title: "Some missing episodes may not be shown",
                summary: "Dusk couldn’t match all episodes between Plex and Sonarr. You can still watch your library and search for a different file from an episode’s menu.", technicalDetails: error)
        }
        if let error = snapshot?.scanMessage {
            return SonarrDownloadIssue(title: "Waiting for Plex",
                summary: "Sonarr imported the download, but it hasn’t appeared in your Plex library yet. Refresh to check again.", technicalDetails: error)
        }
        return nil
    }

    var missingSeasons: [SonarrSeason] {
        guard let snapshot, snapshot.canEnrich else { return [] }
        let present = Set(snapshot.seasons.map(\.index))
        return snapshot.series.seasons.filter { !present.contains($0.seasonNumber) }.sorted { $0.seasonNumber < $1.seasonNumber }
    }
    func seasonArtworkRequest(_ number: Int) -> CinemetaArtworkRequest? {
        guard let snapshot else { return nil }
        return CinemetaArtworkRequest.makeSeasonPreview(seasonNumber: number, show: snapshot.show)
    }

    func episodeArtworkRequest(_ episode: SonarrEpisode) -> CinemetaArtworkRequest? {
        guard let snapshot else { return nil }
        return CinemetaArtworkRequest.makeEpisodePreview(seasonNumber: episode.seasonNumber, episodeNumber: episode.episodeNumber, show: snapshot.show)
    }

    /// Prefer an episode still or landscape background over a cropped series logo.
    func seasonPreviewPath(_ number: Int) -> String? {
        guard let snapshot else { return nil }
        let episodes = snapshot.episodes.filter { $0.seasonNumber == number }.sorted { $0.episodeNumber < $1.episodeNumber }
        let episodeImages = episodes.flatMap { $0.images ?? [] }
        if let image = episodeImages.first(where: { ["screenshot", "snapshot", "still"].contains($0.coverType?.lowercased() ?? "") })?.url {
            return image
        }
        if let image = episodeImages.first?.url { return image }
        let seasonImages = snapshot.series.seasons.first { $0.seasonNumber == number }?.images ?? []
        let backgrounds = ["fanart", "background", "banner"]
        return seasonImages.first(where: { backgrounds.contains($0.coverType?.lowercased() ?? "") })?.url
            ?? seasonImages.first?.url
            ?? snapshot.series.images?.first(where: { backgrounds.contains($0.coverType?.lowercased() ?? "") })?.url
            ?? snapshot.series.images?.first?.url
    }

    func observe(service: SonarrService, showKey: String) async {
        self.service = service
        self.showKey = showKey
        await service.observe(showKey: showKey)
    }
    func refresh() async {
        guard let showKey else { return }
        await service?.retryScan(showKey: showKey)
    }
    func acquire(episode: SonarrEpisode) async {
        guard let showKey else { return }
        await service?.acquire(showKey: showKey, episodeIDs: [episode.id])
    }
    func retry(episode: SonarrEpisode) async {
        guard let showKey else { return }
        await service?.retrySearch(showKey: showKey, episode: episode)
    }
    func acquire(season: Int) async {
        guard let showKey else { return }
        await service?.acquire(showKey: showKey, season: season)
    }
    func replacementActivity(ratingKey: String) -> SonarrActivity? {
        guard let showKey else { return nil }
        return service?.replacementActivity(ratingKey: ratingKey, showKey: showKey)
    }
    func activity(_ episode: SonarrEpisode) -> SonarrActivity {
        guard let showKey, let service else { return SonarrActivity(title: "Unavailable") }
        return service.activity(for: episode, showKey: showKey)
    }
    func activity(season: Int) -> SonarrActivity? {
        guard let showKey else { return nil }
        return service?.seasonActivity(showKey: showKey, season: season)
    }
}
