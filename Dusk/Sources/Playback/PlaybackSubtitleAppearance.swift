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

/// Typeface for app-drawn subtitles.
///
/// Every option is a font that ships with the OS and has a real medium weight,
/// so the weight preference changes the face instead of jumping straight from
/// regular to bold (as Verdana or Trebuchet would, having only those two).
enum SubtitleFont: String, CaseIterable, Identifiable, Sendable {
    /// SF Pro, what Apple's own players use.
    case system
    /// SF Pro Rounded: softer terminals, slightly friendlier at small sizes.
    case rounded
    /// New York, for a printed, cinematic look.
    case serif
    /// The neutral broadcast-caption grotesque.
    case helveticaNeue
    /// Open, geometric-humanist shapes; reads lighter at the same weight.
    case avenirNext

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .rounded: "Rounded"
        case .serif: "Serif"
        case .helveticaNeue: "Helvetica Neue"
        case .avenirNext: "Avenir Next"
        }
    }

    /// Installed family name for the non-system faces; nil for SF designs,
    /// which are resolved through the system font instead of by name.
    var familyName: String? {
        switch self {
        case .system, .rounded, .serif: nil
        case .helveticaNeue: "Helvetica Neue"
        case .avenirNext: "Avenir Next"
        }
    }
}

enum SubtitleFontWeight: String, CaseIterable, Identifiable, Sendable {
    case regular
    case medium
    case semibold
    case bold

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .regular: "Regular"
        case .medium: "Medium"
        case .semibold: "Semibold"
        case .bold: "Bold"
        }
    }
}

/// Subtitle text color. White is the streaming default; yellow is the classic
/// DVD/broadcast alternative some viewers find easier to track.
enum SubtitleTextColor: String, CaseIterable, Identifiable, Sendable {
    case white
    case yellow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .white: "White"
        case .yellow: "Yellow"
        }
    }

    /// sRGB components, shared by the overlay and AVPlayer's markup.
    var rgb: (red: Double, green: Double, blue: Double) {
        switch self {
        case .white: (1, 1, 1)
        case .yellow: (1, 0.9, 0.2)
        }
    }
}

/// Stroke thickness for the Outline style, as a fraction of the font size so it
/// stays proportional at every text size.
enum SubtitleOutlineWidth: String, CaseIterable, Identifiable, Sendable {
    case thin
    case medium
    case thick

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .thin: "Thin"
        case .medium: "Medium"
        case .thick: "Thick"
        }
    }

    /// Thin still holds white text against a near-white frame; Thick is the
    /// stroke Dusk shipped before this became a preference.
    var fontSizeFraction: Double {
        switch self {
        case .thin: 0.035
        case .medium: 0.05
        case .thick: 0.07
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
///
/// Defaults follow the streaming convention: a medium-weight sans with a thin
/// dark edge. Heavier weights and strokes read as shouty and hide more of the
/// picture without being meaningfully more legible.
struct PlaybackSubtitleAppearance: Sendable, Equatable {
    var textSize: SubtitleTextSize = .medium
    var textStyle: SubtitleTextStyle = .outline
    var font: SubtitleFont = .system
    var fontWeight: SubtitleFontWeight = .medium
    var textColor: SubtitleTextColor = .white
    var outlineWidth: SubtitleOutlineWidth = .thin

    static let `default` = PlaybackSubtitleAppearance()

    /// Short description for the rows that link to the style editor.
    var summary: String {
        "\(font.displayName), \(fontWeight.displayName), \(textStyle.displayName)"
    }
}
