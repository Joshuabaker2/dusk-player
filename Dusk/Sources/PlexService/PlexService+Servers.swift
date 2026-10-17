import Foundation
import OSLog

extension PlexService {
    /// The servers the active identity can reach, from plex.tv
    /// `/api/v2/resources`. Concurrent calls for the same identity share one
    /// request.
    ///
    /// - Parameter maxAge: Also accept the previous discovery for this identity
    ///   when it finished within this many seconds. For callers that only need
    ///   the list for display, so they don't repeat the launch refresh's lookup.
    func discoverServers(reusingResultsWithin maxAge: TimeInterval? = nil) async throws -> [PlexServer] {
        guard !needsHomeUserSelection, let activeAccountToken else {
            throw PlexServiceError.notAuthenticated
        }

        if let maxAge,
           let lastServerDiscovery,
           lastServerDiscovery.token == activeAccountToken,
           Date().timeIntervalSince(lastServerDiscovery.date) < maxAge {
            return lastServerDiscovery.servers
        }

        if let serverDiscovery, serverDiscovery.token == activeAccountToken {
            return try await serverDiscovery.task.value
        }

        let task = Task { [weak self] () throws -> [PlexServer] in
            guard let self else { throw CancellationError() }
            return try await self.fetchServerResources(token: activeAccountToken)
        }
        serverDiscovery = (activeAccountToken, task)
        defer {
            if serverDiscovery?.task == task {
                serverDiscovery = nil
            }
        }

        let servers = try await task.value
        if self.activeAccountToken == activeAccountToken {
            lastServerDiscovery = (activeAccountToken, Date(), servers)
        }
        return servers
    }

    func makeResourcesRequest(token: String) -> URLRequest? {
        makePlexTVRequest(
            path: "/api/v2/resources",
            queryItems: [
                URLQueryItem(name: "includeHttps", value: "1"),
                URLQueryItem(name: "includeRelay", value: "1"),
            ],
            token: token
        )
    }

    /// Keeps the resources that are Plex Media Servers.
    nonisolated static func decodeServers(fromResources data: Data) throws -> [PlexServer] {
        guard let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw PlexServiceError.decodingError("Expected JSON array from resources endpoint")
        }

        let decoder = JSONDecoder()
        return jsonArray.compactMap { json -> PlexServer? in
            guard let provides = json["provides"] as? String, provides.contains("server") else {
                return nil
            }
            guard let itemData = try? JSONSerialization.data(withJSONObject: json) else {
                return nil
            }
            return try? decoder.decode(PlexServer.self, from: itemData)
        }
    }

    private func fetchServerResources(token activeAccountToken: String) async throws -> [PlexServer] {
        try await retryAfterFreshAuthentication {
            guard let request = makeResourcesRequest(token: activeAccountToken) else {
                throw PlexServiceError.invalidURL
            }
            let data = try await executeRequest(request)
            let servers = try Self.decodeServers(fromResources: data)

            if isAuthenticationFresh,
               !servers.isEmpty,
               servers.allSatisfy({ $0.usableAccessToken == nil }) {
                plexAuthLogger.notice("Server discovery returned servers without usable access tokens during bootstrap window")
                throw AuthenticationBootstrapError.waitingForPropagation
            }

            return servers
        }
    }

    /// How long, after the first connection succeeds, we keep waiting for a
    /// still-pending higher-priority connection (e.g. the LAN address) to also
    /// come back before committing to the best success we already have. Bounds
    /// the classic "off-network, local address hangs" stall while still letting
    /// a reachable local connection win the race when we're actually home.
    static let connectionPreferenceGrace: Duration = .milliseconds(1500)

    func connect(to server: PlexServer) async throws {
        try await connect(to: server, expectedGeneration: serverSelectionGeneration)
    }

    /// - Parameter expectedGeneration: The server selection this connect
    ///   belongs to. If `clearServer()` ran since (sign-out, a Home switch, the
    ///   bootstrap revoking a resumed session), the result is dropped instead
    ///   of committed.
    private func connect(to server: PlexServer, expectedGeneration: Int) async throws {
        try await retryAfterFreshAuthentication {
            let server = try await connectableServer(from: server)
            let candidates = connectionCandidates(for: server)
            let token = try serverAccessToken(for: server)

            guard !candidates.isEmpty else {
                throw PlexServiceError.networkError("No reachable connections for \(server.name)")
            }

            switch await probeConnections(candidates: candidates, token: token, serverName: server.name) {
            case let .connected(baseURL, connection):
                guard expectedGeneration == serverSelectionGeneration else {
                    throw CancellationError()
                }
                rememberLastGoodConnection(connection)
                setServer(server, baseURL: baseURL, accessToken: token, connection: connection)
                // Best-effort: learn the account's remote-streaming entitlement
                // in the background so the player can warn instantly later.
                // Until the Home bootstrap confirms the identity, it seeds this
                // from the account it reads anyway.
                if homeBootstrapCompleted {
                    Task { await self.loadAccountEntitlementIfNeeded() }
                }
            case .unauthorized:
                plexAuthLogger.notice("Server connect received 401 for \(server.name, privacy: .public) during bootstrap=\(self.isAuthenticationFresh, privacy: .public)")
                throw isAuthenticationFresh
                    ? AuthenticationBootstrapError.waitingForPropagation
                    : PlexServiceError.unauthorized
            case let .failed(reason):
                throw PlexServiceError.networkError(reason)
            }
        }
    }

    /// Probes every candidate connection concurrently and returns the working
    /// one with the highest priority (earliest in the sorted candidate list).
    ///
    /// The race is priority-preserving, not first-past-the-post: a candidate is
    /// only committed once no higher-priority candidate can still win — either
    /// because they have all resolved, or because the preference grace elapsed
    /// after the first success. This keeps local playback preferred when we're
    /// home while never blocking on a hung LAN address when we're away.
    private func probeConnections(
        candidates: [ConnectionCandidate],
        token: String,
        serverName: String
    ) async -> ConnectionResolution {
        let plans = buildProbePlans(candidates: candidates, token: token)
        guard !plans.isEmpty else {
            return .failed("Could not connect to \(serverName)")
        }

        let session = self.session
        let grace = Self.connectionPreferenceGrace
        let planByIndex = Dictionary(uniqueKeysWithValues: plans.map { ($0.index, $0) })

        return await withTaskGroup(of: ProbeEvent.self) { group -> ConnectionResolution in
            for plan in plans {
                group.addTask {
                    .probe(index: plan.index, result: await Self.runProbe(session: session, plan: plan))
                }
            }

            var pending = Set(plans.map(\.index))
            var bestIndex: Int?
            var sawUnauthorized = false
            var lastFailure = "Could not connect to \(serverName)"
            var graceStarted = false

            func winner() -> ConnectionResolution? {
                guard let bestIndex, let plan = planByIndex[bestIndex] else { return nil }
                return .connected(plan.baseURL, plan.connection)
            }

            // Once a success exists, we can commit as soon as no still-pending
            // candidate outranks it (nothing better can arrive).
            func bestIsUnbeatable() -> Bool {
                guard let bestIndex else { return false }
                return !pending.contains { $0 < bestIndex }
            }

            for await event in group {
                switch event {
                case let .probe(index, result):
                    pending.remove(index)
                    switch result {
                    case .success:
                        if bestIndex == nil || index < bestIndex! {
                            bestIndex = index
                        }
                        if !graceStarted {
                            graceStarted = true
                            group.addTask {
                                try? await Task.sleep(for: grace)
                                return .graceElapsed
                            }
                        }
                    case let .failure(unauthorized, reason):
                        if unauthorized { sawUnauthorized = true }
                        lastFailure = reason
                    }

                    if bestIsUnbeatable(), let resolution = winner() {
                        group.cancelAll()
                        return resolution
                    }
                case .graceElapsed:
                    // A better candidate was still pending, but we've waited long
                    // enough — go with the best working connection we have.
                    if let resolution = winner() {
                        group.cancelAll()
                        return resolution
                    }
                }

                if pending.isEmpty {
                    break
                }
            }

            if let resolution = winner() {
                group.cancelAll()
                return resolution
            }
            if sawUnauthorized {
                return .unauthorized
            }
            return .failed(lastFailure)
        }
    }

    private func buildProbePlans(candidates: [ConnectionCandidate], token: String) -> [ProbePlan] {
        candidates.enumerated().compactMap { index, candidate -> ProbePlan? in
            let timeout: TimeInterval = candidate.connection.local ? 20 : 8

            var probeRequest = URLRequest(url: candidate.probeURL)
            probeRequest.httpMethod = "GET"
            probeRequest.timeoutInterval = timeout
            applyHeaders(to: &probeRequest, token: token)

            guard let validationURL = buildURL(base: candidate.baseURL.absoluteString, path: "/library/sections") else {
                return nil
            }
            var validationRequest = URLRequest(url: validationURL)
            validationRequest.httpMethod = "GET"
            validationRequest.timeoutInterval = timeout
            validationRequest.cachePolicy = .reloadIgnoringLocalCacheData
            applyHeaders(to: &validationRequest, token: token)

            return ProbePlan(
                index: index,
                baseURL: candidate.baseURL,
                connection: candidate.connection,
                probeRequest: probeRequest,
                validationRequest: validationRequest
            )
        }
    }

    /// Runs one candidate's reachability probe (`/identity`) followed by an
    /// authorization check (`/library/sections`). Pure networking on Sendable
    /// inputs so it is safe to fan out across a task group off the main actor.
    private static func runProbe(session: URLSession, plan: ProbePlan) async -> ProbeChildResult {
        do {
            let (_, response) = try await session.data(for: plan.probeRequest)
            guard let http = response as? HTTPURLResponse else {
                return .failure(unauthorized: false, reason: "Invalid response")
            }
            if http.statusCode == 401 {
                return .failure(unauthorized: true, reason: "HTTP 401")
            }
            guard (200...299).contains(http.statusCode) else {
                return .failure(unauthorized: false, reason: "HTTP \(http.statusCode)")
            }

            let (_, validationResponse) = try await session.data(for: plan.validationRequest)
            guard let validationHTTP = validationResponse as? HTTPURLResponse else {
                return .failure(unauthorized: false, reason: "Invalid validation response")
            }
            switch validationHTTP.statusCode {
            case 200...299:
                return .success
            case 401:
                return .failure(unauthorized: true, reason: "HTTP 401")
            default:
                return .failure(unauthorized: false, reason: "HTTP \(validationHTTP.statusCode)")
            }
        } catch is CancellationError {
            return .failure(unauthorized: false, reason: "Cancelled")
        } catch {
            return .failure(unauthorized: false, reason: error.localizedDescription)
        }
    }

    private func rememberLastGoodConnection(_ connection: PlexConnection) {
        UserDefaults.standard.set(connection.uri, forKey: Self.defaultsLastGoodConnectionURIKey)
    }

    /// Refreshes the endpoint of a connection restored from disk, once per
    /// launch: the cached address may be stale (the LAN address after leaving
    /// home). Screens already run on the restored connection meanwhile, and
    /// `rawServerRequest` moves their requests if this picks another endpoint.
    func refreshRestoredConnectionIfNeeded() async throws {
        guard isConnected, !isConnectionVerified else { return }
        try await refreshConnectedServerConnection()
    }

    /// Re-resolves the selected server's endpoints from plex.tv and reconnects
    /// to the best one. Concurrent callers share one refresh, and a refresh
    /// started before `clearServer()` never commits.
    func refreshConnectedServerConnection() async throws {
        guard activeAccountToken != nil else { throw PlexServiceError.notAuthenticated }
        guard isConnected || connectedServer != nil else { throw PlexServiceError.noServerConnected }

        let generation = serverSelectionGeneration
        if let endpointRefresh, endpointRefresh.generation == generation {
            return try await endpointRefresh.task.value
        }

        let task = Task { [weak self] () throws -> Void in
            guard let self else { return }
            try await self.performEndpointRefresh(generation: generation)
        }
        endpointRefresh = (generation, task)
        defer {
            if endpointRefresh?.task == task {
                endpointRefresh = nil
            }
        }
        try await task.value
    }

    private func performEndpointRefresh(generation: Int) async throws {
        let currentServerID = connectedServer?.clientIdentifier.nilIfEmpty
            ?? UserDefaults.standard.string(forKey: Self.defaultsServerIDKey)?.nilIfEmpty
        // A lookup from moments ago (the launch's, sent before the first render)
        // is as good as a new one.
        let refreshedServers = try await discoverServers(reusingResultsWithin: Self.recentPlexTVResultReuseWindow)
        guard generation == serverSelectionGeneration else {
            throw CancellationError()
        }

        let refreshedServer: PlexServer?
        if let currentServerID {
            refreshedServer = refreshedServers.first { $0.clientIdentifier == currentServerID }
        } else if refreshedServers.count == 1 {
            refreshedServer = refreshedServers[0]
        } else {
            refreshedServer = nil
        }

        guard let refreshedServer else {
            if currentServerID != nil {
                clearServer()
            }
            throw PlexServiceError.noServerConnected
        }

        plexAuthLogger.notice("Refreshing Plex server endpoint for \(refreshedServer.name, privacy: .public)")
        try await connect(to: refreshedServer, expectedGeneration: generation)
    }

    func connectionCandidates(for server: PlexServer) -> [ConnectionCandidate] {
        var candidates: [ConnectionCandidate] = []
        var seen = Set<String>()

        for connection in server.sortedConnections where !connection.isKnownUnreachableAddress {
            if connection.local, let httpFallbackURI = connection.httpFallbackURI {
                appendConnectionCandidate(
                    uri: httpFallbackURI,
                    connection: connection,
                    seen: &seen,
                    into: &candidates
                )
            }

            if let privateOverlayDirectURI = connection.privateOverlayDirectURI {
                appendConnectionCandidate(
                    uri: privateOverlayDirectURI,
                    connection: connection,
                    seen: &seen,
                    into: &candidates
                )
            }

            appendConnectionCandidate(
                uri: connection.uri,
                connection: connection,
                seen: &seen,
                into: &candidates
            )

            if !connection.local, let httpFallbackURI = connection.httpFallbackURI {
                appendConnectionCandidate(
                    uri: httpFallbackURI,
                    connection: connection,
                    seen: &seen,
                    into: &candidates
                )
            }
        }

        return preferringLastGoodConnection(in: candidates)
    }

    /// Floats the last connection that successfully served this device to the
    /// front of its own priority tier ("remember which one works and stay on
    /// it") without ever promoting it across tiers — so a remembered remote
    /// connection never outranks a reachable LAN connection when we're home.
    private func preferringLastGoodConnection(in candidates: [ConnectionCandidate]) -> [ConnectionCandidate] {
        guard let lastGoodURI = UserDefaults.standard.string(forKey: Self.defaultsLastGoodConnectionURIKey)?.nilIfEmpty else {
            return candidates
        }

        return candidates.enumerated().sorted { lhs, rhs in
            let left = lhs.element
            let right = rhs.element
            if left.connection.sortPriority != right.connection.sortPriority {
                return left.connection.sortPriority < right.connection.sortPriority
            }
            let leftIsLastGood = left.connection.uri == lastGoodURI
            let rightIsLastGood = right.connection.uri == lastGoodURI
            if leftIsLastGood != rightIsLastGood {
                return leftIsLastGood
            }
            return lhs.offset < rhs.offset
        }
        .map(\.element)
    }

    func appendConnectionCandidate(
        uri: String,
        connection: PlexConnection,
        seen: inout Set<String>,
        into candidates: inout [ConnectionCandidate]
    ) {
        guard let baseURL = URL(string: uri),
              seen.insert(baseURL.absoluteString).inserted,
              let probeURL = buildURL(base: baseURL.absoluteString, path: "/identity") else {
            return
        }

        candidates.append(
            ConnectionCandidate(
                baseURL: baseURL,
                probeURL: probeURL,
                connection: connection
            )
        )
    }

    private func connectableServer(from server: PlexServer) async throws -> PlexServer {
        if isAuthenticationFresh {
            let refreshedServers = try await discoverServers()

            if let refreshedServer = refreshedServers.first(where: { $0.clientIdentifier == server.clientIdentifier }) {
                guard refreshedServer.usableAccessToken != nil else {
                    throw AuthenticationBootstrapError.waitingForPropagation
                }

                return refreshedServer
            }
        }

        guard server.usableAccessToken != nil else {
            throw PlexServiceError.networkError("Missing server access token for \(server.name)")
        }

        return server
    }

    func refreshConnectedServerAuthorization() async throws {
        guard let connectedServer else {
            throw PlexServiceError.noServerConnected
        }

        plexAuthLogger.notice("Refreshing server authorization for \(connectedServer.name, privacy: .public)")

        try await refreshConnectedServerConnection()
        plexAuthLogger.notice("Refreshed server authorization for \(connectedServer.name, privacy: .public)")
    }

    private func serverAccessToken(for server: PlexServer) throws -> String {
        if let token = server.usableAccessToken {
            return token
        }

        if isAuthenticationFresh {
            throw AuthenticationBootstrapError.waitingForPropagation
        }

        throw PlexServiceError.unauthorized
    }
}

struct ConnectionCandidate {
    let baseURL: URL
    let probeURL: URL
    let connection: PlexConnection
}

/// A prepared, Sendable unit of work for one candidate probe. The requests are
/// built on the main actor (they need `applyHeaders`) but carry no actor state,
/// so the actual networking can fan out across a task group.
private struct ProbePlan: Sendable {
    let index: Int
    let baseURL: URL
    let connection: PlexConnection
    let probeRequest: URLRequest
    let validationRequest: URLRequest
}

private enum ProbeChildResult: Sendable {
    case success
    case failure(unauthorized: Bool, reason: String)
}

private enum ProbeEvent: Sendable {
    case probe(index: Int, result: ProbeChildResult)
    case graceElapsed
}

enum ConnectionResolution: Sendable {
    case connected(URL, PlexConnection)
    case unauthorized
    case failed(String)
}
