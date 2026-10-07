import Foundation

/// Recovers a searchable title and year from a release file name or a junk
/// Plex title ("www.UIndex.org - GOAT.2026.MULTI.1080p.WEB.H264-LOST.mkv" →
/// "GOAT", 2026).
///
/// Used to offer a Plex match for items the server never identified. It is a
/// heuristic, not a parser: it strips the noise release names reliably carry
/// (site prefixes, bracketed tags, resolution/source/codec tokens, release
/// groups) and then takes everything before the first year, episode marker, or
/// release tag as the title. When stripping would leave nothing, the less
/// aggressive result wins, so a title such as "[REC]" survives.
enum MediaTitleCleaner {
    struct Guess: Equatable, Hashable, Sendable {
        let title: String
        let year: Int?

        var displayName: String {
            year.map { "\(title) (\($0))" } ?? title
        }
    }

    /// Guess from a file path or name. The extension and directories are ignored.
    static func guess(fromFileName path: String) -> Guess? {
        var name = (path as NSString).lastPathComponent
        name = replacing(#"\.(mkv|mp4|m4v|avi|mov|ts|m2ts|wmv|webm|mpg|mpeg|flv|iso)$"#, in: name, with: "")
        return guess(from: name)
    }

    /// Guess from free text, e.g. a Plex title that kept the file name's junk.
    static func guess(from rawText: String) -> Guess? {
        let withoutPrefixes = stripLeadingNoise(rawText)
        // A title that is nothing but a bracketed tag ("[REC]") must not be
        // stripped to nothing.
        let source = tokens(from: withoutPrefixes).isEmpty ? rawText : withoutPrefixes
        var words = tokens(from: stripInlineNoise(source))
        if words.isEmpty {
            words = tokens(from: replacing(#"[\[\]{}()]"#, in: source, with: " "))
        }
        guard !words.isEmpty else { return nil }

        // Everything from the first release tag or episode marker on is noise.
        let cut = words.firstIndex(where: { isReleaseTag($0) || isEpisodeMarker($0) }) ?? words.count

        // The title's year is the last year-like token before the cut, and
        // never the first word, so "2001 A Space Odyssey 1968" keeps its title
        // and "1917 2019" is the film 1917 from 2019.
        if let yearIndex = words[..<cut].indices.last(where: { $0 > 0 && year(from: words[$0]) != nil }) {
            let title = words[..<yearIndex].joined(separator: " ")
            return Guess(title: trimmedTitle(title), year: year(from: words[yearIndex]))
        }

        let title = trimmedTitle(words[..<cut].joined(separator: " "))
        if title.isEmpty {
            // Starting with a tag (a mislabeled file) leaves no usable title.
            return nil
        }
        return Guess(title: title, year: nil)
    }

    /// A title reduced to letters and digits, for deciding whether two titles
    /// name the same thing ("Spider-Man" = "Spider Man", "GOAT" = "G.O.A.T").
    static func comparableTitle(_ title: String) -> String {
        title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    // MARK: - Stripping

    /// Site watermarks and leading bracketed tags that release names are
    /// prefixed with: "www.UIndex.org - ", "[ www.Torrenting.com ] - ",
    /// "[TGx] ", "(Hi10) ", "1337x.to - ".
    private static let leadingNoisePatterns = [
        // A web address with "www." or a scheme, any TLD.
        #"^\s*[\[({]?\s*(?:https?://)?www\.[^\s\])}]+\s*[\])}]?\s*[-–—_:|~.]*\s*"#,
        // A bare domain on a TLD release sites use, only when followed by a
        // real separator — "Mr.Robot" must not look like a domain.
        #"^\s*[\[({]?\s*[a-z0-9-]+\.(?:org|com|net|to|me|cc|xyz|io|tv|info|in|lol|ws|club|link|site|pw|ru|eu|se|nu|bz|li|ag|is|sx|vip|fun|art|top|mx|lt|st|ch|ac|fm|gg|biz)\s*[\])}]?\s*[-–—_:|~]+\s*"#,
        // A leading square-bracketed group: "[TGx]", "[SubsPlease]". Leading
        // parentheses are left alone: they are usually title ("(500) Days of
        // Summer").
        #"^\s*[\[{][^\]}]{1,60}[\]}]\s*[-–—_:|~]*\s*"#,
    ]

    private static func stripLeadingNoise(_ text: String) -> String {
        var result = text
        // Prefixes stack ("[TGx] www.site.org - Title"), so peel until stable.
        for _ in 0..<4 {
            let before = result
            for pattern in leadingNoisePatterns {
                result = replacing(pattern, in: result, with: "")
            }
            if result == before { break }
        }
        return result
    }

    private static func stripInlineNoise(_ text: String) -> String {
        var result = text
        // Bracketed groups are tags ("[1080p]", "[YTS.MX]", "[rarbg]"), except a
        // bracketed year, which is kept as a bare year token.
        result = replacing(#"[\[(]\s*((?:19|20)\d{2})\s*[\])]"#, in: result, with: " $1 ")
        result = replacing(#"\[[^\]]*\]"#, in: result, with: " ")
        result = replacing(#"\{[^}]*\}"#, in: result, with: " ")
        // Parentheses can be part of a title ("(500) Days of Summer"), so they
        // are unwrapped rather than removed; tags inside fall to the cut below.
        result = replacing(#"[()]"#, in: result, with: " ")
        // Dotted codec and audio names would otherwise split into tokens that
        // no longer look like tags ("H.264" → "H", "264"; "DD5.1" → "DD5", "1").
        result = replacing(#"(?i)\bh\.?(26[45])\b"#, in: result, with: "h$1")
        result = replacing(#"(?i)\b(ddp?|dd\+|eac3|ac3|aac|dts|truehd|opus|flac)\s*\.?\s*(\d)\.(\d)\b"#, in: result, with: "$1$2$3")
        return result
    }

    private static func tokens(from text: String) -> [String] {
        text
            .replacingOccurrences(of: "_", with: " ")
            // Dots separate words in release names.
            .replacingOccurrences(of: ".", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.allSatisfy { "-–—|~:+".contains($0) } }
    }

    private static func trimmedTitle(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " -–—_:|~.,"))
    }

    // MARK: - Token classes

    private static func year(from token: String) -> Int? {
        guard token.count == 4, let value = Int(token), (1900...2099).contains(value) else {
            return nil
        }
        return value
    }

    private static func isEpisodeMarker(_ token: String) -> Bool {
        matches(#"^(?i)(s\d{1,2}(e\d{1,3})*|\d{1,2}x\d{2,3}|e\d{2,3}|season|episode)$"#, token)
    }

    /// Words that only ever appear in release names. Deliberately excludes
    /// anything that is also a common title word ("Max", "French", "It",
    /// "Complete"): a missed tag only adds noise after the title, whereas a
    /// false positive would cut the title itself short.
    private static let releaseWords: Set<String> = [
        // Resolution and dynamic range
        "4k", "uhd", "hdr", "hdr10", "hdr10+", "hdr10plus", "dv", "dovi", "sdr", "hlg",
        // Source
        "web", "webdl", "web-dl", "webrip", "web-rip", "webhd", "bluray", "blu-ray", "bdrip",
        "brrip", "bdremux", "remux", "hdtv", "pdtv", "hdrip", "dvdrip", "dvdscr", "dvd5", "dvd9",
        "hdcam", "camrip", "telesync", "telecine", "screener", "vhsrip", "uhdrip",
        // Streaming services (only the unambiguous abbreviations)
        "amzn", "nf", "dsnp", "atvp", "hmax", "pcok", "pmtp", "stan", "crav", "itunes",
        // Video codecs and bit depth
        "x264", "x265", "h264", "h265", "hevc", "avc", "av1", "vp9", "xvid", "divx",
        "10bit", "8bit", "hi10", "hi10p", "12bit",
        // Audio
        "aac", "aac2", "aac20", "aac51", "ac3", "eac3", "ddp", "ddp2", "ddp20", "ddp51",
        "ddp71", "dd2", "dd20", "dd51", "dd71", "dd+", "dts", "dts-hd", "dtshd", "dts-x",
        "dtsx", "truehd", "atmos", "flac", "opus", "lpcm", "mp3", "5.1", "7.1", "2.0",
        // Edition and release flags
        "multi", "multisubs", "dual", "dualaudio", "vostfr", "truefrench", "subbed", "dubbed",
        "proper", "repack", "rerip", "internal", "limited", "unrated", "extended", "remastered",
        "imax", "uncut", "hc", "hardsub", "hardcoded", "readnfo",
    ]

    /// A release group rides on the last tag ("x264-LOST", "WEB-DL"), so a
    /// hyphenated token is judged by its first part. Titles hyphenate words,
    /// not tags ("Spider-Man"), so this cannot cut one short.
    private static func isReleaseTag(_ token: String) -> Bool {
        let lowered = token.lowercased()
        let head = lowered.split(separator: "-").first.map(String.init) ?? lowered
        return [lowered, head].contains { word in
            // 480p, 720p, 1080p, 2160p, 1080i.
            releaseWords.contains(word) || matches(#"^\d{3,4}[pi]$"#, word)
        }
    }

    // MARK: - Regex helpers

    private static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        text.replacingOccurrences(
            of: pattern,
            with: template,
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
