import SwiftUI

struct PlayerControlsIOSOverlay: View {
    @Environment(PlaybackCoordinator.self) private var playback

    let viewModel: PlayerViewModel
    let context: PlayerControlsContext
    let scrubPreviewSource: PlexScrubPreviewSource?
    let controlsTopSafeAreaInset: CGFloat
    let onDismiss: () -> Void
    @State private var directionalFocus: DirectionalTarget?

    private enum DirectionalTarget: Hashable {
        case close
        case pictureInPicture
        case aspectFill
        case playPause
        case audio
        case subtitles
        case settings
    }

    var body: some View {
        DuskDirectionalFocusScope(
            focusedID: $directionalFocus,
            groups: directionalGroups,
            defaultFocus: defaultDirectionalFocus,
            isEnabled: directionalSelectionIsEnabled,
            onActivate: activateDirectionalTarget,
            onDirectionalInputChanged: handleDirectionalInputChanged
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
            .overlay {
                if directionalSelectionIsEnabled {
                    Button("Play/Pause") {
                        viewModel.togglePlayPause()
                    }
                    .keyboardShortcut(" ", modifiers: [])
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .focusable(false)
                    .accessibilityHidden(true)
                }
            }
        }
        .onChange(of: directionalSelectionIsEnabled) { _, isEnabled in
            if !isEnabled {
                viewModel.endAcceleratedSeek()
            }
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

            pictureInPictureButton
            aspectFillButton
        }
    }

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

        return HStack {
            Spacer()
            // Hidden during startup (including the VLCKit audio warmup,
            // masked as .loading): the button would render "play" while
            // video is already moving and then flip the moment the warmup
            // completes. The standard buffering spinner in PlayerView covers
            // the loading presentation instead.
            if !viewModel.isAwaitingPlaybackStart &&
                !isAutomaticFallbackPresentationActive {
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
            }
            Spacer()
        }
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

            HStack {
                PlayerTimeStatusView(viewModel: viewModel)

                Spacer()

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
        supportsDirectionalSelection &&
            viewModel.showControls &&
            !viewModel.showPlaybackSettings &&
            !viewModel.showSubtitleSelection &&
            !viewModel.showSubtitleSearch &&
            !viewModel.showAudioSelection &&
            !viewModel.showPlaybackInfo
    }

    private var directionalGroups: [DuskDirectionalFocusGroup<DirectionalTarget>] {
        let topTargets: [DirectionalTarget] = [.close] +
            (viewModel.engine.isPictureInPicturePossible ? [.pictureInPicture] : []) +
            [.aspectFill]
        let bottomTargets: [DirectionalTarget] =
            (viewModel.audioTracks.count > 1 ? [.audio] : []) +
            [.subtitles] +
            (hasAvailableSettings ? [.settings] : [])

        var groups: [DuskDirectionalFocusGroup<DirectionalTarget>] = [.row(topTargets)]
        if showsPlayPauseButton {
            groups.append(.single(.playPause))
        }
        if !bottomTargets.isEmpty {
            groups.append(.row(bottomTargets))
        }
        return groups
    }

    private var defaultDirectionalFocus: DirectionalTarget? {
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
        // horizontal input should operate the timeline instead of trying to
        // leave a one-item row. Paused playback keeps that behavior even if
        // focus has not yet repaired itself onto the center target.
        guard viewModel.state == .paused || directionalFocus == .playPause else {
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
            context.liveTVContext != nil ||
            !viewModel.audioTracks.isEmpty ||
            !viewModel.subtitleTracks.isEmpty
    }

    private func activateDirectionalTarget(_ target: DirectionalTarget) -> Bool {
        switch target {
        case .close:
            onDismiss()
        case .pictureInPicture:
            guard viewModel.engine.isPictureInPicturePossible else { return false }
            viewModel.togglePictureInPicture()
        case .aspectFill:
            viewModel.toggleAspectFill()
        case .playPause:
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
