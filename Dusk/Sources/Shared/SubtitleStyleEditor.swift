#if !os(tvOS)
import SwiftUI

/// Edits the subtitle appearance against a live preview.
///
/// Pushed from the player's subtitle lists and from Settings, so both surfaces
/// edit the same preferences with the same controls. In the player, the sidecar
/// overlay behind the sheet restyles as values change.
///
/// Every option is a left/right stepper rather than a menu: it is quicker to
/// compare looks by stepping through them, and Left/Right maps directly onto
/// keyboard and controller input on the Mac.
struct SubtitleStyleEditor: View {
    /// Passed in rather than read from the environment: inside the player's
    /// sheets, the Designed-for-iPad modal boundary does not reliably carry
    /// Observation environment values (see docs/playback.md).
    let preferences: UserPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var directionalFocus: Option?

    private enum Option: Hashable {
        case font
        case weight
        case size
        case color
        case contrast
        case outline
        case reset
    }

    private struct Stepper {
        let option: Option
        let title: String
        let value: String
        var detail: String?
        var valueFont: Font?
        let step: (Int) -> Void
    }

    private static let previewHeight: Double = 132
    private static let sampleText = "- Did you hear that?\n- It came from upstairs."
    private static let sampleItalicWord = "upstairs"

    var body: some View {
        DuskDirectionalFocusScope(
            focusedID: $directionalFocus,
            groups: [.grid(directionalTargets, columnCount: 1)],
            defaultFocus: .font,
            isEnabled: supportsDirectionalSelection,
            onActivate: activate,
            onBack: {
                dismiss()
                return true
            },
            onDirectionalBoundary: adjust
        ) {
            ScrollViewReader { proxy in
                List {
                    Section {
                        preview
                            .listRowInsets(EdgeInsets())
                    }
                    .listRowBackground(Color.duskSurface)

                    Section {
                        ForEach(steppers, id: \.option) { stepper in
                            stepperRow(stepper)
                        }
                    } footer: {
                        Text(Self.footerText)
                            .foregroundStyle(Color.duskTextSecondary)
                    }
                    .listRowBackground(Color.duskSurface)

                    Section {
                        resetButton
                    }
                    .listRowBackground(Color.duskSurface)
                }
                .duskScrollContentBackgroundHidden()
                .background(Color.duskBackground)
                .onChange(of: directionalFocus) { _, target in
                    guard let target else { return }
                    withAnimation(.easeOut(duration: 0.16)) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
        }
        .duskNavigationTitle("Subtitle Style")
        .duskNavigationBarTitleDisplayModeInline()
    }

    private static let footerText = "Changes apply right away to downloaded subtitle files. Subtitles inside MP4 videos pick up size, font, color and contrast the next time you play them (their weight is only regular or bold). Videos played through VLC (MKV and similar) keep VLC's own subtitle appearance."

    // MARK: - Preview

    /// Rendered by the same view as the player overlay. The backdrop runs from
    /// near-black to near-white because a style has to hold up over both, and
    /// the bright end is where weak edges fail.
    private var preview: some View {
        let appearance = preferences.subtitleAppearance

        return ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [Color(white: 0.08), Color(white: 0.42), Color(white: 0.9)],
                startPoint: .leading,
                endPoint: .trailing
            )

            SubtitleTextView(
                text: Self.sampleText,
                italicRanges: Self.sampleItalicRanges,
                appearance: appearance,
                fontSize: PlaybackSubtitleStyle.overlayFontSize(
                    for: appearance,
                    videoHeight: Self.previewHeight
                )
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .frame(height: Self.previewHeight)
        .frame(maxWidth: .infinity)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Subtitle preview")
    }

    private static var sampleItalicRanges: [Range<Int>] {
        guard let range = sampleText.range(of: sampleItalicWord) else { return [] }
        let start = sampleText.distance(from: sampleText.startIndex, to: range.lowerBound)
        return [start..<(start + sampleItalicWord.count)]
    }

    // MARK: - Options

    private var steppers: [Stepper] {
        let appearance = preferences.subtitleAppearance
        var steppers = [
            Stepper(
                option: .font,
                title: "Font",
                value: appearance.font.displayName,
                // Each name is set in its own face, so stepping through the
                // fonts previews them right in the row.
                valueFont: SubtitleFontResolver.font(for: appearance, size: 17, italic: false),
                step: { preferences.subtitleFont = cycled(SubtitleFontResolver.availableFonts, from: preferences.subtitleFont, by: $0) }
            ),
            Stepper(
                option: .weight,
                title: "Weight",
                value: appearance.fontWeight.displayName,
                step: { preferences.subtitleFontWeight = cycled(SubtitleFontWeight.allCases, from: preferences.subtitleFontWeight, by: $0) }
            ),
            Stepper(
                option: .size,
                title: "Size",
                value: appearance.textSize.displayName,
                step: { preferences.subtitleTextSize = cycled(SubtitleTextSize.allCases, from: preferences.subtitleTextSize, by: $0) }
            ),
            Stepper(
                option: .color,
                title: "Color",
                value: appearance.textColor.displayName,
                step: { preferences.subtitleTextColor = cycled(SubtitleTextColor.allCases, from: preferences.subtitleTextColor, by: $0) }
            ),
            Stepper(
                option: .contrast,
                title: "Contrast",
                value: appearance.textStyle.displayName,
                detail: appearance.textStyle.detail,
                step: { preferences.subtitleTextStyle = cycled(SubtitleTextStyle.allCases, from: preferences.subtitleTextStyle, by: $0) }
            ),
        ]

        if appearance.textStyle.drawsOutline {
            steppers.append(
                Stepper(
                    option: .outline,
                    title: "Outline",
                    value: appearance.outlineWidth.displayName,
                    step: { preferences.subtitleOutlineWidth = cycled(SubtitleOutlineWidth.allCases, from: preferences.subtitleOutlineWidth, by: $0) }
                )
            )
        }

        return steppers
    }

    private var isDefault: Bool {
        preferences.subtitleAppearance == .default
    }

    private func resetToDefaults() {
        preferences.subtitleAppearance = .default
    }

    private func cycled<Value: Equatable>(_ values: [Value], from current: Value, by offset: Int) -> Value {
        guard !values.isEmpty else { return current }
        let index = values.firstIndex(of: current) ?? 0
        return values[(index + offset % values.count + values.count) % values.count]
    }

    // MARK: - Rows

    private func stepperRow(_ stepper: Stepper) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(stepper.title)
                    .foregroundStyle(Color.duskTextPrimary)

                if let detail = stepper.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Color.duskTextSecondary)
                }
            }

            Spacer(minLength: 8)

            stepButton(systemImage: "chevron.left", accessibilityLabel: "Previous \(stepper.title)") {
                stepper.step(-1)
            }

            Text(stepper.value)
                .font(stepper.valueFont ?? .body)
                .foregroundStyle(Color.duskTextPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 124)

            stepButton(systemImage: "chevron.right", accessibilityLabel: "Next \(stepper.title)") {
                stepper.step(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .focusable(!supportsDirectionalSelection)
        .duskDirectionalFocusHighlight(
            directionalFocus == stepper.option,
            shape: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .id(stepper.option)
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stepper.title)
        .accessibilityValue(stepper.value)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: stepper.step(1)
            case .decrement: stepper.step(-1)
            @unknown default: break
            }
        }
    }

    private func stepButton(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.duskTextPrimary)
                .frame(width: 34, height: 30)
                .background(Color.duskSurface.opacity(0.86), in: Capsule())
                .overlay {
                    Capsule().stroke(Color.duskTextSecondary.opacity(0.18), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var resetButton: some View {
        Button(action: resetToDefaults) {
            Text("Reset to Defaults")
                .foregroundStyle(isDefault ? Color.duskTextSecondary : Color.duskAccent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDefault)
        .focusable(!supportsDirectionalSelection)
        .duskDirectionalFocusHighlight(
            directionalFocus == .reset,
            shape: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .id(Option.reset)
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
    }

    // MARK: - Directional input

    private var supportsDirectionalSelection: Bool {
        #if os(iOS)
        ProcessInfo.processInfo.isiOSAppOnMac
        #else
        false
        #endif
    }

    private var directionalTargets: [Option] {
        steppers.map(\.option) + (isDefault ? [] : [.reset])
    }

    /// Return/controller A steps forward, so a single button still cycles.
    private func activate(_ option: Option) -> Bool {
        if option == .reset {
            guard !isDefault else { return false }
            resetToDefaults()
            return true
        }
        guard let stepper = steppers.first(where: { $0.option == option }) else { return false }
        stepper.step(1)
        return true
    }

    private func adjust(_ key: KeyEquivalent, option: Option) -> Bool {
        guard let stepper = steppers.first(where: { $0.option == option }) else { return false }
        switch key {
        case .leftArrow:
            stepper.step(-1)
        case .rightArrow:
            stepper.step(1)
        default:
            return false
        }
        return true
    }
}
#endif
