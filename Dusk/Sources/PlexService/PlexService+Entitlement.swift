import Foundation

/// Why remote streaming is unavailable for the current session.
enum RemoteStreamingRestriction: Sendable, Equatable {
    /// The user owns this server, is away from its local network, and the
    /// account has no active Plex Pass / Remote Watch Pass. Since April 2025
    /// Plex requires the server owner (or the streaming user) to hold one of
    /// those to stream personal media remotely; only local streaming is free.
    case ownerNeedsPlexPass

    var message: String {
        switch self {
        case .ownerNeedsPlexPass:
            return """
            Remote streaming needs Plex Pass. You're away from your server's local network, \
            and Plex now requires the server owner to have an active Plex Pass (or Remote Watch \
            Pass) to stream personal media remotely. Connect to your home Wi-Fi to keep watching, \
            or get Plex Pass at plex.tv.
            """
        }
    }
}

/// Who an account token belongs to and its subscription state, read from
/// `GET https://plex.tv/api/v2/user`.
struct PlexAccountSnapshot: Sendable {
    let user: PlexUser
    /// nil when the response could not be read for it.
    let subscriptionActive: Bool?
}

extension PlexService {
    private struct AccountEntitlementResponse: Decodable {
        let subscription: PlexSubscription?
    }

    /// One query for every reader of the account document, so they can share a
    /// request: the library order needs the settings, entitlement the
    /// subscription, the Home bootstrap the identity.
    static let accountDocumentQuery = [
        URLQueryItem(name: "includeSubscriptions", value: "1"),
        URLQueryItem(name: "includeProviders", value: "1"),
        URLQueryItem(name: "includeSettings", value: "1"),
        URLQueryItem(name: "includeSharedSettings", value: "1"),
    ]

    /// `GET /api/v2/user` with subscriptions, providers and settings.
    ///
    /// Shared: a request already out for `token`, or one that finished within
    /// `recentPlexTVResultReuseWindow`, answers instead of a new one. At launch
    /// the Home bootstrap and the library-order read both want this document
    /// for the same account. The caller that starts a request sets its timeout
    /// and retry policy; failures are never reused.
    func accountDocument(
        token: String,
        timeoutInterval: TimeInterval? = nil,
        retriesFreshAuthentication: Bool = true
    ) async throws -> Data {
        if let shared = accountDocuments[token],
           shared.finishedAt.map({ Date().timeIntervalSince($0) < Self.recentPlexTVResultReuseWindow }) ?? true {
            return try await shared.task.value
        }

        let task = Task { [weak self] () throws -> Data in
            guard let self else { throw CancellationError() }
            return try await self.rawPlexTVRequest(
                path: "/api/v2/user",
                queryItems: Self.accountDocumentQuery,
                accountToken: token,
                timeoutInterval: timeoutInterval,
                retriesFreshAuthentication: retriesFreshAuthentication
            )
        }
        shareAccountDocument(task, for: token)
        return try await task.value
    }

    /// Publishes an account-document request for `accountDocument(token:)`
    /// readers and stamps it once it finishes.
    func shareAccountDocument(_ task: Task<Data, Error>, for token: String) {
        accountDocuments[token] = (task, nil)
        Task { [weak self] in
            let result = await task.result
            guard let self, self.accountDocuments[token]?.task == task else { return }
            switch result {
            case .success:
                self.accountDocuments[token]?.finishedAt = Date()
            case .failure:
                self.accountDocuments[token] = nil
            }
        }
    }

    /// The account behind `token`, from the shared account document. Plex
    /// answers 404 there for an account that has no settings record yet; the
    /// plain `/api/v2/user` still identifies it.
    func accountSnapshot(
        token: String,
        retriesFreshAuthentication: Bool = true
    ) async throws -> PlexAccountSnapshot {
        let data: Data
        do {
            data = try await accountDocument(
                token: token,
                retriesFreshAuthentication: retriesFreshAuthentication
            )
        } catch PlexServiceError.httpError(statusCode: 404) {
            data = try await rawPlexTVRequest(
                path: "/api/v2/user",
                accountToken: token,
                retriesFreshAuthentication: retriesFreshAuthentication
            )
        }

        let user = try decodeJSON(PlexUser.self, from: data)
        let entitlement = try? decoder.decode(AccountEntitlementResponse.self, from: data)
        return PlexAccountSnapshot(
            user: user,
            subscriptionActive: entitlement.map { $0.subscription?.isActive ?? false }
        )
    }

    /// nil = not yet known, true/false = fetched from the account.
    var accountHasRemoteStreamingEntitlement: Bool? {
        accountSubscriptionActive
    }

    /// Best-effort, cached lookup of the account's subscription state. Never
    /// throws: on failure the state stays `nil` (unknown) so we never wrongly
    /// block playback on a transient plex.tv hiccup. The Home bootstrap seeds
    /// it from the account it already read, so this rarely needs a request.
    func loadAccountEntitlementIfNeeded() async {
        guard accountSubscriptionActive == nil, let token = activeAccountToken else { return }

        do {
            let account = try await accountSnapshot(token: token)
            // A Home switch while this was out makes the answer someone else's.
            guard activeAccountToken == token else { return }
            accountSubscriptionActive = account.subscriptionActive
        } catch {
            plexAuthLogger.notice(
                "Account entitlement lookup failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Detects the Plex Pass remote-streaming restriction for online playback.
    ///
    /// Only decides for servers the account owns: there, the streaming user *is*
    /// the owner, so the account's own subscription is authoritative. For shared
    /// servers the owner's entitlement isn't visible to the client, so we don't
    /// pre-empt playback — those simply fall through to the normal error path.
    /// Returns nil unless we positively know the entitlement is missing.
    func remoteStreamingRestriction() async -> RemoteStreamingRestriction? {
        guard isConnectedRemotely,
              let server = connectedServer,
              server.owned,
              activeHomeUser?.isRestricted != true else {
            return nil
        }

        await loadAccountEntitlementIfNeeded()

        return accountSubscriptionActive == false ? .ownerNeedsPlexPass : nil
    }
}
