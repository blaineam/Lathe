import Foundation

// MARK: - Why subtitles live in LatheMeta

// Putting subtitles into a film is a container rewrite: every video and audio
// sample is copied across untouched and a text track is added beside them.
// That is exactly this module's contract — nothing here decodes or encodes
// media — and it is also what keeps the dependency graph honest. LatheLookup
// already sits on LatheMeta, so "find subtitles online and put them in the
// file" needs no new edge; had the muxer gone into LatheVideo, fetching a
// subtitle would have linked a video transcoder and a WebP encoder.

/// One subtitle: a span of time and the text shown during it.
///
/// ## Plain text, with the styling beside it
///
/// `text` never contains markup. SubRip and WebVTT both carry HTML-ish tags,
/// and a `tx3g` sample does not interpret them — a player shows `<i>` as three
/// literal characters. So the tags are parsed out once, on the way in, and the
/// three a timed-text track can actually express (bold, italic, underline) are
/// kept as ``styles``. Everything else (`<font color>`, `{\an8}`, WebVTT
/// classes and voices) is dropped, because no Apple player would honour it
/// from inside the file.
///
/// Times are seconds, as ``Chapter``'s are, so the two timed-track models read
/// the same way.
public struct SubtitleCue: Sendable, Equatable, Hashable {

    /// When the cue appears, in seconds from the start of the film.
    public var startSeconds: Double

    /// When it disappears.
    ///
    /// Stored as an end rather than a duration because that is what both text
    /// formats write, and converting on the way in and back on the way out is
    /// how a millisecond goes missing.
    public var endSeconds: Double

    /// What is shown. Lines are separated by `"\n"`; no markup.
    public var text: String

    /// Bold, italic and underline spans over ``text``.
    public var styles: [SubtitleStyleRun]

    public init(startSeconds: Double, endSeconds: Double, text: String, styles: [SubtitleStyleRun] = []) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.styles = styles
    }

    public var durationSeconds: Double { endSeconds - startSeconds }
}

/// Character styling a timed-text track can carry.
public struct SubtitleStyle: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    // The values are the 3GPP face-style flags, so a style converts to and from
    // a `tx3g` style record without a table.
    public static let bold = SubtitleStyle(rawValue: 1)
    public static let italic = SubtitleStyle(rawValue: 2)
    public static let underline = SubtitleStyle(rawValue: 4)
}

/// A styled span of a cue's text.
///
/// ## Offsets are Unicode scalars, not bytes and not `Character`s
///
/// A `tx3g` style record addresses text by character position, and every
/// implementation that interoperates with Apple's counts code points: one per
/// scalar, however many UTF-8 bytes it takes. Counting bytes shifts every
/// italic span after an accented letter; counting grapheme clusters shifts it
/// after an emoji with a skin tone. So the model uses the unit the file does.
public struct SubtitleStyleRun: Sendable, Hashable {
    /// Scalar offsets into ``SubtitleCue/text``.
    public var range: Range<Int>
    public var style: SubtitleStyle

    public init(range: Range<Int>, style: SubtitleStyle) {
        self.range = range
        self.style = style
    }
}

/// The text formats subtitles arrive in.
///
/// Lives here rather than in LatheLookup, where it began, because the parser
/// that consumes it is here; LatheLookup's download path still reports one.
public enum SubtitleFormat: String, Sendable, Equatable, CaseIterable {
    case subRip = "srt"
    case webVTT = "vtt"
    case substationAlpha = "ass"
    case unknown = "sub"

    /// The format, from the filename and then from the contents.
    ///
    /// Contents second and authoritative-ish: a `.txt` holding SubRip is common,
    /// and the cue arrow is unmistakable.
    public init(filename: String, contents: Data) {
        let ext = (filename as NSString).pathExtension.lowercased()
        if ext == "ssa" {
            self = .substationAlpha
            return
        }
        if let byName = SubtitleFormat(rawValue: ext), byName != .unknown {
            self = byName
            return
        }
        self.init(sniffing: contents)
    }

    /// The format from the contents alone.
    public init(sniffing contents: Data) {
        var head = contents.prefix(512)
        if head.starts(with: [0xEF, 0xBB, 0xBF]) { head = head.dropFirst(3) }
        let text = String(decoding: head, as: UTF8.self)
        if text.hasPrefix("WEBVTT") { self = .webVTT }
        else if text.contains("[Script Info]") { self = .substationAlpha }
        else if text.contains("-->") { self = .subRip }
        else { self = .unknown }
    }
}

public extension Array where Element == SubtitleCue {

    /// The cues as a player can show them: one at a time, in order, with no
    /// overlaps.
    ///
    /// ## Why overlaps are merged rather than trimmed
    ///
    /// Both text formats allow two cues on screen at once — a speaker at the top
    /// while another speaks at the bottom, a sign translated over dialogue. A
    /// `tx3g` track shows exactly one sample at a time, so the writer has to
    /// decide. Truncating the earlier cue (what ``Chapter`` normalisation does)
    /// would delete dialogue; letting the writer accept overlapping timestamps
    /// produces a track whose later cue silently replaces the earlier. So the
    /// timeline is cut at every boundary and each piece shows every cue active
    /// during it, earliest first, one per line.
    func flattenedForTimedText() -> [SubtitleCue] {
        let valid = filter {
            $0.startSeconds.isFinite && $0.endSeconds.isFinite
                && $0.startSeconds >= 0 && $0.endSeconds > $0.startSeconds
                && !$0.text.isEmpty
        }
        .enumerated()
        .sorted { ($0.element.startSeconds, $0.offset) < ($1.element.startSeconds, $1.offset) }
        .map(\.element)
        guard !valid.isEmpty else { return [] }

        var boundaries = Set<Double>()
        for cue in valid {
            boundaries.insert(cue.startSeconds)
            boundaries.insert(cue.endSeconds)
        }
        let edges = boundaries.sorted()

        var out: [SubtitleCue] = []
        var firstCandidate = 0
        for (from, to) in zip(edges, edges.dropFirst()) {
            // Cues are sorted by start, so everything before `firstCandidate`
            // has already ended and never needs looking at again. That keeps a
            // well-formed file linear rather than quadratic.
            while firstCandidate < valid.count, valid[firstCandidate].endSeconds <= from {
                firstCandidate += 1
            }
            var text = ""
            var styles: [SubtitleStyleRun] = []
            var offset = 0
            var index = firstCandidate
            while index < valid.count, valid[index].startSeconds <= from {
                let cue = valid[index]
                index += 1
                guard cue.endSeconds >= to else { continue }
                if !text.isEmpty {
                    text += "\n"
                    offset += 1
                }
                text += cue.text
                styles += cue.styles.map {
                    SubtitleStyleRun(range: ($0.range.lowerBound + offset)..<($0.range.upperBound + offset),
                                     style: $0.style)
                }
                offset += cue.text.unicodeScalars.count
            }
            guard !text.isEmpty else { continue }

            if var last = out.last, last.endSeconds == from, last.text == text, last.styles == styles {
                last.endSeconds = to
                out[out.count - 1] = last
            } else {
                out.append(SubtitleCue(startSeconds: from, endSeconds: to, text: text, styles: styles))
            }
        }
        return out
    }
}
