import Foundation
import SwiftUI

extension PlayerViewModel {
    /// The HUD's fade curve. Used for both directions so revealing and hiding
    /// the controls are mirror images. `PlayerView` reads it too, so it cannot
    /// be private.
    static let controlsVisibilityAnimation: Animation = .easeInOut(duration: 0.125)
    private static let playPauseAnimation: Animation = .snappy(duration: 0.1)
    private static let pendingPlaybackStateGracePeriod: TimeInterval = 0.35
    private static let seekFeedbackDisplayDuration: Duration = .milliseconds(325)
    private static let markerSkipPadding: TimeInterval = 0.5
    private static let autoSkipCountdownDuration: TimeInterval = 5.0
    private static let bufferingIndicatorDelay: TimeInterval = 2.0
    private static let stallRecoveryDelay: TimeInterval = 12.0
    private static let stallRecoveryCooldown: TimeInterval = 8.0
    private static let stallProgressTolerance: TimeInterval = 0.75
    private static let maxStallRecoveryAttempts = 2
    private static let controlsAutoHideDelay: TimeInterval = 4.0
    // The settings menu is a deliberate, multi-step interaction (open the menu,
    // read the options, drill into a picker), so it gets a longer auto-hide
    // window than a normal tap to avoid the HUD vanishing mid-selection.
    private static let settingsControlsAutoHideDelay: TimeInterval = controlsAutoHideDelay * 2
    private static let controlsAutoHideRetryDelay: TimeInterval = 0.25
    private static let seekPointSelectRevealSuppressionDelay: TimeInterval = 0.45

    func startSync() {
        syncTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sync()
            }
        }
    }

    func sync() {
        let engineState = engine.state
        let now = Date()
        let previousState = state

        if engine.playerViewGeneration != lastPlayerViewGeneration {
            lastPlayerViewGeneration = engine.playerViewGeneration
            engineView = engine.makePlayerView()
        }

        if let pendingPlaybackState,
           let pendingPlaybackStateExpiration,
           now < pendingPlaybackStateExpiration,
           engineState != pendingPlaybackState {
            // Keep the play/pause icon responsive immediately after a tap
            // instead of snapping back while the engine catches up.
        } else {
            pendingPlaybackState = nil
            pendingPlaybackStateExpiration = nil
            state = engineState
        }

        if previousState == .paused, state == .playing {
            dismissPauseUIForPlaybackResume()
        }

        if !isScrubbing {
            currentTime = engine.currentTime
        }
        duration = engine.duration
        seekableRange = engine.seekableTimeRange
        isBuffering = engine.isBuffering
        playbackError = engine.error
        videoEnhancementStatus = engine.videoEnhancementStatus

        let didStartPlayback = !hasStartedPlayback && (state == .playing || currentTime > 0)
        if didStartPlayback {
            hasStartedPlayback = true
        }

        updatePlaybackProgressTracking(now: now)
        updateBufferingPresentation(now: now)
        recoverStalledPlaybackIfNeeded(now: now)
        updateControlsAutoHide(didStartPlayback: didStartPlayback)
        syncTrackLists()
        applyAutomaticTrackSelectionIfNeeded()
        updateAutoSkipState()
        updateUpNextPosterNotification()
        playbackSnapshotHandler?(state, currentTime, duration)
    }

    /// Notifies the coordinator when the reached credits marker changes so it
    /// can raise or dismiss the bottom-right Up Next poster. Debounced by marker
    /// id so it only fires on genuine transitions, and skipped while scrubbing so
    /// a preview drag doesn't flap the poster.
    private func updateUpNextPosterNotification() {
        guard !isScrubbing else { return }

        let markerID = reachedCreditsMarker?.id
        guard markerID != lastNotifiedCreditsMarkerID else { return }

        lastNotifiedCreditsMarkerID = markerID
        upNextPosterHandler?(reachedCreditsMarker)
    }

    func togglePlayPause() {
        if isSpeedBoostActive {
            endSpeedBoost()
        }

        let targetState: PlaybackState = state == .playing ? .paused : .playing
        pendingPlaybackState = targetState
        pendingPlaybackStateExpiration = Date().addingTimeInterval(Self.pendingPlaybackStateGracePeriod)

        withAnimation(Self.playPauseAnimation) {
            state = targetState
        }

        switch targetState {
        case .paused:
            engine.pause()
        case .playing:
            engine.play()
            dismissPauseUIForPlaybackResume()
        default:
            break
        }

        if targetState == .paused {
            touchControls()
        }
    }

    @discardableResult
    func beginSpeedBoost() -> Bool {
        guard liveTVContext == nil,
              state == .playing,
              playbackError == nil,
              !isSpeedBoostActive else {
            return false
        }

        engine.setPlaybackRate(2)
        withAnimation(.easeInOut(duration: 0.15)) {
            isSpeedBoostActive = true
        }
        return true
    }

    func endSpeedBoost() {
        guard isSpeedBoostActive else { return }

        engine.setPlaybackRate(1)
        withAnimation(.easeInOut(duration: 0.15)) {
            isSpeedBoostActive = false
        }
    }

    func togglePictureInPicture() {
        if engine.isPictureInPictureActive {
            engine.stopPictureInPicture()
        } else {
            engine.startPictureInPicture()
        }
        noteControlsInteraction()
    }

    func toggleAspectFill() {
        aspectFillEnabled.toggle()
        engine.setVideoFillEnabled(aspectFillEnabled)
        // Remember the choice for the current orientation only; the other
        // orientation keeps whatever it was last left at.
        if let isLandscapeVideoOrientation {
            userPreferences?.setPlayerAspectFill(aspectFillEnabled, isLandscape: isLandscapeVideoOrientation)
        }
        noteControlsInteraction()
    }

    /// Records the current player orientation (portrait vs landscape) and
    /// applies that orientation's saved zoom-to-fill choice. Portrait and
    /// landscape keep independent settings, so rotating swaps the framing to
    /// whatever that orientation was last left at. Driven by the player's
    /// layout size, so it also covers iPad multitasking window shape changes.
    func updateVideoOrientation(isLandscape: Bool) {
        guard isLandscapeVideoOrientation != isLandscape else { return }
        isLandscapeVideoOrientation = isLandscape
        applyPersistedAspectFill()
    }

    /// Re-applies the persisted zoom-to-fill choice for the current orientation
    /// to both the button state and the engine. No-op until both the
    /// preferences reference and an orientation are known, so it is safe to call
    /// from `onAppear` and from the first layout pass in either order.
    func applyPersistedAspectFill() {
        guard let userPreferences, let isLandscapeVideoOrientation else { return }
        let enabled = userPreferences.playerAspectFill(isLandscape: isLandscapeVideoOrientation)
        aspectFillEnabled = enabled
        engine.setVideoFillEnabled(enabled)
    }

    func seek(by offset: TimeInterval, revealControls: Bool = false) {
        // Transient jump: the target is an approximate offset from the current
        // position, so let the engine take the fast keyframe-tolerant path.
        seek(to: displayPosition + offset, revealControls: revealControls, precise: false)
    }

    func handleSeekJump(by offset: TimeInterval) {
        showSeekFeedback(for: offset)
        seek(by: offset)
    }

    func handleDoubleTapSeek(by offset: TimeInterval) {
        handleSeekJump(by: offset)
    }

    /// Starts a held keyboard/controller seek. The timeline and sidecar
    /// subtitles follow an accelerating preview, but the engine is only touched
    /// once in `endAcceleratedSeek()` so a long hold does not repeatedly flush
    /// its decoder.
    func beginAcceleratedSeek(by interval: TimeInterval) {
        guard interval != 0, !isAcceleratedSeekActive, !isScrubbing else { return }

        isAcceleratedSeekActive = true
        isScrubbing = true
        scrubPosition = clampedSeekPosition(currentTime)
        sidecarSubtitles.scrubPosition = scrubPosition
        cancelScheduledHide()
        appendAcceleratedSeekStep(interval)

        acceleratedSeekTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(450))
            } catch {
                return
            }

            var repeatCount = 0
            while !Task.isCancelled {
                guard let self, self.isAcceleratedSeekActive else { return }
                let multiplier: TimeInterval = repeatCount < 4 ? 1 : (repeatCount < 10 ? 2 : 4)
                self.appendAcceleratedSeekStep(interval * multiplier)
                repeatCount += 1

                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return
                }
            }
        }
    }

    /// Commits the accumulated held-input preview with one fast seek. Controls
    /// stay in their current visibility state so repeated arrow-key taps remain
    /// playback commands rather than unexpectedly entering HUD focus navigation.
    func endAcceleratedSeek() {
        guard isAcceleratedSeekActive else { return }

        let targetPosition = scrubPosition
        acceleratedSeekTask?.cancel()
        acceleratedSeekTask = nil
        isAcceleratedSeekActive = false
        isScrubbing = false
        sidecarSubtitles.scrubPosition = nil
        engine.seek(to: targetPosition, precise: false)

        if showControls {
            scheduleHide()
        }
    }

    private func appendAcceleratedSeekStep(_ offset: TimeInterval) {
        let previousPosition = scrubPosition
        updateScrub(to: scrubPosition + offset)
        let appliedOffset = scrubPosition - previousPosition
        if abs(appliedOffset) > 0.01 {
            showSeekFeedback(for: appliedOffset)
        }
    }

    func skipToPreviousChapter() {
        guard !chapters.isEmpty else { return }

        let positionMs = Int(displayPosition * 1000)
        // Treat a boundary's first second as belonging to that chapter so Left
        // moves to the preceding section instead of landing on the same one.
        guard let currentIndex = chapters.lastIndex(where: {
            $0.startTimeOffset <= positionMs + 1_000
        }), currentIndex > chapters.startIndex else {
            return
        }

        seekToChapter(at: chapters.index(before: currentIndex))
    }

    func skipToNextChapter() {
        guard let nextIndex = chapters.firstIndex(where: {
            $0.startTimeOffset > Int(displayPosition * 1000) + 1_000
        }) else {
            return
        }

        seekToChapter(at: nextIndex)
    }

    private func seekToChapter(at index: Int) {
        let target = TimeInterval(chapters[index].startTimeOffset) / 1_000
        let offset = target - displayPosition
        guard abs(offset) > 0.01 else { return }

        showSeekFeedback(for: offset)
        seek(to: target, revealControls: false)
    }

    func skipActiveMarker() {
        guard let marker = activeSkipMarker else { return }
        cancelAutoSkipCountdown()

        let targetTime = (TimeInterval(marker.endTimeOffset) / 1000.0) + Self.markerSkipPadding
        seek(to: targetTime, revealControls: true)
    }

    /// Handles a tap on the Skip Intro button. Credits no longer route through
    /// here — they are handled by the bottom-right Up Next poster instead of a
    /// skip button.
    func handleSkipMarker(_ marker: PlexMarker) {
        cancelAutoSkipCountdown()
        skipActiveMarker()
    }

    func beginScrub() {
        isScrubbing = true
        scrubPosition = currentTime
        // Sidecar cues follow the thumb during a drag; the engine clock only
        // catches up once the scrub is committed.
        sidecarSubtitles.scrubPosition = scrubPosition
        cancelScheduledHide()
    }

    func updateScrub(to position: TimeInterval) {
        scrubPosition = clampedSeekPosition(position)
        sidecarSubtitles.scrubPosition = scrubPosition
    }

    func endScrub() {
        commitScrub(shouldPlay: false)
    }

    func commitScrub(shouldPlay: Bool) {
        let targetPosition = scrubPosition
        // Final position the user deliberately chose — seek frame-accurately.
        engine.seek(to: targetPosition, precise: true)
        isScrubbing = false
        sidecarSubtitles.scrubPosition = nil

        if shouldPlay {
            pendingPlaybackState = .playing
            pendingPlaybackStateExpiration = Date().addingTimeInterval(Self.pendingPlaybackStateGracePeriod)
            withAnimation(Self.playPauseAnimation) {
                state = .playing
            }
            engine.play()
        }

        touchControls()
    }

    func toggleControls() {
        let shouldShowControls = !showControls
        if shouldShowControls {
            resetControlsInteractionHold()
            suppressImmediateSeekPointSelect()
        }

        withAnimation(Self.controlsVisibilityAnimation) {
            showControls = shouldShowControls
        }

        if shouldShowControls {
            scheduleHide()
        } else {
            resetControlsInteractionHold()
            cancelScheduledHide()
        }
    }

    func touchControls() {
        let shouldRevealControls = !showControls
        if shouldRevealControls {
            resetControlsInteractionHold()
            suppressImmediateSeekPointSelect()
            withAnimation(Self.controlsVisibilityAnimation) {
                showControls = true
            }
        }
        scheduleHide()
    }

    func scheduleHide() {
        scheduleControlsAutoHide(resetDeadline: true)
    }

    func noteControlsInteraction() {
        guard showControls else { return }
        scheduleHide()
    }

    /// Resuming playback is an explicit exit from the pause interaction. Keep
    /// every resume path consistent, including on-screen controls, controller
    /// input, keyboard shortcuts, and external media commands observed by sync.
    func dismissPauseUIForPlaybackResume() {
        endAcceleratedSeek()
        showPlaybackSettings = false
        showSubtitleSelection = false
        showSubtitleSearch = false
        showAudioSelection = false
        showPlaybackInfo = false
        resetControlsInteractionHold()
        cancelScheduledHide()

        guard showControls else { return }
        withAnimation(Self.controlsVisibilityAnimation) {
            showControls = false
        }
    }

    /// Refreshes the auto-hide deadline with the longer settings window when the
    /// user engages the playback settings menu. The menu takes a beat to open,
    /// read, and navigate, so the normal tap timeout is too short and the HUD
    /// would otherwise hide while the menu is still open. Mirrors
    /// `noteControlsInteraction()` and never reveals the HUD on its own, so a
    /// spurious menu lifecycle callback can't strand the controls on screen.
    func noteSettingsMenuInteraction() {
        guard showControls else { return }
        scheduleControlsAutoHide(resetDeadline: true, delay: Self.settingsControlsAutoHideDelay)
    }

    func beginControlsInteractionHold() {
        guard showControls else { return }
        controlsInteractionHoldCount += 1
        isControlsInteractionHeld = true
        scheduleControlsAutoHide(resetDeadline: false)
    }

    func endControlsInteractionHold() {
        controlsInteractionHoldCount = max(0, controlsInteractionHoldCount - 1)
        guard controlsInteractionHoldCount == 0 else { return }

        isControlsInteractionHeld = false
        scheduleHide()
    }

    func endAllControlsInteractionHolds() {
        resetControlsInteractionHold()
        scheduleHide()
    }

    func shouldIgnoreSeekPointSelectAfterReveal() -> Bool {
        guard let suppressSeekPointSelectUntil else { return false }

        self.suppressSeekPointSelectUntil = nil
        return Date() < suppressSeekPointSelectUntil
    }

    /// `precise` defaults to frame-accurate for deliberate targets (marker
    /// skips, tvOS preview commits); `seek(by:)` opts transient double-tap and
    /// remote skip jumps into the engine's fast keyframe-tolerant path.
    func seek(to position: TimeInterval, revealControls: Bool, precise: Bool = true) {
        let clampedPosition = clampedSeekPosition(position)

        engine.seek(to: clampedPosition, precise: precise)

        if revealControls {
            touchControls()
        } else if showControls {
            scheduleHide()
        }
    }

    func clampedSeekPosition(_ position: TimeInterval) -> TimeInterval {
        if let seekableRange {
            return min(max(position, seekableRange.lowerBound), seekableRange.upperBound)
        }
        if duration > 0 {
            return min(max(position, 0), duration)
        }
        return max(position, 0)
    }

    func goLive() {
        guard let seekableRange else { return }
        seek(to: max(seekableRange.lowerBound, seekableRange.upperBound - 1), revealControls: true)
    }

    // MARK: - Auto-Skip

    private func updateAutoSkipState() {
        let marker = activeSkipMarker

        guard let marker, !isScrubbing else {
            if autoSkipCountdownMarkerID != nil {
                cancelAutoSkipCountdown()
            }
            return
        }

        let shouldAutoSkip = marker.isIntro && shouldAutoSkipIntroMarkers

        guard shouldAutoSkip else {
            if autoSkipCountdownMarkerID != nil {
                cancelAutoSkipCountdown()
            }
            return
        }

        // Already counting down for this marker
        if autoSkipCountdownMarkerID == marker.id { return }

        startAutoSkipCountdown(for: marker)
    }

    private func updateBufferingPresentation(now: Date) {
        guard isBuffering,
              playbackError == nil,
              !isPlaybackMakingProgress(now: now) else {
            bufferingStartedAt = nil
            bufferingPresentationHandler?(false)
            return
        }

        let startedAt = bufferingStartedAt ?? now
        bufferingStartedAt = startedAt

        guard now.timeIntervalSince(startedAt) >= Self.bufferingIndicatorDelay else {
            bufferingPresentationHandler?(false)
            return
        }

        bufferingPresentationHandler?(true)
    }

    private func updateControlsAutoHide(didStartPlayback: Bool) {
        guard showControls else {
            cancelScheduledHide()
            return
        }

        guard shouldKeepControlsAutoHidePending else {
            cancelScheduledHide()
            return
        }

        scheduleControlsAutoHide(resetDeadline: didStartPlayback)
    }

    private func isPlaybackMakingProgress(now: Date) -> Bool {
        hasStartedPlayback &&
            state == .playing &&
            now.timeIntervalSince(lastProgressAt) < Self.bufferingIndicatorDelay
    }

    private var canAutoHideControls: Bool {
        showControls &&
            controlsAutoHideIsArmed &&
            !isScrubbing &&
            !isControlsInteractionHeld &&
            playbackError == nil &&
            !showPlaybackSettings &&
            !showSubtitleSelection &&
            !showAudioSelection &&
            !showPlaybackInfo &&
            state == .playing &&
            state != .stopped &&
            state != .error
    }

    private var shouldKeepControlsAutoHidePending: Bool {
        showControls &&
            controlsAutoHideIsArmed &&
            playbackError == nil &&
            state == .playing &&
            state != .stopped &&
            state != .error
    }

    private func cancelScheduledHide() {
        controlsAutoHideTask?.cancel()
        controlsAutoHideTask = nil
        controlsAutoHideDeadline = nil
    }

    private func resetControlsInteractionHold() {
        controlsInteractionHoldCount = 0
        isControlsInteractionHeld = false
    }

    private func suppressImmediateSeekPointSelect() {
        suppressSeekPointSelectUntil = Date().addingTimeInterval(Self.seekPointSelectRevealSuppressionDelay)
    }

    private var controlsAutoHideIsArmed: Bool {
        hasStartedPlayback || state == .playing || currentTime > 0
    }

    private func scheduleControlsAutoHide(resetDeadline: Bool, delay: TimeInterval = PlayerViewModel.controlsAutoHideDelay) {
        guard shouldKeepControlsAutoHidePending else {
            cancelScheduledHide()
            return
        }

        if resetDeadline || controlsAutoHideDeadline == nil {
            controlsAutoHideDeadline = Date().addingTimeInterval(delay)
        }

        guard controlsAutoHideTask == nil else { return }

        controlsAutoHideTask = Task { @MainActor [weak self] in
            while true {
                guard let self else { return }
                guard let deadline = self.controlsAutoHideDeadline else {
                    self.controlsAutoHideTask = nil
                    return
                }

                let remaining = deadline.timeIntervalSinceNow
                if remaining > 0 {
                    do {
                        try await Task.sleep(for: .milliseconds(Self.milliseconds(remaining)))
                    } catch {
                        return
                    }
                    continue
                }

                if self.canAutoHideControls {
                    self.controlsAutoHideTask = nil
                    self.controlsAutoHideDeadline = nil
                    withAnimation(Self.controlsVisibilityAnimation) {
                        self.showControls = false
                    }
                    return
                }

                guard self.shouldKeepControlsAutoHidePending else {
                    self.controlsAutoHideTask = nil
                    self.controlsAutoHideDeadline = nil
                    return
                }

                self.controlsAutoHideDeadline = Date().addingTimeInterval(Self.controlsAutoHideRetryDelay)
            }
        }
    }

    private static func milliseconds(_ interval: TimeInterval) -> Int {
        max(1, Int((interval * 1000).rounded(.up)))
    }

    private func updatePlaybackProgressTracking(now: Date) {
        guard state == .playing || hasStartedPlayback else {
            lastProgressAt = now
            lastProgressPosition = currentTime
            stalledPlaybackStartedAt = nil
            stallRecoveryAttempts = 0
            lastStallRecoveryAt = nil
            return
        }

        if abs(currentTime - lastProgressPosition) > Self.stallProgressTolerance {
            lastProgressAt = now
            lastProgressPosition = currentTime
            stalledPlaybackStartedAt = nil
            stallRecoveryAttempts = 0
            return
        }

        if isBuffering, stalledPlaybackStartedAt == nil {
            stalledPlaybackStartedAt = now
        } else if !isBuffering {
            stalledPlaybackStartedAt = nil
        }
    }

    private func recoverStalledPlaybackIfNeeded(now: Date) {
        guard hasStartedPlayback,
              isBuffering,
              playbackError == nil,
              stallRecoveryAttempts < Self.maxStallRecoveryAttempts else {
            return
        }

        let stalledAt = stalledPlaybackStartedAt ?? lastProgressAt
        guard now.timeIntervalSince(stalledAt) >= Self.stallRecoveryDelay else { return }

        if let lastStallRecoveryAt,
           now.timeIntervalSince(lastStallRecoveryAt) < Self.stallRecoveryCooldown {
            return
        }

        stallRecoveryAttempts += 1
        lastStallRecoveryAt = now
        stalledPlaybackStartedAt = now
        engine.recoverFromStall()
    }

    private func startAutoSkipCountdown(for marker: PlexMarker) {
        cancelAutoSkipCountdown()
        autoSkipCountdownMarkerID = marker.id
        autoSkipCountdownProgress = 0

        autoSkipCountdownTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let duration = Self.autoSkipCountdownDuration
            let startedAt = Date()
            var pausedAt: Date?
            var accumulatedPausedTime: TimeInterval = 0

            while true {
                if Task.isCancelled { return }

                let now = Date()
                if self.state == .paused {
                    pausedAt = pausedAt ?? now
                    do {
                        try await Task.sleep(for: .milliseconds(50))
                    } catch { return }
                    continue
                }

                if let pausedAt {
                    accumulatedPausedTime += now.timeIntervalSince(pausedAt)
                }

                pausedAt = nil

                let elapsed = now.timeIntervalSince(startedAt) - accumulatedPausedTime
                let progress = min(max(elapsed / duration, 0), 1)
                self.autoSkipCountdownProgress = progress

                if progress >= 1 { break }

                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch { return }
            }

            if Task.isCancelled { return }

            guard let currentMarker = self.activeSkipMarker,
                  currentMarker.id == self.autoSkipCountdownMarkerID else { return }

            self.autoSkipCountdownMarkerID = nil
            self.autoSkipCountdownProgress = nil

            if let handler = self.autoSkipHandler {
                handler(currentMarker)
            } else {
                self.skipActiveMarker()
            }
        }
    }

    private var shouldAutoSkipIntroMarkers: Bool {
        autoSkipIntroMode.shouldAutoSkipIntro(isFirstEpisodeInSeason: isFirstEpisodeInSeason)
    }

    func cancelAutoSkipCountdown() {
        autoSkipCountdownTask?.cancel()
        autoSkipCountdownTask = nil
        autoSkipCountdownMarkerID = nil
        autoSkipCountdownProgress = nil
    }

    private func showSeekFeedback(for offset: TimeInterval) {
        let direction: PlayerSeekFeedbackPresentation.Direction = offset < 0 ? .backward : .forward
        let seconds = max(1, Int(abs(offset).rounded()))
        let nextTrigger = (seekFeedback?.trigger ?? 0) + 1

        if let currentFeedback = seekFeedback, currentFeedback.direction == direction {
            withAnimation(.easeOut(duration: 0.12)) {
                seekFeedback = PlayerSeekFeedbackPresentation(
                    direction: direction,
                    seconds: currentFeedback.seconds + seconds,
                    trigger: nextTrigger
                )
            }
        } else {
            withAnimation(.easeOut(duration: 0.12)) {
                seekFeedback = PlayerSeekFeedbackPresentation(
                    direction: direction,
                    seconds: seconds,
                    trigger: nextTrigger
                )
            }
        }

        seekFeedbackTask?.cancel()
        seekFeedbackTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.seekFeedbackDisplayDuration)
            } catch {
                return
            }

            guard let self, !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.18)) {
                self.seekFeedback = nil
            }
        }
    }
}
