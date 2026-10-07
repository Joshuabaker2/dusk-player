import Foundation
import OSLog

private let subtitleSearchLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "SubtitleSearch"
)

/// Drives the in-player "Find More…" subtitle search: asks the Plex server to
/// search its providers, downloads the chosen result, and waits for the new
/// sidecar stream to show up on the item. For an item Plex never matched, it
/// also offers match candidates found from a cleaned-up title.
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

    /// True while the item has no agent match; cleared once a match lands.
    private(set) var isUnmatched: Bool
    private(set) var matchCandidates: [PlexMatchCandidate] = []
    /// The title guess the candidates were found with.
    private(set) var matchQuery: MediaTitleCleaner.Guess?
    private(set) var isSearchingMatches = false
    /// The candidate being applied, so its row can show progress.
    private(set) var matchingGUID: String?

    /// How long to keep re-fetching metadata waiting for the sidecar to appear.
    /// The PUT only means the server accepted the job; the file lands a moment
    /// later, and a short poll is nicer than making the user retry by hand.
    private static let downloadPollAttempts = 8
    private static let downloadPollInterval: Duration = .milliseconds(700)

    private let plexService: PlexService
    private let ratingKey: String
    private let knownSubtitleStreamIDs: Set<Int>
    private let sourcePartID: Int?
    private let matchTarget: PlexMatchTarget?
    private var hasLoadedMatchCandidates = false

    /// "movie" or "show": what a match applies to.
    var matchNoun: String { matchTarget?.noun ?? "item" }

    init(
        plexService: PlexService,
        ratingKey: String,
        language: String,
        knownSubtitleStreamIDs: Set<Int>,
        sourcePartID: Int? = nil,
        matchTarget: PlexMatchTarget? = nil
    ) {
        self.plexService = plexService
        self.ratingKey = ratingKey
        self.language = language
        self.knownSubtitleStreamIDs = knownSubtitleStreamIDs
        self.sourcePartID = sourcePartID
        self.matchTarget = matchTarget
        self.isUnmatched = matchTarget != nil
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

        if isUnmatched, results.isEmpty, !hasLoadedMatchCandidates {
            await loadMatchCandidates()
        }
    }

    /// Tries each title guess until the agent recognizes one. Read-only: nothing
    /// changes on the server until the user picks a candidate.
    private func loadMatchCandidates() async {
        guard let matchTarget else { return }
        hasLoadedMatchCandidates = true
        isSearchingMatches = true
        defer { isSearchingMatches = false }

        for guess in matchTarget.guesses {
            do {
                let candidates = try await plexService.matchCandidates(
                    ratingKey: matchTarget.ratingKey,
                    title: guess.title,
                    year: guess.year,
                    agent: matchTarget.agent,
                    language: matchTarget.language
                )
                matchQuery = guess
                if !candidates.isEmpty {
                    matchCandidates = Array(candidates.prefix(Self.maximumMatchCandidates))
                    return
                }
            } catch {
                subtitleSearchLogger.error(
                    "Match search failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    private static let maximumMatchCandidates = 8

    /// Matches the item in Plex, waits for the refreshed metadata, then
    /// searches again. Returns the refreshed details so the session can adopt
    /// the new title and IDs.
    func applyMatch(_ candidate: PlexMatchCandidate) async -> PlexMediaDetails? {
        guard let matchTarget, matchingGUID == nil else { return nil }

        matchingGUID = candidate.guid
        actionErrorMessage = nil
        defer { matchingGUID = nil }

        let details: PlexMediaDetails?
        do {
            details = try await plexService.applyMatchAndWait(
                target: matchTarget,
                candidate: candidate,
                itemRatingKey: ratingKey
            )
        } catch {
            actionErrorMessage = Self.userFacingMessage(
                for: error,
                fallback: "Couldn't match this \(matchTarget.noun). Changing a match needs the server owner's account."
            )
            subtitleSearchLogger.error("Match failed: \(String(describing: error), privacy: .public)")
            return nil
        }

        guard let details else {
            actionErrorMessage = "Plex accepted the match but is still updating this \(matchTarget.noun). Try searching again in a moment."
            return nil
        }

        isUnmatched = false
        matchCandidates = []
        await load()
        return details
    }

    /// Background playback never opens the search UI or changes the item's
    /// match. Download count is the primary ranking; ties keep Plex's order.
    func downloadMostPopularSubtitle() async -> DownloadOutcome? {
        do {
            let candidates = try await plexService.searchSubtitles(
                ratingKey: ratingKey,
                language: language,
                forced: .onlyExcluded
            )
            guard !Task.isCancelled else { return nil }
            let eligible = candidates.filter {
                !$0.isForced
                    && ($0.languageCode == nil || PlayerViewModel.normalizedLanguageCode($0.languageCode)
                        == PlayerViewModel.normalizedLanguageCode(language))
                    && SubtitleCueParser.isSupportedFormat($0.codec ?? $0.format)
            }
            let best = eligible.enumerated().sorted {
                let lhsDownloads = $0.element.score ?? 0
                let rhsDownloads = $1.element.score ?? 0
                return lhsDownloads == rhsDownloads ? $0.offset < $1.offset : lhsDownloads > rhsDownloads
            }.first?.element
            guard let best else { return nil }
            return await download(best)
        } catch {
            if !Task.isCancelled {
                subtitleSearchLogger.notice("Automatic subtitle search was unavailable")
            }
            return nil
        }
    }

    func download(_ result: PlexSubtitleSearchResult) async -> DownloadOutcome? {
        guard !Task.isCancelled, downloadingKey == nil else { return nil }

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

            guard !Task.isCancelled else { return nil }
            let parts = details.media.flatMap(\.parts)
            let part: PlexMediaPart?
            if let sourcePartID {
                part = parts.first(where: { $0.id == sourcePartID })
            } else {
                part = parts.first
            }
            let subtitleStreams = part?.streams.filter { $0.streamType == .subtitle && $0.key != nil } ?? []
            guard let newStream = subtitleStreams.first(where: {
                !knownSubtitleStreamIDs.contains($0.id)
                    && (($0.languageCode ?? $0.languageTag) == nil
                        || PlayerViewModel.normalizedLanguageCode($0.languageCode ?? $0.languageTag)
                            == PlayerViewModel.normalizedLanguageCode(language))
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
