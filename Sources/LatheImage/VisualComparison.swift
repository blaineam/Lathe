import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import LatheCore

/// How close a re-encoded picture has to stay to its original.
///
/// Both numbers are SSIM — the structural similarity index, where 1 means
/// identical. ``minimumSimilarity`` bounds the whole picture; ``minimumRegionSimilarity``
/// bounds its worst 32 × 32 region, because an encode can score well on
/// average while a sky bands or a face smears, and a person looks at the
/// damage, not the average.
public struct VisualThreshold: Sendable, Equatable {
    public var minimumSimilarity: Double
    public var minimumRegionSimilarity: Double

    public init(minimumSimilarity: Double, minimumRegionSimilarity: Double) {
        self.minimumSimilarity = minimumSimilarity
        self.minimumRegionSimilarity = minimumRegionSimilarity
    }

    /// Lossy, and set so the loss is not visible side by side at full size.
    ///
    /// Calibrated so a 4:2:0 JPEG or HEIC of a detailed picture passes at the
    /// qualities a careful person would pick by eye (around 0.7) and fails where
    /// banding and ringing start to show. It is on the strict side on purpose:
    /// this runs unattended over a whole library, where the cost of being wrong
    /// once is a photograph somebody notices.
    public static let visuallyLossless = VisualThreshold(
        minimumSimilarity: 0.99, minimumRegionSimilarity: 0.97)
}

/// How similar a candidate picture is to its reference.
public struct VisualSimilarity: Sendable, Equatable {
    /// SSIM over luma and both chroma channels, weighted 6 : 1 : 1 — the eye
    /// is far more sensitive to brightness than to colour.
    public var overall: Double
    /// The lowest luma SSIM of any 32 × 32 region.
    public var worstRegion: Double
    /// The size both pictures were compared at.
    public var comparedSize: PixelSize

    public init(overall: Double, worstRegion: Double, comparedSize: PixelSize) {
        self.overall = overall
        self.worstRegion = worstRegion
        self.comparedSize = comparedSize
    }

    public func meets(_ threshold: VisualThreshold) -> Bool {
        overall >= threshold.minimumSimilarity && worstRegion >= threshold.minimumRegionSimilarity
    }

    /// The lower of two measurements, field by field — for a verdict over
    /// several frames, which is only as good as the worst of them.
    public func combined(with other: VisualSimilarity) -> VisualSimilarity {
        VisualSimilarity(
            overall: min(overall, other.overall),
            worstRegion: min(worstRegion, other.worstRegion),
            comparedSize: comparedSize)
    }
}

/// Measures how different a re-encoded picture looks from its original.
///
/// Both pictures are drawn at the candidate's displayed size — orientation
/// applied, and never larger than ``maximumPixelCount`` — so a resize the
/// caller asked for is not counted as damage, and a rotation tag is not
/// counted as a different picture. Structural similarity is then computed with
/// the standard 11-tap Gaussian window over luma and chroma.
public enum VisualComparison {

    /// Pictures larger than this are compared downscaled. Twelve megapixels
    /// keeps a phone photo at its own resolution while bounding the cost of a
    /// 48 MP one.
    public static let maximumPixelCount = 12_000_000

    public static func similarity(of candidate: CGImage, to reference: CGImage) throws -> VisualSimilarity {
        let size = comparisonSize(for: PixelSize(width: candidate.width, height: candidate.height))
        return try Planes(reference, size: size).similarity(to: Planes(candidate, size: size))
    }

    public static func similarity(ofImageData candidate: Data, to reference: Data) throws -> VisualSimilarity {
        let candidateImage = try displayedImage(CGImageSourceCreateWithData(candidate as CFData, nil), name: "candidate")
        let size = comparisonSize(for: PixelSize(width: candidateImage.width, height: candidateImage.height))
        let referenceImage = try displayedImage(
            CGImageSourceCreateWithData(reference as CFData, nil), name: "reference",
            longestSide: max(size.width, size.height))
        return try Planes(referenceImage, size: size).similarity(to: Planes(candidateImage, size: size))
    }

    public static func similarity(ofImageAt candidate: URL, to reference: URL) throws -> VisualSimilarity {
        let candidateImage = try displayedImage(
            CGImageSourceCreateWithURL(candidate as CFURL, nil), name: candidate.lastPathComponent)
        let size = comparisonSize(for: PixelSize(width: candidateImage.width, height: candidateImage.height))
        let referenceImage = try displayedImage(
            CGImageSourceCreateWithURL(reference as CFURL, nil), name: reference.lastPathComponent,
            longestSide: max(size.width, size.height))
        return try Planes(referenceImage, size: size).similarity(to: Planes(candidateImage, size: size))
    }

    // MARK: - Preparing a reference once

    /// A reference decoded and converted once, for a search that compares
    /// many candidates against it.
    public final class Reference: @unchecked Sendable {
        private let source: CGImageSource
        private var prepared: [PixelSize: Planes] = [:]
        private let lock = NSLock()

        public init(data: Data) throws {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0
            else { throw LatheError.invalidInput(reason: "the reference is not an image ImageIO can read") }
            self.source = source
        }

        public init(url: URL) throws {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetCount(source) > 0
            else { throw LatheError.readFailed(path: url.lastPathComponent, reason: "not an image ImageIO can read") }
            self.source = source
        }

        public init(image: CGImage) throws {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
            else { throw LatheError.encodingFailed(stage: "compare", code: nil, reason: "no PNG writer") }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination),
                  let source = CGImageSourceCreateWithData(data as CFData, nil)
            else { throw LatheError.encodingFailed(stage: "compare", code: nil, reason: "could not stage the reference") }
            self.source = source
        }

        public func similarity(ofImageData candidate: Data) throws -> VisualSimilarity {
            let image = try VisualComparison.displayedImage(
                CGImageSourceCreateWithData(candidate as CFData, nil), name: "candidate")
            return try similarity(of: image)
        }

        public func similarity(ofImageAt candidate: URL) throws -> VisualSimilarity {
            let image = try VisualComparison.displayedImage(
                CGImageSourceCreateWithURL(candidate as CFURL, nil), name: candidate.lastPathComponent)
            return try similarity(of: image)
        }

        public func similarity(of candidate: CGImage) throws -> VisualSimilarity {
            let size = VisualComparison.comparisonSize(
                for: PixelSize(width: candidate.width, height: candidate.height))
            return try planes(at: size).similarity(to: Planes(candidate, size: size))
        }

        private func planes(at size: PixelSize) throws -> Planes {
            lock.lock()
            defer { lock.unlock() }
            if let cached = prepared[size] { return cached }
            let image = try VisualComparison.displayedImage(
                source, name: "reference", longestSide: max(size.width, size.height))
            let planes = try Planes(image, size: size)
            prepared[size] = planes
            return planes
        }
    }

    // MARK: - Internals

    static func comparisonSize(for size: PixelSize) -> PixelSize {
        guard size.pixelCount > maximumPixelCount else { return size }
        return ResizeTarget.maxPixels(maximumPixelCount).resolve(from: size)
    }

    /// Image 0 with its orientation applied, at most `longestSide` on its
    /// longest side.
    static func displayedImage(
        _ source: CGImageSource?, name: String, longestSide: Int? = nil
    ) throws -> CGImage {
        guard let source, CGImageSourceGetCount(source) > 0 else {
            throw LatheError.invalidInput(reason: "\(name) is not an image ImageIO can read")
        }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        options[kCGImageSourceThumbnailMaxPixelSize] = longestSide ?? max(width, height, 1)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw LatheError.invalidInput(reason: "\(name) could not be decoded")
        }
        return image
    }
}

/// A picture as three float planes — luma and two chroma — at a fixed size.
final class Planes: @unchecked Sendable {
    let width: Int
    let height: Int
    let y: [Float]
    let cb: [Float]
    let cr: [Float]

    init(_ image: CGImage, size: PixelSize) throws {
        width = size.width
        height = size.height
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw LatheError.encodingFailed(stage: "compare", code: nil, reason: "could not draw the picture") }
        // Transparent areas compare against white, the way a viewer shows them.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw LatheError.encodingFailed(stage: "compare", code: nil, reason: "no pixel buffer")
        }
        let count = width * height
        var y = [Float](repeating: 0, count: count)
        var cb = [Float](repeating: 0, count: count)
        var cr = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let r = Float(pixels[index * 4]) / 255
            let g = Float(pixels[index * 4 + 1]) / 255
            let b = Float(pixels[index * 4 + 2]) / 255
            y[index] = 0.299 * r + 0.587 * g + 0.114 * b
            cb[index] = 0.5 - 0.168736 * r - 0.331264 * g + 0.5 * b
            cr[index] = 0.5 + 0.5 * r - 0.418688 * g - 0.081312 * b
        }
        self.y = y
        self.cb = cb
        self.cr = cr
    }

    func similarity(to other: Planes) throws -> VisualSimilarity {
        guard width == other.width, height == other.height else {
            throw LatheError.invalidInput(reason: "pictures of different sizes cannot be compared")
        }
        let luma = try Self.ssimMap(y, other.y, width: width, height: height)
        // Colour is compared at half resolution, which is roughly the eye's
        // colour acuity — and exactly the resolution 4:2:0 codecs keep it at.
        // At full resolution every subsampled encode reads as damaged, however
        // invisible the difference is.
        let (halfWidth, halfHeight) = (max(width / 2, 1), max(height / 2, 1))
        let blue = try Self.ssimMap(
            Self.halve(cb, width: width, height: height), Self.halve(other.cb, width: width, height: height),
            width: halfWidth, height: halfHeight)
        let red = try Self.ssimMap(
            Self.halve(cr, width: width, height: height), Self.halve(other.cr, width: width, height: height),
            width: halfWidth, height: halfHeight)
        let overall = (6 * Self.mean(luma) + Self.mean(blue) + Self.mean(red)) / 8
        return VisualSimilarity(
            overall: overall,
            worstRegion: Self.worstRegion(luma, width: width, height: height),
            comparedSize: PixelSize(width: width, height: height))
    }

    // MARK: SSIM

    static let kernel: [Float] = {
        let sigma: Float = 1.5
        let taps = (-5...5).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
        let sum = taps.reduce(0, +)
        return taps.map { $0 / sum }
    }()

    static func blur(_ values: [Float], width: Int, height: Int) throws -> [Float] {
        var output = [Float](repeating: 0, count: values.count)
        var input = values
        let error = input.withUnsafeMutableBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                var src = vImage_Buffer(
                    data: source.baseAddress, height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.stride)
                var dst = vImage_Buffer(
                    data: destination.baseAddress, height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.stride)
                return kernel.withUnsafeBufferPointer { k in
                    vImageSepConvolve_PlanarF(
                        &src, &dst, nil, 0, 0,
                        k.baseAddress, UInt32(k.count), k.baseAddress, UInt32(k.count),
                        0, 0, vImage_Flags(kvImageEdgeExtend))
                }
            }
        }
        guard error == kvImageNoError else {
            throw LatheError.encodingFailed(stage: "compare", code: Int32(error), reason: "vImage convolution failed")
        }
        return output
    }

    /// The per-pixel SSIM map, for signals in `0...1`.
    static func ssimMap(_ a: [Float], _ b: [Float], width: Int, height: Int) throws -> [Float] {
        let c1: Float = 0.01 * 0.01
        let c2: Float = 0.03 * 0.03
        let muA = try blur(a, width: width, height: height)
        let muB = try blur(b, width: width, height: height)
        let aa = try blur(vDSP.multiply(a, a), width: width, height: height)
        let bb = try blur(vDSP.multiply(b, b), width: width, height: height)
        let ab = try blur(vDSP.multiply(a, b), width: width, height: height)
        var map = [Float](repeating: 0, count: a.count)
        for i in 0..<a.count {
            let ma = muA[i], mb = muB[i]
            let varA = max(aa[i] - ma * ma, 0)
            let varB = max(bb[i] - mb * mb, 0)
            let cov = ab[i] - ma * mb
            map[i] = ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (varA + varB + c2))
        }
        return map
    }

    /// A 2 × 2 box average. An odd last row or column is dropped.
    static func halve(_ values: [Float], width: Int, height: Int) -> [Float] {
        let (w, h) = (max(width / 2, 1), max(height / 2, 1))
        guard width > 1, height > 1 else { return values }
        var out = [Float](repeating: 0, count: w * h)
        values.withUnsafeBufferPointer { source in
            for row in 0..<h {
                let top = row * 2 * width, bottom = top + width
                for column in 0..<w {
                    let x = column * 2
                    out[row * w + column] =
                        (source[top + x] + source[top + x + 1] + source[bottom + x] + source[bottom + x + 1]) / 4
                }
            }
        }
        return out
    }

    static func mean(_ values: [Float]) -> Double {
        Double(vDSP.mean(values))
    }

    static func worstRegion(_ map: [Float], width: Int, height: Int, side: Int = 32) -> Double {
        var worst = Double.greatestFiniteMagnitude
        var top = 0
        repeat {
            let bottom = min(top + side, height)
            var left = 0
            repeat {
                let right = min(left + side, width)
                var sum: Float = 0
                for row in top..<bottom {
                    map.withUnsafeBufferPointer { buffer in
                        sum += vDSP.sum(buffer[(row * width + left)..<(row * width + right)])
                    }
                }
                worst = min(worst, Double(sum) / Double((bottom - top) * (right - left)))
                left += side
            } while left < width
            top += side
        } while top < height
        return worst == .greatestFiniteMagnitude ? 1 : worst
    }
}
