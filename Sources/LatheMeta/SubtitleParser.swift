import Foundation

/// SubRip and WebVTT, read into ``SubtitleCue``s.
///
/// ## The input is hostile, whether or not anyone meant it to be
///
/// Subtitle files are hand-edited, machine-translated, re-encoded by upload
/// sites and concatenated by people fixing sync. What arrives in practice:
///
/// - **A byte-order mark**, which makes `"WEBVTT"` fail a prefix check and the
///   first cue number fail to parse as a number.
/// - **CRLF, and lone CR**, from Windows and classic Mac editors respectively.
/// - **No blank line after the last cue**, or none between two cues, so a
///   parser that splits on `"\n\n"` swallows the next cue's number and timing
///   into the previous cue's text.
/// - **Windows-1252 and Latin-1**, which fail UTF-8 validation on the first
///   accented letter; and UTF-16 from Windows tools.
/// - **Timestamps with the wrong separator**, a missing hours field, or a
///   seconds field of 75.
/// - **Overlapping cues**, which are legal in both formats and are dealt with at
///   write time — see ``Swift/Array/flattenedForTimedText()``.
///
/// None of it may crash, and none of it may produce a file that looks right and
/// is not. So the parser is a line-oriented state machine rather than a split,
/// every numeric field is range-checked, and every problem has a line number.
///
/// ## Strict, or skip and say so
///
/// ``Recovery/strict`` throws at the first problem, which is right for a file
/// the user is about to fix. ``Recovery/skipInvalidCues`` keeps going and
/// reports each skipped cue in ``ParsedSubtitles/issues``, which is right for a
/// download: one mistimed cue in a thousand should not cost the other 999.
public enum SubtitleParser {

    public enum Recovery: Sendable, Equatable {
        /// Throw at the first problem.
        case strict
        /// Skip what cannot be read and list it in ``ParsedSubtitles/issues``.
        case skipInvalidCues
    }

    /// Nothing that is really a subtitle file comes close. The limit exists so a
    /// mislabelled film does not get decoded into a multi-gigabyte `String`.
    public static let maximumInputBytes = 32 * 1024 * 1024

    /// A `tx3g` sample stores its length in 16 bits, and no screen shows this
    /// much text. A cue over this is a broken file — usually a missing timing
    /// line that folded a whole reel into one cue.
    public static let maximumCueBytes = 16 * 1024

    // MARK: - Entry points

    /// Parses subtitle bytes, detecting the encoding and — unless given — the
    /// format.
    public static func parse(
        _ data: Data, format: SubtitleFormat? = nil, recovery: Recovery = .strict
    ) throws -> ParsedSubtitles {
        guard data.count <= maximumInputBytes else {
            throw SubtitleError.tooLarge(byteCount: data.count, limit: maximumInputBytes)
        }
        let text = try decodeText(data)
        return try parse(text, format: format, recovery: recovery)
    }

    /// Parses subtitle text.
    public static func parse(
        _ text: String, format: SubtitleFormat? = nil, recovery: Recovery = .strict
    ) throws -> ParsedSubtitles {
        var body = Substring(text)
        if body.first == "\u{FEFF}" { body = body.dropFirst() }

        let resolved: SubtitleFormat
        if let format, format != .unknown {
            resolved = format
        } else {
            resolved = SubtitleFormat(sniffing: Data(body.prefix(512).utf8))
        }
        switch resolved {
        case .subRip, .webVTT:
            break
        case .substationAlpha, .unknown:
            // An unknown format that contains no cue arrow is not a format
            // this parser can guess its way through.
            throw SubtitleError.unsupportedFormat(resolved)
        }

        // `isNewline` is true for "\r\n" as one Character, and for a lone "\r",
        // so every line-ending convention splits the same way.
        let lines = body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        var machine = Machine(lines: lines, format: resolved, recovery: recovery)
        let cues = try machine.run()
        guard !cues.isEmpty else {
            // Every cue was skipped: the first reason is more use than "empty".
            throw machine.issues.first?.error ?? SubtitleError.noCues
        }
        return ParsedSubtitles(cues: cues, format: resolved, issues: machine.issues)
    }

    // MARK: - Encoding

    /// The bytes as text, trying the encodings subtitle files are actually in.
    ///
    /// Order matters. A byte-order mark is believed first. Then UTF-8, which is
    /// self-validating: Latin-1 text almost never passes it by accident. Then
    /// Windows-1252, which is what "ANSI" means on the machines most subtitles
    /// were typed on, and finally Latin-1, which accepts every byte — so a file
    /// in some third single-byte encoding comes out with a few wrong letters
    /// rather than not at all.
    ///
    /// NUL bytes outside UTF-16 mean the file is not text, and that is refused
    /// rather than decoded into a string of control characters.
    public static func decodeText(_ data: Data) throws -> String {
        let bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: bytes.dropFirst(3), as: UTF8.self)
        }
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) || bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            guard let text = String(data: data, encoding: .utf32) else { throw SubtitleError.notText }
            return stripBOM(text)
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            guard let text = String(data: data.dropFirst(2), encoding: .utf16LittleEndian) else {
                throw SubtitleError.notText
            }
            return text
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            guard let text = String(data: data.dropFirst(2), encoding: .utf16BigEndian) else {
                throw SubtitleError.notText
            }
            return text
        }

        if bytes.contains(0) {
            // UTF-16 without a mark: ASCII text puts its zero bytes all on one
            // side. Anything else with NULs in it is binary.
            let sample = bytes.prefix(4096)
            var evenZeros = 0, oddZeros = 0
            for (index, byte) in sample.enumerated() where byte == 0 {
                if index % 2 == 0 { evenZeros += 1 } else { oddZeros += 1 }
            }
            let half = sample.count / 2
            if half > 0, oddZeros * 10 >= half * 3, evenZeros * 10 < half,
               let text = String(data: data, encoding: .utf16LittleEndian) {
                return stripBOM(text)
            }
            if half > 0, evenZeros * 10 >= half * 3, oddZeros * 10 < half,
               let text = String(data: data, encoding: .utf16BigEndian) {
                return stripBOM(text)
            }
            throw SubtitleError.notText
        }

        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        throw SubtitleError.notText
    }

    private static func stripBOM(_ text: String) -> String {
        text.first == "\u{FEFF}" ? String(text.dropFirst()) : text
    }

    // MARK: - Timestamps

    /// `[h…:]mm:ss[,.]fff`, in seconds, or `nil`.
    ///
    /// Every field is checked. `00:00:75,000` is rejected rather than read as
    /// 1:15, because a file that says that is broken and guessing hides it;
    /// hours are allowed more than two digits because a long recording needs
    /// them. The fraction may be shorter than three digits and is read as a
    /// fraction — `,5` is half a second, not five milliseconds.
    static func timestamp(_ raw: Substring) -> Double? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }

        let secondsField = parts[parts.count - 1]
        let secondsParts = secondsField.split(
            omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == "." }
        )
        guard secondsParts.count == 1 || secondsParts.count == 2 else { return nil }

        guard let seconds = digits(secondsParts[0], maxCount: 2), seconds < 60 else { return nil }
        var fraction = 0
        var scale = 1
        if secondsParts.count == 2 {
            let field = secondsParts[1]
            guard let value = digits(field, maxCount: 3) else { return nil }
            fraction = value
            scale = field.count == 1 ? 10 : field.count == 2 ? 100 : 1000
        }

        let minutesField = parts[parts.count - 2]
        guard let minutes = digits(minutesField, maxCount: 2), minutes < 60 else { return nil }

        var hours = 0
        if parts.count == 3 {
            guard let value = digits(parts[0], maxCount: 6) else { return nil }
            hours = value
        }
        // One division of an exact integer, so `01:02:05,001` is the same
        // Double as the literal `3725.001` — adding `0.001` to `3725` is not.
        let whole = hours * 3600 + minutes * 60 + seconds
        return Double(whole * scale + fraction) / Double(scale)
    }

    /// ASCII digits only — `Int("+5")` and `Int("٣")` both succeed, and neither
    /// belongs in a timestamp.
    private static func digits(_ text: Substring, maxCount: Int) -> Int? {
        guard !text.isEmpty, text.count <= maxCount else { return nil }
        var value = 0
        for scalar in text.unicodeScalars {
            guard scalar.value >= 48, scalar.value <= 57 else { return nil }
            value = value * 10 + Int(scalar.value - 48)
        }
        return value
    }

    /// The two ends of a timing line, or `nil`. Anything after the second
    /// timestamp — WebVTT cue settings, SubRip's `X1:` coordinates — is
    /// ignored, because neither can be expressed in a `tx3g` sample.
    static func timing(_ line: Substring) -> (start: Double, end: Double)? {
        guard let arrow = line.range(of: "-->") else { return nil }
        let left = line[..<arrow.lowerBound]
        let rightTokens = line[arrow.upperBound...].split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let right = rightTokens.first,
              let start = timestamp(left),
              let end = timestamp(right)
        else { return nil }
        return (start, end)
    }

    // MARK: - The state machine

    private struct Machine {
        let lines: [Substring]
        let format: SubtitleFormat
        let recovery: Recovery
        var issues: [SubtitleIssue] = []
        var index = 0

        init(lines: [Substring], format: SubtitleFormat, recovery: Recovery) {
            self.lines = lines
            self.format = format
            self.recovery = recovery
        }

        mutating func run() throws -> [SubtitleCue] {
            if format == .webVTT { try skipWebVTTHeader() }

            var cues: [SubtitleCue] = []
            while index < lines.count {
                let line = lines[index]
                if isBlank(line) {
                    index += 1
                    continue
                }
                if format == .webVTT, !line.contains("-->"), isWebVTTNonCueBlock(line) {
                    skipBlock()
                    continue
                }

                // A timing line, or an identifier (a SubRip number, a WebVTT
                // id) directly above one.
                let timingIndex: Int
                if line.contains("-->") {
                    timingIndex = index
                } else if index + 1 < lines.count, lines[index + 1].contains("-->") {
                    timingIndex = index + 1
                } else {
                    try report(.unexpectedText(line: index + 1, text: String(line)))
                    skipBlock()
                    continue
                }

                let timingLine = lines[timingIndex]
                index = timingIndex + 1
                let textLines = collectText()

                guard let (start, end) = SubtitleParser.timing(timingLine) else {
                    try report(.malformedTiming(line: timingIndex + 1, text: String(timingLine)))
                    continue
                }
                guard end > start else {
                    try report(.cueEndsBeforeItStarts(line: timingIndex + 1))
                    continue
                }

                let raw = textLines.joined(separator: "\n")
                guard raw.utf8.count <= SubtitleParser.maximumCueBytes else {
                    try report(.cueTooLong(line: timingIndex + 1, byteCount: raw.utf8.count))
                    continue
                }
                let (text, styles) = SubtitleMarkup.strip(raw)
                // An empty cue is legal and shows nothing, so it is dropped
                // without complaint.
                guard !text.isEmpty else { continue }
                cues.append(SubtitleCue(startSeconds: start, endSeconds: end, text: text, styles: styles))
            }

            // SubRip files are not always in order, and a writer needs them to
            // be. Stable, so two cues at the same instant keep their order.
            return cues.enumerated()
                .sorted { ($0.element.startSeconds, $0.offset) < ($1.element.startSeconds, $1.offset) }
                .map(\.element)
        }

        /// The cue's text: everything up to a blank line — or up to the next
        /// cue, for the file with no blank line between cues. A line that is
        /// only digits followed by a timing line is the next cue's number, not
        /// this cue's text.
        private mutating func collectText() -> [String] {
            var collected: [String] = []
            while index < lines.count {
                let line = lines[index]
                if isBlank(line) || line.contains("-->") { break }
                if index + 1 < lines.count, lines[index + 1].contains("-->"),
                   format == .webVTT || isAllDigits(line) {
                    break
                }
                collected.append(String(line).trimmingCharacters(in: .whitespaces))
                index += 1
            }
            return collected
        }

        private mutating func skipWebVTTHeader() throws {
            guard let first = lines.first, first.hasPrefix("WEBVTT") else {
                throw SubtitleError.missingWebVTTHeader
            }
            let rest = first.dropFirst("WEBVTT".count)
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else {
                throw SubtitleError.missingWebVTTHeader
            }
            // The header block runs to the first blank line — unless the file
            // puts a cue straight after it, which real files do.
            index = 1
            while index < lines.count, !isBlank(lines[index]), !lines[index].contains("-->") {
                if index + 1 < lines.count, lines[index + 1].contains("-->") { break }
                index += 1
            }
        }

        private func isWebVTTNonCueBlock(_ line: Substring) -> Bool {
            for keyword in ["NOTE", "STYLE", "REGION"] where line.hasPrefix(keyword) {
                let rest = line.dropFirst(keyword.count)
                if rest.isEmpty || rest.first == " " || rest.first == "\t" { return true }
            }
            return false
        }

        private mutating func skipBlock() {
            while index < lines.count, !isBlank(lines[index]) { index += 1 }
        }

        private mutating func report(_ error: SubtitleError) throws {
            if recovery == .strict { throw error }
            issues.append(SubtitleIssue(error: error))
        }

        private func isBlank(_ line: Substring) -> Bool {
            line.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\u{FEFF}" }
        }

        private func isAllDigits(_ line: Substring) -> Bool {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && trimmed.unicodeScalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
        }
    }
}

/// What a parse produced.
public struct ParsedSubtitles: Sendable, Equatable {
    /// In start order.
    public var cues: [SubtitleCue]
    public var format: SubtitleFormat
    /// What was skipped under ``SubtitleParser/Recovery/skipInvalidCues``.
    /// Always empty under ``SubtitleParser/Recovery/strict``, which throws
    /// instead.
    public var issues: [SubtitleIssue]
}

/// One cue that could not be read, and why.
public struct SubtitleIssue: Sendable, Equatable, CustomStringConvertible {
    public var error: SubtitleError
    public var description: String { error.description }
}

// MARK: - Markup

/// Strips SubRip and WebVTT markup, keeping bold, italic and underline.
enum SubtitleMarkup {

    static func strip(_ raw: String) -> (String, [SubtitleStyleRun]) {
        var output = String.UnicodeScalarView()
        var runs: [SubtitleStyleRun] = []
        var bold = 0, italic = 0, underline = 0
        var runStart = 0
        var runStyle: SubtitleStyle = []

        func currentStyle() -> SubtitleStyle {
            var style: SubtitleStyle = []
            if bold > 0 { style.insert(.bold) }
            if italic > 0 { style.insert(.italic) }
            if underline > 0 { style.insert(.underline) }
            return style
        }
        func styleChanged() {
            let style = currentStyle()
            guard style != runStyle else { return }
            let position = output.count
            if !runStyle.isEmpty, position > runStart {
                runs.append(SubtitleStyleRun(range: runStart..<position, style: runStyle))
            }
            runStart = position
            runStyle = style
        }

        let scalars = Array(raw.unicodeScalars)
        var i = 0
        while i < scalars.count {
            let scalar = scalars[i]
            if scalar == "<", let close = scalars[(i + 1)...].prefix(256).firstIndex(of: ">") {
                let body = String(String.UnicodeScalarView(scalars[(i + 1)..<close]))
                    .trimmingCharacters(in: .whitespaces).lowercased()
                let closing = body.hasPrefix("/")
                // Only something shaped like a tag is a tag: a letter after the
                // optional slash, or a WebVTT timestamp. "I <3 you > him" is
                // text.
                let afterSlash = closing ? body.dropFirst() : Substring(body)
                let isTimestamp = !body.isEmpty && body.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ":" || $0 == ".") }
                guard afterSlash.first?.isLetter == true || isTimestamp else {
                    output.append(scalar)
                    i += 1
                    continue
                }
                let name = afterSlash.prefix { $0.isLetter }
                let delta = closing ? -1 : 1
                switch name {
                case "b": bold = max(0, bold + delta)
                case "i": italic = max(0, italic + delta)
                case "u": underline = max(0, underline + delta)
                default: break   // font, c, v, lang, ruby, timestamps: dropped
                }
                styleChanged()
                i = close + 1
                continue
            }
            // `{\an8}`, `{\i1}` — SubStation override blocks that SubRip files
            // pick up from converters. `{\i1}` and `{\i0}` are honoured.
            if scalar == "{", i + 1 < scalars.count, scalars[i + 1] == "\\",
               let close = scalars[(i + 1)...].prefix(256).firstIndex(of: "}") {
                let body = String(String.UnicodeScalarView(scalars[(i + 2)..<close]))
                for tag in body.split(separator: "\\") {
                    switch tag {
                    case "i1": italic = 1
                    case "i0": italic = 0
                    case "b1": bold = 1
                    case "b0": bold = 0
                    case "u1": underline = 1
                    case "u0": underline = 0
                    default: break
                    }
                }
                styleChanged()
                i = close + 1
                continue
            }
            if scalar == "&", let (decoded, length) = entity(at: i, in: scalars) {
                output.append(decoded)
                i += length
                continue
            }
            output.append(scalar)
            i += 1
        }
        let end = output.count
        if !runStyle.isEmpty, end > runStart {
            runs.append(SubtitleStyleRun(range: runStart..<end, style: runStyle))
        }

        return trim(String(output), runs)
    }

    /// Per-line trailing space removed, and leading and trailing blank lines —
    /// both are what is left when a tag was the only thing on a line — with the
    /// style runs moved to match.
    private static func trim(_ text: String, _ runs: [SubtitleStyleRun]) -> (String, [SubtitleStyleRun]) {
        let scalars = Array(text.unicodeScalars)
        var keep = [Bool](repeating: true, count: scalars.count)

        // Trailing spaces on each line.
        var i = scalars.count - 1
        var atLineEnd = true
        while i >= 0 {
            if scalars[i] == "\n" {
                atLineEnd = true
            } else if atLineEnd, scalars[i] == " " || scalars[i] == "\t" {
                keep[i] = false
            } else {
                atLineEnd = false
            }
            i -= 1
        }
        // Leading and trailing whitespace of the whole cue.
        var lead = 0
        while lead < scalars.count, !keep[lead] || scalars[lead].properties.isWhitespace {
            keep[lead] = false
            lead += 1
        }
        var tail = scalars.count - 1
        while tail >= lead, !keep[tail] || scalars[tail].properties.isWhitespace {
            keep[tail] = false
            tail -= 1
        }
        // Blank lines in the middle collapse to one line break: a tx3g
        // renderer shows an empty line as a gap, and the source never meant one.
        var previousKeptWasNewline = false
        for index in scalars.indices where keep[index] {
            if scalars[index] == "\n" {
                if previousKeptWasNewline { keep[index] = false }
                previousKeptWasNewline = true
            } else {
                previousKeptWasNewline = false
            }
        }

        var newIndex = [Int](repeating: 0, count: scalars.count + 1)
        var out = String.UnicodeScalarView()
        for index in scalars.indices {
            newIndex[index] = out.count
            if keep[index] { out.append(scalars[index]) }
        }
        newIndex[scalars.count] = out.count

        let moved = runs.compactMap { run -> SubtitleStyleRun? in
            let lower = newIndex[min(run.range.lowerBound, scalars.count)]
            let upper = newIndex[min(run.range.upperBound, scalars.count)]
            return upper > lower ? SubtitleStyleRun(range: lower..<upper, style: run.style) : nil
        }
        return (String(out), merge(moved))
    }

    static func merge(_ runs: [SubtitleStyleRun]) -> [SubtitleStyleRun] {
        var merged: [SubtitleStyleRun] = []
        for run in runs {
            if let last = merged.last, last.style == run.style, last.range.upperBound == run.range.lowerBound {
                merged[merged.count - 1].range = last.range.lowerBound..<run.range.upperBound
            } else {
                merged.append(run)
            }
        }
        return merged
    }

    private static let named: [String: Unicode.Scalar] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "lrm": "\u{200E}", "rlm": "\u{200F}",
    ]

    private static func entity(at start: Int, in scalars: [Unicode.Scalar]) -> (Unicode.Scalar, Int)? {
        guard let semicolon = scalars[(start + 1)...].prefix(12).firstIndex(of: ";") else { return nil }
        let name = String(String.UnicodeScalarView(scalars[(start + 1)..<semicolon]))
        let length = semicolon - start + 1
        if let scalar = named[name] { return (scalar, length) }
        if name.hasPrefix("#x") || name.hasPrefix("#X"),
           let value = UInt32(name.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(value) {
            return (scalar, length)
        }
        if name.hasPrefix("#"), let value = UInt32(name.dropFirst()), let scalar = Unicode.Scalar(value) {
            return (scalar, length)
        }
        return nil
    }

    /// Text with its styles written back as SubRip / WebVTT tags.
    static func render(_ text: String, _ styles: [SubtitleStyleRun], escape: Bool) -> String {
        let scalars = Array(text.unicodeScalars)
        var out = ""
        var position = 0
        func plain(_ range: Range<Int>) {
            for scalar in scalars[range] {
                if escape {
                    switch scalar {
                    case "&": out += "&amp;"
                    case "<": out += "&lt;"
                    case ">": out += "&gt;"
                    default: out.unicodeScalars.append(scalar)
                    }
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        for run in styles.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            let lower = max(position, min(run.range.lowerBound, scalars.count))
            let upper = max(lower, min(run.range.upperBound, scalars.count))
            guard upper > lower else { continue }
            plain(position..<lower)
            let tags = [(SubtitleStyle.bold, "b"), (.italic, "i"), (.underline, "u")]
                .filter { run.style.contains($0.0) }.map(\.1)
            out += tags.map { "<\($0)>" }.joined()
            plain(lower..<upper)
            out += tags.reversed().map { "</\($0)>" }.joined()
            position = upper
        }
        plain(position..<scalars.count)
        return out
    }
}

// MARK: - Writing text

/// ``SubtitleCue``s back out as text.
public enum SubtitleSerializer {

    /// SubRip, numbered from 1, with CRLF-free `\n` line endings.
    public static func subRip(_ cues: [SubtitleCue]) -> String {
        var out = ""
        for (number, cue) in cues.enumerated() {
            out += "\(number + 1)\n"
            out += "\(stamp(cue.startSeconds, ",")) --> \(stamp(cue.endSeconds, ","))\n"
            out += SubtitleMarkup.render(cue.text, cue.styles, escape: false) + "\n\n"
        }
        return out
    }

    /// WebVTT. Text is escaped, because a literal `<` in a WebVTT cue starts a
    /// tag.
    public static func webVTT(_ cues: [SubtitleCue]) -> String {
        var out = "WEBVTT\n\n"
        for cue in cues {
            out += "\(stamp(cue.startSeconds, ".")) --> \(stamp(cue.endSeconds, "."))\n"
            out += SubtitleMarkup.render(cue.text, cue.styles, escape: true) + "\n\n"
        }
        return out
    }

    /// `HH:MM:SS,mmm`, rounded to the millisecond — never truncated, because
    /// `1.001` is `1.00099999…` in binary and truncation writes `1.000`.
    static func stamp(_ seconds: Double, _ separator: String) -> String {
        let total = seconds.isFinite ? max(0, Int((seconds * 1000).rounded())) : 0
        let ms = total % 1000
        let s = (total / 1000) % 60
        let m = (total / 60_000) % 60
        let h = total / 3_600_000
        func pad(_ value: Int, _ width: Int) -> String {
            let digits = String(value)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return "\(pad(h, 2)):\(pad(m, 2)):\(pad(s, 2))\(separator)\(pad(ms, 3))"
    }
}
