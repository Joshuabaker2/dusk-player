import SwiftUI

#if !os(tvOS)
struct SettingsIOSView: View {
    @Environment(PlexService.self) private var plexService
    @Environment(SeerrService.self) private var seerrService
    @Environment(UserPreferences.self) private var preferences
    @Environment(DownloadManager.self) private var downloadManager
    @Environment(OfflinePlaybackSyncManager.self) private var offlinePlaybackSyncManager
    @Environment(SupporterStore.self) private var supporterStore
    @Environment(\.openURL) private var openURL
    @Environment(\.duskNavigate) private var navigate
    @State private var presentedAccountURL: URL?
    @State private var confirmsDeletingDownloads = false
    @State private var showsSupporterSheet = false
    @State private var showsIconPicker = false
    @State private var directionalFocus: SettingsDirectionalFocusTarget?
    let viewModel: SettingsViewModel
    let isSelected: Bool

    var body: some View {
        SettingsContainer(viewModel: viewModel) {
            settingsContent
        }
        .sheet(isPresented: accountSheetPresented) {
            if let presentedAccountURL {
                DuskSafariView(url: presentedAccountURL)
            }
        }
        .sheet(isPresented: $showsSupporterSheet) {
            SupporterView(context: .settings)
        }
        .sheet(isPresented: $showsIconPicker) {
            AppIconPickerView()
        }
        .confirmationDialog(
            "Delete all downloads?",
            isPresented: $confirmsDeletingDownloads,
            titleVisibility: .visible
        ) {
            Button("Delete All Downloads", role: .destructive) {
                downloadManager.deleteAllDownloads()
                offlinePlaybackSyncManager.deleteAllLocalState()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Downloaded videos, saved metadata, artwork, pause data, and queue entries will be removed from this device.")
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        @Bindable var preferences = preferences
        let subtitleLanguageBinding = SettingsSupport.subtitleLanguageBinding(preferences)

        DuskDirectionalFocusScope(
            focusedID: $directionalFocus,
            groups: [.grid(directionalTargets, columnCount: 1)],
            defaultFocus: directionalTargets.first,
            isEnabled: supportsDirectionalSelection,
            onActivate: activateDirectionalTarget,
            onDirectionalBoundary: adjustDirectionalTarget
        ) {
            ScrollViewReader { proxy in
                List {
            Section {
                Button {
                    showsSupporterSheet = true
                } label: {
                    SettingsAboutRow(
                        title: supporterStore.isSupporter ? "You're a Supporter" : "Support Dusk",
                        subtitle: supporterStore.isSupporter
                            ? "Thank you for making Dusk possible ❤️"
                            : "Free, no ads, no tracking — chip in if you like it",
                        systemImage: "heart.fill",
                        trailingSystemImage: "chevron.right"
                    )
                }
                .duskSuppressTVOSButtonChrome()
                .settingsDirectionalTarget(.support, focused: directionalFocus, isEnabled: supportsDirectionalSelection)
            }
            .listRowBackground(Color.duskSurface)

            if plexService.homeUsers.count > 1, let activeUser = plexService.activeHomeUser {
                Section {
                    HStack(spacing: 16) {
                        PlexHomeUserAvatar(user: activeUser, size: 48)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Current User")
                                .font(.caption.weight(.semibold))
                                .textCase(.uppercase)
                                .tracking(0.4)
                                .foregroundStyle(Color.duskTextSecondary)

                            Text(activeUser.displayName)
                                .font(.body.weight(.medium))
                                .foregroundStyle(Color.duskTextPrimary)
                                .lineLimit(1)
                        }

                        Spacer()
                    }
                    .padding(.vertical, 6)

                    Button {
                        viewModel.showHomeUserPicker = true
                    } label: {
                        HStack {
                            Text("Switch User")
                                .foregroundStyle(Color.duskAccent)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.duskTextSecondary)
                        }
                    }
                    .duskSuppressTVOSButtonChrome()
                    .settingsDirectionalTarget(.switchUser, focused: directionalFocus, isEnabled: supportsDirectionalSelection)

                    Toggle("Automatically Sign In", isOn: automaticHomeSignInBinding)
                        .foregroundStyle(Color.duskTextPrimary)
                        .tint(Color.duskAccent)
                        .settingsDirectionalTarget(.automaticSignIn, focused: directionalFocus, isEnabled: supportsDirectionalSelection)
                } header: {
                    Text("Plex Home")
                        .foregroundStyle(Color.duskTextSecondary)
                } footer: {
                    Text("When off, Dusk asks who’s watching whenever it starts.")
                        .foregroundStyle(Color.duskTextSecondary)
                }
                .listRowBackground(Color.duskSurface)
            }

            if viewModel.hasMultipleServers {
                Section {
                    if let server = plexService.connectedServer {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(server.name)
                                    .foregroundStyle(Color.duskTextPrimary)
                                Text(viewModel.connectionType)
                                    .font(.caption)
                                    .foregroundStyle(Color.duskTextSecondary)
                            }

                            Spacer()

                            Circle()
                                .fill(Color.duskAccent)
                                .frame(width: 8, height: 8)
                        }
                    } else {
                        Text("Not connected")
                            .foregroundStyle(Color.duskTextSecondary)
                    }

                    Button {
                        viewModel.showServerPicker = true
                    } label: {
                        HStack {
                            Text("Change Server")
                                .foregroundStyle(Color.duskAccent)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.duskTextSecondary)
                        }
                    }
                    .duskSuppressTVOSButtonChrome()
                    .settingsDirectionalTarget(.changeServer, focused: directionalFocus, isEnabled: supportsDirectionalSelection)
                } header: {
                    Text("Plex Server")
                        .foregroundStyle(Color.duskTextSecondary)
                }
                .listRowBackground(Color.duskSurface)
            }

            Section {
                NavigationLink(value: AppNavigationRoute.seerrSettings) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Seerr")
                            .foregroundStyle(Color.duskTextPrimary)
                        Text(seerrService.connectionSubtitle)
                            .font(.caption)
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                }
                .settingsDirectionalTarget(.seerr, focused: directionalFocus, isEnabled: supportsDirectionalSelection)
            } header: {
                Text("Integrations")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text("Optionally add requestable movies and shows to search.")
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            Section {
                NavigationLink(value: AppNavigationRoute.libraryTabSettings) {
                    HStack {
                        Text("Navigation Tabs")
                            .foregroundStyle(Color.duskTextPrimary)

                        Spacer()

                        Text(SettingsSupport.libraryTabsSummary(preferences))
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                }
                .settingsDirectionalTarget(.navigationTabs, focused: directionalFocus, isEnabled: supportsDirectionalSelection)

                NavigationLink(value: AppNavigationRoute.libraryOrderSettings) {
                    HStack {
                        Text("Library Order")
                            .foregroundStyle(Color.duskTextPrimary)

                        Spacer()

                        Text(SettingsSupport.libraryOrderSummary(plexService))
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                }
                .settingsDirectionalTarget(.libraryOrder, focused: directionalFocus, isEnabled: supportsDirectionalSelection)
            } header: {
                Text("Navigation")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(SettingsSupport.navigationFooterText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            Section {
                Toggle("Show Live TV", isOn: $preferences.showsLiveTVOnHome)
                    .foregroundStyle(Color.duskTextPrimary)
                    .tint(Color.duskAccent)
            } header: {
                Text("Home")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(SettingsSupport.homeFooterText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            Section {
                Picker("Max Resolution", selection: $preferences.maxResolution) {
                    ForEach(MaxResolution.allCases) { resolution in
                        Text(resolution.displayName).tag(resolution)
                    }
                }
                .foregroundStyle(Color.duskTextPrimary)
                .settingsDirectionalTarget(.maxResolution, focused: directionalFocus, isEnabled: supportsDirectionalSelection)

                Picker("Subtitles", selection: subtitleLanguageBinding) {
                    ForEach(SettingsSupport.subtitleLanguageOptions, id: \.self) { languageCode in
                        Text(SettingsSupport.subtitleDisplayName(for: languageCode)).tag(languageCode)
                    }
                }
                .foregroundStyle(Color.duskTextPrimary)
                .settingsDirectionalTarget(.subtitles, focused: directionalFocus, isEnabled: supportsDirectionalSelection)

                Toggle("Forced Only", isOn: $preferences.subtitleForcedOnly)
                    .foregroundStyle(Color.duskTextPrimary)
                    .tint(Color.duskAccent)
                    .settingsDirectionalTarget(.forcedOnly, focused: directionalFocus, isEnabled: supportsDirectionalSelection)

                Picker("Subtitle Size", selection: $preferences.subtitleTextSize) {
                    ForEach(SubtitleTextSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
                .foregroundStyle(Color.duskTextPrimary)
                .settingsDirectionalTarget(.subtitleSize, focused: directionalFocus, isEnabled: supportsDirectionalSelection)

                Picker("Subtitle Style", selection: $preferences.subtitleTextStyle) {
                    ForEach(SubtitleTextStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                .foregroundStyle(Color.duskTextPrimary)
                .settingsDirectionalTarget(.subtitleBackground, focused: directionalFocus, isEnabled: supportsDirectionalSelection)

                Picker("Audio", selection: $preferences.defaultAudioLanguage) {
                    ForEach(CommonLanguage.allCases) { language in
                        Text(language.displayName).tag(language.code)
                    }
                }
                .foregroundStyle(Color.duskTextPrimary)
                .settingsDirectionalTarget(.audio, focused: directionalFocus, isEnabled: supportsDirectionalSelection)

                Picker("AI Upscaling", selection: $preferences.videoEnhancementMode) {
                    ForEach(VideoEnhancementMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .foregroundStyle(Color.duskTextPrimary)
                .settingsDirectionalTarget(.aiUpscaling, focused: directionalFocus, isEnabled: supportsDirectionalSelection)
            } header: {
                Text("Playback Defaults")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(SettingsSupport.playbackDefaultsFooterText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            Section {
                Picker("Auto-Skip Intros", selection: $preferences.autoSkipIntroMode) {
                    ForEach(AutoSkipIntroMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .foregroundStyle(Color.duskTextPrimary)
                .settingsDirectionalTarget(.autoSkipIntros, focused: directionalFocus, isEnabled: supportsDirectionalSelection)

                Toggle("Auto-Skip Credits", isOn: $preferences.autoSkipCredits)
                    .foregroundStyle(Color.duskTextPrimary)
                    .tint(Color.duskAccent)
                    .settingsDirectionalTarget(.autoSkipCredits, focused: directionalFocus, isEnabled: supportsDirectionalSelection)

                Toggle("Continuous Play", isOn: $preferences.continuousPlayEnabled)
                    .foregroundStyle(Color.duskTextPrimary)
                    .tint(Color.duskAccent)
                    .settingsDirectionalTarget(.continuousPlay, focused: directionalFocus, isEnabled: supportsDirectionalSelection)

                if preferences.continuousPlayEnabled {
                    Picker("Next Episode Delay", selection: $preferences.continuousPlayCountdown) {
                        ForEach(ContinuousPlayCountdown.allCases) { countdown in
                            Text(countdown.displayName).tag(countdown)
                        }
                    }
                    .foregroundStyle(Color.duskTextPrimary)
                    .settingsDirectionalTarget(.nextEpisodeDelay, focused: directionalFocus, isEnabled: supportsDirectionalSelection)

                    Picker(
                        "Pause After",
                        selection: $preferences.continuousPlayPassoutProtectionEpisodeLimit
                    ) {
                        ForEach(SettingsSupport.passoutProtectionEpisodeOptions, id: \.self) { episodeLimit in
                            Text(SettingsSupport.passoutProtectionDisplayName(for: episodeLimit))
                                .tag(episodeLimit as Int?)
                        }
                    }
                    .foregroundStyle(Color.duskTextPrimary)
                    .settingsDirectionalTarget(.pauseAfter, focused: directionalFocus, isEnabled: supportsDirectionalSelection)
                }

                Toggle("Double-Tap to Seek", isOn: $preferences.playerDoubleTapSeekEnabled)
                    .foregroundStyle(Color.duskTextPrimary)
                    .tint(Color.duskAccent)
                    .settingsDirectionalTarget(.doubleTapSeek, focused: directionalFocus, isEnabled: supportsDirectionalSelection)

                if preferences.playerDoubleTapSeekEnabled {
                    Picker("Back Jump", selection: $preferences.playerDoubleTapBackwardInterval) {
                        ForEach(PlayerSeekInterval.allCases) { interval in
                            Text(interval.displayName).tag(interval)
                        }
                    }
                    .foregroundStyle(Color.duskTextPrimary)
                    .settingsDirectionalTarget(.backJump, focused: directionalFocus, isEnabled: supportsDirectionalSelection)

                    Picker("Forward Jump", selection: $preferences.playerDoubleTapForwardInterval) {
                        ForEach(PlayerSeekInterval.allCases) { interval in
                            Text(interval.displayName).tag(interval)
                        }
                    }
                    .foregroundStyle(Color.duskTextPrimary)
                    .settingsDirectionalTarget(.forwardJump, focused: directionalFocus, isEnabled: supportsDirectionalSelection)
                }
            } header: {
                Text("Playback Behavior")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(SettingsSupport.playbackBehaviorFooterText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            Section {
                Picker("Download Quality", selection: $preferences.downloadMaxResolution) {
                    ForEach(MaxResolution.allCases) { resolution in
                        Text(resolution.displayName).tag(resolution)
                    }
                }
                .foregroundStyle(Color.duskTextPrimary)
                .settingsDirectionalTarget(.downloadQuality, focused: directionalFocus, isEnabled: supportsDirectionalSelection)

                Toggle("Wi-Fi Only", isOn: $preferences.downloadsWifiOnly)
                    .foregroundStyle(Color.duskTextPrimary)
                    .tint(Color.duskAccent)
                    .settingsDirectionalTarget(.wifiOnly, focused: directionalFocus, isEnabled: supportsDirectionalSelection)

                Picker("Simultaneous Downloads", selection: $preferences.maximumActiveDownloads) {
                    ForEach(DownloadConcurrency.allCases) { concurrency in
                        Text(concurrency.displayName).tag(concurrency)
                    }
                }
                .foregroundStyle(Color.duskTextPrimary)
                .settingsDirectionalTarget(.downloadConcurrency, focused: directionalFocus, isEnabled: supportsDirectionalSelection)

                Picker("Keep Free", selection: $preferences.downloadFreeSpaceReserve) {
                    ForEach(DownloadFreeSpaceReserve.allCases) { reserve in
                        Text(reserve.displayName).tag(reserve)
                    }
                }
                .foregroundStyle(Color.duskTextPrimary)
                .settingsDirectionalTarget(.keepFree, focused: directionalFocus, isEnabled: supportsDirectionalSelection)

                HStack {
                    Text("Storage Used")
                        .foregroundStyle(Color.duskTextPrimary)
                    Spacer()
                    Text(formattedBytes(downloadManager.storageUsageBytes))
                        .foregroundStyle(Color.duskTextSecondary)
                }

                if let availableStorageBytes = downloadManager.availableStorageBytes {
                    HStack {
                        Text("Available")
                            .foregroundStyle(Color.duskTextPrimary)
                        Spacer()
                        Text(formattedBytes(availableStorageBytes))
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                }

                if offlinePlaybackSyncManager.pendingSyncCount > 0 {
                    HStack {
                        Text("Pending Watch Sync")
                            .foregroundStyle(Color.duskTextPrimary)
                        Spacer()
                        Text("\(offlinePlaybackSyncManager.pendingSyncCount)")
                            .foregroundStyle(Color.duskTextSecondary)
                    }

                    Button {
                        Task {
                            await offlinePlaybackSyncManager.syncPendingActions(force: true)
                        }
                    } label: {
                        if offlinePlaybackSyncManager.isSyncing {
                            Label("Syncing Watch Progress", systemImage: "arrow.triangle.2.circlepath")
                        } else {
                            Label("Sync Watch Progress Now", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(offlinePlaybackSyncManager.isSyncing)
                    .duskSuppressTVOSButtonChrome()
                    .settingsDirectionalTarget(.syncNow, focused: directionalFocus, isEnabled: supportsDirectionalSelection)
                }

                Button("Delete All Downloads", role: .destructive) {
                    confirmsDeletingDownloads = true
                }
                .disabled(downloadManager.records.isEmpty)
                .duskSuppressTVOSButtonChrome()
                .settingsDirectionalTarget(.deleteDownloads, focused: directionalFocus, isEnabled: supportsDirectionalSelection)
            } header: {
                Text("Downloads")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(SettingsSupport.downloadsFooterText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            Section {
                Picker("Appearance", selection: $preferences.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .foregroundStyle(Color.duskTextPrimary)
                .settingsDirectionalTarget(.appearance, focused: directionalFocus, isEnabled: supportsDirectionalSelection)

                Button {
                    showsIconPicker = true
                } label: {
                    HStack {
                        Text("App Icon")
                            .foregroundStyle(Color.duskTextPrimary)

                        Spacer()

                        Text(DuskAppIcon.current.displayName)
                            .foregroundStyle(Color.duskTextSecondary)

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                }
                .duskSuppressTVOSButtonChrome()
                .settingsDirectionalTarget(.appIcon, focused: directionalFocus, isEnabled: supportsDirectionalSelection)
            } header: {
                Text("Appearance")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(SettingsSupport.appearanceFooterText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            Section {
                Toggle("Force AVPlayer", isOn: $preferences.forceAVPlayer)
                    .foregroundStyle(Color.duskTextPrimary)
                    .tint(Color.duskAccent)
                    .settingsDirectionalTarget(.forceAVPlayer, focused: directionalFocus, isEnabled: supportsDirectionalSelection)

                Toggle("Force VLCKit", isOn: $preferences.forceVLCKit)
                    .foregroundStyle(Color.duskTextPrimary)
                    .tint(Color.duskAccent)
                    .settingsDirectionalTarget(.forceVLCKit, focused: directionalFocus, isEnabled: supportsDirectionalSelection)
            } header: {
                Text("Playback Advanced")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(SettingsSupport.playbackAdvancedFooterText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            Section {
                Button {
                    viewModel.clearImageCache()
                } label: {
                    HStack {
                        Text("Clear Image Cache")
                        Spacer()
                        Text(viewModel.formattedCacheSize)
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                }
                .foregroundStyle(Color.duskAccent)
                .duskSuppressTVOSButtonChrome()
                .settingsDirectionalTarget(.clearImageCache, focused: directionalFocus, isEnabled: supportsDirectionalSelection)
            } header: {
                Text("Storage")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(viewModel.storageFooterText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            Section {
                Toggle("Help Improve Dusk", isOn: $preferences.analyticsEnabled)
                    .foregroundStyle(Color.duskTextPrimary)
                    .tint(Color.duskAccent)

                Link(destination: SettingsSupport.privacyPolicyURL) {
                    SettingsAboutRow(
                        title: "Privacy Policy",
                        subtitle: "getdusk.app/privacy",
                        systemImage: "hand.raised",
                        trailingSystemImage: "arrow.up.right"
                    )
                }
                .foregroundStyle(Color.duskTextPrimary)
            } header: {
                Text("Privacy")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(SettingsSupport.privacyFooterText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            Section {
                HStack {
                    Text("Version")
                        .foregroundStyle(Color.duskTextPrimary)
                    Spacer()
                    Text(viewModel.appVersion)
                        .foregroundStyle(Color.duskTextSecondary)
                }

                Link(destination: SettingsSupport.aboutMeURL) {
                    SettingsAboutRow(
                        title: "About Me",
                        subtitle: "marvinvr.ch",
                        systemImage: "person.crop.circle",
                        trailingSystemImage: "arrow.up.right"
                    )
                }
                .foregroundStyle(Color.duskTextPrimary)
                .settingsDirectionalTarget(.aboutMe, focused: directionalFocus, isEnabled: supportsDirectionalSelection)

                Link(destination: SettingsSupport.githubURL) {
                    SettingsAboutRow(
                        title: "GitHub",
                        subtitle: "github.com/marvinvr/dusk-player",
                        systemImage: "chevron.left.forwardslash.chevron.right",
                        trailingSystemImage: "arrow.up.right"
                    )
                }
                .foregroundStyle(Color.duskTextPrimary)
                .settingsDirectionalTarget(.github, focused: directionalFocus, isEnabled: supportsDirectionalSelection)

                Button {
                    openURL(SettingsSupport.feedbackURL)
                } label: {
                    SettingsAboutRow(
                        title: "Feedback",
                        subtitle: "info@getdusk.app",
                        systemImage: "envelope.badge",
                        trailingSystemImage: "paperplane.fill"
                    )
                }
                .duskSuppressTVOSButtonChrome()
                .settingsDirectionalTarget(.feedback, focused: directionalFocus, isEnabled: supportsDirectionalSelection)
            } header: {
                Text("About")
                    .foregroundStyle(Color.duskTextSecondary)
            } footer: {
                Text(SettingsSupport.aboutFooterText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)

            Section {
                Button {
                    presentedAccountURL = SettingsSupport.plexAccountURL
                } label: {
                    SettingsAboutRow(
                        title: "Manage Plex Account",
                        subtitle: "Open Plex account settings",
                        systemImage: "person.circle",
                        trailingSystemImage: "safari"
                    )
                }
                .foregroundStyle(Color.duskAccent)
                .duskSuppressTVOSButtonChrome()
                .settingsDirectionalTarget(.manageAccount, focused: directionalFocus, isEnabled: supportsDirectionalSelection)

                Button {
                    presentedAccountURL = SettingsSupport.plexAccountURL
                } label: {
                    SettingsAboutRow(
                        title: "Delete Plex Account",
                        subtitle: "Open the Plex deletion controls",
                        systemImage: "trash",
                        trailingSystemImage: "safari",
                        titleColor: .red
                    )
                }
                .duskSuppressTVOSButtonChrome()
                .settingsDirectionalTarget(.deleteAccount, focused: directionalFocus, isEnabled: supportsDirectionalSelection)

                Button("Sign Out", role: .destructive) {
                    plexService.signOut()
                }
                .duskSuppressTVOSButtonChrome()
                .settingsDirectionalTarget(.signOut, focused: directionalFocus, isEnabled: supportsDirectionalSelection)
            } footer: {
                Text(SettingsSupport.accountManagementFooterText + " " + SettingsSupport.accountFooterText)
                    .foregroundStyle(Color.duskTextSecondary)
            }
            .listRowBackground(Color.duskSurface)
                }
                .contentMargins(.top, 12, for: .scrollContent)
                .duskScrollContentBackgroundHidden()
                .onChange(of: directionalFocus) { _, target in
                    guard let target else { return }
                    withAnimation(.easeOut(duration: 0.16)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
        }
    }

    private var supportsDirectionalSelection: Bool {
        #if os(iOS)
        isSelected && ProcessInfo.processInfo.isiOSAppOnMac
        #else
        false
        #endif
    }

    private var directionalTargets: [SettingsDirectionalFocusTarget] {
        var targets: [SettingsDirectionalFocusTarget] = [.support]

        if plexService.homeUsers.count > 1, plexService.activeHomeUser != nil {
            targets += [.switchUser, .automaticSignIn]
        }
        if viewModel.hasMultipleServers {
            targets.append(.changeServer)
        }

        targets += [
            .seerr,
            .navigationTabs,
            .libraryOrder,
            .maxResolution,
            .subtitles,
            .forcedOnly,
            .subtitleSize,
            .subtitleBackground,
            .audio,
            .aiUpscaling,
            .autoSkipIntros,
            .autoSkipCredits,
            .continuousPlay,
        ]

        if preferences.continuousPlayEnabled {
            targets += [.nextEpisodeDelay, .pauseAfter]
        }

        targets.append(.doubleTapSeek)
        if preferences.playerDoubleTapSeekEnabled {
            targets += [.backJump, .forwardJump]
        }

        targets += [.downloadQuality, .wifiOnly, .downloadConcurrency, .keepFree]
        if offlinePlaybackSyncManager.pendingSyncCount > 0,
           !offlinePlaybackSyncManager.isSyncing {
            targets.append(.syncNow)
        }
        if !downloadManager.records.isEmpty {
            targets.append(.deleteDownloads)
        }

        targets += [
            .appearance,
            .appIcon,
            .forceAVPlayer,
            .forceVLCKit,
            .clearImageCache,
            .aboutMe,
            .github,
            .feedback,
            .manageAccount,
            .deleteAccount,
            .signOut,
        ]
        return targets
    }

    private func activateDirectionalTarget(_ target: SettingsDirectionalFocusTarget) -> Bool {
        switch target {
        case .support:
            showsSupporterSheet = true
        case .switchUser:
            viewModel.showHomeUserPicker = true
        case .automaticSignIn:
            plexService.automaticHomeSignIn.toggle()
        case .changeServer:
            viewModel.showServerPicker = true
        case .seerr:
            navigate(.seerrSettings)
        case .navigationTabs:
            navigate(.libraryTabSettings)
        case .libraryOrder:
            navigate(.libraryOrderSettings)
        case .maxResolution, .subtitles, .subtitleSize, .subtitleBackground,
             .audio, .aiUpscaling,
             .autoSkipIntros, .nextEpisodeDelay, .pauseAfter,
             .backJump, .forwardJump, .downloadQuality,
             .downloadConcurrency, .keepFree, .appearance:
            return adjustDirectionalTarget(.rightArrow, target: target)
        case .forcedOnly:
            preferences.subtitleForcedOnly.toggle()
        case .autoSkipCredits:
            preferences.autoSkipCredits.toggle()
        case .continuousPlay:
            preferences.continuousPlayEnabled.toggle()
        case .doubleTapSeek:
            preferences.playerDoubleTapSeekEnabled.toggle()
        case .wifiOnly:
            preferences.downloadsWifiOnly.toggle()
        case .syncNow:
            guard !offlinePlaybackSyncManager.isSyncing else { return false }
            Task { await offlinePlaybackSyncManager.syncPendingActions(force: true) }
        case .deleteDownloads:
            guard !downloadManager.records.isEmpty else { return false }
            confirmsDeletingDownloads = true
        case .appIcon:
            showsIconPicker = true
        case .forceAVPlayer:
            preferences.forceAVPlayer.toggle()
        case .forceVLCKit:
            preferences.forceVLCKit.toggle()
        case .clearImageCache:
            viewModel.clearImageCache()
        case .aboutMe:
            openURL(SettingsSupport.aboutMeURL)
        case .github:
            openURL(SettingsSupport.githubURL)
        case .feedback:
            openURL(SettingsSupport.feedbackURL)
        case .manageAccount, .deleteAccount:
            presentedAccountURL = SettingsSupport.plexAccountURL
        case .signOut:
            plexService.signOut()
        }
        return true
    }

    private func adjustDirectionalTarget(
        _ key: KeyEquivalent,
        target: SettingsDirectionalFocusTarget
    ) -> Bool {
        let offset: Int
        switch key {
        case .leftArrow:
            offset = -1
        case .rightArrow:
            offset = 1
        default:
            return false
        }

        switch target {
        case .maxResolution:
            preferences.maxResolution = cycled(Array(MaxResolution.allCases), from: preferences.maxResolution, offset: offset)
        case .subtitles:
            let current = preferences.defaultSubtitleLanguage ?? ""
            let value = cycled(SettingsSupport.subtitleLanguageOptions, from: current, offset: offset)
            preferences.defaultSubtitleLanguage = value.isEmpty ? nil : value
        case .forcedOnly:
            preferences.subtitleForcedOnly = offset > 0
        case .subtitleSize:
            preferences.subtitleTextSize = cycled(Array(SubtitleTextSize.allCases), from: preferences.subtitleTextSize, offset: offset)
        case .subtitleBackground:
            preferences.subtitleTextStyle = cycled(Array(SubtitleTextStyle.allCases), from: preferences.subtitleTextStyle, offset: offset)
        case .audio:
            let values = CommonLanguage.allCases.map(\.code)
            preferences.defaultAudioLanguage = cycled(values, from: preferences.defaultAudioLanguage, offset: offset)
        case .aiUpscaling:
            preferences.videoEnhancementMode = cycled(Array(VideoEnhancementMode.allCases), from: preferences.videoEnhancementMode, offset: offset)
        case .autoSkipIntros:
            preferences.autoSkipIntroMode = cycled(Array(AutoSkipIntroMode.allCases), from: preferences.autoSkipIntroMode, offset: offset)
        case .autoSkipCredits:
            preferences.autoSkipCredits = offset > 0
        case .continuousPlay:
            preferences.continuousPlayEnabled = offset > 0
        case .nextEpisodeDelay:
            preferences.continuousPlayCountdown = cycled(Array(ContinuousPlayCountdown.allCases), from: preferences.continuousPlayCountdown, offset: offset)
        case .pauseAfter:
            preferences.continuousPlayPassoutProtectionEpisodeLimit = cycled(
                SettingsSupport.passoutProtectionEpisodeOptions,
                from: preferences.continuousPlayPassoutProtectionEpisodeLimit,
                offset: offset
            )
        case .doubleTapSeek:
            preferences.playerDoubleTapSeekEnabled = offset > 0
        case .backJump:
            preferences.playerDoubleTapBackwardInterval = cycled(Array(PlayerSeekInterval.allCases), from: preferences.playerDoubleTapBackwardInterval, offset: offset)
        case .forwardJump:
            preferences.playerDoubleTapForwardInterval = cycled(Array(PlayerSeekInterval.allCases), from: preferences.playerDoubleTapForwardInterval, offset: offset)
        case .downloadQuality:
            preferences.downloadMaxResolution = cycled(Array(MaxResolution.allCases), from: preferences.downloadMaxResolution, offset: offset)
        case .wifiOnly:
            preferences.downloadsWifiOnly = offset > 0
        case .downloadConcurrency:
            preferences.maximumActiveDownloads = cycled(Array(DownloadConcurrency.allCases), from: preferences.maximumActiveDownloads, offset: offset)
        case .keepFree:
            preferences.downloadFreeSpaceReserve = cycled(Array(DownloadFreeSpaceReserve.allCases), from: preferences.downloadFreeSpaceReserve, offset: offset)
        case .appearance:
            preferences.appearanceMode = cycled(Array(AppearanceMode.allCases), from: preferences.appearanceMode, offset: offset)
        default:
            return false
        }
        return true
    }

    private func cycled<Value: Equatable>(
        _ values: [Value],
        from current: Value,
        offset: Int
    ) -> Value {
        guard !values.isEmpty else { return current }
        let currentIndex = values.firstIndex(of: current) ?? 0
        let nextIndex = (currentIndex + offset + values.count) % values.count
        return values[nextIndex]
    }

    private var accountSheetPresented: Binding<Bool> {
        Binding(
            get: { presentedAccountURL != nil },
            set: {
                guard !$0 else { return }
                presentedAccountURL = nil
            }
        )
    }

    private var automaticHomeSignInBinding: Binding<Bool> {
        Binding(
            get: { plexService.automaticHomeSignIn },
            set: { plexService.automaticHomeSignIn = $0 }
        )
    }

    private func formattedBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

private struct SettingsAboutRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let trailingSystemImage: String
    var titleColor: Color = Color.duskTextPrimary

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.duskAccent.opacity(0.14))
                    .frame(width: 34, height: 34)

                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.duskAccent)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(titleColor)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Color.duskTextSecondary)
            }

            Spacer()

            Image(systemName: trailingSystemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.duskTextSecondary)
        }
        .contentShape(Rectangle())
    }
}

private enum SettingsDirectionalFocusTarget: String, Hashable {
    case support
    case switchUser
    case automaticSignIn
    case changeServer
    case seerr
    case navigationTabs
    case libraryOrder
    case maxResolution
    case subtitles
    case forcedOnly
    case subtitleSize
    case subtitleBackground
    case audio
    case aiUpscaling
    case autoSkipIntros
    case autoSkipCredits
    case continuousPlay
    case nextEpisodeDelay
    case pauseAfter
    case doubleTapSeek
    case backJump
    case forwardJump
    case downloadQuality
    case wifiOnly
    case downloadConcurrency
    case keepFree
    case syncNow
    case deleteDownloads
    case appearance
    case appIcon
    case forceAVPlayer
    case forceVLCKit
    case clearImageCache
    case aboutMe
    case github
    case feedback
    case manageAccount
    case deleteAccount
    case signOut
}

private extension View {
    func settingsDirectionalTarget(
        _ target: SettingsDirectionalFocusTarget,
        focused: SettingsDirectionalFocusTarget?,
        isEnabled: Bool
    ) -> some View {
        self
            .focusable(!isEnabled)
            .duskDirectionalFocusHighlight(
                focused == target,
                shape: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .id(target)
    }
}
#endif
