import SwiftUI
import ImageIO
#if canImport(UIKit)
import UIKit
#endif

enum DuskAsyncImagePhase {
    case empty
    case success(Image)
    case failure(any Error)
}

struct DuskArtworkLoadID: Hashable {
    let url: URL?
    let request: CinemetaArtworkRequest?
    let usesCinemeta: Bool
}

struct DuskAsyncImage<Content: View>: View {
    @Environment(PlexService.self) private var plexService
    @Environment(UserPreferences.self) private var preferences

    let url: URL?
    var artworkRequest: CinemetaArtworkRequest? = nil
    @ViewBuilder let content: (DuskAsyncImagePhase) -> Content

    @State private var phase = DuskAsyncImagePhase.empty

    var body: some View {
        content(phase)
            .task(id: DuskArtworkLoadID(url: url, request: artworkRequest, usesCinemeta: artworkRequest != nil && preferences.cinemetaArtworkEnabled)) {
                await loadImage()
            }
    }

    @MainActor
    private func loadImage() async {
        guard url != nil || (preferences.cinemetaArtworkEnabled && artworkRequest != nil) else {
            phase = .empty
            return
        }

        phase = .empty

        do {
            let image = try await DuskImageLoader.shared.artworkImage(
                fallbackURL: url, request: artworkRequest,
                usesCinemeta: preferences.cinemetaArtworkEnabled, using: plexService
            )
            guard !Task.isCancelled else { return }
            phase = .success(Image(uiImage: image))
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failure(error)
        }
    }
}

actor DuskImageLoader {
    static let shared = DuskImageLoader()

    private let session: URLSession
    #if canImport(UIKit)
    private let memoryCache = NSCache<NSURL, CachedMemoryImage>()
    #endif
    private var inFlightTasks: [URL: Task<LoadedImage, Error>] = [:]
    private var failedCinemetaImages: [URL: Date] = [:]

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = AppImageCache.shared
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12

        session = URLSession(configuration: configuration)
        #if canImport(UIKit)
        memoryCache.countLimit = 512
        memoryCache.totalCostLimit = 64 * 1024 * 1024
        #endif
    }

    func artworkImage(
        fallbackURL: URL?, request: CinemetaArtworkRequest?,
        usesCinemeta: Bool, using plexService: PlexService
    ) async throws -> UIImage {
        try Task.checkCancellation()
        if usesCinemeta, fallbackURL?.isFileURL != true, let request,
           let url = await CinemetaArtworkService.shared.imageURL(for: request, using: plexService) {
            try Task.checkCancellation()
            if failedCinemetaImages[url].map({ $0 > .now }) != true {
                do {
                    // External artwork never goes through Plex authentication.
                    let image = try await image(for: url)
                    try Task.checkCancellation()
                    cinemetaArtworkLogger.debug("Loaded online artwork for Plex item \(request.ratingKey, privacy: .private)")
                    return image
                } catch {
                    try Task.checkCancellation()
                    cinemetaArtworkLogger.debug("Online artwork image request failed with code \((error as NSError).code, privacy: .public); trying fallback artwork")
                    failedCinemetaImages[url] = .now.addingTimeInterval(300)
                    if failedCinemetaImages.count > 256 {
                        failedCinemetaImages = failedCinemetaImages.filter { $0.value > .now }
                        if failedCinemetaImages.count > 256 { failedCinemetaImages.removeAll() }
                    }
                }
            }
        }
        try Task.checkCancellation()
        if usesCinemeta, var request, request.wideHeroBannerAspectRatio != nil {
            request.wideHeroBannerAspectRatio = nil
            return try await artworkImage(fallbackURL: fallbackURL, request: request, usesCinemeta: true, using: plexService)
        }
        guard let fallbackURL else { throw URLError(.badURL) }
        return try await image(for: fallbackURL, using: plexService)
    }

    func clearMemoryCache() {
        memoryCache.removeAllObjects()
        failedCinemetaImages.removeAll()
    }

    func image(for url: URL, using plexService: PlexService? = nil, maximumPixelSize: Int? = nil) async throws -> UIImage {
        // Thumbnail variants have separate memory/in-flight keys, while HTTP
        // and disk caching continue to use the original authenticated URL.
        let cacheURL = maximumPixelSize.flatMap {
            URL(string: url.absoluteString + "#dusk-thumbnail-\(max($0, 1))")
        } ?? url
        #if canImport(UIKit)
        let cacheKey = cacheURL as NSURL
        if let cachedImage = memoryCache.object(forKey: cacheKey) {
            if cachedImage.isFresh {
                return cachedImage.image
            }
            memoryCache.removeObject(forKey: cacheKey)
        }
        #endif

        if url.isFileURL {
            let data = try Data(contentsOf: url)
            guard let image = Self.decodeImage(data, maximumPixelSize: maximumPixelSize) else {
                throw URLError(.cannotDecodeContentData)
            }
            #if canImport(UIKit)
            let cachedImage = CachedMemoryImage(image: image)
            memoryCache.setObject(cachedImage, forKey: cacheKey, cost: cachedImage.memoryCost)
            #endif
            return image
        }

        if let task = inFlightTasks[cacheURL] {
            return try await task.value.image
        }

        let task = Task<LoadedImage, Error> { [session] in
            let request = URLRequest(
                url: url,
                cachePolicy: .returnCacheDataElseLoad,
                timeoutInterval: plexService == nil ? 8 : 30
            )

            if let cachedResponse = AppImageCache.cachedResponse(for: request),
               let cachedImage = Self.decodeImage(cachedResponse.data, maximumPixelSize: maximumPixelSize) {
                return LoadedImage(
                    image: cachedImage,
                    cachedAt: AppImageCache.cachedAt(for: cachedResponse) ?? .now
                )
            }

            let data: Data
            if let plexService {
                data = try await plexService.imageData(for: url)
            } else {
                let (fetchedData, response) = try await session.data(for: request)

                if let httpResponse = response as? HTTPURLResponse,
                   !(200...299).contains(httpResponse.statusCode) {
                    throw URLError(.badServerResponse)
                }

                data = fetchedData
            }

            guard let image = Self.decodeImage(data, maximumPixelSize: maximumPixelSize) else {
                throw URLError(.cannotDecodeContentData)
            }

            if let cachedResponse = URLCache.shared.cachedResponse(for: request) {
                AppImageCache.storeCachedResponse(cachedResponse, for: request)
            }
            return LoadedImage(image: image)
        }

        inFlightTasks[cacheURL] = task

        do {
            let loadedImage = try await task.value
            #if canImport(UIKit)
            let cachedImage = CachedMemoryImage(image: loadedImage.image, cachedAt: loadedImage.cachedAt)
            memoryCache.setObject(cachedImage, forKey: cacheKey, cost: cachedImage.memoryCost)
            #endif
            inFlightTasks[cacheURL] = nil
            return loadedImage.image
        } catch {
            inFlightTasks[cacheURL] = nil
            throw error
        }
    }

    private nonisolated static func decodeImage(_ data: Data, maximumPixelSize: Int?) -> UIImage? {
        guard let maximumPixelSize else { return UIImage(data: data) }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(maximumPixelSize, 1),
                kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

#if canImport(UIKit)
private struct LoadedImage: @unchecked Sendable {
    let image: UIImage
    let cachedAt: Date

    init(image: UIImage, cachedAt: Date = .now) {
        self.image = image
        self.cachedAt = cachedAt
    }
}

private final class CachedMemoryImage: @unchecked Sendable {
    let image: UIImage
    let cachedAt: Date

    init(image: UIImage, cachedAt: Date = .now) {
        self.image = image
        self.cachedAt = cachedAt
    }

    var isFresh: Bool {
        Date().timeIntervalSince(cachedAt) <= AppImageCache.maxAge
    }

    var memoryCost: Int {
        guard let image = image.cgImage else { return 0 }
        return image.bytesPerRow * image.height
    }
}
#endif
