import Foundation

/// Pure functions that translate between the Plex account's flat
/// `pinnedSources` list and the connected server's `/library/sections` order.
///
/// Everything here is deliberately side-effect free so the rules stay testable
/// and readable; `LibraryOrderStore` and `PlexService+LibraryOrder` own all the
/// state and networking.
enum LibraryOrderArrangement {
    /// The order Dusk shows libraries in.
    ///
    /// Sections pinned for this server come first, in the account's sidebar
    /// order; everything else keeps its `/library/sections` position at the end.
    ///
    /// Edge cases, all intentional:
    /// - No machine identifier, or no pinned sources at all (fresh account,
    ///   blob missing/404/unparseable, plex.tv unreachable) -> plain server
    ///   order. The blob must never be able to block the library list.
    /// - A pinned entry whose section no longer exists is skipped.
    /// - Duplicate pins for one section: the first one wins.
    /// - `isHidden` entries are *not* pinned to the front. Dusk does not hide
    ///   libraries, so a hidden library falls through to the tail block instead
    ///   of disappearing (see `writeOrder`, which keeps it hidden on write).
    /// - Entries for other servers and for cloud providers (`machineIdentifier
    ///   == "myPlex"`) are ignored here; they are preserved on write.
    static func effectiveOrder(
        libraries: [PlexLibrary],
        pinnedSources: [PlexPinnedSource],
        machineIdentifier: String?
    ) -> [PlexLibrary] {
        guard let machineIdentifier, !machineIdentifier.isEmpty, !pinnedSources.isEmpty else {
            return libraries
        }

        var librariesByKey: [String: PlexLibrary] = [:]
        for library in libraries where librariesByKey[library.key] == nil {
            librariesByKey[library.key] = library
        }

        var placed: [PlexLibrary] = []
        var used: Set<String> = []

        for source in pinnedSources
        where source.machineIdentifier == machineIdentifier && source.isPMSLibrary && !source.isHidden {
            guard let directoryID = source.directoryID,
                  let library = librariesByKey[directoryID],
                  !used.contains(directoryID) else { continue }
            placed.append(library)
            used.insert(directoryID)
        }

        return placed + libraries.filter { !used.contains($0.key) }
    }

    /// Splices this server's freshly reordered entries back into the account's
    /// full pinned list.
    ///
    /// The connected server's entries collapse into one contiguous block placed
    /// where its *first* entry used to be. Entries belonging to other servers or
    /// to cloud providers are copied verbatim, keep their relative order, and
    /// are never dropped or mutated — that is the whole point of the merge, as a
    /// partial write would wipe the user's Plex Web sidebar.
    static func merged(
        existing: [PlexPinnedSource],
        reordered: [PlexPinnedSource],
        machineIdentifier: String
    ) -> [PlexPinnedSource] {
        func isMine(_ source: PlexPinnedSource) -> Bool {
            source.machineIdentifier == machineIdentifier && source.isPMSLibrary
        }

        let others = existing.filter { !isMine($0) }

        let insertionIndex: Int
        if let firstIndex = existing.firstIndex(where: isMine) {
            insertionIndex = existing[..<firstIndex].filter { !isMine($0) }.count
        } else {
            // Nothing pinned for this server yet: append after everything else.
            insertionIndex = others.count
        }

        return Array(others[..<insertionIndex]) + reordered + Array(others[insertionIndex...])
    }

    /// User order in, write order out.
    ///
    /// Existing entries are reused verbatim (only `title` is refreshed from the
    /// section) so unmodeled Plex fields survive; sections that were never
    /// pinned get a freshly built entry.
    ///
    /// Hidden entries keep `isHidden` and are stable-moved to the end of the
    /// block. That makes the write idempotent with `effectiveOrder`, which
    /// already shows hidden libraries last: a library hidden in Plex Web still
    /// appears in Dusk, and dragging it into the middle of the list snaps back
    /// to the end. Documented wart — do not force-unhide, that would silently
    /// undo a choice the user made in another Plex client.
    static func writeOrder(
        userOrder: [PlexLibrary],
        existing: [PlexPinnedSource],
        server: PlexServer
    ) -> [PlexPinnedSource] {
        var existingByDirectoryID: [String: PlexPinnedSource] = [:]
        for source in existing
        where source.machineIdentifier == server.clientIdentifier && source.isPMSLibrary {
            guard let directoryID = source.directoryID,
                  existingByDirectoryID[directoryID] == nil else { continue }
            existingByDirectoryID[directoryID] = source
        }

        var seen: Set<String> = []
        var mapped: [PlexPinnedSource] = []
        for library in userOrder {
            guard !seen.contains(library.key) else { continue }
            seen.insert(library.key)
            if let existingSource = existingByDirectoryID[library.key] {
                mapped.append(existingSource.updatingTitle(library.title))
            } else {
                mapped.append(PlexPinnedSource.make(library: library, server: server))
            }
        }

        return mapped.filter { !$0.isHidden } + mapped.filter(\.isHidden)
    }
}
