import Foundation

extension PlexService {
    func getAcquisitionEpisodes(showKey: String) async throws -> [PlexEpisode] {
        try await fetchMetadata(
            path: "/library/metadata/\(showKey)/allLeaves",
            queryItems: [URLQueryItem(name: "includeGuids", value: "1")]
        )
    }

    /// Paths come from Plex itself: Sonarr may see the same files through a different mount.
    func scanAcquiredShow(_ show: PlexMediaDetails) async throws {
        guard connectedServer?.owned == true, activeHomeUser?.isRestricted != true else {
            throw SonarrError.message("Plex scanning requires server-owner permissions. Waiting for the server's next scan.")
        }
        guard let section = show.librarySectionID, let locations = show.locations, locations.contains(where: { !$0.path.isEmpty }) else {
            throw SonarrError.message("Plex did not provide this show's folder. Waiting for the server's next scan.")
        }
        let serverID = currentServerIdentifier
        let profileID = activeProfileID
        for path in Set(locations.map(\.path)) where !path.isEmpty {
            guard currentServerIdentifier == serverID, activeProfileID == profileID else { throw SonarrError.contextChanged }
            _ = try await rawServerRequest(
                path: "/library/sections/\(section)/refresh",
                queryItems: [URLQueryItem(name: "path", value: path)]
            )
        }
    }
}
