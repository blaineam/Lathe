import Foundation
import LatheCore

// The transcode *vocabulary*: what a caller asks for, and what it is told
// happened. The engine that honours it is ``VideoTranscoder``.

/// Video codecs Lathe can target.
///
/// Note what is absent: **there is no hardware AV1 encoder on current Apple
/// silicon.** Enumerating the available VideoToolbox encoders returns no `av01`
/// entry, and asking for one fails at session creation. Hardware AV1 *decode*
/// does exist on recent chips. AV1 encode on-device would therefore be CPU-only,
/// so there is no `.av1` case here until something can honour it.
public enum VideoCodec: String, Sendable, Hashable, CaseIterable {
    case h264
    case hevc
    /// HEVC with an alpha channel — Apple-only, but the only practical way to
    /// keep transparency in a hardware-encoded video.
    ///
    /// Only useful for a source that *has* an alpha channel. A source without
    /// one encodes to an opaque alpha layer, which costs bytes and buys nothing;
    /// the codec is not chosen for you either way, because guessing wrong is
    /// worse than being asked.
    case hevcWithAlpha
}

/// Whether B-frames are used.
///
/// The default is ``allow``, and so is VideoToolbox's own — the header says
/// `kVTCompressionPropertyKey_AllowFrameReordering` is "True by default". It is
/// set explicitly here anyway, in both directions, because the well-known
/// failure is a transcoder that turns it *off* and never says so: B-frames are a
/// double-digit percentage of the bitrate at equal quality on these encoders,
/// and losing them silently looks like "VideoToolbox is just worse".
///
/// What was actually negotiated is read back off the session and reported as
/// ``VideoTranscodeResult/frameReordering``, so the claim is checkable rather
/// than merely asserted.
public enum BFramePolicy: Sendable, Equatable {
    case allow
    case disallow

    var allowsFrameReordering: Bool { self == .allow }
}

/// How the encoder's rate control was actually configured.
///
/// Reported rather than assumed, because ``QualityTarget`` states an *intent*
/// and not every intent survives contact with every encoder. A caller that asked
/// for ``QualityTarget/constantQualityFactor(_:)`` and reads back
/// ``constantQuality(_:)`` has been told, in the result, that it got the
/// documented fallback.
public enum RateControl: Sendable, Equatable {
    /// `kVTCompressionPropertyKey_Quality`: a fixed quantiser, `0...1`, higher is
    /// better. Available since macOS 10.8 / iOS 8, so it is reachable at this
    /// package's deployment floor — constant-quality video encoding does not
    /// need a recent OS.
    case constantQuality(Double)

    /// `kVTCompressionPropertyKey_ConstantQualityFactor`, `0...1`, higher is
    /// better. Newer, and **probed rather than version-gated**; see
    /// ``VideoTranscoder``.
    case constantQualityFactor(Double)

    /// `kVTCompressionPropertyKey_AverageBitRate`, bits per second.
    case averageBitrate(Int)
}

/// What happened to the audio.
public enum AudioDisposition: Sendable, Equatable {
    /// The source had no audio track.
    case none
    /// The encoded audio was copied across sample-for-sample. No decode, no
    /// re-encode, no generation loss.
    case passedThrough
    /// The audio was decoded and re-encoded to AAC, because the destination
    /// container would not take the source's format as it stood.
    case reencodedAAC
}

/// One video transcode.
public struct VideoTranscodeRequest: Sendable {
    public var source: URL
    /// Where to write. The extension picks the container — `.mov`, `.mp4`,
    /// `.m4v` — and the file is left untouched if anything fails.
    public var destination: URL
    public var codec: VideoCodec
    /// `.quality(_)` maps to `kVTCompressionPropertyKey_Quality`, which is old
    /// enough to be reachable at this package's deployment floor.
    /// `.constantQualityFactor(_)` maps to
    /// `kVTCompressionPropertyKey_ConstantQualityFactor`, which is newer and is
    /// **probed, not version-gated** — same rule as the still-image path.
    /// `.lossless` is refused rather than reinterpreted.
    public var quality: QualityTarget
    /// Aspect-fit downscale to an arbitrary resolution. Never upsamples.
    public var resize: ResizeTarget
    public var metadata: MetadataPolicy
    public var forcePreserve: MetadataForcePreserve
    public var bFrames: BFramePolicy
    /// Copy the audio track through untouched where the destination container
    /// accepts it, instead of decoding and re-encoding it.
    ///
    /// `true` by default, and the default matters: re-encoding AAC to AAC is a
    /// second generation of loss that buys nothing when the file was only ever
    /// asked for a smaller *video* track.
    public var passthroughAudio: Bool

    public init(
        source: URL,
        destination: URL,
        codec: VideoCodec = .hevc,
        quality: QualityTarget = .quality(0.65),
        resize: ResizeTarget = .none,
        metadata: MetadataPolicy = .preserveAll,
        forcePreserve: MetadataForcePreserve = .default,
        bFrames: BFramePolicy = .allow,
        passthroughAudio: Bool = true
    ) {
        self.source = source
        self.destination = destination
        self.codec = codec
        self.quality = quality
        self.resize = resize
        self.metadata = metadata
        self.forcePreserve = forcePreserve
        self.bFrames = bFrames
        self.passthroughAudio = passthroughAudio
    }
}

/// What the transcode did — measured, not assumed.
public struct VideoTranscodeResult: Sendable, Equatable {
    public var output: URL
    public var codec: VideoCodec

    /// The **coded** size actually encoded, which is the size before the track's
    /// rotation is applied. A portrait phone video transcoded without a resize
    /// reports its landscape stored size here, exactly as the source does.
    public var pixelSize: PixelSize

    /// Output duration in seconds, as the written container reports it.
    public var duration: TimeInterval

    /// Frames read from the source and handed to the encoder.
    public var frameCount: UInt64

    public var inputByteCount: UInt64
    public var outputByteCount: UInt64
    public var wallTime: TimeInterval

    /// Whether VideoToolbox actually used a hardware encoder.
    ///
    /// **Read back from the session**
    /// (`kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder`), not
    /// inferred from the chip, the codec or the OS. Asking for hardware is a
    /// hint; this is the answer.
    public var usedHardwareAcceleration: Bool

    /// Whether the session ended up allowing frame reordering, i.e. B-frames.
    /// Also read back rather than assumed.
    public var frameReordering: Bool

    /// How rate control was actually configured. See ``RateControl``.
    public var rateControl: RateControl

    /// What happened to the audio track. See ``AudioDisposition``.
    public var audio: AudioDisposition

    public init(
        output: URL,
        codec: VideoCodec,
        pixelSize: PixelSize,
        duration: TimeInterval,
        frameCount: UInt64,
        inputByteCount: UInt64,
        outputByteCount: UInt64,
        wallTime: TimeInterval,
        usedHardwareAcceleration: Bool,
        frameReordering: Bool,
        rateControl: RateControl,
        audio: AudioDisposition
    ) {
        self.output = output
        self.codec = codec
        self.pixelSize = pixelSize
        self.duration = duration
        self.frameCount = frameCount
        self.inputByteCount = inputByteCount
        self.outputByteCount = outputByteCount
        self.wallTime = wallTime
        self.usedHardwareAcceleration = usedHardwareAcceleration
        self.frameReordering = frameReordering
        self.rateControl = rateControl
        self.audio = audio
    }
}
