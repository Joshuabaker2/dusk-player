import SwiftUI

/// Root view that routes between sign-in, server selection, and the main tab shell
/// based on PlexService auth/connection state.
struct ContentView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(PlaybackCoordinator.self) private var playback
    @State private var discoveredServers: [PlexServer]?
    @State private var connectError: String?
    @State private var homeBootstrapError: String?
    @State private var isBootstrappingHome = false

    var body: some View {
        Group {
            if !plexService.isAuthenticated {
                SignInView()
            } else if !plexService.homeBootstrapCompleted, !plexService.isResumingConfirmedSession {
                homeBootstrapView
            } else if plexService.needsHomeUserSelection {
                HomeUserPickerView(
                    users: plexService.homeUsers,
                    rememberSelection: plexService.automaticHomeSignIn,
                    onComplete: {
                        resetForHomeUserChange()
                    },
                    onSignOut: {
                        signOut()
                    }
                )
            } else if plexService.isConnected {
                MainTabView()
                    .id(plexService.activeProfileID)
            } else if let servers = discoveredServers, servers.count > 1 {
                ServerPickerView(servers: servers) { server in
                    try await plexService.connect(to: server)
                    discoveredServers = nil
                } onSignOut: {
                    signOut()
                }
            } else {
                serverDiscoveryView
            }
        }
        .animation(.default, value: plexService.isAuthenticated)
        .animation(.default, value: plexService.isConnected)
        .animation(.default, value: plexService.homeBootstrapCompleted)
        .animation(.default, value: plexService.needsHomeUserSelection)
        .background(Color.duskBackground.ignoresSafeArea())
        .duskSuppressTVOSButtonChrome()
        .task(id: plexService.isAuthenticated) {
            await bootstrapHomeIfNeeded()
        }
        .task(id: connectionRefreshTaskID) {
            await refreshRestoredConnectionIfNeeded()
        }
        .task(id: sharePlayReadinessTaskID) {
            await playback.retryPendingSharePlayActivityIfPossible()
        }
        .onChange(of: plexService.activeProfileID) { oldProfileID, newProfileID in
            guard oldProfileID != newProfileID else { return }
            resetForHomeUserChange()
        }
        .playerSharePlayPresentation(isPlayer: false)
    }

    /// Stable while a resumed session becomes a confirmed one, so the
    /// endpoint refresh started at launch is not cancelled and repeated.
    private var connectionRefreshTaskID: ConnectionRefreshTaskID {
        ConnectionRefreshTaskID(
            serverIdentifier: plexService.currentServerIdentifier,
            canUseServerSession: plexService.canUseServerSession
        )
    }

    private var sharePlayReadinessTaskID: SharePlayReadinessTaskID {
        SharePlayReadinessTaskID(
            isAuthenticated: plexService.isAuthenticated,
            homeBootstrapCompleted: plexService.homeBootstrapCompleted,
            needsHomeUserSelection: plexService.needsHomeUserSelection,
            serverIdentifier: plexService.currentServerIdentifier
        )
    }

    private var homeBootstrapView: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            VStack(spacing: 18) {
                if let homeBootstrapError {
                    Image(systemName: "person.2.slash")
                        .font(.largeTitle)
                        .foregroundStyle(Color.duskTextSecondary)

                    Text("Couldn’t load Plex")
                        .font(.headline)
                        .foregroundStyle(Color.duskTextPrimary)

                    Text(homeBootstrapError)
                        .foregroundStyle(Color.duskTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .frame(maxWidth: 680)

                    VStack(spacing: 12) {
                        if AuthenticationFailure.requiresReauthentication(message: homeBootstrapError) {
                            Button("Sign In") {
                                signOut()
                            }
                            .font(.headline)
                            .foregroundStyle(Color.duskPrimaryActionLabel)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                            .background(Color.primary.opacity(0.88), in: Capsule())
                            .duskSuppressTVOSButtonChrome()
                            .duskTVOSFocusEffectShape(Capsule())
                        } else {
                            Button("Retry") {
                                Task { await bootstrapHomeIfNeeded(force: true) }
                            }
                            .font(.headline)
                            .foregroundStyle(Color.duskPrimaryActionLabel)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                            .background(Color.primary.opacity(0.88), in: Capsule())
                            .disabled(isBootstrappingHome)
                            .duskSuppressTVOSButtonChrome()
                            .duskTVOSFocusEffectShape(Capsule())

                            Button("Sign Out", role: .destructive) {
                                signOut()
                            }
                            .font(.headline)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                            .background(.ultraThinMaterial, in: Capsule())
                            .duskSuppressTVOSButtonChrome()
                            .duskTVOSFocusEffectShape(Capsule())
                        }
                    }
                } else {
                    ProgressView()
                        .tint(Color.duskAccent)

                    Text("Loading…")
                        .foregroundStyle(Color.duskTextSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private var serverDiscoveryView: some View {
        ZStack {
            Color.duskBackground.ignoresSafeArea()

            VStack(spacing: 16) {
                if let error = connectError {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(Color.duskTextSecondary)
                    Text(error)
                        .foregroundStyle(Color.duskTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    VStack(spacing: 12) {
                        if AuthenticationFailure.requiresReauthentication(message: error) {
                            Button("Sign In") {
                                signOut()
                            }
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                            .background(Color.duskAccent, in: Capsule())
                            .duskSuppressTVOSButtonChrome()
                            .duskTVOSFocusEffectShape(Capsule())
                        } else {
                            Button("Retry") {
                                resetDiscoveryState()
                            }
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                            .background(Color.duskAccent, in: Capsule())
                            .duskSuppressTVOSButtonChrome()
                            .duskTVOSFocusEffectShape(Capsule())

                            Button("Sign Out", role: .destructive) {
                                signOut()
                            }
                            .font(.headline)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 12)
                            .background(.ultraThinMaterial, in: Capsule())
                            .duskSuppressTVOSButtonChrome()
                            .duskTVOSFocusEffectShape(Capsule())
                        }
                    }
                } else {
                    ProgressView()
                        .tint(Color.duskAccent)
                    Text("Finding your servers…")
                        .foregroundStyle(Color.duskTextSecondary)
                }
            }
        }
        .task(id: connectError == nil) {
            guard connectError == nil else { return }
            await discoverAndConnect()
        }
    }

    /// A launch shows Home on the connection restored from disk at once; its
    /// endpoint is refreshed alongside, not in front of it.
    private func refreshRestoredConnectionIfNeeded() async {
        guard plexService.canUseServerSession, plexService.isConnected else { return }

        do {
            try await plexService.refreshRestoredConnectionIfNeeded()
        } catch {
            // Superseded by a sign-out, Home switch or revoked resume.
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            if !plexService.isConnected {
                connectError = error.localizedDescription
            }
        }
    }

    private func discoverAndConnect() async {
        guard plexService.canUseServerSession else {
            return
        }

        do {
            let servers = try await plexService.discoverServers()
            if servers.isEmpty {
                connectError = "No Plex servers found on your account."
            } else if let preferredServerIdentifier = plexService.preferredServerIdentifier,
                      let preferredServer = servers.first(where: {
                          $0.clientIdentifier == preferredServerIdentifier
                      }) {
                try await plexService.connect(to: preferredServer)
                discoveredServers = nil
            } else if servers.count == 1 {
                try await plexService.connect(to: servers[0])
            } else {
                discoveredServers = servers
            }
        } catch {
            connectError = error.localizedDescription
        }
    }

    private func resetDiscoveryState() {
        connectError = nil
        discoveredServers = nil
    }

    private func bootstrapHomeIfNeeded(force: Bool = false) async {
        guard plexService.isAuthenticated else {
            homeBootstrapError = nil
            isBootstrappingHome = false
            return
        }

        guard force || !plexService.homeBootstrapCompleted else { return }
        guard !isBootstrappingHome else { return }

        isBootstrappingHome = true
        homeBootstrapError = nil

        do {
            try await plexService.bootstrapHomeSession()
        } catch {
            homeBootstrapError = error.localizedDescription
        }

        isBootstrappingHome = false
    }

    private func resetForHomeUserChange() {
        resetDiscoveryState()
    }

    private func signOut() {
        resetDiscoveryState()
        homeBootstrapError = nil
        isBootstrappingHome = false
        plexService.signOut()
    }
}

private struct ConnectionRefreshTaskID: Hashable {
    let serverIdentifier: String?
    let canUseServerSession: Bool
}

private struct SharePlayReadinessTaskID: Hashable {
    let isAuthenticated: Bool
    let homeBootstrapCompleted: Bool
    let needsHomeUserSelection: Bool
    let serverIdentifier: String?
}
