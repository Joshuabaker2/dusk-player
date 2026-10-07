import Foundation
import OSLog

private let plexMatchLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "PlexMatch"
)

/// One candidate from Plex's manual match search ("Fix Match").
struct PlexMatchCandidate: Decodable, Sendable, Identifiable, Hashable {
    /// Agent GUID to match to, e.g. `plex://movie/5d77…`.
    let guid: String
    let name: String
    let year: Int?
    /// Same-name films from the same year are common ("GOAT" and two
    /// "G.O.A.T"s in 2026), so the summary and poster are what tell them apart.
    let summary: String?
    let thumb: String?
    let type: String?

    var id: String { guid }

    var displayName: String {
        year.map { "\(name) (\($0))" } ?? name
    }

    /// The candidate's poster, served publicly by Plex's image proxy. Only
    /// https URLs are used; they are loaded without Plex credentials.
    var thumbURL: URL? {
        guard let thumb, let url = URL(string: thumb), url.scheme == "https", url.host != nil else {
            return nil
        }
        return url
    }

    private enum CodingKeys: String, CodingKey {
        case guid, name, year, summary, thumb, type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guid = try container.decode(String.self, forKey: .guid)
        name = try container.decode(String.self, forKey: .name)
        // Agents send the year as a string ("2026"); tolerate numbers too.
        year = (try? container.decodeIfPresent(Int.self, forKey: .year))
            ?? (try? container.decodeIfPresent(String.self, forKey: .year)).flatMap { Int($0) }
        summary = try? container.decodeIfPresent(String.self, forKey: .summary)
        thumb = try? container.decodeIfPresent(String.self, forKey: .thumb)
        type = try? container.decodeIfPresent(String.self, forKey: .type)
    }

    /// The candidate automatic matching may apply without asking: the only one
    /// whose title and year agree with the guess. When several agree once
    /// punctuation is ignored ("GOAT" vs "G.O.A.T"), the one whose title also
    /// matches with punctuation wins; anything still ambiguous is left for the
    /// user to pick from posters.
    static func unambiguousMatch(
        in candidates: [PlexMatchCandidate],
        for guess: MediaTitleCleaner.Guess,
        type: String
    ) -> PlexMatchCandidate? {
        let wantedTitle = MediaTitleCleaner.comparableTitle(guess.title)
        let agreeing = candidates.filter { candidate in
            (candidate.type == nil || candidate.type == type)
                && MediaTitleCleaner.comparableTitle(candidate.name) == wantedTitle
                && (guess.year == nil || candidate.year == guess.year)
        }
        if agreeing.count == 1 {
            return agreeing.first
        }

        let exact = agreeing.filter {
            $0.name.compare(guess.title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        return exact.count == 1 ? exact.first : nil
    }
}

/// What to match and how to search for it.
struct PlexMatchTarget: Sendable {
    /// The item to (re)match: a movie, or a show (episodes are matched through
    /// their show).
    let ratingKey: String
    /// "movie" or "show", for messages; also the candidate type.
    let noun: String
    /// Title guesses, best first (see `MediaTitleCleaner`).
    let guesses: [MediaTitleCleaner.Guess]
    /// The library section's agent and language, so candidates come from the
    /// agent the library uses.
    let agent: String?
    let language: String?
}

extension PlexService {
    /// Whether this account can change matches on the connected server: only
    /// the owner can, and a restricted Home profile never can.
    var canChangeMatches: Bool {
        connectedServer?.owned == true && activeHomeUser?.isRestricted != true
    }

    /// Searches the library's agent for what an item could be, the same query
    /// Plex Web's Fix Match dialog makes. Results keep the agent's relevance
    /// order (they carry no score).
    func matchCandidates(
        ratingKey: String,
        title: String,
        year: Int?,
        agent: String?,
        language: String?
    ) async throws -> [PlexMatchCandidate] {
        var queryItems = [
            URLQueryItem(name: "manual", value: "1"),
            URLQueryItem(name: "title", value: title),
        ]
        if let year {
            queryItems.append(URLQueryItem(name: "year", value: String(year)))
        }
        if let agent {
            queryItems.append(URLQueryItem(name: "agent", value: agent))
        }
        if let language {
            queryItems.append(URLQueryItem(name: "language", value: language))
        }

        let data = try await rawServerRequest(
            path: "/library/metadata/\(ratingKey)/matches",
            queryItems: queryItems
        )
        let response = try decodeJSON(MatchSearchResponse.self, from: data)
        let candidates = (response.MediaContainer.SearchResult ?? []).compactMap(\.value)
        plexMatchLogger.notice(
            "Match search for \(ratingKey, privacy: .public) returned \(candidates.count, privacy: .public) candidates"
        )
        return candidates
    }

    /// Matches the item to `candidate`. Requires server-owner (or admin)
    /// rights. The server refreshes metadata in the background; use
    /// `applyMatchAndWait` to get the result.
    func applyMatch(ratingKey: String, candidate: PlexMatchCandidate) async throws {
        var queryItems = [
            URLQueryItem(name: "guid", value: candidate.guid),
            URLQueryItem(name: "name", value: candidate.name),
        ]
        if let year = candidate.year {
            queryItems.append(URLQueryItem(name: "year", value: String(year)))
        }
        _ = try await rawServerRequest(
            method: "PUT",
            path: "/library/metadata/\(ratingKey)/match",
            queryItems: queryItems
        )
        plexMatchLogger.notice("Matched \(ratingKey, privacy: .public) to \(candidate.guid, privacy: .public)")
    }

    /// Applies a match, waits for the server's refresh to land, and returns
    /// the refreshed details of `itemRatingKey` (the item being viewed or
    /// played, which may be an episode of the matched show). Nil means the
    /// server accepted the match but had not finished refreshing in time.
    func applyMatchAndWait(
        target: PlexMatchTarget,
        candidate: PlexMatchCandidate,
        itemRatingKey: String
    ) async throws -> PlexMediaDetails? {
        try await applyMatch(ratingKey: target.ratingKey, candidate: candidate)

        // A show also re-matches every episode, so allow it a while.
        for _ in 0..<20 {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return nil }
            guard let targetDetails = try? await getMediaDetails(ratingKey: target.ratingKey),
                  targetDetails.guids.contains(where: { $0.id == candidate.guid }) else {
                continue
            }
            let itemDetails = itemRatingKey == target.ratingKey
                ? targetDetails
                : try? await getMediaDetails(ratingKey: itemRatingKey)
            metadataRevision += 1
            return itemDetails
        }
        return nil
    }

    /// What a match for this item would target, or nil when it cannot be
    /// matched (clips, personal-media libraries, nothing to search with).
    func matchTarget(for details: PlexMediaDetails, fileName: String? = nil) -> PlexMatchTarget? {
        // Library items only: Live TV programs and other non-library metadata
        // have no section and cannot be matched.
        guard !details.isClip, details.librarySectionID != nil else { return nil }

        let isEpisode = details.type == .episode
        let targetRatingKey: String?
        switch details.type {
        case .movie, .show: targetRatingKey = details.ratingKey
        case .episode: targetRatingKey = details.grandparentRatingKey
        default: targetRatingKey = nil
        }
        guard let targetRatingKey else { return nil }

        let section = libraryOrder.orderedSections.first { $0.key == details.librarySectionID }
        // Personal-media libraries use the "none" agent on purpose.
        if let agent = section?.agent, agent.hasSuffix(".none") {
            return nil
        }

        let plexTitle = isEpisode ? details.grandparentTitle : details.title
        let fileName = fileName ?? details.media.first?.parts.first?.file
        var guesses: [MediaTitleCleaner.Guess] = []
        for guess in [
            plexTitle.flatMap(MediaTitleCleaner.guess(from:)),
            fileName.flatMap(MediaTitleCleaner.guess(fromFileName:)),
        ] {
            guard let guess else { continue }
            // An episode's year is its air date, not the show's.
            let year = guess.year ?? (isEpisode ? nil : details.year)
            let completed = MediaTitleCleaner.Guess(title: guess.title, year: year)
            if !guesses.contains(completed) {
                guesses.append(completed)
            }
        }
        guard !guesses.isEmpty else { return nil }

        return PlexMatchTarget(
            ratingKey: targetRatingKey,
            noun: isEpisode || details.type == .show ? "show" : "movie",
            guesses: guesses,
            agent: section?.agent,
            language: section?.language
        )
    }

    /// Matches an item Plex never identified when the right candidate is
    /// unambiguous, and returns its refreshed details. Runs at most once per
    /// item per session, and stops for the session once the server refuses a
    /// match (only the owner can change one). Ambiguous items are left alone
    /// for the user to match from posters.
    func autoMatchIfUnambiguous(_ details: PlexMediaDetails) async -> PlexMediaDetails? {
        guard details.isUnmatched, canChangeMatches, !isAutoMatchRefused,
              let target = matchTarget(for: details) else {
            return nil
        }
        let attemptKey = [currentServerIdentifier ?? "", target.ratingKey].joined(separator: "|")
        guard autoMatchAttemptKeys.insert(attemptKey).inserted else { return nil }

        for guess in target.guesses {
            guard let candidates = try? await matchCandidates(
                ratingKey: target.ratingKey,
                title: guess.title,
                year: guess.year,
                agent: target.agent,
                language: target.language
            ) else { continue }

            guard let candidate = PlexMatchCandidate.unambiguousMatch(
                in: candidates,
                for: guess,
                type: target.noun
            ) else {
                plexMatchLogger.notice(
                    "No unambiguous match for \(target.ratingKey, privacy: .public) among \(candidates.count, privacy: .public) candidates"
                )
                continue
            }

            do {
                plexMatchLogger.notice(
                    "Auto-matching \(target.ratingKey, privacy: .public) to \(candidate.guid, privacy: .public)"
                )
                return try await applyMatchAndWait(
                    target: target,
                    candidate: candidate,
                    itemRatingKey: details.ratingKey
                )
            } catch {
                isAutoMatchRefused = true
                plexMatchLogger.error(
                    "Auto-match refused; not retrying this session: \(String(describing: error), privacy: .public)"
                )
                return nil
            }
        }
        return nil
    }
}

private struct MatchSearchResponse: Decodable {
    let MediaContainer: Container

    struct Container: Decodable {
        // Lossy: these rows come from the metadata agent, and one odd entry
        // should not hide the rest.
        let SearchResult: [LossyDecodable<PlexMatchCandidate>]?
    }
}

extension PlexMediaDetails {
    /// True when Plex never identified the item: it has no agent GUIDs, only a
    /// `local://` one (or the legacy "none" agent). Provider lookups such as
    /// subtitle search key off those GUIDs, so they find nothing until the item
    /// is matched.
    var isUnmatched: Bool {
        !guids.contains { guid in
            let id = guid.id.lowercased()
            return !id.hasPrefix("local://") && !id.hasPrefix("com.plexapp.agents.none://")
        }
    }
}
