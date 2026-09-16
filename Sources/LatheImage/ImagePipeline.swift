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
