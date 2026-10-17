import Foundation

struct SonarrImage: Decodable, Sendable {
    let coverType: String?
    let url: String?
}

struct SonarrSeries: Decodable, Sendable, Identifiable {
    let id: Int
    let title: String
    let tvdbId: Int?
    let imdbId: String?
    let monitored: Bool
    let seasons: [SonarrSeason]
    let images: [SonarrImage]?
    let seriesType: String?
    let originalLanguage: SonarrLanguage?

    /// Non-English originals (anime without a reported language included) default replacement searches to English audio.
    var prefersEnglishAudio: Bool {
        guard let name = originalLanguage?.name?.lowercased(), !name.isEmpty, name != "unknown" else {
            return seriesType?.lowercased() == "anime"
        }
        return name != "english"
    }
}

struct SonarrSeason: Decodable, Sendable, Identifiable {
    var id: Int { seasonNumber }
    let seasonNumber: Int
    let monitored: Bool
    let images: [SonarrImage]?
}

struct SonarrEpisode: Decodable, Sendable, Identifiable {
    let id: Int
    let tvdbId: Int?
    let seasonNumber: Int
    let episodeNumber: Int
    let title: String?
    let overview: String?
    let airDateUtc: Date?
    let airDate: String?
    let hasFile: Bool
    let episodeFileId: Int?
    let monitored: Bool
    let images: [SonarrImage]?

    var hasAired: Bool { airDateUtc.map { $0 <= Date() } ?? false }
    var label: String { "S\(seasonNumber) · E\(episodeNumber)" }
}

struct SonarrQueueItem: Decodable, Sendable {
    let id: Int
    let episodeId: Int?
    let seasonNumber: Int?
    let downloadId: String?
    let size: Double?
    let sizeleft: Double?
    let status: String?
    let trackedDownloadState: String?
    let trackedDownloadStatus: String?
    let errorMessage: String?
    let statusMessages: [SonarrQueueMessage]?

    var transferID: String {
        guard let downloadId, !downloadId.isEmpty else { return "queue:\(id)" }
        return downloadId
    }
    var fraction: Double? {
        guard let size, size > 0, let sizeleft else { return nil }
        return min(1, max(0, (size - sizeleft) / size))
    }
    var problem: String? {
        errorMessage.flatMap { $0.isEmpty ? nil : $0 }
            ?? statusMessages?.flatMap { $0.messages ?? [] }.first
    }
}

struct SonarrQueueMessage: Decodable, Sendable {
    let messages: [String]?
}

struct SonarrCommand: Decodable, Sendable {
    let id: Int
    let name: String?
    let queued: Date?
    let body: SonarrCommandBody?
    let status: String?
    let message: String?
    let result: String?
    var isFinished: Bool { ["completed", "failed", "aborted", "cancelled"].contains(status?.lowercased() ?? "") }
    var failed: Bool { status?.lowercased() == "failed" || result?.lowercased() == "unsuccessful" }
}

struct SonarrCommandBody: Decodable, Sendable {
    let name: String?
    let episodeIds: [Int]?
}

struct SonarrActivity: Sendable {
    let title: String
    var progress: Double? = nil
    var message: String? = nil
    var blocksRequest = true
}

/// A presentation union; external episodes never acquire a synthetic Plex rating key.
struct SonarrEpisodeItem: Identifiable {
    let id: String
    let plex: PlexEpisode?
    let sonarr: SonarrEpisode?
}

struct SonarrShowSnapshot {
    let show: PlexMediaDetails
    let series: SonarrSeries
    var seasons: [PlexSeason]
    var plexEpisodes: [PlexEpisode]
    var episodes: [SonarrEpisode]
    var queue: [SonarrQueueItem]
    var matches: [Int: PlexEpisode]
    var mappingError: String?
    var connectionError: String?
    var scanMessage: String?

    var canEnrich: Bool { mappingError == nil }
    func items(season: Int, plexEpisodes: [PlexEpisode]? = nil) -> [SonarrEpisodeItem] {
        let local = plexEpisodes ?? self.plexEpisodes.filter { $0.parentIndex == season }
        guard canEnrich else {
            return local.map { SonarrEpisodeItem(id: "plex:\($0.ratingKey)", plex: $0, sonarr: nil) }
        }
        var consumed = Set<String>()
        var result = episodes.filter { $0.seasonNumber == season }.map { episode in
            let plex = matches[episode.id].flatMap { matched in
                local.first { $0.ratingKey == matched.ratingKey }
            }
            if let plex { consumed.insert(plex.ratingKey) }
            return SonarrEpisodeItem(id: "sonarr:\(episode.id)", plex: plex, sonarr: episode)
        }
        result += local.filter { !consumed.contains($0.ratingKey) }.map {
            SonarrEpisodeItem(id: "plex:\($0.ratingKey)", plex: $0, sonarr: nil)
        }
        return result.sorted { ($0.sonarr?.episodeNumber ?? $0.plex?.index ?? 0) < ($1.sonarr?.episodeNumber ?? $1.plex?.index ?? 0) }
    }
}

struct SonarrRelease: Decodable, Sendable, Identifiable {
    var id: String { "\(indexerId):\(guid ?? title)" }
    let guid: String?
    let indexerId: Int
    let title: String
    let indexer: String?
    let size: Int64?
    let languages: [SonarrLanguage]?
    let quality: SonarrReleaseQuality?
    let customFormats: [SonarrCustomFormatName]?
    let customFormatScore: Int?
    let releaseWeight: Int?
    let rejections: [String]?
    let downloadAllowed: Bool?
    let episodeRequested: Bool?
    let mappedSeriesId: Int?
    let mappedEpisodeInfo: [SonarrReleaseEpisode]?
    let fullSeason: Bool?
    let seeders: Int?

    var languageText: String {
        let names = (languages ?? []).compactMap(\.name).filter { !$0.isEmpty && $0.lowercased() != "unknown" }
        return names.isEmpty ? "Language not reported" : "Reported language: \(names.joined(separator: ", "))"
    }
    var isReportedEnglish: Bool { languages?.contains { $0.name?.lowercased() == "english" } == true }

    /// Release names and custom format names only hint at audio; Dusk never inspects the tracks.
    var englishAudioHints: [String] {
        var hints: [String] = []
        if let tag = Self.titleAudioTag(title) { hints.append(tag) }
        hints += (customFormats ?? []).compactMap(\.name).filter(Self.namesEnglishAudio).map { "Format: \($0)" }
        return hints
    }

    /// Separators become spaces so `[Dual-Audio]`, `DUAL.AAC` and `JA+EN` tokenize alike.
    private static func words(_ value: String) -> String {
        String(value.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
    }

    /// "Multi-Subs" and "Eng Sub" describe subtitles, so subtitle-qualified markers are skipped.
    private static func titleAudioTag(_ title: String) -> String? {
        let text = words(title)
        if text.contains(#/\bdual(?:\s*audio)?\b/#) { return "Dual audio in title" }
        if text.contains(#/\b(?:eng(?:lish)?)?dub(?:bed|s)?\b/#) { return "Dub in title" }
        if text.contains(#/\beng(?:lish)?\s*audio\b/#)
            || text.contains(#/\b(?:jp|jpn|ja|jap|japanese)\s+(?:en|eng|english)\b(?!\s*sub)/#)
            || text.contains(#/\b(?:en|eng|english)\s+(?:jp|jpn|ja|jap|japanese)\b(?!\s*sub)/#) {
            return "English audio in title"
        }
        if text.contains(#/\bmulti(?:\s*audio)?\b(?!\s*sub)/#) { return "Multi-audio in title, English not confirmed" }
        return nil
    }

    /// Matches formats such as "Anime Dual Audio" or "Dubs Only", not "Language: Not English".
    private static func namesEnglishAudio(_ format: String) -> Bool {
        let text = words(format)
        guard !text.contains(#/\b(?:not|non|no|sub|subs|subbed)\b/#) else { return false }
        return text.contains(#/\bdual(?:\s*audio)?\b|\b(?:eng(?:lish)?)?dub(?:bed|s)?\b|\benglish\b|\bmulti\s*audio\b/#)
    }
}
struct SonarrReleaseEpisode: Decodable, Sendable { let id: Int }
struct SonarrLanguage: Decodable, Sendable { let name: String? }
struct SonarrCustomFormatName: Decodable, Sendable { let name: String? }
struct SonarrReleaseQuality: Decodable, Sendable { let quality: SonarrQualityName? }
struct SonarrQualityName: Decodable, Sendable { let name: String? }

struct SonarrReleaseSearch: Sendable {
    let context: String
    let showKey: String
    let plexRatingKey: String
    let episodeID: Int
    let seasonNumber: Int
    let episodeLabel: String
    let episodeWasChosen: Bool
    let seriesID: Int
    let prefersEnglishAudio: Bool
    let originalFileID: Int?
    let currentReleaseTitle: String?
    let plexSignature: Set<String>
    let releases: [SonarrRelease]
    /// Season-search results that include this episode; nil until that slower search runs.
    var seasonPackReleases: [SonarrRelease]?

    var allReleases: [SonarrRelease] { releases + (seasonPackReleases ?? []) }
}

struct SonarrEpisodeFileInfo: Decodable, Sendable { let sceneName: String? }

/// Ambiguous identity is an explicit episode choice, not an empty release search.
struct SonarrEpisodeSelectionRequired: Error, Sendable {
    let context: String
    let seriesTitle: String
    let plexEpisodeLabel: String
    let suggestedEpisodeID: Int?
    let episodes: [SonarrEpisode]
}
