import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Renders one subtitle cue in the user's subtitle appearance.
///
/// Shared by the sidecar overlay and the style editor's preview, so the preview
/// is the real renderer rather than an approximation of it.
struct SubtitleTextView: View {
    let text: String
    /// Character offsets into `text` to set in italics (see `SubtitleCue`).
    var italicRanges: [Range<Int>] = []
    let appearance: PlaybackSubtitleAppearance
    let fontSize: Double
    var lineLimit: Int?

    /// Offsets used to fake a glyph stroke by stamping dark copies behind the
    /// text. SwiftUI has no text-stroke modifier, and this matches what the
    /// engines produce natively (CEA-708 "uniform" edge / freetype outline).
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
        let style = appearance.textStyle
        let content = Text(attributedText)
            .multilineTextAlignment(Self.isDialogue(text) ? .leading : .center)
            .lineLimit(lineLimit)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)

        Group {
            if style.drawsOutline {
                let width = outlineWidth
                ZStack {
                    ForEach(Array(Self.outlineOffsets.enumerated()), id: \.offset) { _, offset in
                        content
                            .foregroundStyle(.black)
                            .offset(x: offset.width * width, y: offset.height * width)
                    }

                    content.foregroundStyle(textColor)
                }
            } else {
                content.foregroundStyle(textColor)
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
        .shadow(color: .black.opacity(shadowOpacity), radius: 2, x: 0, y: 1)
    }

    /// Two-speaker cues ("- Hi.\n- Hello.") are set as a left-aligned block that
    /// is centered as a whole, so the dashes line up. That is the usual
    /// subtitling convention, and it reads as an exchange where two
    /// independently centered lines read as ragged text.
    static func isDialogue(_ text: String) -> Bool {
        let lines = text.split(separator: "\n")
        guard lines.count > 1 else { return false }
        return lines.allSatisfy { line in
            guard let first = line.first else { return false }
            return first == "-" || first == "–" || first == "—"
        }
    }

    private var textColor: Color {
        let rgb = appearance.textColor.rgb
        return Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    /// Scales with the type so the stroke stays proportional at every size.
    private var outlineWidth: CGFloat {
        max(1, CGFloat(fontSize * appearance.outlineWidth.fontSizeFraction))
    }

    private var shadowOpacity: Double {
        switch appearance.textStyle {
        // The stroke carries the contrast; the shadow only softens its edge.
        // A dense one here is most of what made the old outline look heavy.
        case .outline: 0.6
        case .shadow, .translucentBox: 0.85
        case .solidBox: 0
        }
    }

    private var attributedText: AttributedString {
        typealias FontKey = AttributeScopes.SwiftUIAttributes.FontAttribute

        var attributed = AttributedString(text)
        attributed[FontKey.self] = SubtitleFontResolver.font(for: appearance, size: fontSize, italic: false)
        guard !italicRanges.isEmpty else { return attributed }

        let italicFont = SubtitleFontResolver.font(for: appearance, size: fontSize, italic: true)
        let characters = attributed.characters
        let count = characters.count
        for range in italicRanges {
            let lower = min(range.lowerBound, count)
            let upper = min(range.upperBound, count)
            guard lower < upper else { continue }
            let start = characters.index(characters.startIndex, offsetBy: lower)
            let end = characters.index(characters.startIndex, offsetBy: upper)
            attributed[start..<end][FontKey.self] = italicFont
        }
        return attributed
    }
}

/// Resolves a subtitle font preference to a concrete face.
///
/// Named families are matched by family + weight trait, so a weight the family
/// lacks lands on its nearest face (Helvetica Neue has no semibold, so it uses
/// Medium) instead of a synthesized one.
enum SubtitleFontResolver {
    /// The fonts this device can actually render. A missing family would fall
    /// back to the system font and show up as a duplicate System option.
    static var availableFonts: [SubtitleFont] {
        SubtitleFont.allCases.filter(isInstalled)
    }

    static func isInstalled(_ font: SubtitleFont) -> Bool {
        guard let family = font.familyName else { return true }
        #if canImport(UIKit)
        return UIFont.familyNames.contains(family)
        #else
        return false
        #endif
    }

    static func font(for appearance: PlaybackSubtitleAppearance, size: Double, italic: Bool) -> Font {
        #if canImport(UIKit)
        if let uiFont = uiFont(
            appearance.font,
            weight: appearance.fontWeight,
            size: CGFloat(size),
            italic: italic
        ) {
            return Font(uiFont)
        }
        #endif
        let font = Font.system(size: size, weight: swiftUIWeight(appearance.fontWeight))
        return italic ? font.italic() : font
    }

    private static func swiftUIWeight(_ weight: SubtitleFontWeight) -> Font.Weight {
        switch weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }

    #if canImport(UIKit)
    private static func uiFont(
        _ font: SubtitleFont,
        weight: SubtitleFontWeight,
        size: CGFloat,
        italic: Bool
    ) -> UIFont? {
        let uiWeight: UIFont.Weight = switch weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }

        if let family = font.familyName {
            var traits: [UIFontDescriptor.TraitKey: Any] = [.weight: uiWeight.rawValue]
            if italic {
                traits[.symbolic] = UIFontDescriptor.SymbolicTraits.traitItalic.rawValue
            }
            let descriptor = UIFontDescriptor(fontAttributes: [.family: family, .traits: traits])
            let resolved = UIFont(descriptor: descriptor, size: size)
            // An uninstalled family silently matches some unrelated face;
            // the system font is a better fallback than whatever that is.
            return resolved.familyName == family ? resolved : nil
        }

        var descriptor = UIFont.systemFont(ofSize: size, weight: uiWeight).fontDescriptor
        switch font {
        case .rounded:
            descriptor = descriptor.withDesign(.rounded) ?? descriptor
        case .serif:
            descriptor = descriptor.withDesign(.serif) ?? descriptor
        default:
            break
        }
        if italic {
            descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.traitItalic)) ?? descriptor
        }
        return UIFont(descriptor: descriptor, size: size)
    }
    #endif
}
