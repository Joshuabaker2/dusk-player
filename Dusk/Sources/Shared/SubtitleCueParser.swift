import Foundation

/// One timed subtitle line, in media time relative to the start of the file.
struct SubtitleCue: Sendable, Hashable, Identifiable {
    let id: Int
    let start: TimeInterval
    let end: TimeInterval
    /// Display text; may contain newlines for multi-line cues.
    let text: String
    /// Character offsets into `text` that the file sets in italics. Italics
    /// carry meaning in subtitles — off-screen speakers, narration, lyrics,
    /// foreign words — so they survive the markup strip that drops the rest.
    var italicRanges: [Range<Int>] = []
    /// Where the file places the cue. Top placement keeps a subtitle off text
    /// burned into the bottom of the picture (signs, captions, credits).
    var placement: SubtitleCuePlacement = .bottom

    func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }
}

enum SubtitleCuePlacement: Sendable, Hashable {
    case bottom
    case top
}

/// Parses sidecar subtitle files into cues.
///
/// Deliberately pure and `nonisolated` so parsing can run off the main actor —
/// a feature-length SRT is thousands of cues and must not hitch the player.
enum SubtitleCueParser {
    /// Subtitle formats this parser can render as text. Image-based formats
    /// (PGS, VobSub) are intentionally absent: the overlay draws text only, and
    /// offering a track that can never appear is worse than hiding it.
    static let supportedFormats: Set<String> = [
        "srt", "subrip", "vtt", "webvtt", "ass", "ssa", "text", "mov_text", "subtitle",
    ]

    static func isSupportedFormat(_ format: String?) -> Bool {
        guard let format = format?.lowercased().trimmingCharacters(in: .whitespaces),
              !format.isEmpty else {
            // Plex occasionally omits the codec on sidecars; assume text rather
            // than hiding a track that is almost certainly an SRT.
            return true
        }
        return supportedFormats.contains(format)
    }

    static func parse(data: Data) -> [SubtitleCue] {
        guard let text = decodeText(data) else { return [] }
        return parse(text: text)
    }

    static func parse(text: String) -> [SubtitleCue] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}"))

        let cues: [SubtitleCue]
        if normalized.contains("[Script Info]") || normalized.contains("Dialogue:") {
            cues = parseSubStationAlpha(normalized)
        } else {
            cues = parseTimedBlocks(normalized)
        }

        return sanitize(cues)
    }

    // MARK: - Text decoding

    /// Sidecar subtitles are frequently not UTF-8 — legacy SRTs from subtitle
    /// sites are commonly Windows-1252 or Latin-1. Latin-1 is the terminal
    /// fallback because every byte sequence is valid in it, so decoding always
    /// yields something rather than dropping the file.
    static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            if let text = String(data: data, encoding: .utf16) {
                return text
            }
        }

        // Deliberately no bare `.utf16` here: it accepts nearly any byte
        // sequence and would turn a Windows-1252 file into CJK garbage that
        // parses to zero cues. Real UTF-16 is caught by the BOM check above.
        for encoding: String.Encoding in [.utf8, .windowsCP1252, .isoLatin1] {
            if let text = String(data: data, encoding: encoding), !text.isEmpty {
                return text
            }
        }

        return nil
    }

    // MARK: - SRT / WebVTT

    /// Handles SRT and WebVTT together: both are blocks of `start --> end`
    /// followed by text lines. Differences (`,` vs `.` decimals, optional
    /// hours, index lines, cue settings after the end time) are absorbed by the
    /// timestamp parser rather than by two near-identical scanners.
    private static func parseTimedBlocks(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var pendingText: [String] = []
        var pendingRange: (start: TimeInterval, end: TimeInterval, placement: SubtitleCuePlacement?)?
        var nextID = 0

        func flush() {
            guard let range = pendingRange else {
                pendingText.removeAll()
                return
            }
            let body = cleanText(pendingText.joined(separator: "\n"))
            if !body.text.isEmpty {
                cues.append(SubtitleCue(
                    id: nextID,
                    start: range.start,
                    end: range.end,
                    text: body.text,
                    italicRanges: body.italicRanges,
                    // An inline {\an8} (common in SRT) beats the VTT setting.
                    placement: body.placement ?? range.placement ?? .bottom
                ))
                nextID += 1
            }
            pendingRange = nil
            pendingText.removeAll()
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.contains("-->") {
                // A new timing line ends the previous cue even without a blank
                // separator, which some generators omit.
                flush()
                pendingRange = parseTimingLine(trimmed)
                continue
            }

            if trimmed.isEmpty {
                flush()
                continue
            }

            // Anything before a timing line is a header: the WEBVTT preamble,
            // NOTE/STYLE/REGION/X-TIMESTAMP-MAP blocks, SRT index numbers, or
            // VTT cue identifiers. None of it is display text.
            // (X-TIMESTAMP-MAP is ignored rather than honored — standalone
            // sidecars are zero-based; the map only applies to segmented HLS.)
            guard pendingRange != nil else { continue }

            pendingText.append(line)
        }

        flush()
        return cues
    }

    private static func parseTimingLine(
        _ line: String
    ) -> (start: TimeInterval, end: TimeInterval, placement: SubtitleCuePlacement?)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count >= 2 else { return nil }

        let startToken = parts[0].trimmingCharacters(in: .whitespaces)
        // WebVTT appends cue settings ("line:90% align:middle") after the end
        // timestamp; everything past the first space belongs to them.
        let endFields = parts[1]
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        let endToken = endFields.first ?? ""

        guard let start = parseTimestamp(startToken),
              let end = parseTimestamp(endToken) else {
            return nil
        }

        return (start, end, vttPlacement(settings: endFields.dropFirst()))
    }

    /// WebVTT's `line` setting: a percentage of the frame height, or a line
    /// number counted from the top when positive and from the bottom when
    /// negative (`line:0` is the top line, `line:-1` the bottom one).
    private static func vttPlacement(settings: ArraySlice<String>) -> SubtitleCuePlacement? {
        guard let line = settings.first(where: { $0.lowercased().hasPrefix("line:") }) else {
            return nil
        }
        // "line:10%,start" — the part after the comma is alignment.
        let value = line.dropFirst("line:".count).split(separator: ",").first.map(String.init) ?? ""
        if value.hasSuffix("%") {
            guard let percent = Double(value.dropLast()) else { return nil }
            return percent < 50 ? .top : .bottom
        }
        guard let number = Int(value) else { return nil }
        return number >= 0 ? .top : .bottom
    }

    /// Accepts `HH:MM:SS,mmm`, `HH:MM:SS.mmm`, `MM:SS.mmm` and `H:MM:SS.cc`.
    private static func parseTimestamp(_ token: String) -> TimeInterval? {
        let normalized = token
            .replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty else { return nil }

        let components = normalized.split(separator: ":")
        guard components.count == 2 || components.count == 3 else { return nil }

        var seconds: TimeInterval = 0
        for component in components.dropLast() {
            guard let value = Double(component) else { return nil }
            seconds = seconds * 60 + value
        }
        seconds *= 60

        guard let last = Double(components[components.count - 1]) else { return nil }
        return seconds + last
    }

    // MARK: - ASS / SSA

    /// Minimal SubStation Alpha support: dialogue timings and plain text.
    /// Karaoke, exact positioning and styling other than italics and
    /// top/bottom placement are dropped — the overlay renders one text style in
    /// two places, and pretending otherwise would be a lie.
    private static func parseSubStationAlpha(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var startFieldIndex = 1
        var endFieldIndex = 2
        var styleFieldIndex = 3
        var textFieldIndex = 9
        var nextID = 0

        var section = ""
        var styleNameIndex = 0
        var styleItalicIndex: Int?
        var styleAlignmentIndex: Int?
        var styles: [String: (italic: Bool, placement: SubtitleCuePlacement)] = [:]

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            let lowered = line.lowercased()

            if lowered.hasPrefix("["), lowered.hasSuffix("]") {
                section = lowered
                continue
            }

            if section.hasSuffix("styles]") {
                if lowered.hasPrefix("format:") {
                    let fields = commaFields(lowered.dropFirst("format:".count))
                    if let index = fields.firstIndex(of: "name") { styleNameIndex = index }
                    styleItalicIndex = fields.firstIndex(of: "italic")
                    styleAlignmentIndex = fields.firstIndex(of: "alignment")
                } else if lowered.hasPrefix("style:") {
                    let fields = commaFields(line.dropFirst("style:".count))
                    guard fields.indices.contains(styleNameIndex) else { continue }
                    // SSA (v4) numbers alignment 1-3 bottom, 5-7 top, 9-11 middle;
                    // ASS (v4+) uses numpad layout, 7-9 being the top row.
                    let alignment = styleAlignmentIndex.flatMap { fields.indices.contains($0) ? Int(fields[$0]) : nil }
                    let isTop = section == "[v4 styles]"
                        ? (5...7).contains(alignment ?? 2)
                        : (7...9).contains(alignment ?? 2)
                    let isItalic = styleItalicIndex.map { fields.indices.contains($0) && fields[$0] != "0" } ?? false
                    styles[fields[styleNameIndex].lowercased()] = (isItalic, isTop ? .top : .bottom)
                }
                continue
            }

            if lowered.hasPrefix("format:"), lowered.contains("text") {
                let fields = commaFields(lowered.dropFirst("format:".count))
                if let index = fields.firstIndex(of: "start") { startFieldIndex = index }
                if let index = fields.firstIndex(of: "end") { endFieldIndex = index }
                if let index = fields.firstIndex(of: "style") { styleFieldIndex = index }
                if let index = fields.firstIndex(of: "text") { textFieldIndex = index }
                continue
            }

            guard lowered.hasPrefix("dialogue:") else { continue }

            // The text field is last and may itself contain commas, so split
            // only up to the field count and keep the remainder intact.
            let payload = String(line.dropFirst("dialogue:".count))
            let fields = payload.split(
                separator: ",",
                maxSplits: textFieldIndex,
                omittingEmptySubsequences: false
            )
            guard fields.count > textFieldIndex,
                  fields.count > startFieldIndex,
                  fields.count > endFieldIndex,
                  let start = parseTimestamp(String(fields[startFieldIndex]).trimmingCharacters(in: .whitespaces)),
                  let end = parseTimestamp(String(fields[endFieldIndex]).trimmingCharacters(in: .whitespaces)) else {
                continue
            }

            let style = fields.indices.contains(styleFieldIndex)
                ? styles[fields[styleFieldIndex].trimmingCharacters(in: .whitespaces).lowercased()]
                : nil
            let body = cleanText(String(fields[textFieldIndex]), startsItalic: style?.italic ?? false)
            guard !body.text.isEmpty else { continue }

            cues.append(SubtitleCue(
                id: nextID,
                start: start,
                end: end,
                text: body.text,
                italicRanges: body.italicRanges,
                placement: body.placement ?? style?.placement ?? .bottom
            ))
            nextID += 1
        }

        return cues
    }

    private static func commaFields(_ text: Substring) -> [String] {
        text.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: - Text cleanup

    /// Stand-ins for italic on/off while the rest of the markup is stripped.
    /// Private-use code points, so they cannot collide with display text (any
    /// already in the input are removed first).
    private static let italicOn: Character = "\u{E000}"
    private static let italicOff: Character = "\u{E001}"

    private struct CleanedText {
        let text: String
        let italicRanges: [Range<Int>]
        /// Set only when the text itself carries a placement override.
        let placement: SubtitleCuePlacement?
    }

    private static func cleanText(_ raw: String, startsItalic: Bool = false) -> CleanedText {
        let placement = overridePlacement(in: raw)
        var text = raw
            .replacingOccurrences(of: String(italicOn), with: "")
            .replacingOccurrences(of: String(italicOff), with: "")
        if startsItalic {
            text = String(italicOn) + text
        }

        // ASS line breaks and override blocks ({\an8}, {\pos(…)}, …). A block
        // that toggles italics ({\i1}, {\i0}, possibly among other tags) keeps
        // that one meaning; everything else in it is dropped.
        text = text.replacingOccurrences(of: "\\N", with: "\n")
        text = text.replacingOccurrences(of: "\\n", with: "\n")
        text = text.replacingOccurrences(
            of: "\\{[^}]*\\\\i1[^}]*\\}",
            with: String(italicOn),
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "\\{[^}]*\\\\i0[^}]*\\}",
            with: String(italicOff),
            options: .regularExpression
        )
        text = text.replacingOccurrences(
            of: "\\{[^}]*\\}",
            with: "",
            options: .regularExpression
        )
        // HTML-ish markup used by SRT/VTT (<i>, <b>, <font color=…>, <c.classname>).
        // `<i\b` also takes VTT's `<i.classname>` but not `<img>`.
        text = text.replacingOccurrences(
            of: "<i\\b[^>]*>",
            with: String(italicOn),
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "</i\\s*>",
            with: String(italicOff),
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(
            of: "</?[a-zA-Z][^>]*>",
            with: "",
            options: .regularExpression
        )

        for (entity, replacement) in [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&nbsp;", " "),
            ("&lrm;", ""), ("&rlm;", ""),
        ] {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }

        // Resolve the markers into a per-character flag before trimming, so
        // whitespace cleanup can never shift the italics onto the wrong text.
        // An unclosed tag runs to the end of the cue, as players render it.
        var characters: [(character: Character, isItalic: Bool)] = []
        var isItalic = false
        for character in text {
            switch character {
            case italicOn: isItalic = true
            case italicOff: isItalic = false
            default: characters.append((character, isItalic))
            }
        }

        let lines = characters
            .split(omittingEmptySubsequences: false) { $0.character == "\n" }
            .map { trimmed(Array($0)) { $0.character.isWhitespace } }
        let lineBreak: [(character: Character, isItalic: Bool)] = [("\n", false)]
        let joined = trimmed(Array(lines.joined(separator: lineBreak))) { $0.character.isWhitespace }

        var italicRanges: [Range<Int>] = []
        var runStart: Int?
        for (offset, element) in joined.enumerated() {
            if element.isItalic, runStart == nil {
                runStart = offset
            } else if !element.isItalic, let start = runStart {
                italicRanges.append(start..<offset)
                runStart = nil
            }
        }
        if let start = runStart {
            italicRanges.append(start..<joined.count)
        }

        return CleanedText(
            text: String(joined.map(\.character)),
            italicRanges: italicRanges,
            placement: placement
        )
    }

    /// An alignment override in an ASS block: `{\an8}` (numpad layout, 7-9 is
    /// the top row) or the legacy SSA `{\a6}` (5-7 is the top row). Subtitle
    /// sites carry these into SRT files too.
    private static func overridePlacement(in text: String) -> SubtitleCuePlacement? {
        if let value = firstCapture(#"\{[^}]*\\an([1-9])"#, in: text).flatMap(Int.init) {
            return (7...9).contains(value) ? .top : .bottom
        }
        if let value = firstCapture(#"\{[^}]*\\a([0-9]{1,2})(?![0-9])"#, in: text).flatMap(Int.init) {
            return (5...7).contains(value) ? .top : .bottom
        }
        return nil
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[range])
    }

    private static func trimmed<Element>(
        _ elements: [Element],
        where isTrimmable: (Element) -> Bool
    ) -> [Element] {
        guard let first = elements.firstIndex(where: { !isTrimmable($0) }),
              let last = elements.lastIndex(where: { !isTrimmable($0) }) else {
            return []
        }
        return Array(elements[first...last])
    }

    // MARK: - Hygiene

    /// Sorts, drops degenerate cues, and merges duplicates that overlap. The
    /// controller assumes a sorted array so it can binary-search each tick.
    /// A real subtitle line runs well under 200 characters. Anything past this
    /// is a malformed file (or a parse that ran two cues together), and it is
    /// truncated rather than trusted — the renderer sizes itself to its content,
    /// so an absurd cue would otherwise cover the picture.
    private static let maximumCueLength = 400

    private static func truncated(_ cue: SubtitleCue) -> SubtitleCue {
        guard cue.text.count > maximumCueLength else { return cue }
        return SubtitleCue(
            id: cue.id,
            start: cue.start,
            end: cue.end,
            text: String(cue.text.prefix(maximumCueLength)) + "…",
            italicRanges: cue.italicRanges.compactMap { range in
                let upper = min(range.upperBound, maximumCueLength)
                return range.lowerBound < upper ? range.lowerBound..<upper : nil
            },
            placement: cue.placement
        )
    }

    private static func sanitize(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        let valid: [SubtitleCue] = cues.filter { $0.end > $0.start && !$0.text.isEmpty }
        let bounded: [SubtitleCue] = valid.map(truncated)
        let usable: [SubtitleCue] = bounded
            .sorted { lhs, rhs in
                lhs.start == rhs.start ? lhs.end < rhs.end : lhs.start < rhs.start
            }

        var result: [SubtitleCue] = []
        result.reserveCapacity(usable.count)

        for cue in usable {
            // Some generators repeat a line as consecutive overlapping cues;
            // collapsing them avoids a visible re-render mid-sentence.
            if let last = result.last, last.text == cue.text, cue.start <= last.end {
                result[result.count - 1] = SubtitleCue(
                    id: last.id,
                    start: last.start,
                    end: max(last.end, cue.end),
                    text: last.text,
                    italicRanges: last.italicRanges,
                    placement: last.placement
                )
                continue
            }
            result.append(SubtitleCue(
                id: result.count,
                start: cue.start,
                end: cue.end,
                text: cue.text,
                italicRanges: cue.italicRanges,
                placement: cue.placement
            ))
        }

        return result
    }
}
