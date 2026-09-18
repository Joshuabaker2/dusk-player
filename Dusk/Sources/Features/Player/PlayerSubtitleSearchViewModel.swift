import Foundation
import OSLog

private let subtitleSearchLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "SubtitleSearch"
)

/// Drives the in-player "Find More…" subtitle search: asks the Plex server to
/// search its providers, downloads the chosen result, and waits for the new
/// sidecar stream to show up on the item.
@MainActor
@Observable
final class PlayerSubtitleSearchViewModel {
    /// What the caller needs to start playing the freshly downloaded subtitle.
    struct DownloadOutcome: Sendable {
        let details: PlexMediaDetails
        let part: PlexMediaPart?
        let newSubtitleStreamID: Int?
    }

    var language: String {
        didSet {
            guard language != oldValue else { return }
            Task { await load() }
        }
    }

    private(set) var results: [PlexSubtitleSearchResult] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    /// The result currently being downloaded, so its row can show progress.
    private(set) var downloadingKey: String?
    private(set) var actionErrorMessage: String?

    /// How long to keep re-fetching metadata waiting for the sidecar to appear.
    /// The PUT only means the server accepted the job; the file lands a moment
    /// later, and a short poll is nicer than making the user retry by hand.
    private static let downloadPollAttempts = 8
    private static let downloadPollInterval: Duration = .milliseconds(700)

    private let plexService: PlexService
    private let ratingKey: String
    private let knownSubtitleStreamIDs: Set<Int>

    init(
        plexService: PlexService,
        ratingKey: String,
        language: String,
        knownSubtitleStreamIDs: Set<Int>
    ) {
        self.plexService = plexService
        self.ratingKey = ratingKey
        self.language = language
        self.knownSubtitleStreamIDs = knownSubtitleStreamIDs
    }

    /// Keeps decoder internals out of the UI. `PlexServiceError.decodingError`
    /// carries `String(describing:)` of the underlying `DecodingError`, which is
    /// a paragraph of type/keyPath detail — useful in the log, unreadable in a
    /// sheet, and long enough to push the retry button off screen. Any message
    /// is also length-bounded so a verbose network error cannot do the same.
    private static func userFacingMessage(for error: Error, fallback: String) -> String {
        let message: String
        if let plexError = error as? PlexServiceError {
            switch plexError {
            case .decodingError:
                message = "Couldn't read the response from your Plex server."
            default:
                message = plexError.localizedDescription
            }
        } else {
            message = fallback
        }

        guard message.count > 180 else { return message }
        return message.prefix(180).trimmingCharacters(in: .whitespaces) + "…"
    }

    func clearActionError() {
        actionErrorMessage = nil
    }

    func load() async {
        isLoading = true
        errorMessage = nil

        do {
            results = try await plexService.searchSubtitles(
                ratingKey: ratingKey,
                language: language
            )
        } catch {
            results = []
            errorMessage = Self.userFacingMessage(for: error, fallback: "Couldn't search for subtitles.")
            subtitleSearchLogger.error(
                "Subtitle search failed: \(String(describing: error), privacy: .public)"
            )
        }

        isLoading = false
    }

    func download(_ result: PlexSubtitleSearchResult) async -> DownloadOutcome? {
        guard downloadingKey == nil else { return nil }

        downloadingKey = result.key
        actionErrorMessage = nil
        defer { downloadingKey = nil }

        do {
            try await plexService.downloadSubtitle(ratingKey: ratingKey, key: result.key)
        } catch {
            actionErrorMessage = Self.userFacingMessage(for: error, fallback: "Couldn't download this subtitle.")
            subtitleSearchLogger.error(
                "Subtitle download failed: \(String(describing: error), privacy: .public)"
            )
            return nil
        }

        for attempt in 0..<Self.downloadPollAttempts {
            if attempt > 0 {
                try? await Task.sleep(for: Self.downloadPollInterval)
            }
            guard !Task.isCancelled else { return nil }

            guard let details = try? await plexService.getMediaDetails(ratingKey: ratingKey) else {
                continue
            }

            let part = details.media.first?.parts.first
            let subtitleStreams = part?.streams.filter { $0.streamType == .subtitle && $0.key != nil } ?? []
            guard let newStream = subtitleStreams.first(where: {
                !knownSubtitleStreamIDs.contains($0.id)
            }) else {
                continue
            }

            subtitleSearchLogger.notice(
                "Downloaded subtitle appeared as stream \(newStream.id, privacy: .public) after \(attempt + 1, privacy: .public) checks"
            )
            return DownloadOutcome(
                details: details,
                part: part,
                newSubtitleStreamID: newStream.id
            )
        }

        actionErrorMessage = "The server accepted the subtitle but it hasn't appeared yet. Try the picker again in a moment."
        return nil
    }
}
