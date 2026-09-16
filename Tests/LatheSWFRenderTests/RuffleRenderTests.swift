import CoreGraphics
import Foundation
import ImageIO
import LatheCore
import LatheSWF
import Testing

@testable import LatheSWFRender

/// Ruffle itself, playing a real movie.
///
/// The WebView suite beside this one proves the capture path against a canvas
/// the page animates itself. This one proves the part that suite cannot: that
/// the bundled Ruffle build loads, parses a SWF, runs its timeline and draws it,
/// and that what comes out is the movie — at the movie's size, and moving.
@Suite("SWF render, with Ruffle")
@MainActor
struct RuffleRenderTests {

    /// Generous, and not for the Mac's sake — a Mac starts the player in well
    /// under a second. A package test run in the iOS Simulator has no host
    /// application and so no window scene, and WebKit's content process then
    /// runs starved: the first WebView of a run has taken minutes to load, and
    /// a panicking GPU renderer plus the canvas retry can need more than the
    /// default thirty seconds.
    private static let startup: Duration = .seconds(180)

    private func temporaryDirectory(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
    }

    @Test("the bundled runtime is installed, and holds only what Ruffle loads")
    func bundledRuntimeIsComplete() throws {
        let runtime = try #require(RuffleRuntime.bundled)
        #expect(runtime.isInstalled)
        let names = runtime.installedFileNames
        #expect(names.contains("ruffle.js"))
        #expect(names.filter { $0.hasSuffix(".wasm") }.count == 1)
        #expect(names.filter { $0.hasPrefix("core.ruffle.") }.count == 1)
        // Source maps are for a debugger nobody attaches to this WebView.
        #expect(!names.contains { $0.hasSuffix(".map") })
        // Apache-2.0 requires the licence to travel with the code.
        #expect(names.contains("LICENSE_APACHE"))
        #expect(names.contains("LICENSE_MIT"))
    }

    @Test("the synthesised movie is a SWF this package's own parser agrees with")
    func fixtureParses() throws {
        let directory = temporaryDirectory("fixture")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("square.swf")
        try AnimatedSWF.movie().write(to: file)

        let header = try SWFCapture().header(of: file)
        #expect(header.stageWidthInPixels == 160)
        #expect(header.stageHeightInPixels == 120)
        #expect(header.frameCount == 4)
        #expect(header.frameRate == 8)
    }

    /// **The test the rest of this module exists for.**
    ///
    /// A red square moves 36 pixels a frame across a dark stage. Every captured
    /// frame is decoded, the square is found in it, and the test asserts three
    /// things a broken render cannot fake together: the frames are the movie's
    /// size, the square is actually there — so Ruffle drew the movie rather than
    /// a splash screen or an overlay — and it is not in the same place in every
    /// frame, so the timeline ran rather than froze.
    @Test("Ruffle plays a real movie, at its size, and the frames move")
    func rufflePlaysAMovie() async throws {
        let renderer = SWFRenderer()
        let readiness = await renderer.readiness()
        #expect(readiness.runtimeInstalled)
        #expect(readiness.webAssembly.isAvailable, "\(readiness.webAssembly)")

        let result = try await playSquare(
            SWFRenderOptions(framesPerSecond: 16, limit: .seconds(1.5), startupTimeout: Self.startup)
        )
        #expect(result.renderer != nil, "Ruffle did not report a renderer")
    }

    /// The renderer a render falls back to when a GPU renderer panics — which
    /// is what the iOS Simulator does — so it has to be known to work, not
    /// assumed to.
    @Test("Ruffle's canvas renderer, the fallback, plays the same movie")
    func canvasRendererPlaysAMovie() async throws {
        let result = try await playSquare(
            SWFRenderOptions(
                framesPerSecond: 16, limit: .seconds(1.5), startupTimeout: Self.startup,
                preferredRenderer: "canvas"
            )
        )
        #expect(result.renderer == "canvas")
    }

    /// The retry itself. The iOS Simulator's renderer panic is intermittent, so
    /// it cannot be relied on to exercise this; the page is told to report a
    /// panic on its first attempt instead, in the same words a real one uses.
    @Test("a renderer that panics before the first frame is retried with canvas")
    func panickingRendererFallsBackToCanvas() async throws {
        let directory = temporaryDirectory("retry")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("square.swf")
        try AnimatedSWF.movie().write(to: movie)

        let runtime = try #require(RuffleRuntime.bundled)
        let header = try SWFCapture().header(of: movie)
        let stage = SWFRenderStage(
            pixelSize: CGSize(width: header.stageWidthInPixels, height: header.stageHeightInPixels),
            framesPerSecond: header.frameRate, declaredFrameCount: Int(header.frameCount)
        )
        let result = try await SWFRenderer(runtime: runtime).capture(
            mode: "ruffle", movie: movie, runtime: runtime, stage: stage,
            to: directory.appendingPathComponent("frames"),
            options: SWFRenderOptions(framesPerSecond: 16, limit: .frames(8), startupTimeout: Self.startup),
            pageTestHooks: ["panicFirstRenderer": true]
        )

        #expect(result.renderer == "canvas")
        var positions: [Int] = []
        for url in result.frames.frames {
            if let x = try Self.squareLeftEdge(in: try Self.decode(url)) { positions.append(x) }
        }
        #expect(positions.count == result.frames.count, "positions \(positions)")
    }

    /// And a caller who named a renderer gets that renderer's failure, not a
    /// substitute.
    @Test("a renderer the caller chose is not silently replaced")
    func chosenRendererIsNotReplaced() async throws {
        let directory = temporaryDirectory("chosen")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("square.swf")
        try AnimatedSWF.movie().write(to: movie)

        let runtime = try #require(RuffleRuntime.bundled)
        let stage = SWFRenderStage(
            pixelSize: CGSize(width: 160, height: 120), framesPerSecond: 8, declaredFrameCount: 4
        )
        do {
            _ = try await SWFRenderer(runtime: runtime).capture(
                mode: "ruffle", movie: movie, runtime: runtime, stage: stage,
                to: directory.appendingPathComponent("frames"),
                options: SWFRenderOptions(
                    limit: .frames(2), startupTimeout: Self.startup, preferredRenderer: "wgpu-webgl"
                ),
                pageTestHooks: ["panicChosenRenderer": true]
            )
            Issue.record("expected the chosen renderer's panic to fail the render")
        } catch let error as LatheError {
            guard case let .invalidInput(reason) = error else {
                Issue.record("expected invalidInput, got \(error)")
                return
            }
            #expect(reason.contains("panicked"), "\(reason)")
        }
    }

    /// Two passes through the half-second timeline of ``AnimatedSWF``, sampled
    /// at twice its rate, with every frame checked.
    @discardableResult
    private func playSquare(_ options: SWFRenderOptions) async throws -> SWFRenderResult {
        let directory = temporaryDirectory("ruffle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("square.swf")
        try AnimatedSWF.movie().write(to: movie)

        let result = try await SWFRenderer().render(
            movie, to: directory.appendingPathComponent("frames"), options: options
        )

        #expect(result.frames.count == 24)
        #expect(result.pixelSize == CGSize(width: 160, height: 120))

        var positions: [Int] = []
        for url in result.frames.frames {
            let image = try Self.decode(url)
            #expect(image.width == 160)
            #expect(image.height == 120)
            if let x = try Self.squareLeftEdge(in: image) { positions.append(x) }
        }

        let summary =
            "positions \(positions), rendering updates observed: "
            + "\(result.renderingUpdatesObserved), composited: \(result.compositedInAWindow), "
            + "achieved \(String(format: "%.1f", result.achievedFramesPerSecond)) fps, "
            + "renderer: \(result.renderer ?? "unreported")"
        print("Ruffle render: \(summary)")

        // Ruffle drew the square in every frame — including the first, which
        // is only true if the render waited for Ruffle's first draw rather than
        // for the canvas to exist.
        #expect(positions.count == result.frames.count, "\(summary)")
        // And it moved: the timeline has four positions, and a capture of two
        // passes sees all of them unless playback froze or badly stalled.
        #expect(Set(positions).count >= 3, "the square did not move — \(summary)")
        // Every position is one the movie actually uses: 10, 46, 82, 118.
        for x in positions {
            #expect([10, 46, 82, 118].contains { abs($0 - x) <= 2 }, "unexpected x \(x)")
        }
        return result
    }

    @Test("a file that is not a movie is refused before any WebView starts")
    func notAMovie() async throws {
        let directory = temporaryDirectory("junk")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("junk.swf")
        try Data("this is not a flash movie".utf8).write(to: file)

        await #expect(throws: LatheError.self) {
            try await SWFRenderer().render(file, to: directory.appendingPathComponent("frames"))
        }
    }

    // MARK: - Reading the pixels

    private static func decode(_ url: URL) throws -> CGImage {
        let data = try Data(contentsOf: url)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// The leftmost column containing clearly red pixels, or `nil` if there are
    /// none. Redrawn into a known RGBA layout first, so the answer does not
    /// depend on how the PNG happened to be encoded.
    private static func squareLeftEdge(in image: CGImage) throws -> Int? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(
            CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var leftmost: Int?
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if pixels[i] > 200, pixels[i + 1] < 60, pixels[i + 2] < 60 {
                    leftmost = min(leftmost ?? x, x)
                }
            }
        }
        return leftmost
    }
}
