import CoreGraphics
import Foundation
import LatheCore
import LatheImage
import LatheSWF
import WebKit

/// Plays a Flash movie with Ruffle inside a `WKWebView`, and captures its frames.
///
/// ```swift
/// let render = try await SWFRenderer().render(movie, to: framesDirectory)
/// try AnimatedImageWriter().write(
///     render.frames, to: gif, format: .gif,
///     delays: .framesPerSecond(render.framesPerSecond)
/// )
/// ```
///
/// ## Why this exists beside ``SWFCapture`` rather than instead of it
///
/// ``SWFCapture`` walks the tag stream and pulls out the embedded JPEG, PNG,
/// MP3 and PCM at **original quality**, with no WebView, no WebAssembly, and no
/// script executed. This renders the movie *as a movie* — vector shapes, the
/// timeline, ActionScript and all — and gives back pixels.
///
/// They answer different questions and neither replaces the other. If what you
/// want is the artwork somebody drew, extraction returns the actual file they
/// drew it in; rendering returns a re-rasterised photograph of it. If what you
/// want is the cartoon, extraction cannot give you one at any price. Extraction
/// also works on files Ruffle refuses, and rendering works on files that contain
/// no embedded media at all — which is to say, on exactly the files extraction
/// reports as ``SWFVerdict/vectorOrScriptOnly``.
///
/// ## Capture is real time, and there is no way around that
///
/// **A thirty-second movie takes about thirty seconds to capture.** Ruffle is an
/// emulator playing at wall-clock speed; there is no public way to step its
/// clock, so frames are *sampled* from a live performance rather than rendered
/// on demand. Three consequences a caller has to plan for:
///
/// - A long movie is a long job. Show progress, and do not do this on a main
///   thread that something is waiting on.
/// - Asking for a higher ``SWFRenderOptions/framesPerSecond`` does not make it
///   slower; it samples the same playback more finely.
/// - If the machine cannot capture as fast as requested, the recording is
///   **decimated rather than slowed** — playback carries on regardless, so the
///   frames that were not captured are content that is simply missing, and the
///   result plays back fast. ``SWFRenderResult/achievedFramesPerSecond`` and
///   ``SWFRenderResult/keptUp`` report this instead of hiding it.
///
/// ## How the frames are read, and why not `takeSnapshot`
///
/// Two routes are available, and this takes the second:
///
/// - **`WKWebView.takeSnapshot(with:)` on a timer.** Simple, and it photographs
///   the *view*: it needs the view to be onscreen in a window to be reliable,
///   returns images in the display's scale factor rather than the movie's, and
///   goes through the window server on every frame. On an offscreen host it
///   commonly returns blank images.
/// - **Reading Ruffle's `<canvas>`.** Ruffle rasterises into a canvas in its
///   element's shadow root. Copying that canvas into a 2D canvas and reading it
///   gives the pixels Ruffle drew, with no compositor round trip and no
///   dependence on the host being visible.
///
/// The second is faster and is the only one that works offscreen, so it is what
/// runs. Three things had to be true for it to return the movie rather than a
/// blank or frozen picture, and each is handled in `RenderHost/shim.html`:
///
/// - **The player has to keep ticking when WebKit stops calling
///   `requestAnimationFrame`**, which it does for any page it considers not
///   visible — including this offscreen one. The page races every frame request
///   against a 60 Hz fallback clock, scheduled so that WebKit's throttling of
///   nested timers in hidden pages cannot slow it to one frame a second.
/// - **The WebGL canvas has to still hold its picture when it is read.** Ruffle
///   redraws only when the movie advances, so most reads land between draws;
///   the page creates WebGL contexts with `preserveDrawingBuffer`.
/// - **The canvas is in device pixels**, twice the movie's size on a Retina
///   display, so frames are scaled back to the requested size as they are read.
///
/// ``SWFRenderResult/renderingUpdatesObserved`` says whether WebKit's own frame
/// callbacks arrived or the fallback clock carried the render.
///
/// ## What this executes, and who has to decide it is acceptable
///
/// > Important: This module loads a WebAssembly build of Ruffle into a WebView
/// > and hands it a **user-supplied `.swf`, whose ActionScript Ruffle then
/// > interprets.** That is third-party bytecode from an untrusted file being
/// > executed on the user's device.
/// >
/// > It runs inside WebKit, which is the sanctioned place on Apple's platforms
/// > for exactly this — the interpreter is WebAssembly in a `WKWebView`, not
/// > downloaded native code, and nothing is fetched at run time: the Ruffle
/// > build is a resource in the application bundle. The host also refuses
/// > navigation to any scheme but its own, so a movie calling `getURL` cannot
/// > make the WebView fetch anything.
/// >
/// > **This is still a judgement for a human to make, not for this
/// > documentation to make on their behalf.** An application shipping this to
/// > the App Store should weigh it deliberately, and an application that does
/// > not need rendering should link `LatheSWF` alone and have none of it. That
/// > is why this is a separate product.
@MainActor
public final class SWFRenderer {

    /// Where the Ruffle build is. `nil` means the module could not locate its
    /// own resource bundle, which is a packaging fault.
    public let runtime: RuffleRuntime?

    public init(runtime: RuffleRuntime? = RuffleRuntime.bundled) {
        self.runtime = runtime
    }

    /// Whether this build can actually render: the Ruffle files are present and
    /// WebKit here runs WebAssembly.
    ///
    /// Both halves are runtime questions with different remedies — one is a
    /// packaging fault, the other is "this system cannot do it", which includes
    /// a user who has turned on Lockdown Mode — so they are reported separately
    /// rather than as one boolean.
    public func readiness() async
        -> (runtimeInstalled: Bool, webAssembly: WebAssemblySupport.Result)
    {
        let installed = runtime?.isInstalled ?? false
        return (installed, await WebAssemblySupport.probe())
    }

    // MARK: - Rendering

    /// Plays `swf` and writes its frames into `directory` as PNG files named
    /// `frame-00001.png` onwards.
    ///
    /// The defaults come from the movie's own header — its stage size and frame
    /// rate — read with ``SWFCapture/header(of:)``, which costs a few bytes and
    /// decompresses nothing it does not need.
    ///
    /// - Throws: ``LatheError/unsupportedOnThisPlatform(feature:)`` when the
    ///   Ruffle runtime is missing; ``LatheError/invalidInput(reason:)``
    ///   when the file is not a SWF, when the player does not start, or when a
    ///   frame cannot be read; ``LatheError/invalidConfiguration(reason:)`` for
    ///   options the header and the request cannot be reconciled into.
    @discardableResult
    public func render(
        _ swf: URL, to directory: URL, options: SWFRenderOptions = SWFRenderOptions()
    ) async throws -> SWFRenderResult {
        guard let runtime else {
            throw LatheError.unsupportedOnThisPlatform(
                feature: "SWF rendering — LatheSWFRender could not find its own resource bundle"
            )
        }
        try runtime.requireInstalled()

        let header = try SWFCapture().header(of: swf)
        let stage = SWFRenderStage(
            pixelSize: CGSize(
                width: header.stageWidthInPixels, height: header.stageHeightInPixels
            ),
            framesPerSecond: header.frameRate,
            declaredFrameCount: Int(header.frameCount)
        )

        return try await capture(
            mode: "ruffle", movie: swf, runtime: runtime, stage: stage, to: directory,
            options: options
        )
    }

    // MARK: - The loop

    /// The whole render, shared by the real path and by the suite's self test.
    ///
    /// `mode` chooses what goes on the stage — Ruffle, or a canvas the page
    /// animates itself. Everything after that point is identical: the same
    /// scheme handler, the same page, the same capture call, the same decode and
    /// the same files on disk. That is what lets the capture path be tested
    /// apart from the player.
    ///
    /// `pageTestHooks` is merged into the page's configuration, for the suite
    /// only: it is how a test makes the page behave as if a renderer had
    /// panicked, which no real system does on demand.
    func capture(
        mode: String, movie: URL?, runtime: RuffleRuntime, stage: SWFRenderStage, to directory: URL,
        options: SWFRenderOptions, pageTestHooks: [String: Bool] = [:]
    ) async throws -> SWFRenderResult {
        let plan = try options.resolved(againstStageOf: stage)

        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
        } catch {
            throw LatheError.writeFailed(
                path: directory.lastPathComponent, reason: (error as NSError).localizedDescription
            )
        }

        let shim = try Self.shimHTML()
        let handler = RenderSchemeHandler(shim: shim, runtime: runtime, movie: movie)

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: RenderSchemeHandler.scheme)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // A movie cannot be allowed to open windows, and there is nothing here
        // to open them into.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        #if canImport(UIKit)
        // Flash content has sound. Without this, iOS refuses to start audio
        // without a user gesture and Ruffle may wait for one that never comes.
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        #endif

        let size = CGSize(width: plan.width, height: plan.height)
        let webView = WKWebView(
            frame: CGRect(origin: .zero, size: size), configuration: configuration
        )
        let loader = WebViewLoader()
        loader.allowedSchemes = [RenderSchemeHandler.scheme]
        webView.navigationDelegate = loader

        let host = RenderHostWindow()
        let composited = host.attach(webView, size: size)
        defer { host.detach(webView) }

        webView.load(URLRequest(url: RenderSchemeHandler.pageURL))
        try await loader.waitForLoad(timeout: options.startupTimeout)

        _ = try await webView.callAsyncJavaScript(
            "return window.latheInit(config);",
            arguments: [
                "config": [
                    "mode": mode,
                    "movieURL": RenderSchemeHandler.movieURL.absoluteString,
                    "width": plan.width,
                    "height": plan.height,
                    "frameRate": plan.framesPerSecond,
                    "preferredRenderer": options.preferredRenderer as Any,
                    "testHooks": pageTestHooks,
                ] as [String: Any]
            ],
            contentWorld: .page
        )

        try await waitForStage(webView, timeout: options.startupTimeout)

        // MARK: Sampling
        //
        // Each frame's target moment is computed from the START of the capture
        // rather than from the previous frame, so a slow frame does not push
        // every later one back — the cadence stays anchored to wall clock, which
        // is the clock the movie is playing against.
        let clock = ContinuousClock()
        let started = clock.now
        var frames: [URL] = []
        var readInFrameCallback = 0

        for index in 0..<plan.frameCount {
            let target = started.advanced(by: .seconds(Double(index) / plan.framesPerSecond))
            let now = clock.now
            if now < target { try await Task.sleep(until: target, clock: clock) }

            try Task.checkCancellation()
            try await failIfPageReportedAnError(webView)

            let (data, viaFrameCallback) = try await captureOneFrame(
                webView, frameCallbackTimeout: options.frameCallbackTimeout
            )
            if viaFrameCallback { readInFrameCallback += 1 }

            let url = directory.appendingPathComponent(String(format: "frame-%05d.png", index + 1))
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                throw LatheError.writeFailed(
                    path: url.lastPathComponent, reason: (error as NSError).localizedDescription
                )
            }
            frames.append(url)
        }

        let renderer = try? await webView.callAsyncJavaScript(
            "return window.latheState.renderer;", contentWorld: .page
        ) as? String

        let elapsed = Double(
            (clock.now - started).components.seconds
        ) + Double((clock.now - started).components.attoseconds) / 1e18

        return SWFRenderResult(
            frames: FrameSequence(frames),
            framesPerSecond: plan.framesPerSecond,
            pixelSize: size,
            wallClockSeconds: elapsed,
            achievedFramesPerSecond: elapsed > 0 ? Double(frames.count) / elapsed : 0,
            wasTruncatedByFrameCeiling: plan.wasTruncated,
            compositedInAWindow: composited,
            framesReadInFrameCallback: readInFrameCallback,
            renderer: renderer
        )
    }

    // MARK: - Page conversation

    /// Waits until the page says something is on the stage.
    ///
    /// Polls rather than awaiting an event because Ruffle does not emit a
    /// loading event for every movie, and a render that hung on content which
    /// plays perfectly well would be the worse failure. The page reports both
    /// its event and its own look at the canvas; see `shim.html`.
    private func waitForStage(_ webView: WKWebView, timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            try await failIfPageReportedAnError(webView)
            let status = try await webView.callAsyncJavaScript(
                "return window.latheState.status;", contentWorld: .page
            ) as? String
            if status == "ready" { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        // What the page was doing when time ran out is the only evidence there
        // is — nobody has an inspector on this WebView — so it goes in the error.
        let pageState = (try? await webView.callAsyncJavaScript(
            """
            return JSON.stringify({ state: window.latheState, frames: window.latheFrames,
                                    console: window.latheLog });
            """,
            contentWorld: .page
        ) as? String) ?? "unavailable"
        throw LatheError.invalidInput(
            reason: "the player did not put anything on the stage within \(timeout); the movie may "
                + "be one Ruffle cannot open, or WebAssembly may be unavailable here — run "
                + "SWFRenderer.readiness() to tell those apart. Page: \(pageState)"
        )
    }

    private func failIfPageReportedAnError(_ webView: WKWebView) async throws {
        let state = try await webView.callAsyncJavaScript(
            "return { status: window.latheState.status, detail: window.latheState.detail };",
            contentWorld: .page
        ) as? [String: Any]
        guard (state?["status"] as? String) == "error" else { return }
        let detail = (state?["detail"] as? String) ?? "no detail"
        throw LatheError.invalidInput(reason: "the player failed: \(detail)")
    }

    /// One frame, decoded from the page's data URL.
    private func captureOneFrame(
        _ webView: WKWebView, frameCallbackTimeout: Duration
    ) async throws -> (Data, viaFrameCallback: Bool) {
        let components = frameCallbackTimeout.components
        let milliseconds = max(
            1, Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
        )
        let answer = try await webView.callAsyncJavaScript(
            "return await window.latheCapture(rafTimeoutMs);",
            arguments: ["rafTimeoutMs": milliseconds],
            contentWorld: .page
        )
        guard let payload = answer as? [String: Any],
              let dataURL = payload["dataURL"] as? String
        else {
            throw LatheError.invalidInput(
                reason: "the page returned \(String(describing: answer)) instead of a frame"
            )
        }
        guard let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
              !data.isEmpty
        else {
            throw LatheError.invalidInput(reason: "a captured frame was not a readable data URL")
        }
        return (data, (payload["viaFrameCallback"] as? Bool) ?? false)
    }

    // MARK: - Resources

    /// The host page, which is Lathe's own rather than upstream's.
    nonisolated static func shimHTML() throws -> Data {
        guard let url = Bundle.module.resourceURL?.appendingPathComponent("RenderHost/shim.html"),
              let data = try? Data(contentsOf: url)
        else {
            throw LatheError.unsupportedOnThisPlatform(
                feature: "SWF rendering — the render host page is missing from the resource bundle"
            )
        }
        return data
    }
}
