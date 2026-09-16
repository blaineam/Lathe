import CoreGraphics
import Foundation
import ImageIO
import LatheCore
import LatheImage
import Testing

@testable import LatheSWFRender

/// The tests that actually start a `WKWebView`.
///
/// ## What these cover, and the one thing they cannot
///
/// The Ruffle build is fetched rather than committed (see `VENDORING.md`), so a
/// clone has no Ruffle in it and a test that needed one could not run at all.
/// These therefore drive the **real** page, through the **real** scheme handler,
/// with the **real** capture call, decode and frame writer — putting a canvas
/// the page animates itself where Ruffle's canvas would be.
///
/// So everything between "a canvas is drawing" and "a GIF exists" is covered
/// here, on whatever platform the suite runs on. What is not covered, and is
/// stated rather than implied, is Ruffle itself: whether *that* WebAssembly
/// module loads and plays a given movie is not something this suite can know.
@Suite("SWF render, in a WebView")
@MainActor
struct RenderWebViewTests {

    private func temporaryDirectory(_ label: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
    }

    /// A runtime directory with nothing in it. The self-test never requests
    /// anything under `/ruffle/`, so an empty one is exactly right — and it also
    /// means these tests prove the page works without the artifact.
    private func emptyRuntime() -> RuffleRuntime {
        RuffleRuntime(directory: temporaryDirectory("no-ruffle"))
    }

    // MARK: - The capability everything else rests on

    /// **Ruffle is WebAssembly, so this is the load-bearing question.**
    ///
    /// It is asked of the running system rather than answered from an OS version
    /// because the honest answer is complicated: JavaScriptCore runs WebAssembly
    /// without a JIT, an ordinary app's `WKWebView` on iOS has no JIT, and the
    /// Simulator has the host's capabilities rather than a device's. A green
    /// result here says the API is present and works; it says nothing about how
    /// fast it is on a phone.
    @Test("WebKit on this system compiles and runs a WebAssembly module")
    func webAssemblyRuns() async throws {
        let result = await WebAssemblySupport.probe()
        if case let .unavailable(reason) = result {
            Issue.record("WebAssembly is unavailable here: \(reason)")
        }
        #expect(result.isAvailable)
    }

    @Test("the probe module is the 34 bytes it claims to be")
    func probeModuleShape() {
        #expect(WebAssemblySupport.probeModule.count == 34)
        #expect(Array(WebAssemblySupport.probeModule.prefix(4)) == [0x00, 0x61, 0x73, 0x6D])
    }

    // MARK: - The capture path, end to end

    @Test("a render writes ordered PNG frames of the requested size")
    func captureWritesFrames() async throws {
        let output = temporaryDirectory("frames")
        defer { try? FileManager.default.removeItem(at: output) }

        let stage = SWFRenderStage(
            pixelSize: CGSize(width: 64, height: 48), framesPerSecond: 10, declaredFrameCount: 10
        )
        let result = try await SWFRenderer(runtime: nil).capture(
            mode: "selftest", movie: nil, runtime: emptyRuntime(), stage: stage, to: output,
            options: SWFRenderOptions(limit: .frames(6))
        )

        #expect(result.frames.count == 6)
        #expect(result.framesPerSecond == 10)
        #expect(result.pixelSize == CGSize(width: 64, height: 48))

        // Named so a reader — and `FrameSequence.contentsOfDirectory` — puts
        // them back in the order they were captured.
        #expect(result.frames.frames.first?.lastPathComponent == "frame-00001.png")
        #expect(result.frames.frames.last?.lastPathComponent == "frame-00006.png")

        for url in result.frames.frames {
            #expect(FileManager.default.fileExists(atPath: url.path))
            let data = try Data(contentsOf: url)
            #expect(data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))

            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            #expect(image.width == 64)
            #expect(image.height == 48)
        }
    }

    /// A capture loop that returned the same image every time would pass every
    /// assertion above. The stand-in canvas moves a band precisely so that
    /// "these are different frames" is checkable.
    @Test("successive frames are actually different pictures")
    func framesAdvance() async throws {
        let output = temporaryDirectory("advance")
        defer { try? FileManager.default.removeItem(at: output) }

        let stage = SWFRenderStage(
            pixelSize: CGSize(width: 80, height: 40), framesPerSecond: 8, declaredFrameCount: 8
        )
        let result = try await SWFRenderer(runtime: nil).capture(
            mode: "selftest", movie: nil, runtime: emptyRuntime(), stage: stage, to: output,
            options: SWFRenderOptions(limit: .frames(5))
        )

        let bytes = try result.frames.frames.map { try Data(contentsOf: $0) }
        #expect(Set(bytes).count > 1, "every captured frame was byte-identical")
    }

    /// Capture is real time. Six frames at 8 fps is about three quarters of a
    /// second of movie, and the capture takes about that long — which is the
    /// property the documentation claims and the one a caller has to plan for.
    @Test("capture runs in real time, and reports the rate it achieved")
    func captureIsRealTime() async throws {
        let output = temporaryDirectory("realtime")
        defer { try? FileManager.default.removeItem(at: output) }

        let stage = SWFRenderStage(
            pixelSize: CGSize(width: 32, height: 32), framesPerSecond: 8, declaredFrameCount: 8
        )
        let result = try await SWFRenderer(runtime: nil).capture(
            mode: "selftest", movie: nil, runtime: emptyRuntime(), stage: stage, to: output,
            options: SWFRenderOptions(limit: .frames(6))
        )

        // Five intervals at 8 fps is 0.625s; allow generous slack either side so
        // this measures "paced by wall clock" rather than the machine's mood.
        #expect(result.wallClockSeconds > 0.4)
        #expect(result.wallClockSeconds < 20)
        #expect(result.achievedFramesPerSecond > 0)
        #expect(!result.wasTruncatedByFrameCeiling)
    }

    /// The whole point of stopping at frames: what comes out is a `FrameSequence`
    /// the composers that landed separately already know how to assemble, and
    /// this module writes no encoder of its own.
    @Test("the frames hand straight to AnimatedImageWriter and become a GIF")
    func framesChainToAWriter() async throws {
        let output = temporaryDirectory("chain")
        defer { try? FileManager.default.removeItem(at: output) }

        let stage = SWFRenderStage(
            pixelSize: CGSize(width: 48, height: 32), framesPerSecond: 10, declaredFrameCount: 10
        )
        let result = try await SWFRenderer(runtime: nil).capture(
            mode: "selftest", movie: nil, runtime: emptyRuntime(), stage: stage, to: output,
            options: SWFRenderOptions(limit: .frames(4))
        )

        let gif = output.appendingPathComponent("out.gif")
        try AnimatedImageWriter().write(
            result.frames, to: gif, format: .gif,
            delays: .framesPerSecond(result.framesPerSecond)
        )

        let data = try Data(contentsOf: gif)
        // ImageIO stamps GIF87a even for an animation, so the version is not
        // the thing to assert on — the frame count is.
        #expect(data.prefix(3) == Data("GIF".utf8))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 4)
    }

    /// **The fallback is load-bearing, so it is asserted rather than assumed.**
    ///
    /// WebKit suspends rendering updates for content it considers not visible,
    /// and a process with no running application — this test bundle, for
    /// instance — has nothing to drive a display update at all. In that state
    /// `requestAnimationFrame` never fires, so the page's timeout path is the
    /// only way a frame gets read. Both states have to produce frames, and the
    /// result has to say which one happened, because "every frame is identical"
    /// means something completely different in each.
    @Test("frames come out whether or not the frame callback ever fires")
    func fallbackStillProducesFrames() async throws {
        let output = temporaryDirectory("fallback")
        defer { try? FileManager.default.removeItem(at: output) }

        let stage = SWFRenderStage(
            pixelSize: CGSize(width: 32, height: 24), framesPerSecond: 10, declaredFrameCount: 10
        )
        let result = try await SWFRenderer(runtime: nil).capture(
            mode: "selftest", movie: nil, runtime: emptyRuntime(), stage: stage, to: output,
            options: SWFRenderOptions(limit: .frames(4), frameCallbackTimeout: .milliseconds(80))
        )

        #expect(result.frames.count == 4)
        for url in result.frames.frames {
            #expect(try Data(contentsOf: url).count > 0)
        }
        // The flag is derived from the counter and must agree with it, whichever
        // way the host happened to behave.
        #expect(result.renderingUpdatesObserved == (result.framesReadInFrameCallback > 0))
        #expect(result.framesReadInFrameCallback <= result.frames.count)
    }

    // MARK: - Refusals

    @Test("rendering without the Ruffle build refuses, and says what to run")
    func renderWithoutRuntimeRefuses() async throws {
        let swf = temporaryDirectory("movie")
        try FileManager.default.createDirectory(at: swf, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: swf) }
        let file = swf.appendingPathComponent("movie.swf")
        try Data("FWS".utf8).write(to: file)

        let renderer = SWFRenderer(runtime: emptyRuntime())
        do {
            _ = try await renderer.render(file, to: swf.appendingPathComponent("frames"))
            Issue.record("expected a refusal")
        } catch let error as LatheError {
            guard case let .unsupportedOnThisPlatform(feature) = error else {
                Issue.record("expected unsupportedOnThisPlatform, got \(error)")
                return
            }
            #expect(feature.contains("fetch-upstream.sh"))
        }
    }

    @Test("readiness separates a missing download from a platform that cannot run it")
    func readinessSeparatesTheTwoReasons() async throws {
        let renderer = SWFRenderer(runtime: emptyRuntime())
        let readiness = await renderer.readiness()
        #expect(readiness.runtimeInstalled == false)
        // The second half is about this machine, not about the download.
        #expect(readiness.webAssembly.isAvailable)
    }
}
