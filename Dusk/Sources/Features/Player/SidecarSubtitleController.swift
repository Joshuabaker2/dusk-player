import Foundation
import OSLog
import QuartzCore

private let sidecarSubtitleLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "SidecarSubtitles"
)

/// Fetches, parses, and times Plex sidecar subtitle files, which neither
/// playback engine can mount itself.
///
/// The engines render embedded subtitle tracks natively; this drives the
/// app-side overlay used for external (`key != nil`) streams, uniformly for
/// VLCKit and AVPlayer so both look and behave the same.
@MainActor
@Observable
final class SidecarSubtitleController {
    /// Cues to display right now (usually 0 or 1; overlapping cues are legal).
    private(set) var visibleCues: [SubtitleCue] = []
    private(set) var isLoading = false
    private(set) var failureMessage: String?
    private(set) var activeTrackID: Int?
    /// Positive delay shows cues later. Corrects sidecars authored against a
    /// different release of the same title.
    private(set) var delay: TimeInterval = 0

    var isActive: Bool { activeTrackID != nil }

    /// How far the predicted clock may run ahead of the last engine sample.
    /// Sized above libvlc's ~250 ms time-changed cadence so interpolation
    /// smooths a stale clock, while still bounding the damage if playback
    /// stalls in a way the engine does not report.
    private static let maxInterpolationLead: TimeInterval = 0.35
    /// A gap this large between predicted and sampled time is a seek, a
    /// restart, or a clock reset — never normal drift. Comfortably above
    /// `maxInterpolationLead` so ordinary extrapolation never trips it.
    private static let discontinuityThreshold: TimeInterval = 0.9
    private static let delayDefaultsPrefix = "subtitleDelay"
    static let delayStep: TimeInterval = 0.1
    static let delayLimit: TimeInterval = 60

    @ObservationIgnored private let engine: any PlaybackEngine
    @ObservationIgnored private var plexService: PlexService?
    @ObservationIgnored private var itemKey: String?
    /// Live TV runs on a session-relative timeline (`copyts=0`, `offset=-1`),
    /// so sidecar cue timestamps cannot be aligned to it.
    @ObservationIgnored private var isSupportedSession = true

    @ObservationIgnored private var cues: [SubtitleCue] = []
    @ObservationIgnored private var longestCueDuration: TimeInterval = 0
    @ObservationIgnored private var cueCache: [String: [SubtitleCue]] = [:]
    @ObservationIgnored private var activeStreamKey: String?
    @ObservationIgnored nonisolated(unsafe) private var loadTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var ticker: DisplayTicker?

    // Clock anchor for interpolation between engine samples.
    @ObservationIgnored private var anchorMediaTime: TimeInterval = 0
    @ObservationIgnored private var anchorHostTime: CFTimeInterval = 0
    @ObservationIgnored private var lastSampledTime: TimeInterval = 0
    @ObservationIgnored private var lastOutputTime: TimeInterval = 0
    @ObservationIgnored private var hasClockAnchor = false

    /// Set by the player while the user drags the scrubber, so cues follow the
    /// thumb instead of the engine's lagging seek position.
    @ObservationIgnored var scrubPosition: TimeInterval?

    init(engine: any PlaybackEngine) {
        self.engine = engine
    }

    deinit {
        ticker?.stop()
        loadTask?.cancel()
    }

    func configure(plexService: PlexService, itemKey: String?, isSupportedSession: Bool) {
        self.plexService = plexService
        self.itemKey = itemKey
        self.isSupportedSession = isSupportedSession
        if !isSupportedSession {
            deactivate()
        }
    }

    // MARK: - Activation

    func activate(track: SubtitleTrack) {
        guard isSupportedSession, let streamKey = track.externalStreamKey else {
            deactivate()
            return
        }

        guard activeTrackID != track.id else { return }

        loadTask?.cancel()
        activeTrackID = track.id
        activeStreamKey = streamKey
        failureMessage = nil
        delay = storedDelay(forStreamKey: streamKey)
        resetTiming()

        if let cached = cueCache[streamKey] {
            apply(cues: cached)
            return
        }

        guard let plexService else {
            failureMessage = "Not connected to a Plex server."
            return
        }

        isLoading = true
        visibleCues = []
        loadTask = Task { [weak self] in
            await self?.load(streamKey: streamKey, using: plexService)
        }
    }

    func deactivate() {
        loadTask?.cancel()
        loadTask = nil
        ticker?.stop()
        ticker = nil
        activeTrackID = nil
        activeStreamKey = nil
        cues = []
        longestCueDuration = 0
        visibleCues = []
        isLoading = false
        failureMessage = nil
        resetTiming()
    }

    private func load(streamKey: String, using plexService: PlexService) async {
        do {
            let data = try await plexService.subtitleFileData(streamKey: streamKey)
            // Feature-length subtitles are thousands of cues; parsing on the
            // main actor would hitch playback at the moment of selection.
            let parsed = await Task.detached(priority: .userInitiated) {
                SubtitleCueParser.parse(data: data)
            }.value

            guard !Task.isCancelled, activeStreamKey == streamKey else { return }

            isLoading = false
            guard !parsed.isEmpty else {
                failureMessage = "This subtitle file couldn't be read."
                sidecarSubtitleLogger.error(
                    "Parsed 0 cues from sidecar \(streamKey, privacy: .public)"
                )
                return
            }

            cueCache[streamKey] = parsed
            apply(cues: parsed)
            sidecarSubtitleLogger.notice(
                "Loaded \(parsed.count, privacy: .public) cues from sidecar \(streamKey, privacy: .public)"
            )
        } catch {
            guard !Task.isCancelled, activeStreamKey == streamKey else { return }
            isLoading = false
            failureMessage = (error as? PlexServiceError)?.localizedDescription
                ?? "Couldn't download this subtitle."
            sidecarSubtitleLogger.error(
                "Failed to load sidecar \(streamKey, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    private func apply(cues newCues: [SubtitleCue]) {
        cues = newCues
        longestCueDuration = newCues.map { $0.end - $0.start }.max() ?? 0
        isLoading = false
        resetTiming()
        startTicking()
        tick()
    }

    // MARK: - Delay

    func adjustDelay(by amount: TimeInterval) {
        setDelay(delay + amount)
    }

    func setDelay(_ newValue: TimeInterval) {
        let clamped = min(max(newValue, -Self.delayLimit), Self.delayLimit)
        // Guard against float dust accumulating over repeated ±0.1 steps.
        delay = (clamped * 10).rounded() / 10
        if let activeStreamKey {
            storeDelay(delay, forStreamKey: activeStreamKey)
        }
        tick()
    }

    private func delayDefaultsKey(forStreamKey streamKey: String) -> String {
        "\(Self.delayDefaultsPrefix).\(itemKey ?? "unknown").\(streamKey)"
    }

    private func storedDelay(forStreamKey streamKey: String) -> TimeInterval {
        UserDefaults.standard.double(forKey: delayDefaultsKey(forStreamKey: streamKey))
    }

    private func storeDelay(_ value: TimeInterval, forStreamKey streamKey: String) {
        let key = delayDefaultsKey(forStreamKey: streamKey)
        if value == 0 {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    // MARK: - Timing

    private func startTicking() {
        guard ticker == nil else { return }
        let ticker = DisplayTicker { [weak self] in
            self?.tick()
        }
        ticker.start()
        self.ticker = ticker
    }

    private func resetTiming() {
        hasClockAnchor = false
        lastSampledTime = 0
        lastOutputTime = 0
        anchorMediaTime = 0
        anchorHostTime = 0
    }

    private func tick() {
        guard isActive, !cues.isEmpty else {
            if !visibleCues.isEmpty { visibleCues = [] }
            return
        }

        let time = playheadTime() - delay
        let matches = cuesCovering(time)

        // Only publish on an actual cue change: the ticker runs many times per
        // cue, and re-assigning would invalidate the overlay every frame.
        if matches.map(\.id) != visibleCues.map(\.id) {
            visibleCues = matches
        }
    }

    /// The time cues should be matched against, interpolated between engine
    /// clock samples.
    ///
    /// Sampling the real clock every tick (rather than scheduling timers to cue
    /// boundaries) is what makes rate changes, pauses and buffering stalls
    /// need no special handling — the clock simply stops advancing.
    private func playheadTime() -> TimeInterval {
        if let scrubPosition {
            anchor(to: scrubPosition)
            return scrubPosition
        }

        let sample = max(0, engine.preciseCurrentTime)
        let host = CACurrentMediaTime()

        guard hasClockAnchor else {
            anchor(to: sample, host: host)
            return sample
        }

        let isAdvancing = engine.state == .playing && !engine.isBuffering
        // Rate 0 while paused/stalled makes the prediction hold still, which is
        // exactly right: the media clock is not moving either.
        let rate = isAdvancing ? max(TimeInterval(engine.playbackRate), 0.1) : 0

        // Seeks, engine restarts and clock resets land here. Compared against
        // the prediction rather than the last output so that legitimately
        // running ahead (a stale clock, or a 2x rate) is never mistaken for a
        // jump.
        if abs(sample - (anchorMediaTime + (host - anchorHostTime) * rate)) > Self.discontinuityThreshold {
            anchor(to: sample, host: host)
            return sample
        }

        if sample != lastSampledTime {
            anchorMediaTime = sample
            anchorHostTime = host
            lastSampledTime = sample
        }

        guard isAdvancing else {
            // Frozen clock: hold position rather than snapping backwards to a
            // sample the prediction has already passed.
            lastOutputTime = max(sample, lastOutputTime)
            return lastOutputTime
        }

        let predicted = anchorMediaTime + (host - anchorHostTime) * rate
        // Never behind the engine, never more than one sample interval ahead
        // (which is `rate` times longer in media time at 2x), and never moving
        // backwards without a discontinuity.
        let maxLead = Self.maxInterpolationLead * max(rate, 1)
        let clamped = min(max(predicted, sample), sample + maxLead)
        lastOutputTime = max(clamped, lastOutputTime)
        return lastOutputTime
    }

    private func anchor(to time: TimeInterval, host: CFTimeInterval = CACurrentMediaTime()) {
        anchorMediaTime = time
        anchorHostTime = host
        lastSampledTime = time
        lastOutputTime = time
        hasClockAnchor = true
    }

    /// All cues covering `time`. Cue arrays are sorted by start time, so this
    /// binary-searches and then walks back only as far as the longest cue can
    /// reach — overlapping cues stay supported without scanning the file.
    private func cuesCovering(_ time: TimeInterval) -> [SubtitleCue] {
        guard !cues.isEmpty else { return [] }

        var low = 0
        var high = cues.count - 1
        var lastStartedIndex = -1

        while low <= high {
            let mid = (low + high) / 2
            if cues[mid].start <= time {
                lastStartedIndex = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }

        guard lastStartedIndex >= 0 else { return [] }

        var matches: [SubtitleCue] = []
        var index = lastStartedIndex
        let earliestPossibleStart = time - longestCueDuration

        while index >= 0, cues[index].start >= earliestPossibleStart {
            if cues[index].contains(time) {
                matches.append(cues[index])
            }
            index -= 1
        }

        return matches.reversed()
    }
}

/// CADisplayLink needs an ObjC target; keeping it in a proxy lets the
/// controller stay a plain `@Observable` class.
@MainActor
private final class DisplayTicker: NSObject {
    // `nonisolated(unsafe)` so teardown can run from the controller's deinit;
    // both accesses happen on the main thread in practice.
    nonisolated(unsafe) private var link: CADisplayLink?
    private let onTick: () -> Void

    init(onTick: @escaping () -> Void) {
        self.onTick = onTick
    }

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(handleTick))
        // Cue boundaries don't need per-frame precision; ~20 Hz keeps the
        // timing tight while leaving the display link cheap.
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 20)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    nonisolated func stop() {
        link?.invalidate()
        link = nil
    }

    /// CADisplayLink fires on the main run loop, so this is genuinely
    /// main-actor work despite arriving through an ObjC selector.
    @objc private func handleTick() {
        onTick()
    }
}
