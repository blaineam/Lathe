import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import LatheImage

@Suite("Frame detail")
struct FrameDetailTests {

    private func png(_ directory: URL, _ name: String, square: CGRect?) throws -> URL {
        let context = try #require(CGContext(
            data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        if let square {
            context.setFillColor(CGColor(red: 1, green: 0.2, blue: 0.2, alpha: 1))
            context.fill(square)
        }
        let url = directory.appendingPathComponent(name)
        let sink = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(sink, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(sink))
        return url
    }

    @Test("a flat frame scores 0 and a partly filled one scores its filled fraction")
    func scores() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("frame-detail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let flat = try png(directory, "flat.png", square: nil)
        let tenth = try png(directory, "tenth.png", square: CGRect(x: 0, y: 0, width: 50, height: 20))
        #expect(FrameDetail.score(of: flat) == 0)
        #expect(abs((FrameDetail.score(of: tenth) ?? 0) - 0.1) < 0.001)
        #expect(FrameDetail.score(of: directory.appendingPathComponent("missing.png")) == nil)
    }

    @Test("the first frame that clears the bar wins, else the most detailed")
    func bestIndex() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("frame-best-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let flat = try png(directory, "a.png", square: nil)
        let small = try png(directory, "b.png", square: CGRect(x: 0, y: 0, width: 10, height: 10))  // 1%
        let big = try png(directory, "c.png", square: CGRect(x: 0, y: 0, width: 50, height: 50))  // 25%
        let bigger = try png(directory, "d.png", square: CGRect(x: 0, y: 0, width: 80, height: 80))

        #expect(FrameDetail.bestIndex(of: [flat, small, big, bigger]) == 2)
        // Nothing clears 5%: the most detailed one, not the first.
        #expect(FrameDetail.bestIndex(of: [flat, small], minimum: 0.5) == 1)
        #expect(FrameDetail.bestIndex(of: []) == nil)
    }
}
