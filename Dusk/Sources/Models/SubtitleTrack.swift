import Foundation

/// An app-level subtitle track used by the playback engine.
/// Decoupled from Plex API models so either engine can produce these.
struct SubtitleTrack: Sendable, Identifiable, Hashable {
    /// Engine-reported tracks carry the engine's own non-negative model ID.
    /// External (sidecar) tracks are not known to any engine, so they get a
    /// negative ID minted from the Plex stream ID — see `externalTrackID`.
    let id: Int
    let displayTitle: String
    let language: String?
    let languageCode: String?
    let codec: String?
    let isForced: Bool
    let isHearingImpaired: Bool
    let isExternal: Bool

    /// For external (sidecar) subtitles, the Plex stream path the file is
    /// fetched from (e.g. `/library/streams/1234`). Neither engine can mount
    /// these, so `SidecarSubtitleController` downloads and renders them itself.
    let externalStreamKey: String?
}

extension SubtitleTrack {
    /// Create from a Plex subtitle stream. Only used for external streams —
    /// embedded ones come from the engine and are decorated with Plex metadata
    /// in `PlayerViewModel+TrackSelection`.
    init(stream: PlexStream) {
        self.id = Self.externalTrackID(forPlexStreamID: stream.id)
        self.displayTitle = stream.extendedDisplayTitle ?? stream.displayTitle ?? stream.language ?? "Unknown"
        self.language = stream.language
        self.languageCode = stream.languageCode
        self.codec = stream.codec
        self.isForced = stream.isForced ?? false
        self.isHearingImpaired = stream.isHearingImpaired ?? false
        self.isExternal = stream.key != nil
        self.externalStreamKey = stream.key
    }

    /// External tracks live in a negative ID namespace so they can never
    /// collide with engine track IDs, which count up from zero
    /// (`VLCKitEngine.modelID`, and AVPlayer's media-selection option indices).
    static func externalTrackID(forPlexStreamID streamID: Int) -> Int {
        -abs(streamID) - 1
    }
}
