import Foundation
import Testing

@testable import LatheMeta

/// SubRip and WebVTT parsing, mostly against the files people actually have
/// rather than the ones the specifications describe.
@Suite("Subtitle parsing")
struct SubtitleParserTests {

    private static let srt = """
    1
    00:00:01,000 --> 00:00:02,500
    Hello there.

    2
    00:00:03,000 --> 00:00:04,000
    <i>Two</i> lines,
    with <b>bold</b>.

    """

    // MARK: - The ordinary case

    @Test("a well-formed SubRip file parses to its cues, text and timing")
    func parsesSubRip() throws {
        let parsed = try SubtitleParser.parse(Self.srt)
        #expect(parsed.format == .subRip)
        #expect(parsed.issues.isEmpty)
        #expect(parsed.cues.count == 2)
        #expect(parsed.cues[0] == SubtitleCue(startSeconds: 1, endSeconds: 2.5, text: "Hello there."))
        #expect(parsed.cues[1].text == "Two lines,\nwith bold.")
        #expect(parsed.cues[1].styles == [
            SubtitleStyleRun(range: 0..<3, style: .italic),
            SubtitleStyleRun(range: 16..<20, style: .bold),
        ])
    }

    @Test("a WebVTT file parses, skipping its header, notes, styles and cue settings")
    func parsesWebVTT() throws {
        let vtt = """
        WEBVTT - a title
        Kind: captions

        NOTE this is a comment
        that runs two lines

        STYLE
        ::cue { color: yellow }

        intro
        00:01.000 --> 00:02.000 align:start position:10%
        <v Roger>Hi &amp; welcome</v>

        01:00:00.250 --> 01:00:01.000
        <c.loud>Later</c> <00:00:00.500>on
        """
        let parsed = try SubtitleParser.parse(vtt)
        #expect(parsed.format == .webVTT)
        #expect(parsed.cues.map(\.text) == ["Hi & welcome", "Later on"])
        #expect(parsed.cues[0].startSeconds == 1)
        #expect(parsed.cues[1].startSeconds == 3600.25)
    }

    // MARK: - Hostile input

    /// A byte-order mark, CRLF line endings, and no blank line at the end:
    /// three things one Windows editor does at once.
    @Test("a BOM, CRLF and a missing final blank line change nothing")
    func bomAndCRLF() throws {
        let windows = "\u{FEFF}" + Self.srt.replacingOccurrences(of: "\n", with: "\r\n")
            .trimmingCharacters(in: .newlines)
        let parsed = try SubtitleParser.parse(Data(windows.utf8))
        #expect(parsed.cues == (try SubtitleParser.parse(Self.srt)).cues)

        let classicMac = Self.srt.replacingOccurrences(of: "\n", with: "\r")
        #expect(try SubtitleParser.parse(classicMac).cues.count == 2)

        let vtt = "\u{FEFF}WEBVTT\r\n\r\n00:01.000 --> 00:02.000\r\nHi"
        #expect(try SubtitleParser.parse(Data(vtt.utf8)).cues.map(\.text) == ["Hi"])
    }

    /// The failure a `"\n\n"` split produces: with no blank line between two
    /// cues, the second cue's number and timing become the first cue's text.
    @Test("cues with no blank line between them stay separate")
    func missingBlankLines() throws {
        let squashed = """
        1
        00:00:01,000 --> 00:00:02,000
        First
        2
        00:00:02,000 --> 00:00:03,000
        Second
        2021 was a year
        """
        let parsed = try SubtitleParser.parse(squashed)
        #expect(parsed.cues.map(\.text) == ["First", "Second\n2021 was a year"],
                "a number that is not above a timing line is text")
    }

    @Test("Windows-1252, Latin-1 and UTF-16 all decode")
    func legacyEncodings() throws {
        let text = "1\n00:00:01,000 --> 00:00:02,000\nCafé – “déjà vu”\n"
        let cp1252 = try #require(text.data(using: .windowsCP1252))
        #expect(String(data: cp1252, encoding: .utf8) == nil, "the fixture must not be valid UTF-8")
        #expect(try SubtitleParser.parse(cp1252).cues.first?.text == "Café – “déjà vu”")

        let latin = "1\n00:00:01,000 --> 00:00:02,000\nÇa va\n"
        let latin1 = try #require(latin.data(using: .isoLatin1))
        #expect(try SubtitleParser.parse(latin1).cues.first?.text == "Ça va")

        let utf16 = try #require(text.data(using: .utf16))   // with a BOM
        #expect(try SubtitleParser.parse(utf16).cues.first?.text == "Café – “déjà vu”")
        let unmarked = try #require(text.data(using: .utf16LittleEndian))
        #expect(try SubtitleParser.parse(unmarked).cues.first?.text == "Café – “déjà vu”")
    }

    @Test("binary data is refused as not text, rather than decoded into noise")
    func binaryIsRefused() {
        var bytes = [UInt8](repeating: 0, count: 64)
        for index in bytes.indices { bytes[index] = UInt8((index * 37) % 256) }
        #expect(throws: SubtitleError.notText) {
            try SubtitleParser.parse(Data(bytes), format: .subRip)
        }
    }

    @Test("a malformed timestamp is named by line, and strict parsing stops there")
    func malformedTimestamps() {
        for bad in ["00:00:01,000 --> 00:00:xx,000", "00:00:75,000 --> 00:00:76,000",
                    "00:61:00,000 --> 00:62:00,000", "0:0:1,0000 --> 0:0:2,000",
                    "+1:00:01,000 --> 1:00:02,000", "00:00:01,000 --> ", "--> 00:00:01,000"] {
            let text = "1\n00:00:00,000 --> 00:00:01,000\nfine\n\n2\n\(bad)\nbroken\n"
            #expect(throws: SubtitleError.malformedTiming(line: 6, text: bad), "\(bad)") {
                try SubtitleParser.parse(text)
            }
        }
    }

    @Test("skipping invalid cues keeps the rest, and says what was skipped")
    func lenientRecovery() throws {
        let text = """
        1
        00:00:01,000 --> 00:00:02,000
        Good

        2
        00:00:05,000 --> 00:00:04,000
        Backwards

        stray words

        3
        00:00:0x,000 --> 00:00:07,000
        Garbled

        4
        00:00:08,000 --> 00:00:09,000
        Also good
        """
        #expect(throws: SubtitleError.cueEndsBeforeItStarts(line: 6)) {
            try SubtitleParser.parse(text)
        }
        let parsed = try SubtitleParser.parse(text, recovery: .skipInvalidCues)
        #expect(parsed.cues.map(\.text) == ["Good", "Also good"])
        #expect(parsed.issues.map(\.error) == [
            .cueEndsBeforeItStarts(line: 6),
            .unexpectedText(line: 9, text: "stray words"),
            .malformedTiming(line: 12, text: "00:00:0x,000 --> 00:00:07,000"),
        ])
    }

    @Test("empty, cue-less and unsupported files throw errors that say so")
    func emptyAndUnsupported() {
        #expect(throws: SubtitleError.unsupportedFormat(.unknown)) { try SubtitleParser.parse("") }
        #expect(throws: SubtitleError.noCues) {
            try SubtitleParser.parse("1\n00:00:01,000 --> 00:00:02,000\n\n")
        }
        #expect(throws: SubtitleError.unsupportedFormat(.substationAlpha)) {
            try SubtitleParser.parse("[Script Info]\nTitle: x\n")
        }
        #expect(throws: SubtitleError.missingWebVTTHeader) {
            try SubtitleParser.parse("WEBVTTX\n\n00:01.000 --> 00:02.000\nx", format: .webVTT)
        }
        #expect(throws: SubtitleError.tooLarge(byteCount: SubtitleParser.maximumInputBytes + 1,
                                               limit: SubtitleParser.maximumInputBytes)) {
            try SubtitleParser.parse(Data(count: SubtitleParser.maximumInputBytes + 1))
        }
        let huge = "1\n00:00:01,000 --> 00:00:02,000\n" + String(repeating: "a", count: 20_000)
        #expect(throws: SubtitleError.cueTooLong(line: 2, byteCount: 20_000)) {
            try SubtitleParser.parse(huge)
        }
    }

    @Test("out-of-order cues are sorted, and markup that is not a tag is kept")
    func orderingAndLiteralBrackets() throws {
        let text = """
        2
        00:00:05,000 --> 00:00:06,000
        I <3 you & {him}

        1
        00:00:01,000 --> 00:00:02,000
        {\\an8}<font color="#ff0000">Top</font> {\\i1}sign{\\i0}
        """
        let cues = try SubtitleParser.parse(text).cues
        #expect(cues.map(\.text) == ["Top sign", "I <3 you & {him}"])
        #expect(cues[0].styles == [SubtitleStyleRun(range: 4..<8, style: .italic)])
    }

    /// Hostile input must not crash. A fixed-seed generator, so a failure is
    /// reproducible.
    @Test("random mutations of a real file never crash the parser")
    func fuzz() {
        var state: UInt64 = 0x5EED
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
        let seed = Array((Self.srt + "WEBVTT\n<i>&#x1F600;&amp</i>{\\i1}-->").utf8)
        for _ in 0..<2_000 {
            var bytes = seed
            for _ in 0..<(1 + Int(next() % 12)) {
                let at = Int(next() % UInt64(bytes.count))
                switch next() % 3 {
                case 0: bytes[at] = UInt8(truncatingIfNeeded: next())
                case 1: bytes.remove(at: at)
                default: bytes.insert(UInt8(truncatingIfNeeded: next()), at: at)
                }
            }
            for recovery in [SubtitleParser.Recovery.strict, .skipInvalidCues] {
                if let parsed = try? SubtitleParser.parse(Data(bytes), recovery: recovery) {
                    for cue in parsed.cues {
                        #expect(cue.endSeconds > cue.startSeconds)
                        let length = cue.text.unicodeScalars.count
                        #expect(cue.styles.allSatisfy { $0.range.upperBound <= length })
                        // And every cue survives the trip into a sample and back.
                        let payload = TimedTextSample.payload(text: cue.text, styles: cue.styles, fontSize: 18)
                        #expect(TimedTextSample.decodeTx3g([UInt8](payload))?.0 == cue.text)
                    }
                }
            }
        }
    }

    // MARK: - Writing text back

    @Test("SubRip and WebVTT serialisation round-trip text, styling and timing")
    func serialisationRoundTrips() throws {
        let cues = try SubtitleParser.parse(Self.srt).cues + [
            SubtitleCue(startSeconds: 3_725.001, endSeconds: 3_726.999, text: "a < b & c"),
        ]
        let srt = SubtitleSerializer.subRip(cues)
        #expect(srt.contains("01:02:05,001 --> 01:02:06,999"), "milliseconds are rounded, not truncated")
        #expect(try SubtitleParser.parse(srt).cues == cues)

        let vtt = SubtitleSerializer.webVTT(cues)
        #expect(vtt.hasPrefix("WEBVTT\n"))
        #expect(vtt.contains("a &lt; b &amp; c"))
        #expect(try SubtitleParser.parse(vtt).cues == cues)
    }

    // MARK: - Flattening

    /// Two cues on screen together cannot both be one `tx3g` sample, and
    /// neither may be lost.
    @Test("overlapping cues become one sample per span, earliest cue first")
    func overlapsAreMerged() {
        let cues = [
            SubtitleCue(startSeconds: 0, endSeconds: 4, text: "Dialogue",
                        styles: [SubtitleStyleRun(range: 0..<8, style: .italic)]),
            SubtitleCue(startSeconds: 2, endSeconds: 6, text: "SIGN",
                        styles: [SubtitleStyleRun(range: 0..<4, style: .bold)]),
            SubtitleCue(startSeconds: 8, endSeconds: 9, text: "Later"),
            SubtitleCue(startSeconds: 9, endSeconds: 8, text: "Backwards"),
            SubtitleCue(startSeconds: .nan, endSeconds: 9, text: "NaN"),
        ]
        let flat = cues.flattenedForTimedText()
        #expect(flat.map(\.text) == ["Dialogue", "Dialogue\nSIGN", "SIGN", "Later"])
        #expect(flat.map(\.startSeconds) == [0, 2, 4, 8])
        #expect(flat.map(\.endSeconds) == [2, 4, 6, 9])
        #expect(flat[1].styles == [
            SubtitleStyleRun(range: 0..<8, style: .italic),
            SubtitleStyleRun(range: 9..<13, style: .bold),
        ])
    }

    // MARK: - Language

    @Test("languages become an ISO 639-2 code and a BCP 47 tag, and junk is refused")
    func languages() throws {
        let cases: [(String, String, String?)] = [
            ("en", "eng", "en"), ("eng", "eng", "en"), ("fre", "fra", "fr"), ("ger", "deu", "de"),
            ("pt-br", "por", "pt-BR"), ("zh_hant", "zho", "zh-Hant"), ("und", "und", nil),
            ("xx", "und", "xx"),
        ]
        for (input, code, tag) in cases {
            let language = try SubtitleLanguage(input)
            #expect(language.iso639_2 == code, "\(input)")
            #expect(language.bcp47 == tag, "\(input)")
        }
        for junk in ["", "e", "english language", "en--US", "../en", "123", "en-toolongsubtag"] {
            #expect(throws: SubtitleError.invalidLanguage(junk)) { try SubtitleLanguage(junk) }
        }
    }

    @Test("every subtitle error says what to do")
    func errorsExplainThemselves() {
        let errors: [SubtitleError] = [
            .notText, .tooLarge(byteCount: 1, limit: 0), .unsupportedFormat(.substationAlpha),
            .missingWebVTTHeader, .malformedTiming(line: 1, text: "x"), .cueEndsBeforeItStarts(line: 1),
            .unexpectedText(line: 1, text: "x"), .cueTooLong(line: 1, byteCount: 1), .noCues,
            .invalidLanguage("x"), .unsupportedContainer(".mkv"), .noVideoTrack("a"),
            .cuesOutsideFilm(language: "en"), .destinationIsSource("a"),
            .muxFailed(stage: "s", reason: "r"), .trackNotFound(trackID: 1),
            .unreadableTrack(trackID: 1, format: "c608"),
        ]
        for error in errors {
            #expect(!(error.errorDescription ?? "").isEmpty)
            #expect(!(error.recoverySuggestion ?? "").isEmpty, "\(error) has no suggestion")
            #expect(!(error as NSError).localizedDescription.contains("error "),
                    "\(error) reports as a case index")
        }
    }
}
