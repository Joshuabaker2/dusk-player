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
    /// Plex's confidence, 0–100.
    let score: Int?

    var id: String { guid }

    var displayName: String {
        year.map { "\(name) (\($0))" } ?? name
    }

    private enum CodingKeys: String, CodingKey {
        case guid, name, year, score
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guid = try container.decode(String.self, forKey: .guid)
        name = try container.decode(String.self, forKey: .name)
        // Agents have sent both numbers and strings here.
        year = (try? container.decodeIfPresent(Int.self, forKey: .year))
            ?? (try? container.decodeIfPresent(String.self, forKey: .year)).flatMap { Int($0) }
        score = (try? container.decodeIfPresent(Int.self, forKey: .score))
            ?? (try? container.decodeIfPresent(String.self, forKey: .score)).flatMap { Int($0) }
    }
}

extension PlexService {
    /// Searches the library's agent for what an item could be, the same query
    /// Plex Web's Fix Match dialog makes.
    ///
    /// `agent` and `language` should be the item's library section values;
    /// without them the server falls back to its defaults, which may be a
    /// different agent than the library uses.
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
        return candidates.sorted { ($0.score ?? 0) > ($1.score ?? 0) }
    }

    /// Matches the item to `candidate`. The server refreshes its metadata in
    /// the background, so the new GUIDs show up on a later metadata fetch.
    /// Requires server-owner (or admin) rights.
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
