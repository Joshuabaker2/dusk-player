import Foundation

/// One timed subtitle line, in media time relative to the start of the file.
struct SubtitleCue: Sendable, Hashable, Identifiable {
    let id: Int
    let start: TimeInterval
    let end: TimeInterval
    /// Display text; may contain newlines for multi-line cues.
    let text: String

    func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }
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
        var pendingRange: (start: TimeInterval, end: TimeInterval)?
        var nextID = 0

        func flush() {
            guard let range = pendingRange else {
                pendingText.removeAll()
                return
            }
            let body = cleanText(pendingText.joined(separator: "\n"))
            if !body.isEmpty {
                cues.append(SubtitleCue(id: nextID, start: range.start, end: range.end, text: body))
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

    private static func parseTimingLine(_ line: String) -> (start: TimeInterval, end: TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count >= 2 else { return nil }

        let startToken = parts[0].trimmingCharacters(in: .whitespaces)
        // WebVTT appends cue settings ("line:90% align:middle") after the end
        // timestamp; everything past the first space belongs to them.
        let endToken = parts[1]
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? ""

        guard let start = parseTimestamp(startToken),
              let end = parseTimestamp(endToken) else {
            return nil
        }

        return (start, end)
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
    /// Positioning, karaoke and styling are dropped — the overlay renders a
    /// single centered text style, and pretending otherwise would be a lie.
    private static func parseSubStationAlpha(_ text: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var startFieldIndex = 1
        var endFieldIndex = 2
        var textFieldIndex = 9
        var nextID = 0

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)

            if line.lowercased().hasPrefix("format:"), line.lowercased().contains("text") {
                let fields = line
                    .dropFirst("format:".count)
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                if let index = fields.firstIndex(of: "start") { startFieldIndex = index }
                if let index = fields.firstIndex(of: "end") { endFieldIndex = index }
                if let index = fields.firstIndex(of: "text") { textFieldIndex = index }
                continue
            }

            guard line.lowercased().hasPrefix("dialogue:") else { continue }

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

            let body = cleanText(String(fields[textFieldIndex]))
            guard !body.isEmpty else { continue }

            cues.append(SubtitleCue(id: nextID, start: start, end: end, text: body))
            nextID += 1
        }

        return cues
    }

    // MARK: - Text cleanup

    private static func cleanText(_ raw: String) -> String {
        var text = raw

        // ASS line breaks and override blocks ({\an8}, {\pos(…)}, …).
        text = text.replacingOccurrences(of: "\\N", with: "\n")
        text = text.replacingOccurrences(of: "\\n", with: "\n")
        text = text.replacingOccurrences(
            of: "\\{[^}]*\\}",
            with: "",
            options: .regularExpression
        )
        // HTML-ish markup used by SRT/VTT (<i>, <b>, <font color=…>, <c.classname>).
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

        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
            text: String(cue.text.prefix(maximumCueLength)) + "…"
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
                    text: last.text
                )
                continue
            }
            result.append(SubtitleCue(id: result.count, start: cue.start, end: cue.end, text: cue.text))
        }

        return result
    }
}
