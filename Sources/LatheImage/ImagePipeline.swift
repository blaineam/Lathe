import Foundation
import LatheCore

/// How EXIF orientation is handled on re-encode.
///
/// `CGImageSourceCreateImageAtIndex` returns pixels in **stored** orientation;
/// the rotation lives in the tag. There are exactly two correct strategies,
/// **never both** (double-rotates) and never neither (rotates).
public enum OrientationStrategy: Sendable, Equatable {
    /// Rotate the pixels, then write `orientation = 1`. Simplifies everything
    /// downstream — OCR, thumbnails, video frames — at the cost of forfeiting
    /// lossless JPEG rotate, of a mandatory redraw, and of the 8-bit RGB
    /// conversion that redraw implies for a CMYK or 16-bit source.
    ///
    /// ``ImageEncoder`` falls back to this regardless of what was asked for when
    /// the destination format has nowhere to store a tag, because losing the
    /// rotation is worse than performing it.
    case bake
    /// Leave pixels untouched and copy the tag verbatim. The default: it is the
    /// non-destructive one, and it composes with a resize, which
    /// ``bake`` does at the price of a conversion the caller did not ask for.
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
        orientation: OrientationStrategy = .preserveTag
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

/// Aspect-fit downscaling to an arbitrary resolution.
///
/// **Resizing itself is no longer missing** — ``ImageEncoder`` takes a
/// ``ResizeTarget`` and honours it, and this protocol's signature is that call
/// with fewer options. It is kept only as the seam for a *standalone* resampler
/// (vImage / Core Image Lanczos) that does not also re-encode, which is a
/// different operation from the one the encoder performs. If that never
/// materialises, this should go the way the scaffold's other duplicate
/// vocabularies did rather than sit here looking like a missing feature.
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
/// for the lossy path by accident, and the separation is enforced rather than
/// merely documented: ``ImageEncoder`` refuses ``QualityTarget/lossless``
/// outright and names this protocol in the refusal, instead of quietly
/// reinterpreting "do not re-encode" as "re-encode at maximum quality".
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

/// The stand-in for the parts of the still-image engine that are still unbuilt.
/// Every call throws ``LatheError/notImplemented(feature:)``.
///
/// Encoding is no longer among them — that is ``ImageEncoder``, which is real —
/// so this conforms to the three protocols that remain: resampling as a
/// standalone operation, the lossless metadata rewrite, and animation.
///
/// It exists so that callers can be written and reviewed against the real API
/// surface now, and so a missing implementation is a named refusal rather than a
/// crash or a silent no-op.
public struct UnimplementedImagePipeline: ImageResizer, ImageMetadataRewriter, AnimationRecompressor {

    public init() {}

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
