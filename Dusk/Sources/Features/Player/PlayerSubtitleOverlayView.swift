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

    /// Most of the picture that subtitles may ever cover.
    private static let maximumHeightFraction: CGFloat = 0.35

    /// Offsets used to fake a glyph stroke by stamping dark copies behind the
    /// white text. SwiftUI has no text-stroke modifier, and this matches what
    /// the engines produce natively (CEA-708 "uniform" edge / freetype outline).
    private static let outlineOffsets: [CGSize] = {
        let diagonal = 0.7
        return [
            CGSize(width: 1, height: 0), CGSize(width: -1, height: 0),
            CGSize(width: 0, height: 1), CGSize(width: 0, height: -1),
            CGSize(width: diagonal, height: diagonal), CGSize(width: -diagonal, height: diagonal),
            CGSize(width: diagonal, height: -diagonal), CGSize(width: -diagonal, height: -diagonal),
        ]
    }()

    var body: some View {
        // Sized from the height of the area the video is rendered into, so the
        // overlay and the engines' own renderers are defined against the same
        // reference (see PlaybackSubtitleStyle.baseCaptionHeightFraction).
        GeometryReader { geometry in
            let fontSize = PlaybackSubtitleStyle.overlayFontSize(
                for: appearance,
                videoHeight: geometry.size.height
            )

            VStack {
                Spacer(minLength: 0)

                VStack(spacing: 4) {
                    ForEach(cues) { cue in
                        cueText(cue, fontSize: fontSize)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, bottomInset)
                // Hard ceiling on how much picture subtitles may cover.
                // `fixedSize` above makes each cue take its full ideal height
                // and refuse to compress, so without this a single pathological
                // cue — a subtitle file is untrusted input — renders as a wall
                // of text over the whole frame instead of being clipped.
                // Real captions are 2-3 lines; anything beyond that is a bug in
                // the file or in us, and must not be able to hide the video.
                .frame(
                    maxWidth: .infinity,
                    maxHeight: geometry.size.height * Self.maximumHeightFraction,
                    alignment: .bottom
                )
                .clipped()
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

    /// Changes whenever something worth logging changes, so the diagnostic
    /// fires on real transitions instead of every layout pass.
    private func diagnosticSignature(containerHeight: CGFloat) -> String {
        "\(Int(containerHeight))-\(cues.map(\.id))"
    }

    @ViewBuilder
    private func cueText(_ cue: SubtitleCue, fontSize: Double) -> some View {
        let style = appearance.textStyle
        let body = styledText(cue.text, fontSize: fontSize)

        Group {
            if style.drawsOutline {
                ZStack {
                    ForEach(Array(Self.outlineOffsets.enumerated()), id: \.offset) { _, offset in
                        body
                            .foregroundStyle(.black)
                            .offset(
                                x: offset.width * outlineWidth(for: fontSize),
                                y: offset.height * outlineWidth(for: fontSize)
                            )
                    }

                    body.foregroundStyle(.white)
                }
            } else {
                body.foregroundStyle(.white)
            }
        }
        .padding(.horizontal, style.backgroundOpacity > 0 ? 10 : 0)
        .padding(.vertical, style.backgroundOpacity > 0 ? 3 : 0)
        .background {
            if style.backgroundOpacity > 0 {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.black.opacity(style.backgroundOpacity))
            }
        }
        .shadow(
            color: .black.opacity(style.drawsShadow ? 0.85 : 0),
            radius: style.drawsOutline ? 3 : 2,
            x: 0,
            y: 1
        )
    }

    private func styledText(_ text: String, fontSize: Double) -> some View {
        Text(text)
            .font(.system(size: fontSize, weight: .semibold))
            .multilineTextAlignment(.center)
            .lineLimit(Self.maximumLines)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Broadcast and streaming both cap captions at two lines; a little slack
    /// above that absorbs long single cues without letting one fill the screen.
    private static let maximumLines = 4

    /// Scales with the type so the stroke stays proportional at every size.
    private func outlineWidth(for fontSize: Double) -> CGFloat {
        max(1, CGFloat(fontSize) * 0.07)
    }
}
