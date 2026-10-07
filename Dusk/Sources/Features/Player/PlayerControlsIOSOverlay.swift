import SwiftUI

struct PlayerControlsIOSOverlay: View {
    @Environment(PlaybackCoordinator.self) private var playback

    let viewModel: PlayerViewModel
    let context: PlayerControlsContext
    let scrubPreviewSource: PlexScrubPreviewSource?
    let controlsTopSafeAreaInset: CGFloat
    let onDismiss: () -> Void
    @State private var directionalFocus: DirectionalTarget?
    @State private var airPlayActivation = 0

    private enum DirectionalTarget: Hashable {
        case close
        case airPlay
        case goLive
        case pictureInPicture
        case aspectFill
        case playPause
        case transportPlayPause
        case audio
        case subtitles
        case settings
        case upNext
    }

    var body: some View {
        DuskDirectionalFocusScope(
            focusedID: $directionalFocus,
            groups: directionalGroups,
            defaultFocus: defaultDirectionalFocus,
            isEnabled: directionalSelectionIsEnabled,
            onActivate: activateDirectionalTarget,
            onBack: {
                if viewModel.isAcceleratedSeekActive { viewModel.cancelAcceleratedSeek() }
                else { viewModel.toggleControls() }
                return true
            },
            onDirectionalInputChanged: handleDirectionalInputChanged,
            onInputCancelled: { viewModel.cancelAcceleratedSeek() },
            onDirectionalBoundary: { _, _ in
                viewModel.noteControlsInteraction()
                return false
            }
        ) {
            GeometryReader { _ in
                ZStack {
                    PlayerControlsGradientBackdrop()

                    VStack {
                        topBar
                        Spacer()
                        centerControls
                        Spacer()
                        bottomBar
                    }
                    .padding(.horizontal, PlayerOverlayLayout.controlsHorizontalPadding)
                    .padding(.top, controlsTopSafeAreaInset + 16)
                    .padding(.bottom, 8)
                }
                // Moving a mouse/trackpad pointer anywhere over the visible controls
                // keeps them up instead of letting them fade mid-reach. Never reveals
                // the HUD on its own — `noteControlsInteraction()` is a no-op while the
                // controls are hidden.
                .onContinuousHover { phase in
                    if case .active = phase {
                        viewModel.noteControlsInteraction()
                    }
                }
            }
        }
        .onChange(of: directionalSelectionIsEnabled) { _, isEnabled in
            if !isEnabled {
                viewModel.cancelAcceleratedSeek()
            }
        }
        .onChange(of: directionalFocus) { _, newValue in
            viewModel.isUpNextPosterFocused = newValue == .upNext
            viewModel.noteControlsInteraction()
        }
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 20) {
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .focusable(!supportsDirectionalSelection)
            .duskDirectionalFocusHighlight(
                directionalFocus == .close,
                shape: Circle()
            )

            if let header = context.mediaHeader {
                PlayerMediaHeaderView(header: header)
            }

            Spacer()

            #if os(iOS)
            airPlayButton
            #endif
            if !playback.isAirPlayPlaybackActive {
                pictureInPictureButton
                aspectFillButton
            }
        }
    }

    #if os(iOS)
    /// Same 44pt glass circle as the buttons beside it — the route picker
    /// underneath carries the accessibility label and opens the system sheet.
    private var airPlayButton: some View {
        PlayerAirPlayControl(isActive: playback.isAirPlayPlaybackActive, activation: airPlayActivation)
            .frame(width: 44, height: 44)
            .background(.ultraThinMaterial, in: Circle())
            .duskDirectionalFocusHighlight(directionalFocus == .airPlay, shape: Circle())
    }
    #endif

    @ViewBuilder
    private var pictureInPictureButton: some View {
        if viewModel.engine.isPictureInPicturePossible {
            Button {
                viewModel.togglePictureInPicture()
            } label: {
                Image(systemName: viewModel.engine.isPictureInPictureActive ? "pip.exit" : "pip.enter")
                    .font(.title3.weight(.semibold))
                    .contentTransition(.symbolEffect(.replace, options: .speed(2)))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel("Picture in Picture")
            .focusable(!supportsDirectionalSelection)
            .duskDirectionalFocusHighlight(
                directionalFocus == .pictureInPicture,
                shape: Circle()
            )
        }
    }

    private var aspectFillButton: some View {
        Button {
            viewModel.toggleAspectFill()
        } label: {
            Image(systemName: viewModel.aspectFillEnabled
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right")
                .font(.title3.weight(.semibold))
                .contentTransition(.symbolEffect(.replace, options: .speed(2)))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(viewModel.aspectFillEnabled ? "Fit video to screen" : "Zoom video to fill screen")
        .focusable(!supportsDirectionalSelection)
        .duskDirectionalFocusHighlight(
            directionalFocus == .aspectFill,
            shape: Circle()
        )
    }

    private var centerControls: some View {
        let isPlaying = viewModel.state == .playing
        let isSpinnerActive = isLoadingPresentationActive

        return HStack {
            Spacer()
            // The center slot belongs to `PlayerView`'s shared spinner whenever
            // that spinner is up: startup (including the VLCKit audio warmup,
            // masked as .loading), delayed mid-play buffering, and the automatic
            // direct-play → server-stream recovery. Stacking the button under it
            // reads as a double control, and during startup it would render
            // "play" while video is already moving, then flip the moment the
            // warmup completes.
            //
            // The button stays mounted at zero opacity rather than being removed:
            // a removal transition here is re-decided on every render pass, and
            // sync republishes `currentTime` 4x/sec, so it would pop instead of
            // fade (same trap as the HUD itself, see `PlayerSessionView`).
            Button { viewModel.togglePlayPause() } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44))
                    .contentTransition(.symbolEffect(.replace, options: .speed(2)))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .focusable(!supportsDirectionalSelection)
            .duskDirectionalFocusHighlight(
                directionalFocus == .playPause,
                shape: Circle()
            )
            .opacity(isSpinnerActive ? 0 : 1)
            .allowsHitTesting(!isSpinnerActive)
            .accessibilityHidden(isSpinnerActive)
            .animation(.easeInOut(duration: 0.15), value: isSpinnerActive)
            Spacer()
        }
    }

    /// Mirrors what makes `PlayerView`'s spinner visible. `playerLoadingState` is
    /// the coordinator's single source of truth for that; the view-model-local
    /// startup checks stay in as a same-frame guard, since the coordinator reads
    /// its own engine reference and can lag by a render pass across a handoff.
    private var isLoadingPresentationActive: Bool {
        playback.playerLoadingState.isVisible ||
            viewModel.isAwaitingPlaybackStart ||
            isAutomaticFallbackPresentationActive
    }

    private var isAutomaticFallbackPresentationActive: Bool {
        playback.isAutomaticDirectPlayFallbackActive ||
            (
                playback.isAutomaticDirectPlayFallbackAvailable &&
                    viewModel.playbackError != nil
            )
    }

    private var bottomBar: some View {
        VStack(spacing: 4) {
            PlayerSeekBar(
                viewModel: viewModel,
                isInteractive: true,
                scrubPreviewSource: scrubPreviewSource
            )

            if supportsDirectionalSelection {
                // Equal side columns keep transport at the window's center,
                // regardless of the time readout or track-name lengths.
                HStack(spacing: 12) {
                    timeStatus
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if showsPlayPauseButton { transportPlayPauseButton }
                    trackControls
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                HStack {
                    timeStatus
                    Spacer()
                    trackControls
                }
            }
        }
    }

    private var timeStatus: some View {
        PlayerTimeStatusView(viewModel: viewModel)
            .duskDirectionalFocusHighlight(directionalFocus == .goLive, shape: Capsule())
    }

    private var trackControls: some View {
        HStack {
            audioSelectionButton
            subtitleSelectionButton
            PlayerTrackSettingsMenu(
                viewModel: viewModel,
                context: context,
                requestsFocus: directionalFocus == .settings,
                usesDirectionalSelection: supportsDirectionalSelection
            )
        }
    }

    private var transportPlayPauseButton: some View {
        let isPlaying = viewModel.state == .playing
        return Button { viewModel.togglePlayPause() } label: {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.body.weight(.semibold))
                .contentTransition(.symbolEffect(.replace, options: .speed(2)))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
        .duskDirectionalFocusHighlight(directionalFocus == .transportPlayPause, shape: Circle())
    }

    @ViewBuilder
    private var audioSelectionButton: some View {
        if viewModel.audioTracks.count > 1 {
            Button {
                viewModel.noteSettingsMenuInteraction()
                viewModel.showAudioSelection = true
            } label: {
                Label {
                    Text(viewModel.selectedAudioTrack?.compactDisplayTitle ?? "Audio")
                        .lineLimit(1)
                } icon: {
                    Image(systemName: "speaker.wave.2")
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(.white.opacity(0.12), in: Capsule())
            }
            .accessibilityLabel("Audio")
            .accessibilityValue(viewModel.selectedAudioTrack?.compactDisplayTitle ?? "Unknown")
            .focusable(!supportsDirectionalSelection)
            .duskDirectionalFocusHighlight(
                directionalFocus == .audio,
                shape: Capsule()
            )
        }
    }

    private var subtitleSelectionButton: some View {
        Button {
            viewModel.noteSettingsMenuInteraction()
            viewModel.showSubtitleSelection = true
        } label: {
            Label {
                Text(viewModel.selectedSubtitleTrack?.displayTitle ?? "Subtitles")
                    .lineLimit(1)
            } icon: {
                Image(systemName: viewModel.selectedSubtitleTrack == nil
                    ? "captions.bubble"
                    : "captions.bubble.fill")
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(.white.opacity(0.12), in: Capsule())
        }
        .accessibilityLabel("Subtitles")
        .accessibilityValue(viewModel.selectedSubtitleTrack?.displayTitle ?? "Off")
        // Deliberately enabled with no tracks: the picker is where subtitle
        // search lives, which is exactly what an item with none needs.
        .focusable(!supportsDirectionalSelection)
        .duskDirectionalFocusHighlight(
            directionalFocus == .subtitles,
            shape: Capsule()
        )
    }

    private var supportsDirectionalSelection: Bool {
        #if os(iOS)
        ProcessInfo.processInfo.isiOSAppOnMac
        #else
        false
        #endif
    }

    private var directionalSelectionIsEnabled: Bool {
        (supportsDirectionalSelection || playback.upNextPoster != nil) &&
            viewModel.showControls &&
            !viewModel.showPlaybackSettings &&
            !viewModel.showSubtitleSelection &&
            !viewModel.showSubtitleSearch &&
            !viewModel.showAudioSelection &&
            !viewModel.showPlaybackInfo
    }

    private var directionalGroups: [DuskDirectionalFocusGroup<DirectionalTarget>] {
        let topTargets: [DirectionalTarget] = [.close, .airPlay] +
            (playback.isAirPlayPlaybackActive ? [] :
                (viewModel.engine.isPictureInPicturePossible ? [.pictureInPicture] : []) + [.aspectFill])
        let bottomTargets: [DirectionalTarget] =
            (viewModel.isLiveTV && !viewModel.isAtLiveEdge ? [.goLive] : []) +
            (supportsDirectionalSelection && showsPlayPauseButton ? [.transportPlayPause] : []) +
            (viewModel.audioTracks.count > 1 ? [.audio] : []) +
            [.subtitles] +
            (hasAvailableSettings ? [.settings] : [])

        var groups: [DuskDirectionalFocusGroup<DirectionalTarget>] = [.row(topTargets)]
        if showsPlayPauseButton {
            groups.append(.single(.playPause))
        }
        if playback.upNextPoster != nil {
            groups.append(.single(.upNext))
        }
        if !bottomTargets.isEmpty {
            groups.append(.row(bottomTargets))
        }
        return groups
    }

    private var defaultDirectionalFocus: DirectionalTarget? {
        if playback.upNextPoster != nil { return .upNext }
        if showsPlayPauseButton {
            return .playPause
        }
        return directionalGroups.lazy.compactMap(\.targets.first).first
    }

    private func handleDirectionalInputChanged(
        _ key: KeyEquivalent,
        isPressed: Bool
    ) -> Bool {
        // The center Play/Pause target doubles as the playback seek focus:
        // horizontal input operates the timeline only at the transport target.
        // Paused playback must still allow movement along other control rows.
        viewModel.noteControlsInteraction()
        if !isPressed, viewModel.isAcceleratedSeekActive {
            viewModel.endAcceleratedSeek()
            return true
        }
        // Up offers a direct path to the next episode from any HUD control.
        if isPressed, key == .upArrow, playback.upNextPoster != nil {
            directionalFocus = .upNext
            viewModel.isUpNextPosterFocused = true
            return true
        }
        guard directionalFocus == .playPause else {
            return false
        }

        let interval: TimeInterval
        switch key {
        case .leftArrow:
            interval = -PlayerOverlayLayout.keyboardControllerBackwardSeekInterval
        case .rightArrow:
            interval = PlayerOverlayLayout.keyboardControllerForwardSeekInterval
        default:
            return false
        }

        if isPressed {
            viewModel.beginAcceleratedSeek(by: interval)
        } else {
            viewModel.endAcceleratedSeek()
        }
        return true
    }

    private var showsPlayPauseButton: Bool {
        !viewModel.isAwaitingPlaybackStart && !isAutomaticFallbackPresentationActive
    }

    private var hasAvailableSettings: Bool {
        context.hasPlaybackInfo ||
            context.hasQualityControl ||
            context.hasSharePlayControl ||
            context.liveTVContext != nil ||
            !viewModel.audioTracks.isEmpty ||
            !viewModel.subtitleTracks.isEmpty
    }

    private func activateDirectionalTarget(_ target: DirectionalTarget) -> Bool {
        switch target {
        case .upNext:
            guard playback.upNextPoster != nil else { return false }
            playback.playUpNextPosterNow()
        case .close:
            onDismiss()
        case .airPlay:
            airPlayActivation += 1
        case .goLive:
            viewModel.goLive()
        case .pictureInPicture:
            guard viewModel.engine.isPictureInPicturePossible else { return false }
            viewModel.togglePictureInPicture()
        case .aspectFill:
            viewModel.toggleAspectFill()
        case .playPause, .transportPlayPause:
            guard showsPlayPauseButton else { return false }
            viewModel.togglePlayPause()
        case .audio:
            guard viewModel.audioTracks.count > 1 else { return false }
            viewModel.noteSettingsMenuInteraction()
            viewModel.showAudioSelection = true
        case .subtitles:
            viewModel.noteSettingsMenuInteraction()
            viewModel.showSubtitleSelection = true
        case .settings:
            guard hasAvailableSettings else { return false }
            viewModel.noteSettingsMenuInteraction()
            viewModel.showPlaybackSettings = true
        }
        return true
    }
}
