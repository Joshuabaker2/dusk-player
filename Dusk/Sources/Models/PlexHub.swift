import Foundation

/// A "hub" on the Plex home screen (e.g. "Continue Watching", "Recently Added Movies").
/// Returned from `GET /hubs`, `GET /hubs/sections/{sectionId}`, and `GET /hubs/search`.
struct PlexHub: Decodable, Sendable, Identifiable, Hashable {
    var id: String { hubIdentifier ?? title }

    let key: String?
    let title: String
    let type: String?
    let hubIdentifier: String?
    let size: Int?
    let more: Bool?
    /// Section this row belongs to. Present on `GET /hubs` rows that come from a
    /// library; absent on global rows such as Continue Watching.
    let librarySectionID: String?
    let librarySectionTitle: String?
    let items: [PlexItem]

    enum CodingKeys: String, CodingKey {
        case key, title, type, hubIdentifier, size, more
        case librarySectionID, librarySectionTitle
        case metadata = "Metadata"
        case directories = "Directory"
    }

    /// `librarySectionID` and `librarySectionTitle` are required parameters on
    /// purpose: every call site has to decide what it means by them. Prefer
    /// `replacingItems(_:)` over calling this directly.
    init(
        key: String?,
        title: String,
        type: String?,
        hubIdentifier: String?,
        size: Int?,
        more: Bool?,
        librarySectionID: String?,
        librarySectionTitle: String?,
        items: [PlexItem]
    ) {
        self.key = key
        self.title = title
        self.type = type
        self.hubIdentifier = hubIdentifier
        self.size = size
        self.more = more
        self.librarySectionID = librarySectionID
        self.librarySectionTitle = librarySectionTitle
        self.items = items
    }

    /// The `/library/sections` key this hub belongs to.
    ///
    /// Falls back to the numeric suffix Plex appends to per-library hub
    /// identifiers (`movie.recentlyadded.3` -> `"3"`), which older servers send
    /// even when `librarySectionID` is missing from the payload. Global rows
    /// (`home.continue`, `home.ondeck`) have neither and resolve to nil.
    var resolvedLibrarySectionID: String? {
        if let librarySectionID = librarySectionID?.nilIfEmpty {
            return librarySectionID
        }
        guard let hubIdentifier,
              let suffix = hubIdentifier.split(separator: ".").last,
              !suffix.isEmpty,
              suffix.allSatisfy(\.isNumber) else { return nil }
        return String(suffix)
    }

    /// Same hub with a different item list; every other field is preserved.
    /// Use this instead of the memberwise init so new fields never get dropped.
    func replacingItems(_ items: [PlexItem]) -> PlexHub {
        PlexHub(
            key: key,
            title: title,
            type: type,
            hubIdentifier: hubIdentifier,
            size: size,
            more: more,
            librarySectionID: librarySectionID,
            librarySectionTitle: librarySectionTitle,
            items: items
        )
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        title = try container.decode(String.self, forKey: .title)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        hubIdentifier = try container.decodeIfPresent(String.self, forKey: .hubIdentifier)
        size = try container.decodeIfPresent(Int.self, forKey: .size)
        more = try container.decodeIfPresent(Bool.self, forKey: .more) ??
            (try container.decodeIfPresent(Int.self, forKey: .more).map { $0 != 0 })
        // Plex serializes librarySectionID as a number; tolerate strings too.
        if let numericSectionID = try? container.decodeIfPresent(Int.self, forKey: .librarySectionID) {
            librarySectionID = String(numericSectionID)
        } else {
            librarySectionID = (try? container.decodeIfPresent(String.self, forKey: .librarySectionID)) ?? nil
        }
        librarySectionTitle = try container.decodeIfPresent(String.self, forKey: .librarySectionTitle)

        let metadataItems = try container.decodeLossyPlexItemsIfPresent(forKey: .metadata)
        let directoryItems = try container.decodeLossyPlexItemsIfPresent(forKey: .directories)
        items = metadataItems + directoryItems
    }
}

private extension KeyedDecodingContainer where Key == PlexHub.CodingKeys {
    func decodeLossyPlexItemsIfPresent(forKey key: Key) throws -> [PlexItem] {
        guard contains(key), try !decodeNil(forKey: key) else { return [] }
        return try decode(LossyPlexItemArray.self, forKey: key).items
    }
}

private struct LossyPlexItemArray: Decodable {
    let items: [PlexItem]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var items: [PlexItem] = []

        while !container.isAtEnd {
            do {
                items.append(try container.decode(PlexItem.self))
            } catch {
                // Plex short-search responses can include suggestion directories that do not
                // conform to the media item shape the UI expects.
                _ = try container.decode(IgnoredJSONValue.self)
            }
        }

        self.items = items
    }
}

private struct IgnoredJSONValue: Decodable {
    init(from decoder: Decoder) throws {
        if var container = try? decoder.unkeyedContainer() {
            while !container.isAtEnd {
                _ = try container.decode(IgnoredJSONValue.self)
            }
            return
        }

        if let container = try? decoder.container(keyedBy: DynamicCodingKey.self) {
            for key in container.allKeys {
                _ = try container.decode(IgnoredJSONValue.self, forKey: key)
            }
            return
        }

        let container = try decoder.singleValueContainer()

        if container.decodeNil() { return }
        if (try? container.decode(Bool.self)) != nil { return }
        if (try? container.decode(Int.self)) != nil { return }
        if (try? container.decode(Double.self)) != nil { return }
        if (try? container.decode(String.self)) != nil { return }

        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
