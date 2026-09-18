import Foundation

/// One on-demand subtitle candidate returned by the Plex server's subtitle
/// search (`/library/metadata/{ratingKey}/subtitles`). These are *not* streams
/// on the media yet — the server downloads and attaches one as a sidecar when
/// asked, at which point it shows up as a `PlexStream` with a non-nil `key`.
///
/// Decoding is deliberately permissive: these values are relayed from a
/// third-party provider (OpenSubtitles) rather than produced by Plex's own
/// library scanner, and the same field arrives as a number on one result and a
/// string on the next.
struct PlexSubtitleSearchResult: Decodable, Sendable, Identifiable, Hashable {
    /// Opaque provider key, e.g. `com.plexapp.agents.opensubtitles://…`. This
    /// is what the download call echoes back to the server, and it is the only
    /// field guaranteed unique across results.
    let key: String
    /// The subtitle file name as published by the provider. This is the line
    /// users actually scan when picking a release-matched subtitle.
    let title: String?
    /// Where the subtitle came from, e.g. "Open Subtitles".
    let providerTitle: String?
    /// Plex names this `score`, but it carries the provider's download count —
    /// the popularity signal shown next to each result.
    let score: Int?
    let format: String?
    let codec: String?
    let language: String?
    let languageCode: String?
    let hearingImpaired: Bool?
    let forced: Bool?
    /// Set when the provider considers this an exact match for the file.
    let perfectMatch: Bool?

    var id: String { key }

    var displayTitle: String {
        title?.nilIfEmpty ?? language?.nilIfEmpty ?? "Subtitle"
    }

    var isHearingImpaired: Bool { hearingImpaired ?? false }
    var isForced: Bool { forced ?? false }
    var isPerfectMatch: Bool { perfectMatch ?? false }

    /// Uppercased container/codec label (e.g. "SRT"), when the server sends one.
    var formatLabel: String? {
        (format?.nilIfEmpty ?? codec?.nilIfEmpty)?.uppercased()
    }

    enum CodingKeys: String, CodingKey {
        case key, title, providerTitle, score, format, codec
        case language, languageCode, hearingImpaired, forced, perfectMatch
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        providerTitle = try container.decodeIfPresent(String.self, forKey: .providerTitle)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        codec = try container.decodeIfPresent(String.self, forKey: .codec)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        languageCode = try container.decodeIfPresent(String.self, forKey: .languageCode)

        score = Self.decodeNumberish(container: container, key: .score)
        hearingImpaired = Self.decodeBoolish(container: container, key: .hearingImpaired)
        forced = Self.decodeBoolish(container: container, key: .forced)
        perfectMatch = Self.decodeBoolish(container: container, key: .perfectMatch)
    }

    /// Providers serialize the download count as a number on some results and a
    /// quoted string on others.
    private static func decodeNumberish(
        container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Int(value)
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int(value) ?? Double(value).map(Int.init)
        }
        return nil
    }

    /// Same tolerance as `PlexStream.decodeBoolish`, plus the string forms
    /// ("1"/"0"/"true") this endpoint has been seen to use.
    private static func decodeBoolish(
        container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Bool? {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value != 0
        }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            switch value.lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: return nil
            }
        }
        return nil
    }
}
