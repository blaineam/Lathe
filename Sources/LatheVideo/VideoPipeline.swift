import CoreMedia
import Foundation
import LatheCore

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
    case hevcWithAlpha
}

/// Whether B-frames are used.
///
/// Some encoders disable B-frames on VideoToolbox by default. Lathe does not:
/// allowing them is a free compression win on the Apple encoders.
public enum BFramePolicy: Sendable, Equatable {
    case allow
    case disallow
}

public struct VideoTranscodeRequest: Sendable {
    public var source: URL
    public var destination: URL
    public var codec: VideoCodec
    /// `.quality(_)` maps to `kVTCompressionPropertyKey_Quality`, which is old
    /// enough to be reachable at this package's deployment floor.
    /// `.constantQualityFactor(_)` maps to
    /// `kVTCompressionPropertyKey_ConstantQualityFactor`, which is newer and is
    /// **probed, not version-gated** — same rule as the still-image path.
    public var quality: QualityTarget
    /// Aspect-fit downscale to an arbitrary resolution. Never upsamples.
    public var resize: ResizeTarget
    public var metadata: MetadataPolicy
    public var forcePreserve: MetadataForcePreserve
    public var bFrames: BFramePolicy
    /// Re-encode audio, or pass the original track through untouched.
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

public struct VideoTranscodeResult: Sendable, Equatable {
    public var output: URL
    public var codec: VideoCodec
    public var pixelSize: PixelSize
    public var duration: TimeInterval
    public var inputByteCount: UInt64
    public var outputByteCount: UInt64
    public var wallTime: TimeInterval

    public init(
        output: URL,
        codec: VideoCodec,
        pixelSize: PixelSize,
        duration: TimeInterval,
        inputByteCount: UInt64,
        outputByteCount: UInt64,
        wallTime: TimeInterval
    ) {
        self.output = output
        self.codec = codec
        self.pixelSize = pixelSize
        self.duration = duration
        self.inputByteCount = inputByteCount
        self.outputByteCount = outputByteCount
        self.wallTime = wallTime
    }
}

/// The container and track facts a caller needs before deciding what to do.
public struct VideoProbe: Sendable, Equatable {
    public var duration: TimeInterval
    public var pixelSize: PixelSize
    /// The track's codec four-character code, e.g. `"hvc1"`, `"avc1"`, `"av01"`.
    public var codecFourCC: String
    public var nominalFrameRate: Float
    /// `nil` when counting frames would require a full decode pass and the
    /// caller did not ask for it.
    public var frameCount: Int?
    public var hasAudioTrack: Bool

    public init(
        duration: TimeInterval,
        pixelSize: PixelSize,
        codecFourCC: String,
        nominalFrameRate: Float,
        frameCount: Int?,
        hasAudioTrack: Bool
    ) {
        self.duration = duration
        self.pixelSize = pixelSize
        self.codecFourCC = codecFourCC
        self.nominalFrameRate = nominalFrameRate
        self.frameCount = frameCount
        self.hasAudioTrack = hasAudioTrack
    }
}

/// Duration, codec, dimensions and frame count, without shelling out to a
/// command-line prober.
///
/// Not yet implemented; `AVAsset` / `AVAssetTrack` is the intended backing —
/// pure Apple APIs, no third-party code.
public protocol VideoProber: Sendable {
    func probe(_ url: URL) async throws -> VideoProbe
}

/// Frame extraction for thumbnails and for perceptual hashing.
///
/// Not yet implemented; `AVAssetImageGenerator` (plus vImage for the grayscale
/// reduction) is the intended backing.
public protocol VideoThumbnailer: Sendable {
    func thumbnail(_ url: URL, at time: CMTime, maxPixelSize: Int) async throws -> Data

    /// 32x32 grayscale frames for pHash, sampled evenly across the asset.
    func perceptualHashFrames(_ url: URL, count: Int) async throws -> [Data]
}

/// Transcode with a quality target and an aspect-fit downscale.
///
/// Not yet implemented; VideoToolbox + `AVAssetWriter` is the intended backing.
///
/// Two design constraints live here rather than in a comment on the
/// implementation, because they shape the API:
///
/// - **Long jobs need background-execution support** plus thermal and low-power
///   back-off, so the call is `async` and cancellable rather than a blocking
///   convenience.
/// - **True mid-file resume requires GOP-aligned segmented encoding.** When that
///   lands, segment the *video* but encode audio in a **single continuous
///   pass** and mux at the end: concatenating separately-encoded AAC segments
///   produces audible clicks and cumulative A/V drift from the encoder's
///   priming samples.
public protocol VideoTranscoder: Sendable {
    func transcode(
        _ request: VideoTranscodeRequest,
        progress: ProgressHandle
    ) async throws -> VideoTranscodeResult
}

// MARK: - Scaffold implementations

/// Throws ``LatheError/notImplemented(feature:)`` for everything. Present so the
/// API surface is reviewable and injectable before the real engine lands.
public struct UnimplementedVideoPipeline: VideoProber, VideoThumbnailer, VideoTranscoder {

    public init() {}

    public func probe(_ url: URL) async throws -> VideoProbe {
        throw LatheError.todo("VideoProber.probe(_:)")
    }

    public func thumbnail(_ url: URL, at time: CMTime, maxPixelSize: Int) async throws -> Data {
        throw LatheError.todo("VideoThumbnailer.thumbnail(_:at:maxPixelSize:)")
    }

    public func perceptualHashFrames(_ url: URL, count: Int) async throws -> [Data] {
        throw LatheError.todo("VideoThumbnailer.perceptualHashFrames(_:count:)")
    }

    public func transcode(
        _ request: VideoTranscodeRequest,
        progress: ProgressHandle
    ) async throws -> VideoTranscodeResult {
        throw LatheError.todo("VideoTranscoder.transcode(_:progress:) to \(request.codec.rawValue)")
    }
}
