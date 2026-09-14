import Foundation
import LatheCore

/// The `format` object of an ffprobe report.
///
/// See ``MediaInfo/ffprobeReport()`` for why the numeric-looking fields are
/// strings.
public struct FFProbeFormat: Codable, Sendable, Equatable {
    public var filename: String
    public var numberOfStreams: Int
    public var formatName: String
    public var startTime: String
    public var duration: String
    public var size: String?
    public var bitRate: String?

    enum CodingKeys: String, CodingKey {
        case filename
        case numberOfStreams = "nb_streams"
        case formatName = "format_name"
        case startTime = "start_time"
        case duration
        case size
        case bitRate = "bit_rate"
    }
}

/// One entry of an ffprobe report's `streams` array.
public struct FFProbeStream: Codable, Sendable, Equatable {
    public var index: Int
    public var codecName: String
    public var codecType: String
    public var codecTagString: String
    public var width: Int?
    public var height: Int?
    public var codedWidth: Int?
    public var codedHeight: Int?
    public var rFrameRate: String?
    public var averageFrameRate: String?
    public var sampleRate: String?
    public var channels: Int?
    public var duration: String
    public var bitRate: String?

    enum CodingKeys: String, CodingKey {
        case index
        case codecName = "codec_name"
        case codecType = "codec_type"
        case codecTagString = "codec_tag_string"
        case width
        case height
        case codedWidth = "coded_width"
        case codedHeight = "coded_height"
        case rFrameRate = "r_frame_rate"
        case averageFrameRate = "avg_frame_rate"
        case sampleRate = "sample_rate"
        case channels
        case duration
        case bitRate = "bit_rate"
    }
}

/// An ffprobe report: what `ffprobe -show_format -show_streams -of json` prints.
///
/// `streams` is declared before `format` so the encoded key order matches
/// ffprobe's. Nothing should depend on that — JSON objects are unordered — but a
/// human diffing two outputs will notice, and a compatibility shim that
/// *reads* like the thing it replaces is easier to trust.
public struct FFProbeReport: Codable, Sendable, Equatable {
    public var streams: [FFProbeStream]
    public var format: FFProbeFormat
}

extension MediaInfo {

    /// This file's facts in ffprobe's own JSON shape — a compatibility shim for
    /// callers migrating off a command-line prober.
    ///
    /// ## Why this exists
    ///
    /// Replacing a subprocess prober is rarely a single change. The call site
    /// that spawned it is usually one of several, the JSON it produced is
    /// already parsed by code that works, and that parsing is often in another
    /// language or another process. Emitting the same shape means the
    /// subprocess can be removed on its own, as one reviewable change, and the
    /// parsing replaced later — or never. ``MediaInfo`` is the better type and
    /// new code should use it directly; this is the bridge, not the
    /// destination.
    ///
    /// ## The string-typed numbers are not a mistake
    ///
    /// ffprobe emits `duration`, `bit_rate`, `size`, `start_time` and
    /// `sample_rate` as **JSON strings**, while `width`, `height`, `channels`
    /// and `index` are **JSON numbers**. Every parser written against ffprobe
    /// therefore expects a string in the first group, and "helpfully" emitting a
    /// number instead is a breaking change that shows up as a type error deep
    /// inside somebody else's decoder. The shape is copied exactly, including
    /// ffprobe's six-decimal duration formatting.
    ///
    /// ## What is deliberately missing
    ///
    /// `codec_long_name`, `profile`, `pix_fmt`, `time_base`, `nb_frames`,
    /// `disposition`, `tags` and `probe_score` are not emitted. AVFoundation
    /// does not report most of them, and none can be synthesised honestly —
    /// inventing `nb_frames` from `duration × frame rate` would be a guess
    /// presented as a measurement. Absent keys decode as `nil` in every
    /// reasonable parser; wrong keys do not.
    ///
    /// One field is *shaped* like ffprobe's and not always *valued* like it:
    /// `codec_tag_string` carries AVFoundation's media subtype verbatim, which
    /// for an audio track is the CoreAudio format ID rather than the container's
    /// sample-description tag — `aac ` where ffprobe prints `mp4a`. The
    /// container tag is not reachable through AVFoundation, and translating a
    /// guess into it would be worse than reporting the truth. Compare
    /// `codec_name`, which does match.
    ///
    /// Rotation is another known gap: ffprobe reports `width`/`height` as the
    /// **coded** dimensions and puts rotation in `side_data`, which is not
    /// emitted here. This follows ffprobe for the coded dimensions, so a
    /// portrait phone video reports landscape `width`/`height` — exactly as
    /// ffprobe does. ``MediaInfo/pixelSize`` gives the display size instead.
    public func ffprobeReport() -> FFProbeReport {
        FFProbeReport(
            streams: tracks.map { track in
                FFProbeStream(
                    index: track.index,
                    codecName: track.codecName,
                    codecType: track.kind.ffprobeCodecType,
                    codecTagString: track.codecFourCC,
                    width: track.codedSize?.width,
                    height: track.codedSize?.height,
                    codedWidth: track.codedSize?.width,
                    codedHeight: track.codedSize?.height,
                    rFrameRate: track.nominalFrameRate.map(Self.rationalFrameRate),
                    averageFrameRate: track.nominalFrameRate.map(Self.rationalFrameRate),
                    sampleRate: track.sampleRate.map { String(Int($0.rounded())) },
                    channels: track.channelCount,
                    duration: Self.ffprobeSeconds(track.duration),
                    bitRate: track.estimatedBitRate.map { String(Int($0.rounded())) }
                )
            },
            format: FFProbeFormat(
                filename: fileName,
                numberOfStreams: tracks.count,
                formatName: containerName,
                startTime: Self.ffprobeSeconds(0),
                duration: Self.ffprobeSeconds(duration),
                size: byteCount.map(String.init),
                bitRate: estimatedBitRate.map { String(Int($0.rounded())) }
            )
        )
    }

    /// ``ffprobeReport()`` encoded as UTF-8 JSON.
    ///
    /// - Parameter prettyPrinted: two-space indented output, as
    ///   `ffprobe -of json` produces by default. `false` gives the compact form.
    public func ffprobeJSON(prettyPrinted: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        // Slashes are not escaped, because ffprobe does not escape them and a
        // filename containing one would otherwise come out as `a\/b`. Keys are
        // *not* sorted: the declaration order in `FFProbeReport` is ffprobe's
        // order, and sorting would discard it for no gain.
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .withoutEscapingSlashes]
            : [.withoutEscapingSlashes]
        do {
            return try encoder.encode(ffprobeReport())
        } catch {
            throw LatheError.wrapping(error)
        }
    }

    /// ``ffprobeJSON(prettyPrinted:)`` as a `String`.
    public func ffprobeJSONString(prettyPrinted: Bool = true) throws -> String {
        let data = try ffprobeJSON(prettyPrinted: prettyPrinted)
        guard let text = String(data: data, encoding: .utf8) else {
            throw LatheError.underlying("ffprobe JSON was not valid UTF-8")
        }
        return text
    }

    // MARK: - Formatting

    /// Six decimal places and a locale-independent decimal point — ffprobe's
    /// format. `String(format:)` with an explicit POSIX locale, because the
    /// default locale would produce `3,000000` in half of Europe and break every
    /// parser downstream.
    static func ffprobeSeconds(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "N/A" }
        return String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), seconds)
    }

    /// ffprobe prints frame rates as exact rationals (`30/1`, `30000/1001`).
    ///
    /// AVFoundation gives a `Float`, so the rational has to be reconstructed.
    /// Integer rates are exact; anything else is matched against the /1001
    /// family that every broadcast rate belongs to, and otherwise rendered over
    /// a denominator of 1000. The result is an accurate *value* in all cases and
    /// the conventional *spelling* in the cases that have one.
    static func rationalFrameRate(_ rate: Double) -> String {
        guard rate.isFinite, rate > 0 else { return "0/0" }
        if abs(rate - rate.rounded()) < 0.0005 {
            return "\(Int(rate.rounded()))/1"
        }
        let broadcast = (rate * 1001 / 1000).rounded() * 1000
        if abs(rate - broadcast / 1001) < 0.0005 {
            return "\(Int(broadcast))/1001"
        }
        return "\(Int((rate * 1000).rounded()))/1000"
    }
}
