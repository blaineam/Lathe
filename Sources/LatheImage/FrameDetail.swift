import CoreGraphics
import Foundation
import ImageIO

/// How much is in a picture, for choosing among candidate frames.
///
/// A frame pulled out of a video or a Flash movie is often a black fade, a
/// logo on white, or an empty stage. ``score(of:)`` puts a number on "mostly
/// one colour" so a caller can skip those and take the first frame that has
/// something in it.
public enum FrameDetail {

    /// The fraction (0…1) of pixels that are *not* the picture's dominant
    /// colour. A flat frame is 0; a frame that is half background and half
    /// subject is 0.5.
    ///
    /// Colours are grouped to four bits a channel, so a gradient or faint
    /// noise in a background does not read as detail. Around 0.05 separates a
    /// title card or a face from an empty frame.
    ///
    /// - Returns: `nil` when the file cannot be decoded.
    public static func score(of url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return score(of: image)
    }

    public static func score(of image: CGImage) -> Double? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return 0 }
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var counts = [UInt32](repeating: 0, count: 65536)
        let pixels = width * height
        for pixel in 0..<pixels {
            let base = pixel * 4
            let key = Int(data[base] >> 4) << 12 | Int(data[base + 1] >> 4) << 8
                | Int(data[base + 2] >> 4) << 4 | Int(data[base + 3] >> 4)
            counts[key] += 1
        }
        return 1 - Double(counts.max() ?? 0) / Double(pixels)
    }

    /// The index of the first of `frames`, in the order given, whose score is
    /// at least `minimum`; failing that, the index of the highest-scoring one.
    /// `nil` only when `frames` is empty or none can be decoded.
    public static func bestIndex(of frames: [URL], minimum: Double = 0.05) -> Int? {
        var best: (index: Int, score: Double)?
        for (index, frame) in frames.enumerated() {
            guard let score = score(of: frame) else { continue }
            if score >= minimum { return index }
            if score > (best?.score ?? -1) { best = (index, score) }
        }
        return best?.index
    }
}
