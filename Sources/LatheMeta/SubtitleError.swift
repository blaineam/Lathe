import Foundation

/// What goes wrong with subtitles, separated by what the person should do next.
///
/// Its own type rather than more ``LatheCore/LatheError`` cases, for the reason
/// `LookupError` is: subtitle failures are overwhelmingly about the *subtitle
/// file* — somebody else's hand-edited text — and the useful response is
/// "open line 212", not "encoding failed". Every case carries what is needed to
/// say that, and ``recoverySuggestion`` says it.
///
/// `LocalizedError` for the same reason as `LookupError`: without it, an alert
/// reads "The operation couldn't be completed. (LatheMeta.SubtitleError
/// error 3.)"
public enum SubtitleError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {

    // MARK: Reading the text

    /// The bytes are not text in any encoding worth guessing at — they contain
    /// NUL bytes and are not UTF-16. Usually a `.sub` that is really a VobSub
    /// bitmap index, or a file that is not subtitles at all.
    case notText

    /// Larger than any subtitle file, which makes it something else.
    case tooLarge(byteCount: Int, limit: Int)

    /// A format this package reads the name of but not the contents of.
    case unsupportedFormat(SubtitleFormat)

    /// A `.vtt` whose first line is not `WEBVTT`.
    case missingWebVTTHeader

    /// A timing line that is not two timestamps around an arrow. `line` is
    /// 1-based, as an editor shows it.
    case malformedTiming(line: Int, text: String)

    /// A cue that ends before, or at the same moment as, it starts.
    case cueEndsBeforeItStarts(line: Int)

    /// Text where a cue number or timing line was expected.
    case unexpectedText(line: Int, text: String)

    /// A cue so long that no player could show it.
    case cueTooLong(line: Int, byteCount: Int)

    /// The file parsed, and there was nothing in it.
    case noCues

    // MARK: Writing into a film

    /// A language that is not a BCP 47 tag or an ISO 639 code.
    case invalidLanguage(String)

    /// The destination is not a container Apple's writer will put a subtitle
    /// track into.
    case unsupportedContainer(String)

    /// The source has no video, so there is nothing for subtitles to sit over.
    case noVideoTrack(String)

    /// Every cue starts after the film ends.
    case cuesOutsideFilm(language: String)

    /// The destination is the source.
    case destinationIsSource(String)

    /// The writer refused a track or a sample, or failed to finish.
    case muxFailed(stage: String, reason: String)

    // MARK: Reading out of a film

    /// No subtitle track with that identifier.
    case trackNotFound(trackID: Int32)

    /// A subtitle track in a format this package cannot turn into text —
    /// CEA-608 captions or a bitmap format.
    case unreadableTrack(trackID: Int32, format: String)

    public var description: String {
        switch self {
        case .notText:
            return "the subtitle file is not text"
        case let .tooLarge(count, limit):
            return "the subtitle file is \(count) bytes, over the \(limit)-byte limit"
        case let .unsupportedFormat(format):
            return "\(Self.name(of: format)) subtitles are not supported"
        case .missingWebVTTHeader:
            return "the WebVTT file does not start with a WEBVTT line"
        case let .malformedTiming(line, text):
            return "line \(line) is not a valid timing line: \"\(Self.clip(text))\""
        case let .cueEndsBeforeItStarts(line):
            return "the cue timed on line \(line) ends before it starts"
        case let .unexpectedText(line, text):
            return "line \(line) is outside any cue: \"\(Self.clip(text))\""
        case let .cueTooLong(line, count):
            return "the cue timed on line \(line) is \(count) bytes long"
        case .noCues:
            return "the subtitle file contains no cues"
        case let .invalidLanguage(code):
            return "\"\(code)\" is not a language code"
        case let .unsupportedContainer(name):
            return "\(name) cannot carry a subtitle track"
        case let .noVideoTrack(name):
            return "\(name) has no video track"
        case let .cuesOutsideFilm(language):
            return "every \(language) cue starts after the film ends"
        case let .destinationIsSource(name):
            return "\(name) is both the source and the destination"
        case let .muxFailed(stage, reason):
            return "adding subtitles failed while \(stage): \(reason)"
        case let .trackNotFound(id):
            return "there is no subtitle track \(id)"
        case let .unreadableTrack(id, format):
            return "subtitle track \(id) is \(format), which cannot be read as text"
        }
    }

    public var errorDescription: String? { description }

    /// What the person reading this can actually do about it.
    public var recoverySuggestion: String? {
        switch self {
        case .notText:
            return "Choose a .srt or .vtt file. A .sub next to a .idx is a picture-based "
                + "format and has to be converted with OCR first."
        case .tooLarge:
            return "Check that this is really a subtitle file; a feature film's subtitles "
                + "are well under a megabyte."
        case .unsupportedFormat:
            return "Convert it to SubRip (.srt) or WebVTT (.vtt) first, or pick a "
                + "different download — most subtitles are offered as SubRip."
        case .missingWebVTTHeader:
            return "If the file is really SubRip, rename it to .srt; otherwise add a "
                + "first line reading WEBVTT."
        case .malformedTiming, .cueEndsBeforeItStarts, .unexpectedText, .cueTooLong:
            return "Fix that line in a text editor, or parse with recovery set to skip "
                + "invalid cues to keep the rest of the file."
        case .noCues:
            return "The file may be empty or in another format; open it in a text editor to check."
        case .invalidLanguage:
            return "Use a code such as \"en\", \"pt-BR\" or \"fra\", or \"und\" when the "
                + "language is not known."
        case .unsupportedContainer:
            return "Write to an .mp4, .m4v or .mov. Matroska and WebM are not written by "
                + "Apple's frameworks."
        case .noVideoTrack:
            return "Subtitles are added to films. Check that this is the file you meant."
        case .cuesOutsideFilm:
            return "These subtitles are timed for a different cut or release. Pick a download "
                + "whose release name matches this file."
        case .destinationIsSource:
            return "Write the result to a new file and move it into place afterwards."
        case .muxFailed:
            return "The source may use a codec this system cannot pass through into the "
                + "chosen container; try writing a .mov instead."
        case .trackNotFound:
            return "List the file's subtitle tracks first and use one of their identifiers."
        case .unreadableTrack:
            return "Only text subtitle tracks (tx3g or WebVTT) can be extracted."
        }
    }

    private static func name(of format: SubtitleFormat) -> String {
        switch format {
        case .subRip: "SubRip"
        case .webVTT: "WebVTT"
        case .substationAlpha: "SubStation Alpha"
        case .unknown: "Unrecognised"
        }
    }

    /// Enough of a bad line to find it, without echoing a megabyte of garbage
    /// into an alert.
    private static func clip(_ text: String) -> String {
        text.count > 60 ? String(text.prefix(60)) + "…" : text
    }
}
