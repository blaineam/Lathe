import CoreGraphics
import Foundation
import LatheCore
import Testing

@testable import LatheSWFRender

/// The parts of rendering that need no WebView: where the runtime lives, what
/// the scheme handler will serve, and the arithmetic that turns a movie's own
/// header into a capture plan.
@Suite("SWF render support")
struct RenderSupportTests {

    // MARK: - Locating the runtime

    @Test("the module can find where its Ruffle directory goes, present or not")
    func bundledRuntimeIsLocatable() throws {
        let runtime = try #require(RuffleRuntime.bundled)
        #expect(runtime.directory.lastPathComponent == "ruffle")
        // The copied directory is `RenderHost`, and its name is load-bearing on
        // iOS. SwiftPM copies a target's resource directory to the resource
        // bundle's ROOT, and an iOS bundle is flat — so a directory called
        // `Resources` sitting at that root makes the bundle look like a macOS
        // one with no `Contents`, and `codesign` rejects it outright with
        // "bundle format unrecognized, invalid, or unsuitable". It builds and
        // tests perfectly on macOS, where `Contents/Resources` is expected, and
        // fails only for iOS — which is exactly the kind of break that reaches
        // a release.
        #expect(runtime.directory.deletingLastPathComponent().lastPathComponent == "RenderHost")
        // Deliberately no assertion that it is installed: a clone has not run
        // the fetch script, and this test has to pass in that clone.
        #expect(runtime.entryPoint.lastPathComponent == "ruffle.js")
    }

    @Test("a missing runtime refuses by name, and names the script that fixes it")
    func missingRuntimeNamesTheRemedy() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-ruffle-\(UUID().uuidString)")
        let runtime = RuffleRuntime(directory: empty)

        #expect(!runtime.isInstalled)
        #expect(runtime.installedFileNames.isEmpty)
        do {
            try runtime.requireInstalled()
            Issue.record("expected a refusal")
        } catch let error as LatheError {
            guard case let .unsupportedOnThisPlatform(feature) = error else {
                Issue.record("expected unsupportedOnThisPlatform, got \(error)")
                return
            }
            #expect(feature.contains("fetch-upstream.sh"))
            #expect(feature.contains("VENDORING.md"))
        }
    }

    // MARK: - Serving, which is a security boundary

    /// Every path served under `/ruffle/` is requested by third-party
    /// JavaScript, so escaping the directory has to be impossible rather than
    /// merely unlikely.
    @Test("a path that escapes the runtime directory resolves to nothing")
    func traversalIsRefused() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("ruffle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try Data("x".utf8).write(to: base.appendingPathComponent("ruffle.js"))

        let runtime = RuffleRuntime(directory: base)

        #expect(runtime.fileURL(forRelativePath: "ruffle.js") != nil)
        #expect(runtime.fileURL(forRelativePath: "core/core.wasm") != nil)

        #expect(runtime.fileURL(forRelativePath: "../secrets") == nil)
        #expect(runtime.fileURL(forRelativePath: "../../../../etc/passwd") == nil)
        #expect(runtime.fileURL(forRelativePath: "a/../../b") == nil)
        #expect(runtime.fileURL(forRelativePath: "") == nil)
        #expect(runtime.fileURL(forRelativePath: "/") == nil)
    }

    /// A raw string-prefix check would call this contained, because
    /// `/tmp/ruffle-evil` begins with `/tmp/ruffle`. The comparison is on whole
    /// path components for exactly this case.
    @Test("a sibling directory whose name merely starts the same is not inside")
    func siblingPrefixIsNotContainment() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("prefix-\(UUID().uuidString)", isDirectory: true)
        let inside = root.appendingPathComponent("ruffle", isDirectory: true)
        let sibling = root.appendingPathComponent("ruffle-evil", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("x".utf8).write(to: sibling.appendingPathComponent("stolen.js"))

        let runtime = RuffleRuntime(directory: inside)
        #expect(runtime.fileURL(forRelativePath: "../ruffle-evil/stolen.js") == nil)
    }

    /// The `.wasm` MIME type is the single most common way a self-hosted Ruffle
    /// deployment fails: `WebAssembly.instantiateStreaming` rejects anything
    /// that is not `application/wasm`, and a system-inferred type for an
    /// extension it has never met is not that.
    @Test("wasm is served as application/wasm, and the rest of the table holds")
    func mimeTypes() {
        #expect(RenderSchemeHandler.mimeType(forExtension: "wasm") == "application/wasm")
        #expect(RenderSchemeHandler.mimeType(forExtension: "WASM") == "application/wasm")
        #expect(RenderSchemeHandler.mimeType(forExtension: "js") == "text/javascript")
        #expect(RenderSchemeHandler.mimeType(forExtension: "html") == "text/html")
        #expect(
            RenderSchemeHandler.mimeType(forExtension: "swf") == "application/x-shockwave-flash"
        )
        #expect(RenderSchemeHandler.mimeType(forExtension: "zzz") == "application/octet-stream")
    }

    @Test("the host page is a bundled resource and is really there")
    func shimIsBundled() throws {
        let html = try SWFRenderer.shimHTML()
        let text = String(decoding: html, as: UTF8.self)
        #expect(text.contains("latheCapture"))
        #expect(text.contains("latheInit"))
        #expect(text.contains("selftest"))
    }

    // MARK: - The capture plan

    private let stage = SWFRenderStage(
        pixelSize: CGSize(width: 550, height: 400), framesPerSecond: 12, declaredFrameCount: 240
    )

    @Test("the defaults come from the movie's own header")
    func defaultsFollowTheHeader() throws {
        let plan = try SWFRenderOptions().resolved(againstStageOf: stage)
        #expect(plan.framesPerSecond == 12)
        #expect(plan.width == 550)
        #expect(plan.height == 400)
        // 240 frames at 12 fps is 20 seconds, sampled at 12 fps: 240 frames.
        #expect(plan.frameCount == 240)
        #expect(!plan.wasTruncated)
    }

    @Test("a requested rate and size override the header")
    func overridesWin() throws {
        let plan = try SWFRenderOptions(
            framesPerSecond: 30, pixelSize: CGSize(width: 100, height: 80), limit: .seconds(2)
        ).resolved(againstStageOf: stage)
        #expect(plan.framesPerSecond == 30)
        #expect(plan.width == 100)
        #expect(plan.frameCount == 60)
    }

    @Test("an explicit frame count is taken literally")
    func explicitFrameCount() throws {
        let plan = try SWFRenderOptions(limit: .frames(7)).resolved(againstStageOf: stage)
        #expect(plan.frameCount == 7)
    }

    /// Every other stopping condition is arithmetic on numbers **the file
    /// chose**. A movie declaring 65535 frames at 0.1 fps is asking for a
    /// seven-day capture, and the ceiling is what stops that being a job that
    /// looks like a hang.
    @Test("the frame ceiling cuts a capture short, and says that it did")
    func frameCeilingTruncates() throws {
        let greedy = SWFRenderStage(
            pixelSize: CGSize(width: 100, height: 100), framesPerSecond: 0.1,
            declaredFrameCount: 65_535
        )
        let plan = try SWFRenderOptions(maximumFrameCount: 100)
            .resolved(againstStageOf: greedy)
        #expect(plan.frameCount == 100)
        #expect(plan.wasTruncated)
    }

    @Test("a header's absurd frame rate is refused rather than acted on")
    func absurdFrameRateRefused() {
        let broken = SWFRenderStage(
            pixelSize: CGSize(width: 10, height: 10), framesPerSecond: 0, declaredFrameCount: 10
        )
        #expect(throws: LatheError.self) {
            try SWFRenderOptions().resolved(againstStageOf: broken)
        }
        // And the caller is told they can override it, because they can.
        #expect(throws: Never.self) {
            try SWFRenderOptions(framesPerSecond: 12).resolved(againstStageOf: broken)
        }
    }

    @Test("an absurd stage is refused rather than allocated")
    func absurdStageRefused() {
        let huge = SWFRenderStage(
            pixelSize: CGSize(width: 60_000, height: 60_000), framesPerSecond: 12,
            declaredFrameCount: 10
        )
        #expect(throws: LatheError.self) {
            try SWFRenderOptions().resolved(againstStageOf: huge)
        }
        let empty = SWFRenderStage(
            pixelSize: .zero, framesPerSecond: 12, declaredFrameCount: 10
        )
        #expect(throws: LatheError.self) {
            try SWFRenderOptions().resolved(againstStageOf: empty)
        }
    }

    @Test("a nonsensical duration or frame count is refused")
    func nonsensicalLimits() {
        #expect(throws: LatheError.self) {
            try SWFRenderOptions(limit: .seconds(0)).resolved(againstStageOf: stage)
        }
        #expect(throws: LatheError.self) {
            try SWFRenderOptions(limit: .frames(0)).resolved(againstStageOf: stage)
        }
        #expect(throws: LatheError.self) {
            try SWFRenderOptions(maximumFrameCount: 0).resolved(againstStageOf: stage)
        }
    }
}
