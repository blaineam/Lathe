import Foundation

/// A pixel size. Deliberately integral and framework-free so it can cross a
/// language boundary unchanged and be shared by stills, video and document page
/// images.
public struct PixelSize: Sendable, Hashable, CustomStringConvertible {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var description: String { "\(width)x\(height)" }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public var longestSide: Int { max(width, height) }
    public var pixelCount: Int { width * height }
}

/// How to scale.
///
/// **Never upsamples.** ImageIO's `kCGImageSourceThumbnailMaxPixelSize` *will*
/// enlarge a smaller source if you let it; that trap is closed here by
/// construction — ``resolve(from:)`` returns the source size unchanged whenever
/// the target would be larger.
///
/// The size arithmetic below is real. The resampling that consumes it is not yet
/// implemented: stills will use vImage / Core Image Lanczos, video will use
/// `AVAssetWriter` output settings.
public enum ResizeTarget: Sendable, Equatable {
    /// Leave the pixel dimensions alone.
    case none

    /// Fit inside this box, preserving aspect ratio. The arbitrary-resolution
    /// aspect-fit downscale.
    case fit(PixelSize)

    /// Fit inside a square of this side length.
    case longestSide(Int)

    /// Scale by a factor. Values > 1 are clamped to 1 (never upsample).
    case scale(Double)

    /// Cap total pixel count — useful as a memory admission-control gate.
    ///
    /// A hard ceiling, honoured exactly, with one stated exception: neither
    /// dimension is ever reduced below 1 pixel. An extreme aspect ratio (say
    /// 8000x17) against a very small cap therefore lands slightly over it rather
    /// than collapsing to nothing. Preserving a usable image beats honouring a
    /// cap that no real memory budget would ever set.
    case maxPixels(Int)

    /// Compute the output size for a given source size.
    ///
    /// - Returns: the size to encode at. Always `<=` `source` in both
    ///   dimensions; returns `source` unchanged when the target would enlarge.
    public func resolve(from source: PixelSize) -> PixelSize {
        guard !source.isEmpty else { return source }

        switch self {
        case .none:
            return source

        case let .fit(box):
            guard !box.isEmpty else { return source }
            let ratio = min(Double(box.width) / Double(source.width),
                            Double(box.height) / Double(source.height))
            return Self.applyRatio(min(ratio, 1), to: source)

        case let .longestSide(side):
            guard side > 0 else { return source }
            let ratio = Double(side) / Double(source.longestSide)
            return Self.applyRatio(min(ratio, 1), to: source)

        case let .scale(factor):
            guard factor > 0 else { return source }
            return Self.applyRatio(min(factor, 1), to: source)

        case let .maxPixels(cap):
            guard cap > 0, source.pixelCount > cap else { return source }
            let ratio = (Double(cap) / Double(source.pixelCount)).squareRoot()
            // Round *down* here: `maxPixels` is a hard ceiling, usually derived
            // from a memory budget, and rounding to nearest can land just over
            // it. The other cases round to nearest because a pixel either way is
            // invisible and the aspect ratio matters more.
            return Self.applyRatio(min(ratio, 1), to: source, rounding: .down)
        }
    }

    private static func applyRatio(
        _ ratio: Double,
        to source: PixelSize,
        rounding rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero
    ) -> PixelSize {
        guard ratio < 1 else { return source }
        return PixelSize(
            width: max(1, Int((Double(source.width) * ratio).rounded(rule))),
            height: max(1, Int((Double(source.height) * ratio).rounded(rule)))
        )
    }
}
