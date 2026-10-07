import Foundation
import OSLog

/// Application-key movie artwork lookup; end users never configure a key.
actor FanartMovieBannerService {
    static let shared = FanartMovieBannerService()

    static var isConfigured: Bool { projectKey != nil }

    private static var projectKey: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "DuskFanartProjectAPIKey") as? String else { return nil }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.count == 32, key.utf8.allSatisfy({ (48 ... 57).contains($0) || (65 ... 70).contains($0) || (97 ... 102).contains($0) }) else {
            return nil
        }
        return key
    }

    private struct Image: Decodable, Sendable {
        let url: String
        let lang: String?
        let likes: Int
        let width: Int
        let height: Int

        private enum CodingKeys: String, CodingKey { case url, lang, likes, width, height }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = try c.decode(String.self, forKey: .url)
            lang = try c.decodeIfPresent(String.self, forKey: .lang)
            func number(_ key: CodingKeys, fallback: Int) -> Int {
                if let value = try? c.decode(Int.self, forKey: key) { return value }
                if let value = try? c.decode(String.self, forKey: key), let number = Int(value) { return number }
                return fallback
            }
            likes = number(.likes, fallback: 0)
            width = number(.width, fallback: 1000)
            height = number(.height, fallback: 185)
        }
    }

    private struct Response: Decodable, Sendable {
        let imdb_id: String?
        let moviebanner: [Image]?
        let moviebackground: [Image]?
        let movie4kbackground: [Image]?
    }

    private struct CachedGallery {
        let response: Response?
        let expiresAt: Date
    }

    private let apiKey: String?
    private let session: URLSession
    private var cache: [String: CachedGallery] = [:]
    private var inFlight: [String: Task<Response?, Never>] = [:]

    init() {
        apiKey = Self.projectKey
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        session = URLSession(configuration: config, delegate: FanartRedirectPolicy(), delegateQueue: nil)
    }

    func bannerURL(imdbID: String, targetAspectRatio: Double) async -> URL? {
        guard let imdbID = CinemetaArtworkRequest.validIMDbID(imdbID),
              targetAspectRatio.isFinite, targetAspectRatio >= 2 else { return nil }
        let images = (await gallery(imdbID: imdbID))?.moviebanner ?? []
        let ranked = images.filter {
            $0.width >= 750 && $0.height >= 120 && Double($0.width) / Double($0.height) >= 2
        }.sorted { lhs, rhs in
            if languageRank(lhs) != languageRank(rhs) { return languageRank(lhs) < languageRank(rhs) }
            let lhsDistance = abs(log((Double(lhs.width) / Double(lhs.height)) / targetAspectRatio))
            let rhsDistance = abs(log((Double(rhs.width) / Double(rhs.height)) / targetAspectRatio))
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            if lhs.width != rhs.width { return lhs.width > rhs.width }
            if lhs.likes != rhs.likes { return lhs.likes > rhs.likes }
            return lhs.url < rhs.url
        }
        return ranked.compactMap { imageURL($0) }.first
    }

    /// Landscape gallery artwork for the Home montage; never title banners.
    func backgroundURLs(imdbID: String, limit: Int = 5) async -> [URL] {
        guard let imdbID = CinemetaArtworkRequest.validIMDbID(imdbID),
              let gallery = await gallery(imdbID: imdbID) else { return [] }
        // Prefer 1080p images for small tiles; use 4K when a title has fewer.
        let images = ((gallery.moviebackground ?? []) + (gallery.movie4kbackground ?? [])).filter {
            $0.width >= 1000 && $0.height >= 500 &&
                (1.4 ... 2.2).contains(Double($0.width) / Double($0.height))
        }.sorted { lhs, rhs in
            if languageRank(lhs) != languageRank(rhs) { return languageRank(lhs) < languageRank(rhs) }
            if lhs.width != rhs.width { return lhs.width < rhs.width }
            if lhs.likes != rhs.likes { return lhs.likes > rhs.likes }
            return lhs.url < rhs.url
        }
        var seen = Set<URL>()
        return Array(images.compactMap { imageURL($0) }.filter { seen.insert($0).inserted }.prefix(max(0, min(limit, 5))))
    }

    private func gallery(imdbID: String) async -> Response? {
        guard let apiKey else { return nil }
        if let cached = cache[imdbID], cached.expiresAt > .now {
            return cached.response
        } else if let task = inFlight[imdbID] {
            return await task.value
        } else {
            let task = Task { [session] () -> Response? in
                guard let url = URL(string: "https://webservice.fanart.tv/v3.2/movies/\(imdbID)") else { return nil }
                var request = URLRequest(url: url)
                request.setValue(apiKey, forHTTPHeaderField: "api-key")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("Dusk artwork client", forHTTPHeaderField: "User-Agent")
                guard let (data, response) = try? await session.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let result = try? JSONDecoder().decode(Response.self, from: data),
                      result.imdb_id == nil || CinemetaArtworkRequest.validIMDbID(result.imdb_id) == imdbID else {
                    cinemetaArtworkLogger.debug("Fanart.tv movie gallery unavailable; retaining the Cinemeta backdrop")
                    return nil
                }
                return result
            }
            inFlight[imdbID] = task
            let loaded = await task.value
            inFlight[imdbID] = nil
            cache[imdbID] = CachedGallery(response: loaded, expiresAt: .now.addingTimeInterval(loaded == nil ? 300 : 86_400))
            if cache.count > 512, let oldest = cache.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
                cache[oldest] = nil
            }
            return loaded
        }
    }

    private func languageRank(_ image: Image) -> Int {
        let language = (Locale.preferredLanguages.first ?? "en")
            .components(separatedBy: "-").first?.lowercased() ?? "en"
        if image.lang == "00" || image.lang == nil || image.lang == "" { return 0 }
        if image.lang == language { return 1 }
        if image.lang == "en" { return 2 }
        return 3
    }

    private func imageURL(_ image: Image) -> URL? {
        guard var components = URLComponents(string: image.url),
              components.host == "assets.fanart.tv", components.user == nil, components.password == nil else { return nil }
        components.scheme = "https"
        return components.url
    }

    func clearCache() { cache.removeAll() }
}

private final class FanartRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        // The project key is sent only to the provider's API host.
        let allowed = request.url?.scheme == "https" && request.url?.host == "webservice.fanart.tv"
        completionHandler(allowed ? request : nil)
    }
}
