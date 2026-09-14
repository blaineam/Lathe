import AVFoundation
import CoreMedia
import Foundation
import LatheCore

/// What kind of thing a track carries, in Lathe's normalised vocabulary.
///
/// `AVMediaType` is a string type that can grow new members, so it is mapped
/// into a closed enum here for the same reason ``LatheError`` is closed: callers
/// switch on it to make decisions, and that is only safe if the set is
/// enumerable. The original string survives on
/// ``MediaTrackInfo/mediaTypeIdentifier`` for anything this mapping loses.
public enum MediaTrackKind: String, Sendable, Hashable, CaseIterable {
    case video
    case audio
    case text
    case closedCaption
    case subtitle
    case timecode
    case metadata
    case muxed
    case other

    init(_ mediaType: AVMediaType) {
        switch mediaType {
        case .video: self = .video
        case .audio: self = .audio
        case .text: self = .text
        case .closedCaption: self = .closedCaption
        case .subtitle: self = .subtitle
        case .timecode: self = .timecode
        case .metadata: self = .metadata
        case .muxed: self = .muxed
        default: self = .other
        }
    }

    /// The value ffprobe would print for `codec_type`.
    ///
    /// ffprobe's vocabulary is smaller than AVFoundation's — it knows `video`,
    /// `audio`, `subtitle`, `data` and `attachment` — so several kinds collapse
    /// onto `data`. See ``MediaInfo/ffprobeReport()``.
    public var ffprobeCodecType: String {
        switch self {
        case .video: "video"
        case .audio: "audio"
        case .subtitle, .closedCaption, .text: "subtitle"
        case .timecode, .metadata, .muxed, .other: "data"
        }
    }
}

/// One track's facts, as reported by the container.
///
/// Everything here comes from the container's own headers — no decoding
/// happens — so probing a four-hour movie costs the same as probing a
/// four-second one.
public struct MediaTrackInfo: Sendable, Equatable {

    /// Position in the container's track list, 0-based. Matches ffprobe's
    /// `index` for the common case of one AVFoundation track per stream.
    public var index: Int

    public var kind: MediaTrackKind

    /// The `AVMediaType` raw value, verbatim, for anything ``kind`` collapsed.
    public var mediaTypeIdentifier: String

    /// The format description's media subtype as a four-character code —
    /// `"avc1"`, `"hvc1"`, `"aac "`, `"lpcm"`.
    ///
    /// Unmapped: it is exactly what `CMFormatDescriptionGetMediaSubType`
    /// returned. ``codecName`` is derived from it and is the convenience.
    ///
    /// **The two media types do not mean the same thing by it**, which is a
    /// genuine AVFoundation quirk rather than a Lathe one. For a video track the
    /// subtype is the container's own sample-description tag, so H.264 in a
    /// QuickTime file reports `"avc1"`. For an audio track it is the *CoreAudio*
    /// format ID, so the same file's AAC track reports `"aac "` — with the
    /// trailing space that four-character codes pad with — and never the
    /// container tag `"mp4a"` a container inspector would print. Compare
    /// ``codecName`` if you want one vocabulary across both.
    public var codecFourCC: String

    /// The codec's common name — `"h264"`, `"hevc"`, `"aac"`.
    ///
    /// Spelled the way ffprobe spells it, because the whole point of carrying a
    /// second name is that callers migrating off a command-line prober already
    /// compare against these strings. Unknown four-character codes pass through
    /// lowercased rather than becoming `"unknown"`, so a new codec degrades to
    /// something searchable instead of to nothing.
    public var codecName: String

    /// The coded (stored) pixel dimensions, before any rotation is applied.
    /// `nil` for non-visual tracks.
    public var codedSize: PixelSize?

    /// The dimensions a player would present, i.e. ``codedSize`` with the
    /// track's preferred transform applied.
    ///
    /// These differ for every portrait video shot on a phone: the frames are
    /// stored landscape with a 90° rotation in the track matrix. A caller that
    /// lays out a thumbnail wants this one; a caller that allocates an encoder
    /// wants ``codedSize``. Reporting only one of them is how "why is my
    /// portrait video sideways" bugs start.
    public var displaySize: PixelSize?

    /// Frames per second as declared by the container, not measured. `nil` for
    /// non-visual tracks, and `0` is possible for a track whose header lies.
    public var nominalFrameRate: Double?

    /// Bits per second, estimated by AVFoundation from the track's size and
    /// duration. `nil` when the container does not give enough to estimate.
    public var estimatedBitRate: Double?

    /// The track's own duration, which can be shorter than the container's.
    public var duration: TimeInterval

    /// Audio only.
    public var sampleRate: Double?

    /// Audio only.
    public var channelCount: Int?

    public init(
        index: Int,
        kind: MediaTrackKind,
        mediaTypeIdentifier: String,
        codecFourCC: String,
        codecName: String,
        codedSize: PixelSize? = nil,
        displaySize: PixelSize? = nil,
        nominalFrameRate: Double? = nil,
        estimatedBitRate: Double? = nil,
        duration: TimeInterval,
        sampleRate: Double? = nil,
        channelCount: Int? = nil
    ) {
        self.index = index
        self.kind = kind
        self.mediaTypeIdentifier = mediaTypeIdentifier
        self.codecFourCC = codecFourCC
        self.codecName = codecName
        self.codedSize = codedSize
        self.displaySize = displaySize
        self.nominalFrameRate = nominalFrameRate
        self.estimatedBitRate = estimatedBitRate
        self.duration = duration
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

/// Everything ``MediaProbe`` learned about a file.
///
/// Structured rather than stringly-typed: this is the type a caller switches on
/// to decide what to do next, and ``ffprobeJSON(prettyPrinted:)`` exists only for
/// callers who still have to feed a string to something downstream.
public struct MediaInfo: Sendable, Equatable {

    /// The file's name — **the last path component only**.
    ///
    /// Not the full path, on purpose. `MediaInfo` ends up in logs, in crash
    /// reports and in the ffprobe shim's output, and a full path to personal
    /// media is exactly the kind of thing that should not travel. The caller
    /// already has the `URL` it passed in.
    public var fileName: String

    /// Container duration in seconds.
    ///
    /// `0` for a genuinely empty asset and — importantly — also `0` for a live
    /// or indefinite asset, whose duration is not a number at all. Checking
    /// ``hasDeterminateDuration`` distinguishes them.
    public var duration: TimeInterval

    /// `false` when the asset reported an indefinite duration, which a
    /// `TimeInterval` cannot represent.
    public var hasDeterminateDuration: Bool

    /// File size in bytes, or `nil` if it could not be read.
    public var byteCount: UInt64?

    /// Tracks in container order.
    public var tracks: [MediaTrackInfo]

    /// A best-effort ffmpeg-style container name, derived from the file
    /// extension. See ``ffprobeReport()``.
    public var containerName: String

    public init(
        fileName: String,
        duration: TimeInterval,
        hasDeterminateDuration: Bool = true,
        byteCount: UInt64? = nil,
        tracks: [MediaTrackInfo],
        containerName: String
    ) {
        self.fileName = fileName
        self.duration = duration
        self.hasDeterminateDuration = hasDeterminateDuration
        self.byteCount = byteCount
        self.tracks = tracks
        self.containerName = containerName
    }

    // MARK: - Derived

    public var videoTracks: [MediaTrackInfo] { tracks.filter { $0.kind == .video } }
    public var audioTracks: [MediaTrackInfo] { tracks.filter { $0.kind == .audio } }

    /// Whether the file has an audio track **at all**.
    ///
    /// Says nothing about whether that track makes a sound — a track of digital
    /// silence is still a track. `LatheAudio`'s `LoudnessProbe` answers the
    /// other question, and keeps the two apart for the same reason.
    public var hasAudioTrack: Bool { !audioTracks.isEmpty }

    public var hasVideoTrack: Bool { !videoTracks.isEmpty }

    /// The first video track, which is the one a player would show.
    public var primaryVideoTrack: MediaTrackInfo? { videoTracks.first }

    /// The presentation size of the primary video track.
    public var pixelSize: PixelSize? {
        primaryVideoTrack.flatMap { $0.displaySize ?? $0.codedSize }
    }

    /// Overall bit rate in bits per second: the sum of the tracks' estimates, or
    /// — when no track offered one — the file size divided by the duration.
    public var estimatedBitRate: Double? {
        let perTrack = tracks.compactMap(\.estimatedBitRate).filter { $0 > 0 }
        if !perTrack.isEmpty { return perTrack.reduce(0, +) }
        guard let byteCount, duration > 0 else { return nil }
        return Double(byteCount) * 8 / duration
    }

    /// `true` for a file AVFoundation opened but that has nothing playable in
    /// it: no tracks, or no duration and no visual track.
    ///
    /// Still images land here. `AVURLAsset` does not refuse every image file —
    /// it can open some of them and then report an asset with no tracks and a
    /// zero duration — so "opened successfully" is not the same as "is a media
    /// file", and a caller that treats it that way will try to transcode a JPEG.
    public var isEmptyAsset: Bool {
        tracks.isEmpty || (!hasVideoTrack && !hasAudioTrack)
    }
}

// MARK: - Four-character codes

extension MediaTrackInfo {

    /// Renders a `FourCharCode` the way container tools print it.
    ///
    /// Non-printable bytes are hex-escaped rather than dropped: some codes are
    /// not ASCII at all, and silently producing a shorter string would make two
    /// different codecs compare equal.
    static func fourCharacterCode(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return bytes.map { byte in
            (0x20...0x7E).contains(byte)
                ? String(UnicodeScalar(byte))
                : String(format: "\\x%02x", byte)
        }.joined()
    }

    /// Maps a four-character code onto the name ffmpeg's tools print.
    ///
    /// Both spellings of the codes that have two are listed, because audio and
    /// video tracks are named from different registries — see
    /// ``MediaTrackInfo/codecFourCC``. Trailing padding spaces are trimmed
    /// first, so `"aac "` and `"aac"` are the same key.
    ///
    /// Anything unrecognised falls through to the trimmed, lowercased code,
    /// which stays greppable: a new codec should look unfamiliar rather than
    /// look like an error.
    static func commonCodecName(forFourCharacterCode code: String) -> String {
        switch code.lowercased().trimmingCharacters(in: .whitespaces) {
        case "avc1", "avc3", "h264": "h264"
        case "hvc1", "hev1", "hvc2": "hevc"
        case "av01": "av1"
        case "vp09", "vp08": "vp9"
        case "mp4v", "mp4s": "mpeg4"
        case "jpeg", "mjpa", "mjpb", "dmb1": "mjpeg"
        case "ap4h", "apch", "apcn", "apcs", "apco", "ap4x": "prores"
        // `mp4a` is the container tag, `aac` the CoreAudio format ID.
        case "mp4a", "aac", "aach", "aacp", "paac": "aac"
        case ".mp3", "mp3": "mp3"
        case "lpcm", "sowt", "twos", "in24", "in32", "fl32", "fl64": "pcm"
        case "alac": "alac"
        case "ac-3", "ac3": "ac3"
        case "ec-3": "eac3"
        case "opus": "opus"
        case "qtrl", "tmcd": "timecode"
        case "text", "tx3g": "mov_text"
        case "c608": "eia_608"
        default: code.lowercased().trimmingCharacters(in: .whitespaces)
        }
    }
}
