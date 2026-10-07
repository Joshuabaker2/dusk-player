import Foundation
import OSLog

/// Key-free series gallery for landscape montage panels and optional banners.
actor TVMazeBannerService {
    static let shared = TVMazeBannerService()

    private struct Show: Decodable {
        struct Externals: Decodable { let imdb: String? }
        let id: Int
        let externals: Externals
    }

    private struct GalleryImage: Decodable {
        struct Resolution: Decodable {
            let url: String
            let width: Int?
            let height: Int?
        }
        struct Resolutions: Decodable { let original: Resolution? }
        let type: String?
        let resolutions: Resolutions
    }

    private struct Banner: Sendable {
        let url: URL
        let width: Int
        let height: Int
        var aspectRatio: Double { Double(width) / Double(height) }
    }

    private struct CachedGallery {
        let banners: [Banner]
        let expiresAt: Date
    }

    private let session: URLSession
    private var cache: [String: CachedGallery] = [:]
    private var inFlight: [String: Task<[Banner]?, Never>] = [:]

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Dusk artwork client",
            "Accept": "application/json",
        ]
        session = URLSession(configuration: configuration)
    }

    func bannerURL(imdbID: String, targetAspectRatio: Double) async -> URL? {
        guard let imdbID = CinemetaArtworkRequest.validIMDbID(imdbID),
              targetAspectRatio.isFinite, targetAspectRatio >= 2 else { return nil }
        let banners = await gallery(imdbID: imdbID).filter { $0.aspectRatio >= 2 }
        let ranked = banners.sorted { lhs, rhs in
            let lhsDistance = abs(log(lhs.aspectRatio / targetAspectRatio))
            let rhsDistance = abs(log(rhs.aspectRatio / targetAspectRatio))
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            if lhs.width != rhs.width { return lhs.width > rhs.width }
            return lhs.url.absoluteString < rhs.url.absoluteString
        }
        guard let banner = ranked.first else { return nil }
        cinemetaArtworkLogger.debug("Selected TVmaze hero banner \(banner.width, privacy: .public)×\(banner.height, privacy: .public)")
        return banner.url
    }

    func backgroundURLs(imdbID: String, limit: Int = 4) async -> [URL] {
        guard let imdbID = CinemetaArtworkRequest.validIMDbID(imdbID) else { return [] }
        let images = await gallery(imdbID: imdbID).filter { $0.height >= 400 && $0.aspectRatio <= 2.2 }
        let sorted = images.sorted {
            if $0.width != $1.width { return $0.width > $1.width }
            return $0.url.absoluteString < $1.url.absoluteString
        }
        var seen = Set<URL>()
        return Array(sorted.map(\.url).filter { seen.insert($0).inserted }.prefix(max(0, min(limit, 4))))
    }

    private func gallery(imdbID: String) async -> [Banner] {
        let banners: [Banner]
        if let cached = cache[imdbID], cached.expiresAt > .now {
            banners = cached.banners
        } else if let task = inFlight[imdbID] {
            banners = await task.value ?? []
        } else {
            let task = Task { [session] () -> [Banner]? in
                guard let lookupURL = URL(string: "https://api.tvmaze.com/lookup/shows?imdb=\(imdbID)"),
                      let (showData, showResponse) = try? await session.data(from: lookupURL),
                      (showResponse as? HTTPURLResponse)?.statusCode == 200,
                      let show = try? JSONDecoder().decode(Show.self, from: showData),
                      show.externals.imdb == imdbID,
                      let galleryURL = URL(string: "https://api.tvmaze.com/shows/\(show.id)/images"),
                      let (data, response) = try? await session.data(from: galleryURL),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let images = try? JSONDecoder().decode([GalleryImage].self, from: data) else {
                    cinemetaArtworkLogger.debug("TVmaze gallery lookup failed; retaining the Cinemeta backdrop")
                    return nil
                }
                return images.compactMap { image in
                    guard image.type == nil || image.type == "banner" || image.type == "background",
                          let original = image.resolutions.original,
                          let width = original.width, let height = original.height,
                          width >= 750, height >= 120,
                          Double(width) / Double(height) >= 1.4,
                          let url = URL(string: original.url), url.scheme == "https",
                          url.host != nil, url.user == nil, url.password == nil else { return nil }
                    return Banner(url: url, width: width, height: height)
                }
            }
            inFlight[imdbID] = task
            let loaded = await task.value
            inFlight[imdbID] = nil
            banners = loaded ?? []
            cache[imdbID] = CachedGallery(
                banners: banners,
                expiresAt: .now.addingTimeInterval(loaded == nil ? 300 : 86_400)
            )
            if cache.count > 512, let oldest = cache.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
                cache[oldest] = nil
            }
        }
        return banners
    }

    func clearCache() {
        cache.removeAll()
    }
}
