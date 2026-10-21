import CoreGraphics
import Foundation
import ImageIO
import LatheCore
import LatheImage
import LatheSWF
import Testing

@testable import LatheSWFRender

/// Thumbnails: the arithmetic and naming that need no WebView, and then the
/// real thing — Ruffle playing a movie into a WebP.
@Suite("SWF thumbnails")
@MainActor
struct SWFThumbnailerTests {

    private static let startup: Duration = .seconds(180)

    private func scratch(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func header(width: Int, height: Int) throws -> SWFHeader {
        let directory = try scratch("header")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("m.swf")
        try AnimatedSWF.movie(width: width, height: height).write(to: file)
        return try SWFCapture().header(of: file)
    }

    // MARK: - No WebView

    @Test("the render size keeps the stage's shape and hits the requested longest side")
    func renderSize() throws {
        let wide = try header(width: 400, height: 200)
        let size = SWFThumbnailer.renderSize(for: wide, longestSide: 100)
        #expect(size == CGSize(width: 100, height: 50))
        // Vector art: asking for more than the stage is allowed.
        #expect(SWFThumbnailer.renderSize(for: wide, longestSide: 800) == CGSize(width: 800, height: 400))
        #expect(SWFThumbnailer.renderSize(for: wide, longestSide: nil) == CGSize(width: 400, height: 200))
    }

    @Test("two movies with one name do not overwrite each other")
    func namesAreUnique() {
        var taken: Set<String> = []
        let folder = URL(fileURLWithPath: "/tmp/out")
        let names = ["a/Game.swf", "b/game.swf", "c/Game.swf"].map {
            SWFThumbnailer.uniqueDestination(
                for: URL(fileURLWithPath: $0), in: folder, format: .webp, taken: &taken
            ).lastPathComponent
        }
        #expect(names == ["Game.webp", "game-2.webp", "Game-3.webp"])
    }

    @Test("JPEG gets a white background rather than a black box; WebP keeps its alpha")
    func backgroundPolicy() {
        #expect(SWFThumbnailer.background(.transparent, for: .jpeg) != nil)
        #expect(SWFThumbnailer.background(.transparent, for: .webp) == nil)
        #expect(SWFThumbnailer.background(.black, for: .webp) != nil)
    }

    @Test("detail is zero for a flat frame and grows with what is on it")
    func detailScore() throws {
        let directory = try scratch("detail")
        defer { try? FileManager.default.removeItem(at: directory) }
        func png(_ name: String, drawing: (CGContext) -> Void) throws -> URL {
            let context = try #require(CGContext(
                data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            drawing(context)
            let url = directory.appendingPathComponent(name)
            let sink = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(sink, try #require(context.makeImage()), nil)
            #expect(CGImageDestinationFinalize(sink))
            return url
        }
        let flat = try png("flat.png") { _ in }
        let square = try png("square.png") {
            $0.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            $0.fill(CGRect(x: 0, y: 0, width: 50, height: 20))  // 10% of the frame
        }
        #expect(SWFThumbnailer.detail(of: flat) == 0)
        #expect(abs(SWFThumbnailer.detail(of: square) - 0.1) < 0.001)
    }

    // MARK: - With Ruffle

    @Test("a batch cuts WebP thumbnails, names each, and reports the bad file without stopping")
    func batchOfThumbnails() async throws {
        let directory = try scratch("thumbs")
        defer { try? FileManager.default.removeItem(at: directory) }
        let good = directory.appendingPathComponent("square.swf")
        try AnimatedSWF.movie().write(to: good)
        let bad = directory.appendingPathComponent("broken.swf")
        try Data("not a movie".utf8).write(to: bad)
        let another = directory.appendingPathComponent("again.swf")
        try AnimatedSWF.movie().write(to: another)

        var events = 0
        let outcomes = try await SWFThumbnailer().thumbnails(
            of: [good, bad, another], into: directory.appendingPathComponent("out"),
            options: SWFThumbnailOptions(
                format: .webp, longestSide: 80, position: .seconds(0.5), startupTimeout: Self.startup),
            progress: { _ in events += 1 })

        #expect(outcomes.count == 3)
        #expect(events == 6)
        guard case let .made(first) = outcomes[0] else {
            Issue.record("the first movie should have produced a thumbnail: \(outcomes[0])")
            return
        }
        #expect(first.output.pathExtension == "webp")
        #expect(first.pixelSize == CGSize(width: 80, height: 60))
        #expect(first.byteCount > 0)
        #expect(!first.isBlank)

        // It is a WebP of the right size, not just a file with the right name.
        let source = try #require(CGImageSourceCreateWithURL(first.output as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 80 && image.height == 60)

        guard case .failed = outcomes[1] else {
            Issue.record("a file that is not a SWF should fail by itself")
            return
        }
        guard case .made = outcomes[2] else {
            Issue.record("the failure should not have stopped the batch")
            return
        }
    }
}
