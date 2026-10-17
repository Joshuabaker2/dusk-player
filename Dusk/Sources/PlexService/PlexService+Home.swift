import Foundation
import OSLog

/// What the last successful Home bootstrap confirmed on this device: the
/// identity and the profile it showed. A cold launch resumes Home from the
/// persisted server only while the restored session is exactly this one.
enum ConfirmedLaunchIdentity: Equatable {
    /// The linked account itself; its Plex Home had at most one member.
    case primaryAccount(profileID: String)
    /// A multi-user Home member restored by automatic sign-in.
    case rememberedHomeUser(profileID: String)

    private static let primaryPrefix = "primary:"
    private static let homeUserPrefix = "home-user:"

    init?(rawValue: String) {
        if rawValue.hasPrefix(Self.primaryPrefix),
           let profileID = String(rawValue.dropFirst(Self.primaryPrefix.count)).nilIfEmpty {
            self = .primaryAccount(profileID: profileID)
        } else if rawValue.hasPrefix(Self.homeUserPrefix),
                  let profileID = String(rawValue.dropFirst(Self.homeUserPrefix.count)).nilIfEmpty {
            self = .rememberedHomeUser(profileID: profileID)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case let .primaryAccount(profileID):
            return Self.primaryPrefix + profileID
        case let .rememberedHomeUser(profileID):
            return Self.homeUserPrefix + profileID
        }
    }
}

extension PlexService {
    /// Resolves the linked account's Plex Home and restores an automatically
    /// signed-in member when possible.
    ///
    /// Existing installations get one compatibility escape hatch: if their
    /// first Home lookup after upgrading fails transiently, a previously
    /// connected legacy session remains usable for that launch. Once a Home
    /// lookup succeeds, known multi-user accounts always fail closed.
    ///
    /// A launch that `canResumeConfirmedSession` runs Home on the persisted
    /// server while this works (`isResumingConfirmedSession`). Every outcome
    /// other than confirming that same identity ends it: a newly multi-user
    /// Home or an invalid remembered member clears the server and requires a
    /// selection, and a failed lookup leaves the error screen, as before.
    /// Concurrent callers share one bootstrap.
    func bootstrapHomeSession() async throws {
        if let homeBootstrapTask {
            return try await homeBootstrapTask.value
        }

        let task = Task { [weak self] () throws -> Void in
            guard let self else { return }
            try await self.performHomeBootstrap()
        }
        homeBootstrapTask = task
        defer {
            if homeBootstrapTask == task {
                homeBootstrapTask = nil
            }
        }
        try await task.value
    }

    /// Whether this launch can show Home from the persisted server while the
    /// Home bootstrap runs: the last bootstrap confirmed exactly the identity
    /// and profile restored from disk, and that identity's server, endpoint and
    /// server token survived. Anything else waits for the bootstrap.
    var canResumeConfirmedSession: Bool {
        guard primaryAccountToken != nil,
              connectedServer != nil,
              serverBaseURL != nil,
              serverAuthToken != nil,
              let rawIdentity = UserDefaults.standard.string(
                  forKey: Self.defaultsConfirmedLaunchIdentityKey
              ),
              let identity = ConfirmedLaunchIdentity(rawValue: rawIdentity) else {
            return false
        }

        switch identity {
        case let .primaryAccount(profileID):
            return !hasRememberedHomeUserToken
                && activeAccountToken == primaryAccountToken
                && activeProfileID == profileID
        case let .rememberedHomeUser(profileID):
            return automaticHomeSignIn
                && hasRememberedHomeUserToken
                && activeHomeUser?.stableProfileID == profileID
                && activeProfileID == profileID
        }
    }

    /// Sends a resumed launch's plex.tv requests from `init`, off the main
    /// actor. The first render holds the main actor for hundreds of
    /// milliseconds, and the Home bootstrap and endpoint refresh cannot start
    /// before it ends; they pick these up instead of sending their own:
    /// the Home user list, the account document (the library-order read shares
    /// it too) and the server resources.
    func startResumedLaunchRequests() {
        guard let primaryAccountToken else { return }
        let session = self.session

        if let request = makePlexTVRequest(path: "/api/v2/home/users", token: primaryAccountToken) {
            launchHomeUsersRequest = (
                primaryAccountToken,
                Task.detached(priority: .userInitiated) {
                    try await Self.performRequest(request, session: session)
                }
            )
        }

        var accountTokens = [primaryAccountToken]
        if hasRememberedHomeUserToken, let activeAccountToken, activeAccountToken != primaryAccountToken {
            accountTokens.append(activeAccountToken)
        }
        for token in accountTokens {
            guard let request = makePlexTVRequest(
                path: "/api/v2/user",
                queryItems: Self.accountDocumentQuery,
                token: token
            ) else { continue }
            shareAccountDocument(
                Task.detached(priority: .userInitiated) {
                    try await Self.performRequest(request, session: session)
                },
                for: token
            )
        }

        if let activeAccountToken, let request = makeResourcesRequest(token: activeAccountToken) {
            let task = Task.detached(priority: .userInitiated) { () throws -> [PlexServer] in
                let data = try await Self.performRequest(request, session: session)
                return try Self.decodeServers(fromResources: data)
            }
            serverDiscovery = (activeAccountToken, task)
            Task { [weak self] in
                let result = await task.result
                guard let self, self.serverDiscovery?.task == task else { return }
                self.serverDiscovery = nil
                if case let .success(servers) = result, self.activeAccountToken == activeAccountToken {
                    self.lastServerDiscovery = (activeAccountToken, Date(), servers)
                }
            }
        }
    }

    /// Holds playback started on a resuming session until this launch's Home
    /// bootstrap confirms the identity, so nothing plays on credentials the
    /// bootstrap may still revoke.
    func confirmHomeSessionForPlayback() async throws {
        guard isResumingConfirmedSession else { return }
        try await bootstrapHomeSession()
        guard homeBootstrapCompleted, !needsHomeUserSelection else {
            throw PlexServiceError.homeUserUnavailable
        }
    }

    private func performHomeBootstrap() async throws {
        guard let primaryAccountToken else {
            throw PlexServiceError.notAuthenticated
        }
        defer { isResumingConfirmedSession = false }

        // A remembered member's token is checked alongside the Home lookup
        // rather than after it.
        let rememberedToken = automaticHomeSignIn && hasRememberedHomeUserToken && activeHomeUser != nil
            ? activeAccountToken
            : nil

        do {
            async let fetchedUsers = fetchHomeUsers(primaryToken: primaryAccountToken)
            async let fetchedPrimaryAccount = accountSnapshot(token: primaryAccountToken)
            async let rememberedAccount = rememberedAccountCheck(token: rememberedToken)

            let users = try await fetchedUsers
            let primaryAccount = try await fetchedPrimaryAccount
            // Signing out or into another account while this was out makes the
            // answer stale; never commit it over the new state.
            guard self.primaryAccountToken == primaryAccountToken else {
                throw CancellationError()
            }
            updatePrimaryProfileIdentity(from: primaryAccount.user, homeUsers: users)
            homeUsers = users

            if users.count <= 1 {
                activatePrimaryAccount(homeUser: users.first)
                accountSubscriptionActive = primaryAccount.subscriptionActive
                markHomeBootstrapCompleted()
                recordConfirmedLaunchIdentity(activeProfileID.map { .primaryAccount(profileID: $0) })
                return
            }

            if automaticHomeSignIn,
               let restoredUser = restoredHomeUser(in: users),
               hasRememberedHomeUserToken,
               let activeAccountToken {
                var check = await rememberedAccount
                if check == nil || rememberedToken != activeAccountToken {
                    check = await rememberedAccountCheck(token: activeAccountToken)
                }
                guard self.primaryAccountToken == primaryAccountToken,
                      self.activeAccountToken == activeAccountToken else {
                    throw CancellationError()
                }
                if let check, validateRestoredHomeSession(user: restoredUser, check: check) {
                    activeHomeUser = restoredUser
                    homeSelectionRequested = false
                    if case let .success(account) = check {
                        accountSubscriptionActive = account.subscriptionActive
                    }
                    persistActiveHomeUser(restoredUser)
                    markHomeBootstrapCompleted()
                    recordConfirmedLaunchIdentity(.rememberedHomeUser(profileID: restoredUser.stableProfileID))
                    return
                }
            }

            // An old server token may have owner-level access. Do not let it
            // survive the moment we learn this is a multi-user Home.
            clearServer()
            activeAccountToken = primaryAccountToken
            activeHomeUser = nil
            currentUser = nil
            accountSubscriptionActive = nil
            homeSelectionRequested = true
            hasRememberedHomeUserToken = false
            KeychainHelper.delete(key: Self.keychainActiveHomeTokenKey)
            recordConfirmedLaunchIdentity(nil)
            markHomeBootstrapCompleted()
        } catch {
            let migrationCompleted = UserDefaults.standard.bool(
                forKey: Self.defaultsHomeMigrationCompletedKey
            )
            if !migrationCompleted, connectedServer != nil, serverBaseURL != nil {
                // Preserve the pre-Home behavior for one offline/transient
                // upgraded launch. We intentionally do not mark migration as
                // complete, so the next launch checks again.
                activeAccountToken = primaryAccountToken
                homeBootstrapCompleted = true
                homeSelectionRequested = false
                plexAuthLogger.notice(
                    "Plex Home bootstrap unavailable; preserving legacy session until the next launch"
                )
                return
            }
            throw error
        }
    }

    /// Switches the active Plex identity. The PIN is sent only in this request
    /// and is never written to Keychain, UserDefaults, logs, or a model.
    func switchHomeUser(
        _ user: PlexHomeUser,
        pin: String?,
        remember: Bool
    ) async throws {
        guard homeUsers.contains(where: { $0.id == user.id }) else {
            throw PlexServiceError.homeUserUnavailable
        }
        guard let primaryAccountToken else {
            throw PlexServiceError.notAuthenticated
        }

        let normalizedPIN = pin?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        if user.isProtected, normalizedPIN == nil {
            throw PlexServiceError.homePINRequired
        }

        let responseData: Data
        do {
            responseData = try await rawPlexTVRequest(
                method: "POST",
                path: "/api/home/users/\(user.id)/switch",
                queryItems: normalizedPIN.map { [URLQueryItem(name: "pin", value: $0)] },
                accountToken: primaryAccountToken,
                retriesFreshAuthentication: false
            )
        } catch let error as PlexServiceError {
            if user.isProtected,
               error == .unauthorized || error == .httpError(statusCode: 403) {
                throw PlexServiceError.homePINIncorrect
            }
            throw error
        }

        guard let switchedToken = switchToken(from: responseData) else {
            throw PlexServiceError.decodingError(
                "Plex did not return an account token when switching Home users."
            )
        }

        // Commit only after the switch succeeds, so a wrong PIN leaves the
        // existing playback/session state intact.
        clearServer()
        activeAccountToken = switchedToken
        activeHomeUser = user
        currentUser = nil
        accountSubscriptionActive = nil
        authTokenUpdatedAt = Date()
        homeSelectionRequested = false
        automaticHomeSignIn = remember
        persistActiveHomeUser(user)

        if remember {
            hasRememberedHomeUserToken = true
            KeychainHelper.save(
                key: Self.keychainActiveHomeTokenKey,
                data: Data(switchedToken.utf8)
            )
            recordConfirmedLaunchIdentity(.rememberedHomeUser(profileID: user.stableProfileID))
        } else {
            hasRememberedHomeUserToken = false
            KeychainHelper.delete(key: Self.keychainActiveHomeTokenKey)
            recordConfirmedLaunchIdentity(nil)
        }
    }

    /// Makes the shared picker visible without signing out or discarding the
    /// current session. State is cleared only after another user successfully
    /// switches.
    func requestHomeUserSelection() {
        guard hasPlexHome else { return }
        homeSelectionRequested = true
    }

    /// Lets a presented picker be dismissed when it was opened from Settings.
    /// Startup selection remains mandatory because it has no active Home user.
    func cancelHomeUserSelection() {
        guard activeHomeUser != nil else { return }
        homeSelectionRequested = false
    }

    func setAutomaticHomeSignIn(_ enabled: Bool) {
        automaticHomeSignIn = enabled
    }

    func automaticHomeSignInDidChange() {
        let enabled = automaticHomeSignIn
        UserDefaults.standard.set(enabled, forKey: Self.defaultsAutomaticHomeSignInKey)

        guard enabled else {
            hasRememberedHomeUserToken = false
            KeychainHelper.delete(key: Self.keychainActiveHomeTokenKey)
            if case .rememberedHomeUser = confirmedLaunchIdentity {
                recordConfirmedLaunchIdentity(nil)
            }
            return
        }

        guard activeHomeUser != nil, let activeAccountToken else { return }
        hasRememberedHomeUserToken = true
        KeychainHelper.save(
            key: Self.keychainActiveHomeTokenKey,
            data: Data(activeAccountToken.utf8)
        )
    }

    private func fetchHomeUsers(primaryToken: String) async throws -> [PlexHomeUser] {
        let data: Data
        if let launchRequest = launchHomeUsersRequest, launchRequest.token == primaryToken {
            launchHomeUsersRequest = nil
            data = try await launchRequest.task.value
        } else {
            data = try await rawPlexTVRequest(
                path: "/api/v2/home/users",
                accountToken: primaryToken
            )
        }
        return try decodeHomeUsers(from: data)
    }

    private var confirmedLaunchIdentity: ConfirmedLaunchIdentity? {
        UserDefaults.standard
            .string(forKey: Self.defaultsConfirmedLaunchIdentityKey)
            .flatMap(ConfirmedLaunchIdentity.init(rawValue:))
    }

    func recordConfirmedLaunchIdentity(_ identity: ConfirmedLaunchIdentity?) {
        if let identity {
            UserDefaults.standard.set(identity.rawValue, forKey: Self.defaultsConfirmedLaunchIdentityKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsConfirmedLaunchIdentityKey)
        }
    }

    private func updatePrimaryProfileIdentity(
        from account: PlexUser,
        homeUsers: [PlexHomeUser]
    ) {
        let matchingHomeUser: PlexHomeUser?
        if let uuid = account.uuid?.nilIfEmpty {
            matchingHomeUser = homeUsers.first { $0.uuid == uuid }
        } else {
            matchingHomeUser = homeUsers.first {
                $0.id == account.id
                    || ($0.username != nil && $0.username == account.username)
            }
        }

        let resolvedID = matchingHomeUser?.stableProfileID
            ?? account.uuid?.nilIfEmpty
            ?? "plex-account-\(account.id)"

        primaryProfileID = resolvedID
        UserDefaults.standard.set(resolvedID, forKey: Self.defaultsPrimaryProfileIDKey)
    }

    private func activatePrimaryAccount(homeUser: PlexHomeUser?) {
        activeAccountToken = primaryAccountToken
        activeHomeUser = homeUser
        currentUser = nil
        accountSubscriptionActive = nil
        homeSelectionRequested = false
        KeychainHelper.delete(key: Self.keychainActiveHomeTokenKey)
        hasRememberedHomeUserToken = false

        if let homeUser {
            persistActiveHomeUser(homeUser)
            if primaryProfileID == nil {
                primaryProfileID = homeUser.stableProfileID
                UserDefaults.standard.set(
                    homeUser.stableProfileID,
                    forKey: Self.defaultsPrimaryProfileIDKey
                )
            }
        } else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsActiveHomeUserDataKey)
        }
    }

    private func restoredHomeUser(in users: [PlexHomeUser]) -> PlexHomeUser? {
        guard let activeHomeUser else { return nil }
        return users.first {
            $0.stableProfileID == activeHomeUser.stableProfileID
                || $0.id == activeHomeUser.id
        }
    }

    private func persistActiveHomeUser(_ user: PlexHomeUser) {
        if let data = try? encoder.encode(user) {
            UserDefaults.standard.set(data, forKey: Self.defaultsActiveHomeUserDataKey)
        }
    }

    private func markHomeBootstrapCompleted() {
        homeBootstrapCompleted = true
        UserDefaults.standard.set(true, forKey: Self.defaultsHomeMigrationCompletedKey)
    }

    private func decodeHomeUsers(from data: Data) throws -> [PlexHomeUser] {
        if let users = try? decoder.decode([PlexHomeUser].self, from: data) {
            return users
        }

        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw PlexServiceError.decodingError("Invalid Plex Home users response.")
        }

        let rawUsers: [Any]?
        if let dictionary = object as? [String: Any] {
            rawUsers = Self.userArray(in: dictionary)
        } else {
            rawUsers = nil
        }

        guard let rawUsers else {
            throw PlexServiceError.decodingError(
                "Expected a Plex Home users array or envelope."
            )
        }

        let users = rawUsers.compactMap { rawUser -> PlexHomeUser? in
            guard JSONSerialization.isValidJSONObject(rawUser),
                  let userData = try? JSONSerialization.data(withJSONObject: rawUser) else {
                return nil
            }
            return try? decoder.decode(PlexHomeUser.self, from: userData)
        }

        if users.count != rawUsers.count {
            throw PlexServiceError.decodingError(
                "Plex Home returned users in an unsupported format."
            )
        }
        return users
    }

    private static func userArray(in dictionary: [String: Any]) -> [Any]? {
        for key in ["users", "Users", "User", "Metadata"] {
            if let users = dictionary[key] as? [Any] {
                return users
            }
            if let nested = dictionary[key] as? [String: Any],
               let users = userArray(in: nested) {
                return users
            }
        }

        if let container = dictionary["MediaContainer"] as? [String: Any] {
            return userArray(in: container)
        }
        if let container = dictionary["mediaContainer"] as? [String: Any] {
            return userArray(in: container)
        }
        return nil
    }

    private func switchToken(from data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data),
           let token = Self.switchToken(in: object) {
            return token
        }

        let parserDelegate = PlexHomeSwitchTokenParser()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        return parser.parse() ? parserDelegate.token : nil
    }

    private static func switchToken(in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            for key in ["authToken", "authenticationToken"] {
                if let token = dictionary[key] as? String,
                   let token = token.nilIfEmpty {
                    return token
                }
            }
            for key in ["user", "User", "account"] {
                if let nested = dictionary[key],
                   let token = switchToken(in: nested) {
                    return token
                }
            }
        }
        return nil
    }

    /// Reads the account behind a remembered member's token. nil when there is
    /// no remembered token to check.
    private func rememberedAccountCheck(token: String?) async -> Result<PlexAccountSnapshot, Error>? {
        guard let token else { return nil }
        do {
            return .success(try await accountSnapshot(token: token, retriesFreshAuthentication: false))
        } catch {
            return .failure(error)
        }
    }

    private func validateRestoredHomeSession(
        user: PlexHomeUser,
        check: Result<PlexAccountSnapshot, Error>
    ) -> Bool {
        switch check {
        case let .success(snapshot):
            let account = snapshot.user
            if let expectedUUID = user.uuid?.nilIfEmpty,
               let actualUUID = account.uuid?.nilIfEmpty {
                return expectedUUID == actualUUID
            }
            return account.id == user.id
                || (user.username != nil && user.username == account.username)
        case let .failure(error as PlexServiceError)
            where error == .unauthorized || error == .httpError(statusCode: 403):
            plexAuthLogger.notice(
                "Remembered Plex Home token is no longer valid; requiring user selection"
            )
            return false
        case let .failure(error):
            // The primary Home list already confirmed this member still exists.
            // A non-auth validation failure should not discard a remembered
            // offline-capable identity due to a transient Plex response.
            plexAuthLogger.notice(
                "Could not validate remembered Plex Home token: \(error.localizedDescription, privacy: .public)"
            )
            return true
        }
    }
}

private final class PlexHomeSwitchTokenParser: NSObject, XMLParserDelegate {
    private(set) var token: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard token == nil else { return }
        token = attributeDict["authenticationToken"]?.nilIfEmpty
            ?? attributeDict["authToken"]?.nilIfEmpty
    }
}
