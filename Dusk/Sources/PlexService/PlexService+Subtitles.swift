import Foundation
import OSLog

private let plexSubtitlesLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "PlexSubtitles"
)

extension PlexService {
    /// Search options mirroring the Plex server's on-demand subtitle search.
    enum SubtitleSearchMatchOption: Int, Sendable {
        case preferExcluded = 0
        case preferIncluded = 1
        case onlyIncluded = 2
        case onlyExcluded = 3
    }

    /// Asks the server to search its subtitle providers (OpenSubtitles) for the
    /// item. The server does the matching by title/season/episode and file
    /// hash — the client only supplies the language and the SDH/forced policy.
    ///
    /// Requires subtitle search to be available server-side (Plex Pass with the
    /// provider configured). When it is not, servers answer with an empty list
    /// rather than an error, so callers must treat "no results" as expected.
    func searchSubtitles(
        ratingKey: String,
        language: String,
        hearingImpaired: SubtitleSearchMatchOption = .preferExcluded,
        forced: SubtitleSearchMatchOption = .preferExcluded
    ) async throws -> [PlexSubtitleSearchResult] {
        let data = try await rawServerRequest(
            path: "/library/metadata/\(ratingKey)/subtitles",
            queryItems: [
                URLQueryItem(name: "language", value: language),
                URLQueryItem(name: "hearingImpaired", value: String(hearingImpaired.rawValue)),
                URLQueryItem(name: "forced", value: String(forced.rawValue)),
            ]
        )

        // Lossy elements: these rows come from a third-party provider via Plex,
        // so one malformed entry must not fail the whole search.
        let response = try decodeJSON(
            StreamResponse<LossyDecodable<PlexSubtitleSearchResult>>.self,
            from: data
        )
        let decoded = response.MediaContainer.Stream ?? []
        let results = decoded.compactMap(\.value)
        if results.count != decoded.count {
            plexSubtitlesLogger.notice(
                "Skipped \(decoded.count - results.count, privacy: .public) unreadable subtitle search results"
            )
        }
        plexSubtitlesLogger.notice(
            "Subtitle search for \(ratingKey, privacy: .public) language=\(language, privacy: .public) returned \(results.count, privacy: .public) results"
        )
        return results
    }

    /// Tells the server to fetch a searched subtitle and attach it to the item
    /// as a sidecar stream. The server does the downloading, so success here
    /// only means it accepted the request — the new stream appears on a
    /// subsequent metadata fetch, not necessarily immediately.
    func downloadSubtitle(ratingKey: String, key: String) async throws {
        _ = try await rawServerRequest(
            method: "PUT",
            path: "/library/metadata/\(ratingKey)/subtitles",
            queryItems: [URLQueryItem(name: "key", value: key)]
        )
        plexSubtitlesLogger.notice(
            "Requested subtitle download for \(ratingKey, privacy: .public)"
        )
    }

    /// Fetches the bytes of a sidecar subtitle stream. `streamKey` is the
    /// `key` of a subtitle `PlexStream` (e.g. `/library/streams/1234`), which
    /// Plex serves as the raw subtitle file.
    func subtitleFileData(streamKey: String) async throws -> Data {
        if preferredServerToken == nil {
            try await recoverServerAuthorizationIfPossible()
        }

        do {
            return try await sendSubtitleFileRequest(streamKey: streamKey)
        } catch let error as PlexServiceError where error == .unauthorized {
            try await recoverServerAuthorizationIfPossible()
            return try await sendSubtitleFileRequest(streamKey: streamKey)
        }
    }

    private func sendSubtitleFileRequest(streamKey: String) async throws -> Data {
        guard let baseURL = serverBaseURL else {
            throw PlexServiceError.noServerConnected
        }

        guard let serverToken = preferredServerToken else {
            throw isAuthenticationFresh ? PlexServiceError.authenticationPending : PlexServiceError.unauthorized
        }

        guard let url = buildURL(base: baseURL.absoluteString, path: streamKey) else {
            throw PlexServiceError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .returnCacheDataElseLoad
        applyHeaders(to: &request, token: serverToken)
        // The shared headers ask for JSON; this endpoint returns a subtitle
        // file, and some servers honor Accept strictly enough to 406 on it.
        request.setValue("text/plain,application/octet-stream,*/*", forHTTPHeaderField: "Accept")

        return try await executeRequest(request)
    }
}
