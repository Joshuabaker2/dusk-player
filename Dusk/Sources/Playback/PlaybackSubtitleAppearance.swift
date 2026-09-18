import Foundation

/// User-facing subtitle text size. The multipliers scale each renderer's own
/// default rather than setting an absolute size, so the platform baselines
/// (smaller on iPad, larger on TV) stay intact.
enum SubtitleTextSize: String, CaseIterable, Identifiable, Sendable {
    case small
    case medium
    case large
    case extraLarge

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .extraLarge: "Extra Large"
        }
    }

    var scale: Double {
        switch self {
        case .small: 0.8
        case .medium: 1.0
        case .large: 1.25
        case .extraLarge: 1.5
        }
    }
}

/// How subtitle text is separated from the picture behind it.
///
/// The ordering mirrors how much of the picture each option covers, and the
/// defaults follow the streaming convention (Netflix, Apple, YouTube): white
/// text with a dark edge, no box. Boxed styles are the broadcast/CEA-708
/// fallback — maximally legible, but they hide part of the frame.
enum SubtitleTextStyle: String, CaseIterable, Identifiable, Sendable {
    /// Thin dark stroke around each glyph plus a soft shadow. Readable over
    /// both bright and dark scenes without covering the picture.
    case outline
    /// Drop shadow only. The lightest option; can wash out over bright scenes.
    case shadow
    /// Translucent dark box behind the text block.
    case translucentBox = "box"
    /// Opaque box, the classic broadcast caption look.
    case solidBox

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .outline: "Outline"
        case .shadow: "Shadow"
        case .translucentBox: "Light Box"
        case .solidBox: "Solid Box"
        }
    }

    /// One-line explanation for the settings row.
    var detail: String {
        switch self {
        case .outline: "Dark edge around the text. Recommended."
        case .shadow: "Soft shadow only. Least obtrusive."
        case .translucentBox: "Dimmed panel behind the text."
        case .solidBox: "Opaque panel. Most legible."
        }
    }

    var drawsOutline: Bool { self == .outline }

    var drawsShadow: Bool {
        self != .solidBox
    }

    /// Opacity of the panel behind the text, 0 when the style draws none.
    var backgroundOpacity: Double {
        switch self {
        case .outline, .shadow: 0
        case .translucentBox: 0.5
        case .solidBox: 0.92
        }
    }
}

/// The subtitle look, resolved from preferences and carried on
/// `PlaybackSource` so engines can apply it when they open media.
struct PlaybackSubtitleAppearance: Sendable, Equatable {
    var textSize: SubtitleTextSize = .medium
    var textStyle: SubtitleTextStyle = .outline

    static let `default` = PlaybackSubtitleAppearance()
}
