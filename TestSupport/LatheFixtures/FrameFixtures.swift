import CoreGraphics
import Foundation
import ImageIO

/// A directory of numbered stills — the input every composition test needs.
///
/// Separate from ``DocumentFixtures`` because three suites want it, in three
/// modules: the animation writer lives in `LatheImage`, the video writer in
/// `LatheVideo` and the PDF and comic writers in `LatheDoc`, and SwiftPM test
/// targets cannot depend on one another. That is the same reason `LatheFixtures`
/// exists at all.
///
/// **The frames are told apart by their pixels, not by their names.** Each one
/// is a distinct flat grey, so "frame 3 of the output is frame 3 of the input"
/// is a measurement — read the output back, sample the middle of each frame,
/// compare — rather than a count that a writer which dropped and duplicated a
/// frame would also pass.
public enum FrameFixtures {

    /// The grey of frame `index` of `count`, in `0...1`.
    ///
    /// Deliberately never 0 or 1. Pure black and pure white survive every
    /// round trip, including ones that lost the frame entirely and left the
    /// canvas at its cleared value — so a fixture built out of them cannot tell
    /// a written frame from an unwritten one.
    public static func gray(_ index: Int, of count: Int) -> CGFloat {
        CGFloat(index + 1) / CGFloat(count + 1)
    }

    /// Writes `count` numbered stills into `directory` and returns them in
    /// order.
    ///
    /// Names are zero-padded to the width of the count, which is what
    /// `FrameExtractor.frames(from:into:)` does and what
    /// `FrameSequence.contentsOfDirectory(_:)` expects to find.
    ///
    /// - Parameters:
    ///   - count: how many frames.
    ///   - directory: created if it does not exist.
    ///   - size: every frame's size, unless `sizes` overrides it.
    ///   - sizes: per-frame sizes, for the mismatched-frames cases. One entry
    ///     per frame when given.
    ///   - fileExtension: `png` or `jpg`. PNG by default, because it is lossless
    ///     and a grey that went in comes back out.
    @discardableResult
    public static func stills(
        count: Int,
        in directory: URL,
        size: CGSize = CGSize(width: 64, height: 48),
        sizes: [CGSize]? = nil,
        fileExtension: String = "png",
        basename: String = "frame"
    ) throws -> [URL] {
        precondition(count >= 1)
        precondition(sizes == nil || sizes?.count == count)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let width = String(count).count
        var written: [URL] = []
        for index in 0..<count {
            let data: Data
            let frameSize = sizes?[index] ?? size
            switch fileExtension.lowercased() {
            case "png":
                data = try DocumentFixtures.solidPNG(size: frameSize, gray: gray(index, of: count))
            case "jpg", "jpeg":
                data = try DocumentFixtures.solidJPEG(size: frameSize, gray: gray(index, of: count))
            default:
                throw FixtureError.unsupported("no frame fixture writes .\(fileExtension)")
            }
            let url = directory.appendingPathComponent(
                String(format: "\(basename)-%0\(width)d.\(fileExtension)", index + 1)
            )
            written.append(try DocumentFixtures.write(data, to: url))
        }
        return written
    }

    /// The grey at the centre of `image`, in `0...1`.
    ///
    /// The centre rather than a corner: every composer here letterboxes, so a
    /// corner can legitimately be the margin rather than the frame. One pixel
    /// rather than an average, so a frame that is half one grey and half another
    /// — which is what a shifted or duplicated frame looks like — does not
    /// average into looking correct.
    public static func centreGray(of image: CGImage) throws -> Double {
        var pixel: [UInt8] = [0, 0, 0, 0]
        guard let context = CGContext(
            data: &pixel,
            width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw FixtureError.writerUnavailable("no 1x1 sampling context")
        }
        // Draw the whole image scaled down to the single pixel's worth of the
        // *centre*, by placing it so its middle lands on the one pixel.
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(
            x: -Double(image.width) / 2 + 0.5,
            y: -Double(image.height) / 2 + 0.5,
            width: Double(image.width),
            height: Double(image.height)
        ))
        // BGRA little-endian: [B, G, R, A]. A flat grey makes all three equal,
        // so any one of them is the answer.
        return Double(pixel[2]) / 255.0
    }

    /// Every frame of an image file, decoded, in order.
    public static func decodeFrames(of url: URL) throws -> [CGImage] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw FixtureError.writeFailed("\(url.lastPathComponent) would not open")
        }
        return try (0..<CGImageSourceGetCount(source)).map { index in
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                throw FixtureError.writeFailed("frame \(index) of \(url.lastPathComponent)")
            }
            return image
        }
    }
}
