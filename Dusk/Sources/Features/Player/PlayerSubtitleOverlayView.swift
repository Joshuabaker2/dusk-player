import OSLog
import SwiftUI

private let subtitleOverlayLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Dusk",
    category: "SubtitleOverlay"
)

/// Draws sidecar subtitle cues over the video.
///
/// Embedded subtitle tracks are rendered by the playback engine itself; this
/// exists only for Plex external (sidecar) streams, which neither engine can
/// mount. Using one app-side renderer for both engines keeps those subtitles
/// looking and behaving identically on MKV (VLCKit) and MP4 (AVPlayer).
struct PlayerSubtitleOverlayView: View {
    let cues: [SubtitleCue]
    let appearance: PlaybackSubtitleAppearance
    let bottomInset: CGFloat
    /// Clearance for cues the file places at the top (`{\an8}`, a top ASS
    /// style, a low VTT `line`), so they sit below the HUD's title bar.
    let topInset: CGFloat

    /// Most of the picture that subtitles may ever cover.
    private static let maximumHeightFraction: CGFloat = 0.35

    /// Widest a subtitle line may run. Long unbroken cues wrap here instead of
    /// spanning the frame edge to edge, which forces the eye to sweep the whole
    /// picture; authored line breaks are unaffected.
    private static let maximumWidthFraction: CGFloat = 0.8

    var body: some View {
        // Sized from the height of the area the video is rendered into, so the
        // overlay and the engines' own renderers are defined against the same
        // reference (see PlaybackSubtitleStyle.baseCaptionHeightFraction).
        GeometryReader { geometry in
            let fontSize = PlaybackSubtitleStyle.overlayFontSize(
                for: appearance,
                videoHeight: geometry.size.height
            )

            ZStack {
                region(.top, fontSize: fontSize, size: geometry.size)
                region(.bottom, fontSize: fontSize, size: geometry.size)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Diagnostic, not decoration: a subtitle file is untrusted input
            // and the layout is driven by a measured container, so a bad cue or
            // an unbounded height would both show up as an unreadable mass of
            // text. This says which, in one run.
            .onChange(of: diagnosticSignature(containerHeight: geometry.size.height)) { _, _ in
                subtitleOverlayLogger.notice(
                    "Sidecar overlay: containerHeight=\(Int(geometry.size.height), privacy: .public) fontSize=\(Int(fontSize), privacy: .public) cues=\(cues.count, privacy: .public) chars=\(cues.map(\.text.count).max() ?? 0, privacy: .public) lines=\(cues.map { $0.text.split(separator: "\n").count }.max() ?? 0, privacy: .public) size=\(appearance.textSize.rawValue, privacy: .public)"
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        // Deliberately brief: a slower fade reads as the subtitles lagging the
        // audio even when the timing is exact.
        .animation(.easeOut(duration: 0.08), value: cues.map(\.id))
    }

    /// One stack of cues pinned to the top or bottom edge. Each region gets the
    /// same ceiling, so top placement can never double what subtitles cover.
    @ViewBuilder
    private func region(_ placement: SubtitleCuePlacement, fontSize: Double, size: CGSize) -> some View {
        let regionCues = cues.filter { $0.placement == placement }
        if !regionCues.isEmpty {
            let alignment: Alignment = placement == .top ? .top : .bottom

            VStack(spacing: 4) {
                ForEach(regionCues) { cue in
                    SubtitleTextView(
                        text: cue.text,
                        italicRanges: cue.italicRanges,
                        appearance: appearance,
                        fontSize: fontSize,
                        lineLimit: Self.maximumLines
                    )
                }
            }
            .frame(maxWidth: size.width * Self.maximumWidthFraction)
            .padding(.horizontal, 24)
            .padding(.top, placement == .top ? topInset : 0)
            .padding(.bottom, placement == .bottom ? bottomInset : 0)
            // Hard ceiling on how much picture subtitles may cover.
            // `fixedSize` in the text view makes each cue take its full ideal
            // height and refuse to compress, so without this a single
            // pathological cue — a subtitle file is untrusted input — renders
            // as a wall of text over the whole frame instead of being clipped.
            // Real captions are 2-3 lines; anything beyond that is a bug in
            // the file or in us, and must not be able to hide the video.
            .frame(
                maxWidth: .infinity,
                maxHeight: size.height * Self.maximumHeightFraction,
                alignment: alignment
            )
            .clipped()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        }
    }

    /// Changes whenever something worth logging changes, so the diagnostic
    /// fires on real transitions instead of every layout pass.
    private func diagnosticSignature(containerHeight: CGFloat) -> String {
        "\(Int(containerHeight))-\(cues.map(\.id))"
    }

    /// Broadcast and streaming both cap captions at two lines; a little slack
    /// above that absorbs long single cues without letting one fill the screen.
    private static let maximumLines = 4
}
