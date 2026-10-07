import Foundation
import OSLog

let cinemetaArtworkLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk", category: "CinemetaArtwork"
)

/// Optional image enrichment only; Plex still owns metadata and playback.
struct CinemetaArtworkRequest: Hashable, Sendable {
    enum MediaType: String, Hashable, Sendable { case movie, series }
    enum Kind: Hashable, Sendable { case poster, background, seasonPreview(Int) }

    let ratingKey: String
    let mediaType: MediaType
    let imdbID: String?
    let kind: Kind
    let title: String?
    let year: Int?
    var wideHeroBannerAspectRatio: Double? = nil

    private static func make(
        type: PlexMediaType, isClip: Bool, ratingKey: String,
        parentKey: String?, showKey: String?, guids: [PlexGuid], kind: Kind,
        title: String, year: Int?
    ) -> Self? {
        guard !isClip else { return nil }
        switch type {
        case .movie, .show:
            return Self(
                ratingKey: ratingKey,
                mediaType: type == .movie ? .movie : .series,
                imdbID: imdbID(from: guids),
                kind: kind, title: title, year: year
            )
        case .episode:
            guard let showKey else { return nil }
            return Self(ratingKey: showKey, mediaType: .series, imdbID: nil, kind: kind, title: nil, year: nil)
        case .season where kind == .background:
            guard let parentKey else { return nil }
            return Self(ratingKey: parentKey, mediaType: .series, imdbID: nil, kind: kind, title: nil, year: nil)
        default:
            return nil
        }
    }

    static func make(for item: PlexItem, kind: Kind) -> Self? {
        make(
            type: item.type, isClip: item.isClip, ratingKey: item.ratingKey,
            parentKey: item.parentRatingKey, showKey: item.grandparentRatingKey,
            guids: item.guids, kind: kind, title: item.title, year: item.year
        )
    }

    static func make(for details: PlexMediaDetails, kind: Kind) -> Self? {
        make(
            type: details.type, isClip: details.isClip, ratingKey: details.ratingKey,
            parentKey: details.parentRatingKey, showKey: details.grandparentRatingKey,
            guids: details.guids, kind: kind, title: details.title, year: details.year
        )
    }

    static func makeHeroBackground(
        for item: PlexItem, prefersWideBanners: Bool, targetAspectRatio: Double
    ) -> Self? {
        var request = make(for: item, kind: .background)
        if prefersWideBanners, targetAspectRatio >= 2 {
            request?.wideHeroBannerAspectRatio = targetAspectRatio
        }
        return request
    }

    static func makeSeasonPreview(for season: PlexSeason, showKey: String?) -> Self? {
        guard let showKey = season.parentRatingKey ?? showKey else { return nil }
        return Self(ratingKey: showKey, mediaType: .series, imdbID: nil,
                    kind: .seasonPreview(season.index), title: nil, year: nil)
    }

    static func imdbID(from guids: [PlexGuid]) -> String? {
        guids.compactMap { guid in
            validIMDbID(guid.value(for: "imdb") ?? guid.value(for: "com.plexapp.agents.imdb"))
        }.first
    }

    static func validIMDbID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = String(raw.prefix { $0 != "?" && $0 != "#" })
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        guard value.hasPrefix("tt"), value.count > 2, value.count <= 20,
              value.dropFirst(2).utf8.allSatisfy({ (48 ... 57).contains($0) }) else { return nil }
        return value
    }
}

actor CinemetaArtworkService {
    static let shared = CinemetaArtworkService()

    private struct LookupKey: Hashable, Sendable {
        let context: String
        let ratingKey: String
        let mediaType: CinemetaArtworkRequest.MediaType
        let imdbID: String?
        let title: String?
        let year: Int?
    }

    private struct Artwork: Decodable, Sendable {
        let id: String
        let type: String?
        let poster: String?
        let background: String?
        let seasonPreviews: [Int: String]

        private enum CodingKeys: String, CodingKey { case id, type, poster, background, videos }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            type = try container.decodeIfPresent(String.self, forKey: .type)
            poster = try container.decodeIfPresent(String.self, forKey: .poster)
            background = try container.decodeIfPresent(String.self, forKey: .background)
            // Cache only one representative still per season, not every video
            // in long-running series. Optional bad video data must not break
            // otherwise valid show posters/backgrounds.
            let videos = (try? container.decode([Video].self, forKey: .videos)) ?? []
            var previews: [Int: String] = [:]
            var episodeNumbers: [Int: Int] = [:]
            for video in videos {
                guard let season = video.season, season >= 0,
                      let episode = video.episode, episode > 0,
                      let thumbnail = video.thumbnail,
                      thumbnail != poster, thumbnail != background,
                      let url = URL(string: thumbnail), url.scheme == "https",
                      url.host != nil, url.user == nil, url.password == nil,
                      episode < (episodeNumbers[season] ?? .max) else { continue }
                previews[season] = thumbnail
                episodeNumbers[season] = episode
            }
            seasonPreviews = previews
        }
    }

    private struct Video: Decodable {
        let season: Int?
        let episode: Int?
        let thumbnail: String?

        private enum CodingKeys: String, CodingKey { case season, episode, thumbnail }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            season = try? container.decode(Int.self, forKey: .season)
            episode = try? container.decode(Int.self, forKey: .episode)
            thumbnail = try? container.decode(String.self, forKey: .thumbnail)
        }
    }

    private struct Response: Decodable { let meta: Artwork? }
    private struct CatalogResponse: Decodable { let metas: [Candidate]? }
    private struct Candidate: Decodable {
        let id: String
        let type: String?
        let name: String
        let releaseInfo: String?
    }
    private struct CachedArtwork {
        let artwork: Artwork?
        let expiresAt: Date
    }

    private let session: URLSession
    private var cache: [LookupKey: CachedArtwork] = [:]
    private var inFlight: [LookupKey: Task<Artwork?, Never>] = [:]

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        session = URLSession(configuration: configuration)
    }

    func imageURL(for request: CinemetaArtworkRequest, using plexService: PlexService) async -> URL? {
        let artwork = await lookupArtwork(for: request, using: plexService)
        if request.kind == .background,
           let targetAspectRatio = request.wideHeroBannerAspectRatio,
           let imdbID = artwork?.id ?? CinemetaArtworkRequest.validIMDbID(request.imdbID) {
            switch request.mediaType {
            case .movie:
                if let banner = await FanartMovieBannerService.shared.bannerURL(imdbID: imdbID, targetAspectRatio: targetAspectRatio) { return banner }
            case .series:
                if let banner = await TVMazeBannerService.shared.bannerURL(imdbID: imdbID, targetAspectRatio: targetAspectRatio) { return banner }
            }
        }
        let path: String?
        switch request.kind {
        case .poster: path = artwork?.poster
        case .background: path = artwork?.background
        case .seasonPreview(let season): path = artwork?.seasonPreviews[season]
        }
        guard let path, let url = URL(string: path), url.scheme == "https",
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        if request.kind == .poster, url.host == "images.metahub.space",
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.path = components.path.replacingOccurrences(of: "/poster/small/", with: "/poster/medium/")
            return components.url
        }
        return url
    }

    func heroGalleryURLs(for request: CinemetaArtworkRequest, using plexService: PlexService) async -> [URL] {
        guard request.mediaType != .movie || FanartMovieBannerService.isConfigured else { return [] }
        let context = await Self.context(for: plexService)
        let artwork = await lookupArtwork(for: request, using: plexService)
        guard let imdbID = artwork?.id ?? CinemetaArtworkRequest.validIMDbID(request.imdbID) else { return [] }
        let urls: [URL]
        switch request.mediaType {
        case .movie: urls = await FanartMovieBannerService.shared.backgroundURLs(imdbID: imdbID, limit: 4)
        case .series: urls = await TVMazeBannerService.shared.backgroundURLs(imdbID: imdbID, limit: 4)
        }
        guard await Self.context(for: plexService) == context else { return [] }
        return urls
    }

    private func lookupArtwork(for request: CinemetaArtworkRequest, using plexService: PlexService) async -> Artwork? {
        let context = await Self.context(for: plexService)
        let key = LookupKey(
            context: context, ratingKey: request.ratingKey,
            mediaType: request.mediaType, imdbID: request.imdbID,
            title: request.title, year: request.year
        )
        let artwork: Artwork?
        if let cached = cache[key], cached.expiresAt > .now {
            artwork = cached.artwork
        } else if let task = inFlight[key] {
            artwork = await task.value
        } else {
            let task = Task { [session] () -> Artwork? in
                var imdbID = CinemetaArtworkRequest.validIMDbID(request.imdbID)
                var title = request.title
                var year = request.year
                var fileName: String?
                if imdbID == nil {
                    if let details = try? await plexService.getMediaDetails(ratingKey: request.ratingKey),
                       !details.isClip, details.type == (request.mediaType == .movie ? .movie : .show) {
                        imdbID = CinemetaArtworkRequest.imdbID(from: details.guids)
                        title = details.title
                        year = details.year ?? year
                        fileName = details.media.first?.parts.first?.file
                    }
                    guard await Self.context(for: plexService) == context else { return nil }
                }
                if imdbID == nil {
                    cinemetaArtworkLogger.debug("No IMDb GUID for Plex item \(request.ratingKey, privacy: .private); trying an exact title/year match")
                    for guess in Self.titleGuesses(title: title, year: year, fileName: fileName) {
                        imdbID = await Self.findIMDbID(title: guess.title, year: guess.year, type: request.mediaType, session: session)
                        if imdbID != nil { break }
                    }
                }
                guard let imdbID,
                      let url = URL(string: "https://v3-cinemeta.strem.io/meta/\(request.mediaType.rawValue)/\(imdbID).json") else {
                    cinemetaArtworkLogger.debug("No unambiguous Cinemeta identity for Plex item \(request.ratingKey, privacy: .private); using Plex artwork")
                    return nil
                }
                // This is a separate, anonymous session. No Plex credentials,
                // filenames, server addresses or watch state are sent (a title
                // recovered from a file name is sent, never the name itself).
                guard let (data, response) = try? await session.data(from: url) else {
                    cinemetaArtworkLogger.debug("Cinemeta metadata request failed; using Plex artwork")
                    return nil
                }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    cinemetaArtworkLogger.debug("Cinemeta metadata HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0, privacy: .public); using Plex artwork")
                    return nil
                }
                guard let result = try? JSONDecoder().decode(Response.self, from: data),
                      let meta = result.meta, meta.id == imdbID,
                      meta.type == nil || meta.type == request.mediaType.rawValue else {
                    cinemetaArtworkLogger.debug("Cinemeta returned unusable metadata; using Plex artwork")
                    return nil
                }
                return meta
            }
            inFlight[key] = task
            artwork = await task.value
            inFlight[key] = nil
            guard await Self.context(for: plexService) == context else { return nil }
            cache[key] = CachedArtwork(
                artwork: artwork,
                expiresAt: .now.addingTimeInterval(artwork == nil ? 300 : 86_400)
            )
            if cache.count > 512, let oldest = cache.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
                cache[oldest] = nil
            }
        }
        return artwork
    }

    func clearCache() {
        cache.removeAll()
    }

    private static func findIMDbID(
        title: String, year: Int, type: CinemetaArtworkRequest.MediaType, session: URLSession
    ) async -> String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%=&+"))
        guard let encoded = title.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://v3-cinemeta.strem.io/catalog/\(type.rawValue)/top/search=\(encoded).json"),
              let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let result = try? JSONDecoder().decode(CatalogResponse.self, from: data) else {
            cinemetaArtworkLogger.debug("Cinemeta title/year search failed; using Plex artwork")
            return nil
        }
        let matches = (result.metas ?? []).filter {
            normalizedTitle($0.name) == normalizedTitle(title) &&
                $0.releaseInfo.flatMap { Int($0.prefix(4)) } == year &&
                ($0.type == nil || $0.type == type.rawValue)
        }
        let ids = Set(matches.compactMap { CinemetaArtworkRequest.validIMDbID($0.id) })
        guard ids.count == 1 else { return nil }
        return ids.first
    }

    /// Titles to search Cinemeta with, each needing a year (only exact
    /// title/year matches are trusted). An item Plex never matched often has a
    /// title that still carries release junk ("www UIndex org - GOAT 2026
    /// 1080p"), so the cleaned title and one recovered from the file name are
    /// tried after Plex's own.
    private static func titleGuesses(title: String?, year: Int?, fileName: String?) -> [(title: String, year: Int)] {
        var guesses: [(title: String, year: Int)] = []
        func add(_ title: String?, _ year: Int?) {
            guard let title, !title.isEmpty, let year,
                  !guesses.contains(where: { $0.title == title && $0.year == year }) else { return }
            guesses.append((title, year))
        }
        add(title, year)
        if let cleaned = title.flatMap(MediaTitleCleaner.guess(from:)) {
            add(cleaned.title, cleaned.year ?? year)
        }
        if let fromFile = fileName.flatMap(MediaTitleCleaner.guess(fromFileName:)) {
            add(fromFile.title, fromFile.year ?? year)
        }
        return guesses
    }

    private static func normalizedTitle(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    @MainActor
    private static func context(for plexService: PlexService) -> String {
        [plexService.currentServerIdentifier, plexService.serverBaseURL?.absoluteString,
         plexService.activeProfileID].compactMap { $0 }.joined(separator: "|")
    }
}
