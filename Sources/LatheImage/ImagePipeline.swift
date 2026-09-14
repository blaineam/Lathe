import Foundation
import LatheCore

/// How EXIF orientation is handled on re-encode.
///
/// `CGImageSourceCreateImageAtIndex` returns pixels in **stored** orientation;
/// the rotation lives in the tag. There are exactly two correct strategies,
/// **never both** (double-rotates) and never neither (rotates).
public enum OrientationStrategy: Sendable, Equatable {
    /// Rotate the pixels, then write `orientation = 1`. Recommended: it
    /// simplifies everything downstream — OCR, thumbnails, video frames — at the
    /// cost of forfeiting lossless JPEG rotate.
    case bake
    /// Leave pixels untouched and copy the tag verbatim.
    case preserveTag
}

/// One still-image encode.
public struct ImageEncodeRequest: Sendable {
    public var source: URL
    public var destination: URL
    /// Desired output format. If the running system cannot encode it,
    /// ``ImageEncoder`` throws ``LatheError/encodeUnavailable(format:)`` rather
    /// than silently substituting — the caller picks the fallback, using
    /// ``EncodeSupport/firstSupported(of:)``.
    public var format: ImageFormat
    public var quality: QualityTarget
    public var resize: ResizeTarget
    public var metadata: MetadataPolicy
    public var forcePreserve: MetadataForcePreserve
    public var orientation: OrientationStrategy

    public init(
        source: URL,
        destination: URL,
        format: ImageFormat,
        quality: QualityTarget = .quality(0.7),
        resize: ResizeTarget = .none,
        metadata: MetadataPolicy = .preserveAll,
        forcePreserve: MetadataForcePreserve = .default,
        orientation: OrientationStrategy = .bake
    ) {
        self.source = source
        self.destination = destination
        self.format = format
        self.quality = quality
        self.resize = resize
        self.metadata = metadata
        self.forcePreserve = forcePreserve
        self.orientation = orientation
    }
}

public struct ImageEncodeResult: Sendable, Equatable {
    public var output: URL
    public var format: ImageFormat
    public var pixelSize: PixelSize
    public var inputByteCount: UInt64
    public var outputByteCount: UInt64
    public var wallTime: TimeInterval
    /// `true` when the pixel data was copied through untouched
    /// (`CGImageDestinationCopyImageSource`) and only metadata changed.
    public var wasLosslessRewrite: Bool

    public init(
        output: URL,
        format: ImageFormat,
        pixelSize: PixelSize,
        inputByteCount: UInt64,
        outputByteCount: UInt64,
        wallTime: TimeInterval,
        wasLosslessRewrite: Bool
    ) {
        self.output = output
        self.format = format
        self.pixelSize = pixelSize
        self.inputByteCount = inputByteCount
        self.outputByteCount = outputByteCount
        self.wallTime = wallTime
        self.wasLosslessRewrite = wasLosslessRewrite
    }
}

/// The still-image engine.
///
/// Not yet implemented. The intended backing is ImageIO for
/// AVIF/HEIC/JPEG/PNG/GIF, plus libwebp (BSD-3) for the one format ImageIO can
/// decode but not encode, plus a giflib (MIT) quantizer in front of the ImageIO
/// GIF writer.
public protocol ImageEncoder: Sendable {
    /// - Throws: ``LatheError/encodeUnavailable(format:)`` if
    ///   ``EncodeSupport`` says the format cannot be written here;
    ///   ``LatheError/cancelled(atUnit:)`` if the progress handle trips.
    func encode(_ request: ImageEncodeRequest, progress: ProgressHandle) throws -> ImageEncodeResult
}

/// Aspect-fit downscaling to an arbitrary resolution.
///
/// Not yet implemented; vImage / Core Image Lanczos is the intended backing. The
/// size arithmetic is already real in ``ResizeTarget/resolve(from:)``, which
/// never upsamples — what is missing is the resampling itself.
public protocol ImageResizer: Sendable {
    func resize(
        source: URL,
        destination: URL,
        target: ResizeTarget,
        format: ImageFormat,
        quality: QualityTarget,
        progress: ProgressHandle
    ) throws -> ImageEncodeResult
}

/// Metadata strip/preserve **without touching a pixel**.
///
/// Not yet implemented. `CGImageDestinationCopyImageSource` copies the encoded
/// image data unchanged and rewrites only the metadata. Most tools get this
/// wrong by decoding and re-encoding — losing quality in order to remove a GPS
/// tag. This is a separate protocol from ``ImageEncoder`` so it is hard to reach
/// for the lossy path by accident.
public protocol ImageMetadataRewriter: Sendable {
    func rewriteMetadata(
        source: URL,
        destination: URL,
        policy: MetadataPolicy,
        forcePreserve: MetadataForcePreserve
    ) throws -> ImageEncodeResult
}

/// Animated formats — GIF, animated WebP, APNG, animated HEIF.
///
/// Not yet implemented. ImageIO's GIF writer already does competitive
/// *inter-frame* optimization but has no palette control, so the work here is
/// adding a quantizer rather than replacing the writer. Note that the obvious
/// off-the-shelf GIF optimizer is GPL-2.0-only with no library API, so it can
/// never be linked from here — see the licence rule in the README.
public protocol AnimationRecompressor: Sendable {
    func recompress(
        source: URL,
        destination: URL,
        format: ImageFormat,
        paletteSize: Int,
        quality: QualityTarget,
        progress: ProgressHandle
    ) throws -> ImageEncodeResult
}

// MARK: - Scaffold implementations

/// The stand-in until the still-image engine lands. Every call throws
/// ``LatheError/notImplemented(feature:)``.
///
/// It exists so that callers can be written and reviewed against the real API
/// surface now, and so a missing implementation is a named refusal rather than a
/// crash or a silent no-op.
public struct UnimplementedImagePipeline: ImageEncoder, ImageResizer, ImageMetadataRewriter, AnimationRecompressor {

    public init() {}

    public func encode(_ request: ImageEncodeRequest, progress: ProgressHandle) throws -> ImageEncodeResult {
        // The capability check is real even though the encode is not: a caller
        // asking for WebP gets "this system cannot encode WebP" today, which is
        // the same answer it will get later on a build without a WebP encoder
        // linked.
        try EncodeSupport.shared.requireEncodable(request.format)
        throw LatheError.todo("ImageEncoder.encode(_:progress:) for \(request.format)")
    }

    public func resize(
        source: URL,
        destination: URL,
        target: ResizeTarget,
        format: ImageFormat,
        quality: QualityTarget,
        progress: ProgressHandle
    ) throws -> ImageEncodeResult {
        throw LatheError.todo("ImageResizer.resize(...)")
    }

    public func rewriteMetadata(
        source: URL,
        destination: URL,
        policy: MetadataPolicy,
        forcePreserve: MetadataForcePreserve
    ) throws -> ImageEncodeResult {
        throw LatheError.todo("ImageMetadataRewriter.rewriteMetadata(...)")
    }

    public func recompress(
        source: URL,
        destination: URL,
        format: ImageFormat,
        paletteSize: Int,
        quality: QualityTarget,
        progress: ProgressHandle
    ) throws -> ImageEncodeResult {
        throw LatheError.todo("AnimationRecompressor.recompress(...)")
    }
}
