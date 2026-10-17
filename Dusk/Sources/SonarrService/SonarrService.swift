import Foundation

/// Optional acquisition companion. Plex remains the only playback and watch-state backend.
@MainActor
@Observable
final class SonarrService {
    private let plex: PlexService
    private var connections = SonarrCredentialStore.load()
    private var session: URLSession = SonarrService.makeSession()
    private var generation = 0
    private var contextID = ""
    private var isActive = true
    private var observers: [UUID: String] = [:]
    private var pollTask: Task<Void, Never>?
    private var refreshing = Set<String>()
    private var seriesIndex: [SonarrSeries]?
    private var seriesIndexDate = Date.distantPast
    private var requests: [Int: PendingSearch] = [:]
    private var submitting = Set<String>()
    private var replacementJobs: [Int: ReplacementJob] = [:]
    private struct ReplacementJob {
        let search: SonarrReleaseSearch
        let started: Date
        var activity: SonarrActivity
        var imported = false
        var finished = false
    }
    private var lastScan: [String: Date] = [:]
    private var scannedFiles: [String: Set<Int>] = [:]
    private var importStarted: [String: Date] = [:]
    private(set) var snapshots: [String: SonarrShowSnapshot] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var lastConnectionError: String?
    private(set) var revision = 0

    private struct PendingSearch {
        let showKey: String
        let commandID: Int?
        let started: Date
        var activity: SonarrActivity
    }

    init(plexService: PlexService) {
        plex = plexService
        contextID = currentContext
    }

    var connection: SonarrConnection? {
        guard plex.isAuthenticated else { return nil }
        return connections.first { $0.profileID == plex.activeProfileID && $0.serverID == plex.currentServerIdentifier }
    }
    var isConnected: Bool { connection != nil }
    var observationContext: String { "\(currentContext):\(generation)" }
    var connectionSubtitle: String {
        if lastConnectionError != nil { return "Connection needs attention" }
        return isConnected ? "Connected" : "Not connected"
    }
    private var currentContext: String {
        "\(plex.activeProfileID ?? ""):\(plex.currentServerIdentifier ?? ""):\(plex.isAuthenticated)"
    }

    func contextDidChange() {
        guard currentContext != contextID else { return }
        contextID = currentContext
        reset()
        if !plex.isAuthenticated {
            connections = []
            SonarrCredentialStore.save([])
        }
    }

    private func reset() {
        generation += 1
        pollTask?.cancel()
        pollTask = nil
        session.invalidateAndCancel()
        session = Self.makeSession()
        snapshots = [:]
        errors = [:]
        seriesIndex = nil
        requests = [:]
        replacementJobs = [:]
        submitting = []
        refreshing = []
        lastScan = [:]
        scannedFiles = [:]
        importStarted = [:]
        lastConnectionError = nil
        revision += 1
        startPolling()
    }

    func setActive(_ active: Bool) {
        isActive = active
        pollTask?.cancel()
        pollTask = nil
        if !active {
            session.invalidateAndCancel()
            session = Self.makeSession()
        }
        startPolling()
    }

    static func normalizedURL(_ text: String) throws -> URL {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              var components = URLComponents(string: value.contains("://") ? value : "https://\(value)"),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { throw SonarrError.invalidURL }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw SonarrError.invalidURL }
        return url
    }

    func connect(url: String, apiKey: String) async throws {
        guard let profile = plex.activeProfileID, let server = plex.currentServerIdentifier else { throw SonarrError.notConnected }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw SonarrError.message("Enter the API key from Sonarr Settings → General → Security.") }
        let candidate = SonarrConnection(baseURL: try Self.normalizedURL(url), apiKey: key, profileID: profile, serverID: server)
        let version = generation
        _ = try await data(path: "api/v3/system/status", connection: candidate)
        let _: [SonarrSeries] = try await get("api/v3/series", connection: candidate)
        try check(version)
        connections.removeAll { $0.profileID == profile && $0.serverID == server }
        connections.append(candidate)
        SonarrCredentialStore.save(connections)
        reset()
    }

    func testConnection() async throws {
        _ = try await data(path: "api/v3/system/status")
        lastConnectionError = nil
    }

    func disconnect() {
        guard let profile = plex.activeProfileID, let server = plex.currentServerIdentifier else { return }
        connections.removeAll { $0.profileID == profile && $0.serverID == server }
        SonarrCredentialStore.save(connections)
        reset()
    }

    /// A screen lease owns visibility, while one service task polls all visible shows.
    func observe(showKey: String) async {
        let id = UUID()
        observers[id] = showKey
        startPolling()
        defer { observers.removeValue(forKey: id); stopPollingIfUnused() }
        do {
            while !Task.isCancelled { try await Task.sleep(for: .seconds(60)) }
        } catch { }
    }

    private func startPolling() {
        #if !os(tvOS)
        guard pollTask == nil, isActive, isConnected, !observers.isEmpty else { return }
        pollTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                for showKey in Set(self.observers.values).sorted() {
                    guard !Task.isCancelled else { return }
                    await self.refresh(showKey: showKey)
                }
                failures = self.lastConnectionError == nil ? 0 : min(3, failures + 1)
                let visible = Set(self.observers.values)
                let fastImports = self.importStarted.contains { visible.contains($0.key) && Date().timeIntervalSince($0.value) < 120 }
                let activeSearch = self.requests.values.contains { visible.contains($0.showKey) && $0.activity.blocksRequest && $0.commandID != nil }
                let replacementPending = self.replacementJobs.values.contains { visible.contains($0.search.showKey) && !$0.imported && !$0.finished && $0.activity.blocksRequest }
                let activeTransfers = self.snapshots.contains { visible.contains($0.key) && !$0.value.queue.isEmpty }
                let delay = failures > 0 ? min(60, 7.5 * pow(2, Double(failures))) : (fastImports || activeSearch || activeTransfers || replacementPending ? 5.0 : 30.0)
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
        #endif
    }

    private func stopPollingIfUnused() {
        guard observers.isEmpty else { return }
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh(showKey: String) async {
        guard isActive, isConnected, !refreshing.contains(showKey) else { return }
        let version = generation
        refreshing.insert(showKey)
        defer { if version == generation { refreshing.remove(showKey) } }
        do {
            let show = try await plex.getMediaDetails(ratingKey: showKey)
            try check(version)
            if seriesIndex == nil || Date().timeIntervalSince(seriesIndexDate) > 60 {
                let index: [SonarrSeries] = try await get("api/v3/series")
                try check(version)
                seriesIndex = index
                seriesIndexDate = Date()
            }
            guard let seriesID = try match(show: show)?.id else {
                errors[showKey] = nil
                snapshots[showKey] = nil
                lastConnectionError = nil
                return
            }
            let series: SonarrSeries = try await get("api/v3/series/\(seriesID)", query: [URLQueryItem(name: "includeSeasonImages", value: "true")])
            let episodes: [SonarrEpisode] = try await get("api/v3/episode", query: [URLQueryItem(name: "seriesId", value: "\(seriesID)"), URLQueryItem(name: "includeImages", value: "true")])
            let queue: [SonarrQueueItem] = try await get("api/v3/queue/details", query: [URLQueryItem(name: "seriesId", value: "\(seriesID)")])
            let commands: [SonarrCommand] = try await get("api/v3/command")
            let seasons = try await plex.getSeasons(showKey: showKey)
            let plexEpisodes = try await plex.getAcquisitionEpisodes(showKey: showKey)
            try check(version)
            let mapping = Self.map(episodes, to: plexEpisodes)
            let previous = snapshots[showKey]
            var snapshot = SonarrShowSnapshot(show: show, series: series, seasons: seasons, plexEpisodes: plexEpisodes,
                                              episodes: episodes, queue: queue, matches: mapping.matches, mappingError: mapping.error)
            snapshot.scanMessage = previous?.scanMessage
            snapshots[showKey] = snapshot
            errors[showKey] = nil
            lastConnectionError = nil
            restoreSearches(showKey: showKey, commands: commands)
            await reconcileRequests(showKey: showKey, commands: commands)
            try check(version)
            await reconcileImports(showKey: showKey, version: version)
            await reconcileReplacements(showKey: showKey, version: version)
            try check(version)
            if previous == nil || Set(previous?.plexEpisodes.map(\.ratingKey) ?? []) != Set(plexEpisodes.map(\.ratingKey)) {
                plex.metadataRevision += 1
            }
            revision += 1
        } catch {
            guard version == generation, !Task.isCancelled, !(error is CancellationError),
                  (error as? URLError)?.code != .cancelled else { return }
            errors[showKey] = error.localizedDescription
            snapshots[showKey]?.connectionError = error.localizedDescription
            lastConnectionError = error.localizedDescription
        }
    }

    private func match(show: PlexMediaDetails) throws -> SonarrSeries? {
        let tvdb = Set(show.guids.compactMap { $0.value(for: "tvdb") }.compactMap(Int.init))
        let imdb = Set(show.guids.compactMap { $0.value(for: "imdb") })
        let primary = (seriesIndex ?? []).filter { $0.tvdbId.map(tvdb.contains) == true }
        let fallback = (seriesIndex ?? []).filter { $0.imdbId.map(imdb.contains) == true }
        guard primary.count <= 1, fallback.count <= 1,
              primary.isEmpty || fallback.isEmpty || primary.first?.id == fallback.first?.id else {
            throw SonarrError.message("Plex and Sonarr series identifiers conflict. Correct the match before acquiring episodes.")
        }
        return primary.first ?? fallback.first
    }

    /// Number-based joins require evidence from existing episodes; never guess another ordering.
    private static func map(_ episodes: [SonarrEpisode], to plexEpisodes: [PlexEpisode]) -> (matches: [Int: PlexEpisode], error: String?) {
        var matches: [Int: PlexEpisode] = [:]
        var evidence = false
        func normalized(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
        for plexEpisode in plexEpisodes {
            let ids = Set((plexEpisode.guids ?? []).compactMap { $0.value(for: "tvdb") }.compactMap(Int.init))
            let exact = episodes.filter { $0.tvdbId.map { ids.contains($0) && $0 > 0 } == true }
            let numbered = episodes.filter { $0.seasonNumber == plexEpisode.parentIndex && $0.episodeNumber == plexEpisode.index }
            guard exact.count <= 1, numbered.count <= 1 else { return ([:], "Episode numbering is ambiguous between Plex and Sonarr.") }
            if let exact = exact.first {
                guard exact.seasonNumber == plexEpisode.parentIndex, exact.episodeNumber == plexEpisode.index else {
                    return ([:], "Plex and Sonarr use different episode ordering. Align the series ordering before downloading.")
                }
                guard matches[exact.id] == nil else { return ([:], "Multiple Plex episodes match the same Sonarr episode.") }
                matches[exact.id] = plexEpisode
                evidence = true
            } else if let episode = numbered.first {
                // An external ID that contradicts the numbered match is never a fallback.
                if !ids.isEmpty, let id = episode.tvdbId, id > 0, !ids.contains(id) {
                    return ([:], "Plex and Sonarr episode identifiers disagree.")
                }
                let titleAgrees = episode.title.map { normalized($0) == normalized(plexEpisode.title) && !normalized($0).isEmpty } == true
                let uniqueAirDate = episodes.filter { $0.seasonNumber == episode.seasonNumber && $0.airDate == episode.airDate }.count == 1
                let dateAgrees = uniqueAirDate && episode.airDate != nil && episode.airDate == plexEpisode.originallyAvailableAt
                guard titleAgrees || dateAgrees else { return ([:], "Could not verify matching episode ordering in Plex and Sonarr.") }
                guard matches[episode.id] == nil else { return ([:], "Multiple Plex episodes match the same Sonarr episode.") }
                matches[episode.id] = plexEpisode
                evidence = true
            } else {
                return ([:], "Some Plex episodes cannot be matched to Sonarr. Check the series ordering.")
            }
        }
        guard evidence else { return ([:], "Could not verify episode ordering for this series.") }
        return (matches, nil)
    }

    func activity(for episode: SonarrEpisode, showKey: String) -> SonarrActivity {
        guard let snapshot = snapshots[showKey] else { return SonarrActivity(title: "Unavailable") }
        if let replacement = replacementActivity(episodeID: episode.id, showKey: showKey) { return replacement }
        if snapshot.matches[episode.id] != nil { return SonarrActivity(title: "Available in Plex") }
        if episode.hasFile { return SonarrActivity(title: "Waiting for Plex", message: snapshot.scanMessage) }
        let queue = snapshot.queue.filter { $0.episodeId == episode.id || ($0.episodeId == nil && $0.seasonNumber == episode.seasonNumber) }
        if let item = queue.first {
            let state = item.trackedDownloadState?.lowercased() ?? ""
            let status = item.status?.lowercased() ?? ""
            if ["importblocked", "failed", "failedpending"].contains(state) || ["failed", "warning", "downloadclientunavailable"].contains(status) || item.trackedDownloadStatus?.lowercased() == "error" {
                return SonarrActivity(title: "Needs attention", message: item.problem ?? "Check this download in Sonarr.")
            }
            if ["importpending", "importing"].contains(state) || status == "completed" {
                return SonarrActivity(title: "Importing", message: item.problem)
            }
            if status == "paused" { return SonarrActivity(title: "Paused", progress: item.fraction) }
            if status == "downloading" { return SonarrActivity(title: "Downloading", progress: item.fraction) }
            return SonarrActivity(title: "Queued", message: item.problem)
        }
        if let pending = requests[episode.id] { return pending.activity }
        if !episode.hasAired {
            return SonarrActivity(title: episode.airDate.map { "Airs \($0)" } ?? "Air date unknown")
        }
        return SonarrActivity(title: "Download to server", blocksRequest: false)
    }

    func seasonActivity(showKey: String, season: Int) -> SonarrActivity? {
        guard let snapshot = snapshots[showKey], snapshot.canEnrich else { return nil }
        let episodes = snapshot.episodes.filter { $0.seasonNumber == season }
        guard !episodes.isEmpty else { return nil }
        let available = episodes.filter { snapshot.matches[$0.id] != nil }.count
        let queue = snapshot.queue.filter { item in
            item.seasonNumber == season || episodes.contains { $0.id == item.episodeId }
        }
        let unique = Dictionary(grouping: queue, by: \.transferID).compactMap { $0.value.first }
        let known = unique.filter { ($0.size ?? 0) > 0 && $0.sizeleft != nil }
        let total = known.reduce(0) { $0 + ($1.size ?? 0) }
        let progress = known.count == unique.count && total > 0 ? known.reduce(0) { $0 + max(0, ($1.size ?? 0) - ($1.sizeleft ?? 0)) } / total : nil
        let priorities = ["Needs attention": 0, "Downloading": 1, "Paused": 2, "Importing": 3, "Searching": 4, "Queued": 5, "Waiting for Plex": 6, "Search failed": 7]
        let active = episodes.filter {
            (snapshot.matches[$0.id] == nil || replacementJobs[$0.id]?.finished == false) && $0.hasAired && (activity(for: $0, showKey: showKey).blocksRequest || requests[$0.id] != nil)
        }.map { activity(for: $0, showKey: showKey) }.min {
            priorities[$0.title, default: 8] < priorities[$1.title, default: 8]
        }
        let status = active?.title
        let canSearch = episodes.contains { !activity(for: $0, showKey: showKey).blocksRequest && $0.hasAired }
        let needsMonitoring = snapshot.series.seasons.first { $0.seasonNumber == season }?.monitored == false
            || episodes.contains { !$0.hasAired && !$0.monitored && !$0.hasFile }

        return SonarrActivity(title: status ?? "\(available) of \(episodes.count) available", progress: progress.map { min(1, max(0, $0)) },
                              message: "\(available) of \(episodes.count) episodes available", blocksRequest: (!canSearch && !needsMonitoring) || submitting.contains(showKey))
    }

    func acquire(showKey: String, episodeIDs: Set<Int>? = nil, season: Int? = nil) async {
        guard isActive, isConnected else { return }
        let version = generation
        var reserved = Set<Int>()
        // Reserve immediately, including while another mutation for the show is finishing.
        if let snapshot = snapshots[showKey] {
            for episode in snapshot.episodes where episodeIDs?.contains(episode.id) == true || (episodeIDs == nil && episode.seasonNumber == season) {
                if !episode.hasFile && snapshot.matches[episode.id] == nil && episode.hasAired && !activity(for: episode, showKey: showKey).blocksRequest {
                    reserved.insert(episode.id)
                    requests[episode.id] = PendingSearch(showKey: showKey, commandID: nil, started: Date(), activity: SonarrActivity(title: "Searching"))
                }
            }
        }
        if episodeIDs != nil && reserved.isEmpty { return }
        do {
            while submitting.contains(showKey) || refreshing.contains(showKey) {
                try await Task.sleep(for: .milliseconds(100))
                try check(version)
            }
        } catch {
            if version == generation {
                for id in reserved { requests[id] = nil }
            }
            return
        }
        submitting.insert(showKey)
        defer { if version == generation { submitting.remove(showKey) } }
        var selected: [SonarrEpisode] = []
        var submittedCommand = false
        do {
            await refresh(showKey: showKey)
            try check(version)
            guard let snapshot = snapshots[showKey], snapshot.canEnrich else { throw SonarrError.message("Verify the Plex and Sonarr episode match before downloading.") }
            guard snapshot.connectionError == nil, errors[showKey] == nil else { throw SonarrError.message("Refresh Sonarr's status before downloading.") }
            selected = snapshot.episodes.filter { episode in
                let intended = episodeIDs?.contains(episode.id) ?? (episode.seasonNumber == season)
                let queued = snapshot.queue.contains { $0.episodeId == episode.id || ($0.episodeId == nil && $0.seasonNumber == episode.seasonNumber) }
                let previous = requests[episode.id]
                let alreadyActive = previous?.activity.blocksRequest == true && (!reserved.contains(episode.id) || previous?.commandID != nil)
                return intended && episode.hasAired && !episode.hasFile && snapshot.matches[episode.id] == nil && !queued && !alreadyActive
            }
            let selectedIDs = Set(selected.map(\.id))
            for id in reserved.subtracting(selectedIDs) where requests[id]?.commandID == nil { requests[id] = nil }
            // Season Pass accepts a targeted season list and no global monitoring policy.
            if let season {
                _ = try await data(path: "api/v3/seasonpass", method: "POST", body: ["series": [["id": snapshot.series.id, "monitored": true, "seasons": [["seasonNumber": season, "monitored": true]]]]])
                try check(version)
                let missing = snapshot.episodes.filter { $0.seasonNumber == season && !($0.hasFile || snapshot.matches[$0.id] != nil) }
                if !missing.isEmpty {
                    _ = try await data(path: "api/v3/episode/monitor", method: "PUT", body: ["episodeIds": missing.map(\.id), "monitored": true])
                }
            } else if !selected.isEmpty {
                _ = try await data(path: "api/v3/seasonpass", method: "POST", body: ["series": [["id": snapshot.series.id, "monitored": true]]])
                _ = try await data(path: "api/v3/episode/monitor", method: "PUT", body: ["episodeIds": selected.map(\.id), "monitored": true])
            }
            try check(version)
            guard !selected.isEmpty else {
                await refresh(showKey: showKey)
                return
            }
            submittedCommand = true
            let command: SonarrCommand = try await send("api/v3/command", method: "POST", body: ["name": "EpisodeSearch", "episodeIds": selected.map(\.id)])
            try check(version)
            for episode in selected {
                requests[episode.id] = PendingSearch(showKey: showKey, commandID: command.id, started: Date(), activity: SonarrActivity(title: "Searching"))
            }
            await refresh(showKey: showKey)
        } catch {
            guard version == generation, !Task.isCancelled else { return }
            let message = submittedCommand ? "The search may have been accepted. Check status before retrying. \(error.localizedDescription)" : error.localizedDescription
            for id in reserved {
                requests[id]?.activity = SonarrActivity(title: submittedCommand ? "Check Sonarr status" : "Search failed", message: message, blocksRequest: submittedCommand)
            }
            errors[showKey] = message
        }
        revision += 1
    }

    func retrySearch(showKey: String, episode: SonarrEpisode) async {
        guard requests[episode.id]?.activity.title == "Check Sonarr status" else { return }
        requests[episode.id] = nil
        await acquire(showKey: showKey, episodeIDs: [episode.id])
    }

    private func restoreSearches(showKey: String, commands: [SonarrCommand]) {
        guard let snapshot = snapshots[showKey] else { return }
        let episodeIDs = Set(snapshot.episodes.map(\.id))
        for command in commands where (command.name ?? command.body?.name)?.lowercased() == "episodesearch" {
            for id in command.body?.episodeIds ?? [] where episodeIDs.contains(id) {
                if !command.isFinished, requests[id]?.commandID == nil {
                    requests[id] = PendingSearch(showKey: showKey, commandID: command.id, started: command.queued ?? Date(), activity: SonarrActivity(title: "Searching"))
                } else if let pending = requests[id], pending.commandID == nil,
                          pending.activity.title == "Check Sonarr status",
                          let queued = command.queued, queued >= pending.started.addingTimeInterval(-5) {
                    requests[id] = PendingSearch(showKey: showKey, commandID: command.id, started: pending.started, activity: SonarrActivity(title: "Searching"))
                }
            }
        }
    }

    private func reconcileRequests(showKey: String, commands commandList: [SonarrCommand]) async {
        let version = generation
        guard let snapshot = snapshots[showKey] else { return }
        let pending = requests.filter { $0.value.showKey == showKey }
        var commands = Dictionary(commandList.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (episodeID, search) in pending {
            if snapshot.matches[episodeID] != nil || snapshot.episodes.first(where: { $0.id == episodeID })?.hasFile == true {
                requests[episodeID] = nil
                continue
            }
            guard let id = search.commandID else { continue }
            do {
                let command: SonarrCommand
                if let cached = commands[id] { command = cached }
                else { command = try await get("api/v3/command/\(id)"); commands[id] = command }
                try check(version)
                if command.isFinished && Date().timeIntervalSince(search.started) > 15 {
                    requests[episodeID]?.activity = SonarrActivity(title: command.failed ? "Search failed" : "No release found · monitoring",
                                                                  message: command.failed ? command.message : "Sonarr will keep monitoring. Click to search again.", blocksRequest: false)
                }
            } catch {
                guard version == generation, !Task.isCancelled else { return }
                // Missing/expired command history is not evidence of a completed download.
                requests[episodeID]?.activity = SonarrActivity(title: "Check Sonarr status", message: "The search status is unavailable. Refresh or check Sonarr before retrying.")
            }
        }
    }

    private func reconcileImports(showKey: String, version: Int) async {
        guard let snapshot = snapshots[showKey] else { return }
        let waiting = snapshot.episodes.filter {
            $0.hasFile && ((snapshot.canEnrich && snapshot.matches[$0.id] == nil) ||
                (replacementJobs[$0.id]?.finished == false && $0.episodeFileId != replacementJobs[$0.id]?.search.originalFileID))
        }
        guard !waiting.isEmpty else {
            importStarted[showKey] = nil
            snapshots[showKey]?.scanMessage = nil
            return
        }
        if importStarted[showKey] == nil { importStarted[showKey] = Date() }
        let files = Set(waiting.map { ($0.episodeFileId ?? 0) > 0 ? ($0.episodeFileId ?? $0.id) : $0.id })
        guard !files.isSubset(of: scannedFiles[showKey] ?? []), Date().timeIntervalSince(lastScan[showKey] ?? .distantPast) >= 30 else { return }
        lastScan[showKey] = Date()
        do {
            try await plex.scanAcquiredShow(snapshot.show)
            try check(version)
            scannedFiles[showKey, default: []].formUnion(files)
            snapshots[showKey]?.scanMessage = nil
        } catch {
            guard version == generation else { return }
            snapshots[showKey]?.scanMessage = error.localizedDescription
            // A denied or unsupported scan is not repeatedly submitted in the polling loop.
            scannedFiles[showKey, default: []].formUnion(files)
        }
    }

    func retryScan(showKey: String) async {
        scannedFiles[showKey] = nil
        lastScan[showKey] = nil
        await refresh(showKey: showKey)
    }

    /// Interactive results are Sonarr's ranked decisions. Existing files are never deleted here.
    func searchAlternativeReleases(ratingKey: String, confirmedEpisodeID: Int? = nil, confirmationContext: String? = nil) async throws -> SonarrReleaseSearch {
        let version = generation
        guard isConnected else { throw SonarrError.notConnected }
        if confirmedEpisodeID != nil, confirmationContext != observationContext { throw SonarrError.contextChanged }
        let details = try await plex.getMediaDetails(ratingKey: ratingKey, checkFiles: true)
        try check(version)
        guard details.type == .episode, let showKey = details.grandparentRatingKey else {
            throw SonarrError.message("Sonarr alternatives are available for TV episodes. Movie replacement requires a future Radarr connection.")
        }
        while refreshing.contains(showKey) { try await Task.sleep(for: .milliseconds(100)); try check(version) }
        await refresh(showKey: showKey)
        try check(version)
        guard let snapshot = snapshots[showKey] else {
            throw SonarrError.message(errors[showKey] ?? "This episode's show is not matched to an existing series in Sonarr.")
        }
        if let error = snapshot.connectionError { throw SonarrError.message(error) }
        let episode: SonarrEpisode
        if let confirmedEpisodeID {
            guard let selected = snapshot.episodes.first(where: { $0.id == confirmedEpisodeID }) else {
                throw SonarrError.message("The selected Sonarr episode is no longer available. Refresh the search.")
            }
            episode = selected
        } else if let verified = Self.replacementEpisode(details: details, episodes: snapshot.episodes) {
            episode = verified
        } else {
            let label = MediaTextFormatter.seasonEpisodeLabel(season: details.parentIndex, episode: details.index) ?? "Episode"
            let numbered = snapshot.episodes.filter { $0.seasonNumber == details.parentIndex && $0.episodeNumber == details.index }
            throw SonarrEpisodeSelectionRequired(context: observationContext, seriesTitle: snapshot.series.title,
                                                 plexEpisodeLabel: "\(label) · \(details.title)",
                                                 suggestedEpisodeID: numbered.count == 1 ? numbered.first?.id : nil,
                                                 episodes: snapshot.episodes)
        }
        var currentTitle: String?
        if let fileID = episode.episodeFileId, fileID > 0 {
            let info: SonarrEpisodeFileInfo? = try? await get("api/v3/episodefile/\(fileID)")
            currentTitle = info?.sceneName
        }
        try check(version)
        let releases: [SonarrRelease] = try await get("api/v3/release", query: [URLQueryItem(name: "episodeId", value: "\(episode.id)")])
        try check(version)
        return SonarrReleaseSearch(context: observationContext, showKey: showKey, plexRatingKey: ratingKey,
                                   episodeID: episode.id, seasonNumber: episode.seasonNumber,
                                   episodeLabel: "\(episode.label) · \(episode.title ?? "Episode")", episodeWasChosen: confirmedEpisodeID != nil,
                                   seriesID: snapshot.series.id, prefersEnglishAudio: snapshot.series.prefersEnglishAudio,
                                   originalFileID: episode.episodeFileId, currentReleaseTitle: currentTitle,
                                   plexSignature: Self.fileSignature(details), releases: releases)
    }

    /// Dual-audio anime is often released only as season batches, which an episode search never returns.
    func searchSeasonPacks(for search: SonarrReleaseSearch) async throws -> SonarrReleaseSearch {
        let version = generation
        guard search.context == observationContext else { throw SonarrError.contextChanged }
        let found: [SonarrRelease] = try await get("api/v3/release", query: [URLQueryItem(name: "seriesId", value: "\(search.seriesID)"),
                                                                             URLQueryItem(name: "seasonNumber", value: "\(search.seasonNumber)")])
        try check(version)
        let known = Set(search.releases.map(\.id))
        var result = search
        result.seasonPackReleases = found.filter { release in
            !known.contains(release.id) && release.mappedEpisodeInfo?.contains { $0.id == search.episodeID } == true
        }
        return result
    }

    func grabAlternative(_ release: SonarrRelease, search: SonarrReleaseSearch) async throws {
        let version = generation
        guard search.context == observationContext else { throw SonarrError.contextChanged }
        guard search.allReleases.contains(where: { $0.id == release.id }), let guid = release.guid, !guid.isEmpty,
              release.downloadAllowed != false, release.mappedSeriesId == search.seriesID,
              release.mappedEpisodeInfo?.contains(where: { $0.id == search.episodeID }) == true else {
            throw SonarrError.message("Sonarr did not map this release to the selected episode. Refresh the search or check Sonarr.")
        }
        guard !submitting.contains(search.showKey) else { throw SonarrError.message("A request is already being submitted for this show.") }
        guard replacementJobs[search.episodeID]?.activity.blocksRequest != true,
              requests[search.episodeID]?.activity.blocksRequest != true else {
            throw SonarrError.message("A download/search is already pending for this episode. Refresh Sonarr's status before trying another release.")
        }
        submitting.insert(search.showKey)
        defer { if generation == version { submitting.remove(search.showKey) } }
        while refreshing.contains(search.showKey) { try await Task.sleep(for: .milliseconds(100)); try check(version) }
        await refresh(showKey: search.showKey)
        try check(version)
        guard let snapshot = snapshots[search.showKey], snapshot.connectionError == nil,
              snapshot.series.id == search.seriesID,
              let selected = snapshot.episodes.first(where: { $0.id == search.episodeID }) else {
            throw SonarrError.message("The episode match changed. Refresh the release search before downloading.")
        }
        guard selected.episodeFileId == search.originalFileID else {
            throw SonarrError.message("The existing file changed while you were browsing. Refresh the release search before downloading.")
        }
        let currentDetails = try await plex.getMediaDetails(ratingKey: search.plexRatingKey, checkFiles: true)
        try check(version)
        guard currentDetails.type == .episode, currentDetails.grandparentRatingKey == search.showKey,
              search.episodeWasChosen || Self.replacementEpisode(details: currentDetails, episodes: snapshot.episodes)?.id == search.episodeID else {
            throw SonarrError.message("The selected episode's identity changed. Refresh the release search before downloading.")
        }
        guard !snapshot.queue.contains(where: { $0.episodeId == search.episodeID || ($0.episodeId == nil && $0.seasonNumber == snapshot.episodes.first(where: { $0.id == search.episodeID })?.seasonNumber) }) else {
            throw SonarrError.message("Sonarr already has a download for this episode. Follow its progress or resolve it in Sonarr first.")
        }
        replacementJobs[search.episodeID] = ReplacementJob(search: search, started: Date(), activity: SonarrActivity(title: "Requesting replacement"))
        do {
            _ = try await data(path: "api/v3/release", method: "POST", body: ["guid": guid, "indexerId": release.indexerId, "episodeId": search.episodeID])
            try check(version)
            replacementJobs[search.episodeID]?.activity = SonarrActivity(title: "Download requested")
        } catch {
            guard generation == version else { throw SonarrError.contextChanged }
            if let failure = error as? SonarrError {
                switch failure {
                case .unauthorized, .denied:
                    replacementJobs[search.episodeID] = nil
                    throw failure
                case .server(let status) where (400..<500).contains(status) && status != 408:
                    replacementJobs[search.episodeID] = nil
                    if status == 404 { throw SonarrError.message("Sonarr's cached release search expired. Refresh the search and select the release again.") }
                    throw failure
                default: break
                }
            }
            replacementJobs[search.episodeID]?.activity = SonarrActivity(title: "Check Sonarr status", message: "The request may have been accepted. Refresh before choosing another release.")
            throw SonarrError.message("The request may have been accepted. Check Sonarr before retrying. \(error.localizedDescription)")
        }
        await refresh(showKey: search.showKey)
    }

    func replacementActivity(episodeID: Int, showKey: String) -> SonarrActivity? {
        guard let job = replacementJobs[episodeID], job.search.showKey == showKey else { return nil }
        if job.finished { return job.activity }
        if let item = snapshots[showKey]?.queue.first(where: { $0.episodeId == episodeID }) {
            let state = item.trackedDownloadState?.lowercased() ?? ""
            if ["importblocked", "failed", "failedpending"].contains(state) || item.trackedDownloadStatus?.lowercased() == "error" {
                return SonarrActivity(title: "Needs attention", message: item.problem ?? "Check the replacement in Sonarr.")
            }
            if ["importpending", "importing"].contains(state) || item.status?.lowercased() == "completed" { return SonarrActivity(title: "Importing replacement") }
            if item.status?.lowercased() == "paused" { return SonarrActivity(title: "Replacement paused", progress: item.fraction) }
            return SonarrActivity(title: "Downloading replacement", progress: item.fraction, message: item.problem)
        }
        return job.activity
    }

    func replacementActivity(ratingKey: String, showKey: String) -> SonarrActivity? {
        if let job = replacementJobs.values.first(where: { $0.search.showKey == showKey && $0.search.plexRatingKey == ratingKey }) {
            return replacementActivity(episodeID: job.search.episodeID, showKey: showKey)
        }
        guard let snapshot = snapshots[showKey], let id = snapshot.matches.first(where: { $0.value.ratingKey == ratingKey })?.key else { return nil }
        return replacementActivity(episodeID: id, showKey: showKey)
    }

    private func reconcileReplacements(showKey: String, version: Int) async {
        guard let snapshot = snapshots[showKey] else { return }
        for (id, job) in replacementJobs where job.search.showKey == showKey && !job.finished {
            guard let episode = snapshot.episodes.first(where: { $0.id == id }) else { continue }
            if episode.hasFile, episode.episodeFileId != job.search.originalFileID {
                replacementJobs[id]?.imported = true
                replacementJobs[id]?.activity = SonarrActivity(title: "Waiting for Plex", message: snapshot.scanMessage)
                do {
                    let details = try await plex.getMediaDetails(ratingKey: job.search.plexRatingKey, checkFiles: true)
                    try check(version)
                    if Self.fileSignature(details) != job.search.plexSignature {
                        replacementJobs[id]?.finished = true
                        replacementJobs[id]?.activity = SonarrActivity(title: "Replacement available in Plex", blocksRequest: false)
                        plex.metadataRevision += 1
                    }
                } catch { if generation != version || Task.isCancelled { return } }
            } else if !snapshot.queue.contains(where: { $0.episodeId == id }), Date().timeIntervalSince(job.started) > 30 {
                replacementJobs[id]?.activity = SonarrActivity(title: "Check Sonarr status", message: "No active replacement has been reported. Refresh Sonarr before retrying.", blocksRequest: false)
            }
        }
    }

    /// A single interactive replacement is independent of unrelated season/special mismatches.
    /// Exact external identity may legitimately use a different display numbering scheme.
    private static func replacementEpisode(details: PlexMediaDetails, episodes: [SonarrEpisode]) -> SonarrEpisode? {
        let ids = Set(details.guids.compactMap { $0.value(for: "tvdb") }.compactMap {
            Int($0.prefix { $0 != "?" && $0 != "#" })
        }.filter { $0 > 0 })
        if !ids.isEmpty {
            let exact = episodes.filter { $0.tvdbId.map(ids.contains) == true }
            return exact.count == 1 ? exact.first : nil
        }
        let numbered = episodes.filter { $0.seasonNumber == details.parentIndex && $0.episodeNumber == details.index }
        guard numbered.count == 1, let episode = numbered.first else { return nil }
        func normalized(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
        let title = normalized(details.title)
        let genericTitle = title == "episode\(episode.episodeNumber)" || title == "\(episode.episodeNumber)"
        let titleAgrees = !genericTitle && episode.title.map { !normalized($0).isEmpty && normalized($0) == title } == true
        let dateAgrees = episode.airDate != nil && episode.airDate == details.originallyAvailableAt &&
            episodes.filter { $0.seasonNumber == episode.seasonNumber && $0.airDate == episode.airDate }.count == 1
        return titleAgrees || dateAgrees ? episode : nil
    }

    private static func fileSignature(_ details: PlexMediaDetails) -> Set<String> {
        Set(details.media.filter(\.hasAvailablePart).flatMap { media in
            media.parts.map { part in
                let audio = part.streams.filter { $0.streamType == .audio }.map { "\($0.languageCode ?? $0.language ?? ""):\($0.codec ?? "")" }.joined(separator: ",")
                return "\(part.id):\(part.file ?? ""):\(part.size ?? 0):\(audio)"
            }
        })
    }

    func imageData(path: String) async throws -> Data {
        guard let connection else { throw SonarrError.notConnected }
        let base = connection.baseURL
        let url: URL
        if let absolute = URL(string: path), absolute.host != nil { url = absolute }
        else if path.hasPrefix("/") {
            guard let root = URL(string: "/", relativeTo: base), let resolved = URL(string: path, relativeTo: root)?.absoluteURL else { throw SonarrError.invalidURL }
            url = resolved
        } else { url = base.appendingPathComponent(path) }
        guard url.scheme == base.scheme, url.host == base.host, url.port == base.port else { throw SonarrError.invalidURL }
        return try await data(url: url, connection: connection)
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 120
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration, delegate: SonarrSessionDelegate(), delegateQueue: nil)
    }
    private func check(_ version: Int) throws {
        try Task.checkCancellation()
        guard generation == version, contextID == currentContext else { throw SonarrError.contextChanged }
    }
    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], connection: SonarrConnection? = nil) async throws -> T {
        let bytes = try await data(path: path, query: query, connection: connection)
        return try Self.decoder().decode(T.self, from: bytes)
    }
    private func send<T: Decodable>(_ path: String, method: String, body: [String: Any]) async throws -> T {
        let bytes = try await data(path: path, method: method, body: body)
        return try Self.decoder().decode(T.self, from: bytes)
    }
    private func data(path: String, method: String = "GET", query: [URLQueryItem] = [], body: [String: Any]? = nil, connection supplied: SonarrConnection? = nil) async throws -> Data {
        try check(generation)
        guard let connection = supplied ?? connection else { throw SonarrError.notConnected }
        var components = URLComponents(url: connection.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw SonarrError.invalidURL }
        return try await data(url: url, connection: connection, method: method, body: body)
    }
    private func data(url: URL, connection: SonarrConnection, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        let version = generation
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.httpMethod = method
        if method == "GET", url.path.hasSuffix("/api/v3/release") { request.timeoutInterval = 90 }
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(connection.apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (bytes, response) = try await session.data(for: request)
        try check(version)
        guard let http = response as? HTTPURLResponse else { throw SonarrError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return bytes
        case 401: throw SonarrError.unauthorized
        case 403: throw SonarrError.denied
        default: throw SonarrError.server(http.statusCode)
        }
    }
    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else { throw SonarrError.invalidResponse }
            return date
        }
        return decoder
    }
}
