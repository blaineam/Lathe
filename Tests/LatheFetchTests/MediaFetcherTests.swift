import AVFoundation
import Foundation
import LatheCore
import Testing

@testable import LatheFetch

/// The `yt-dlp` surface, end to end.
///
/// The default run is offline and asserts the things that hold with nothing
/// installed — which is the state a first launch is in, and therefore a state
/// that has to behave rather than merely fail. Everything that reaches PyPI or a
/// media site is behind `LATHE_FETCH_NETWORK_TESTS=1`, for the reasons the
/// installer suite gives: a default run that needs the network is a run that
/// fails on an aeroplane, behind a proxy, and whenever somebody else's release
/// breaks, none of which is a fact about this package.
@Suite("yt-dlp downloads media")
struct MediaFetcherTests {

    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lathe-fetcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Offline

    @Test("the requirement list is two pure-Python projects and nothing else")
    func requirements() {
        // Everything else in yt-dlp's `default` extra is either a C extension
        // iOS cannot load or something this package does not use. Keeping the
        // list short is what keeps the install honest about what it is doing.
        #expect(MediaFetcher.requirements == ["yt-dlp", "yt-dlp-ejs"])
    }

    @Test("readiness on an interpreter with no yt-dlp says so, rather than failing")
    func readinessWithoutYtDlp() async throws {
        guard let runtime = SharedInterpreter.runtimeOrKnownIssue() else { return }
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let fetcher = MediaFetcher(
            runtime: runtime, installer: PythonPackageInstaller(runtime: runtime, root: root))
        let readiness = try await fetcher.readiness()

        // "Not installed yet" is the ordinary state on a first launch. A
        // throw here would make it look like a broken package.
        #expect(!readiness.isFullyOperational)
        #expect(readiness.developedAgainstVersion == MediaFetcherDriver.developedAgainstVersion)
        #expect(!readiness.report.isEmpty)
        print(readiness.report)
    }

    @Test("extracting with no yt-dlp is a notInstalled error, not a crash")
    func extractWithoutYtDlp() async throws {
        guard let runtime = SharedInterpreter.runtimeOrKnownIssue() else { return }
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        // A root with nothing in it, and deliberately not activated, so the
        // interpreter cannot find yt-dlp however the rest of the suite left it.
        let fetcher = MediaFetcher(
            runtime: runtime, installer: PythonPackageInstaller(runtime: runtime, root: root))
        await fetcher.setConfiguration(MediaFetcher.Configuration())

        // Only meaningful when nothing earlier in the process installed it —
        // the interpreter is shared by the whole suite and never restarts.
        let alreadyThere = (try? await runtime.evaluateDetached("__import__('yt_dlp').__name__")) != nil
        guard !alreadyThere else {
            withKnownIssue("yt-dlp is already imported in this process") {
                Issue.record("cannot test the uninstalled path here")
            }
            return
        }

        let error = await #expect(throws: MediaFetchError.self) {
            try await fetcher.listing(for: URL(string: "https://example.invalid/x")!)
        }
        guard case .notInstalled = error else {
            Issue.record("expected notInstalled, got \(String(describing: error))")
            return
        }
    }

    @Test("progress ticks from Python land on the handle and scale across parts")
    func progressBridgeScalesAcrossParts() {
        // The bridge is exercised directly rather than through a download,
        // because the arithmetic — how two parts share one bar — is the part
        // that can be wrong without anything failing.
        let recorder = FractionRecorder()
        let handle = ProgressHandle(
            sink: ObservingProgressSink { recorder.record($0.fraction) }, throttle: .unthrottled)

        let video = MediaFormat(formatID: "v", byteCount: 900)
        let audio = MediaFormat(formatID: "a", byteCount: 100)
        let token = ProgressBridge.register(
            handle: handle, selection: .pair(video: video, audio: audio), scale: 0.85)
        defer { ProgressBridge.unregister(token) }

        func tick(part: Int, downloaded: Int, total: Int, status: String = "downloading") -> Bool {
            let payload = #"{"token":\#(token),"part":\#(part),"part_count":2,"status":"\#(status)","downloaded_bytes":\#(downloaded),"total_bytes":\#(total)}"#
            return ProgressBridge.deliver(payload)
        }

        #expect(tick(part: 0, downloaded: 450, total: 900))
        #expect(tick(part: 0, downloaded: 900, total: 900, status: "finished"))
        #expect(tick(part: 1, downloaded: 50, total: 100))
        #expect(tick(part: 1, downloaded: 100, total: 100, status: "finished"))

        let fractions = recorder.fractions.compactMap { $0 }
        #expect(fractions.count == 4)
        // The big part is worth nine tenths of the download phase, and the
        // download phase is worth 85% of the job.
        #expect(abs(fractions[0] - 0.9 * 0.5 * 0.85) < 0.001, "got \(fractions[0])")
        #expect(abs(fractions[1] - 0.9 * 0.85) < 0.001, "got \(fractions[1])")
        #expect(abs(fractions[3] - 0.85) < 0.001, "the download phase ends at its share, got \(fractions[3])")
        #expect(
            zip(fractions, fractions.dropFirst()).allSatisfy { $1 >= $0 },
            "progress went backwards: \(fractions)")
    }

    @Test("a sink that says stop is answered with stop, which is what cancels the download")
    func progressBridgeCarriesCancellation() {
        let handle = ProgressHandle(sink: ClosureProgressSink { _ in false }, throttle: .unthrottled)
        let token = ProgressBridge.register(
            handle: handle, selection: .single(MediaFormat(formatID: "a", byteCount: 10)), scale: 1)
        defer { ProgressBridge.unregister(token) }

        let payload = #"{"token":\#(token),"part":0,"part_count":1,"status":"downloading","downloaded_bytes":1,"total_bytes":10}"#
        #expect(!ProgressBridge.deliver(payload), "the return value is the cancellation signal")
    }

    @Test("a tick for a download that has already been abandoned answers stop")
    func progressBridgeRejectsUnknownTokens() {
        // Registration is scoped to one download by the caller's `defer`, so a
        // late tick from an abandoned one finds nothing — and continuing a
        // download whose owner is gone is worse than ending it.
        let payload = #"{"token":999999,"part":0,"part_count":1,"status":"downloading"}"#
        #expect(!ProgressBridge.deliver(payload))
        #expect(!ProgressBridge.deliver("not json at all"))
    }

    @Test("a fragmented stream reports progress in fragments when it has no byte total")
    func progressBridgeUsesFragments() {
        let recorder = FractionRecorder()
        let handle = ProgressHandle(
            sink: ObservingProgressSink { recorder.record($0.fraction) }, throttle: .unthrottled)
        let token = ProgressBridge.register(
            handle: handle, selection: .single(MediaFormat(formatID: "a")), scale: 1)
        defer { ProgressBridge.unregister(token) }

        let payload = #"{"token":\#(token),"part":0,"part_count":1,"status":"downloading","fragment_index":25,"fragment_count":100}"#
        #expect(ProgressBridge.deliver(payload))
        #expect(abs((recorder.fractions.last.flatMap { $0 } ?? 0) - 0.25) < 0.001)
    }

    // MARK: - Against the real thing (network, opt-in)

    @Test(
        "yt-dlp installs, prepares, and reports what works",
        .enabled(if: SharedInterpreter.networkTestsEnabled && SharedInterpreter.isAvailable))
    func installsAndPrepares() async throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let installer = PythonPackageInstaller(runtime: runtime, root: root)
        let store = try await installer.installTrustStore()
        try runtime.useTrustStore(store)

        let fetcher = MediaFetcher(runtime: runtime, installer: installer)

        let plan = try await fetcher.plan()
        print("")
        print(plan.summary)
        print("")
        let planned = plan.steps.map(\.release.canonicalName)
        #expect(planned.contains("yt-dlp"))
        #expect(planned.contains("yt-dlp-ejs"))
        // yt-dlp's own `dependencies` array is empty — everything is an extra —
        // so the graph is exactly the two projects asked for. That is the fact
        // that makes this feasible on a device at all.
        #expect(!planned.contains("pycryptodomex"), "a C extension iOS cannot load")
        #expect(!planned.contains("brotli"), "also a C extension; upstream already excludes it on iOS")

        let installation = try await fetcher.install()
        for package in installation.all {
            print("  installed \(package.name) \(package.version) (\(package.members.count) files)")
        }

        var configuration = MediaFetcher.Configuration()
        configuration.cacheDirectory = root.appendingPathComponent("cache", isDirectory: true)
        await fetcher.setConfiguration(configuration)

        let readiness = try await fetcher.prepare()
        print("")
        print(readiness.report)
        print("")

        #expect(readiness.isInstalled)
        #expect(readiness.version != nil)
        #expect(
            readiness.cryptographyBackend == "pure-python",
            "pycryptodomex is a C extension and is deliberately never installed")
        #expect(readiness.solverScriptsAvailable, "\(readiness.solverScriptsReason ?? "")")
        #expect(
            readiness.javaScriptSolverAvailable,
            "the JS challenge provider did not register: \(readiness.javaScriptUnavailableReason ?? "")")

        if readiness.version != MediaFetcherDriver.developedAgainstVersion {
            print(
                "  note: running yt-dlp \(readiness.version ?? "?"), developed against "
                    + MediaFetcherDriver.developedAgainstVersion)
        }
    }

    @Test(
        "a real extraction returns formats that the selector can act on",
        .enabled(if: SharedInterpreter.networkTestsEnabled && SharedInterpreter.isAvailable))
    func extractsFromYouTube() async throws {
        let fetcher = try await preparedFetcher()
        let listing = try await fetcher.listing(
            for: URL(string: "https://www.youtube.com/watch?v=aqz-KE-bpKQ")!)

        print("  \(listing.title ?? "?") — \(listing.formats.count) formats")
        print("  tallest overall: \(listing.maximumHeight.map(String.init) ?? "?")p")
        print("  tallest pre-muxed: \(listing.maximumPreMuxedHeight.map(String.init) ?? "none at all")")

        #expect(listing.extractor?.lowercased().contains("youtube") == true)
        #expect(!listing.formats.isEmpty)

        let selection = try FormatSelector.select(from: listing, policy: .upTo(height: 720))
        print("  selection at ≤720p: \(selection.summary)")
        #expect((selection.height ?? 0) <= 720)
    }

    @Test(
        "a small file downloads, and the result is playable",
        .enabled(if: SharedInterpreter.networkTestsEnabled && SharedInterpreter.isAvailable))
    func downloadsSomethingSmall() async throws {
        let fetcher = try await preparedFetcher()
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let listing = try await fetcher.listing(
            for: URL(string: "https://www.youtube.com/watch?v=aqz-KE-bpKQ")!)

        // The smallest audio rendition, so the test moves a megabyte rather
        // than a gigabyte. The download path is identical either way.
        var policy = FormatPolicy.audio
        policy.requiresSingleRequestHTTP = true
        let selection = try FormatSelector.select(from: listing, policy: policy)
        print("  downloading \(selection.summary)")

        let samples = FractionRecorder()
        let progress = ProgressHandle(
            sink: ObservingProgressSink { samples.record($0.fraction) }, throttle: .standard)

        let destination = root.appendingPathComponent("audio.\(selection.containerExtension)")
        let result = try await fetcher.download(
            selection, from: listing, to: destination, progress: progress)

        print("  \(result.byteCount) bytes at \(result.url.lastPathComponent)")
        #expect(result.byteCount > 0)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(!result.wasMuxed)
        #expect(samples.fractions.count > 1, "progress was reported more than once")

        // Nothing left over beside it.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".lathe-fetch-") }
        #expect(leftovers.isEmpty, "working directories left behind: \(leftovers)")
    }

    @Test(
        "a video-plus-audio download muxes into one playable file",
        .enabled(if: SharedInterpreter.networkTestsEnabled && SharedInterpreter.isAvailable))
    func downloadsAndMuxes() async throws {
        let fetcher = try await preparedFetcher()
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let listing = try await fetcher.listing(
            for: URL(string: "https://www.youtube.com/watch?v=aqz-KE-bpKQ")!)

        // 144p, so the test downloads the smallest thing that still exercises
        // the two-stream path and the muxer.
        var policy = FormatPolicy.upTo(height: 240)
        policy.requiresSingleRequestHTTP = true
        let selection = try FormatSelector.select(from: listing, policy: policy)
        print("  \(selection.summary)")
        guard selection.needsMuxing else {
            withKnownIssue("this item offered a pre-muxed rendition at this height") {
                Issue.record("nothing to mux")
            }
            return
        }

        let destination = root.appendingPathComponent("joined.mp4")
        let result = try await fetcher.download(selection, from: listing, to: destination)
        #expect(result.wasMuxed)
        #expect(result.byteCount > 0)

        let joined = AVURLAsset(url: destination)
        #expect(try await joined.loadTracks(withMediaType: .video).count == 1)
        #expect(try await joined.loadTracks(withMediaType: .audio).count == 1)
        print("  joined \(result.byteCount) bytes with both tracks")
    }

    @Test(
        "a playlist URL is reported as a playlist rather than half-extracted",
        .enabled(if: SharedInterpreter.networkTestsEnabled && SharedInterpreter.isAvailable))
    func reportsPlaylists() async throws {
        let fetcher = try await preparedFetcher()
        let error = await #expect(throws: MediaFetchError.self) {
            try await fetcher.listing(
                for: URL(string: "https://www.youtube.com/playlist?list=PLbpi6ZahtOH6Blw3RGYpWkSByi_T7Rygb")!)
        }
        guard case let .isPlaylist(_, count) = error else {
            Issue.record("expected isPlaylist, got \(String(describing: error))")
            return
        }
        print("  playlist of \(count) items")
    }

    @Test(
        "an unsupported URL is reported as unsupported",
        .enabled(if: SharedInterpreter.networkTestsEnabled && SharedInterpreter.isAvailable))
    func reportsUnsupportedSites() async throws {
        let fetcher = try await preparedFetcher()
        // The generic extractor claims almost anything, so this asserts only
        // that the failure is mapped rather than escaping as a raw traceback.
        let error = await #expect(throws: MediaFetchError.self) {
            try await fetcher.listing(for: URL(string: "https://lathe.invalid/nothing-here")!)
        }
        print("  \(error?.localizedDescription ?? "")")
    }

    /// A fetcher with `yt-dlp` installed and prepared, shared by the network
    /// tests so they do not each pay for an install.
    private func preparedFetcher() async throws -> MediaFetcher {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let root = try SharedFetcher.root()
        let installer = PythonPackageInstaller(runtime: runtime, root: root)
        let store = try await installer.installTrustStore()
        try runtime.useTrustStore(store)
        let fetcher = MediaFetcher(runtime: runtime, installer: installer)
        _ = try await fetcher.install()

        var configuration = MediaFetcher.Configuration()
        configuration.cacheDirectory = root.appendingPathComponent("cache", isDirectory: true)
        await fetcher.setConfiguration(configuration)
        _ = try await fetcher.prepare()
        return fetcher
    }
}

// MARK: - Helpers

/// One package root for the whole network run.
///
/// The interpreter is shared by the suite and never restarts, so installing
/// `yt-dlp` into a fresh directory per test would leave `sys.path` pointing at
/// directories that no longer exist — and `import yt_dlp` would then be a cache
/// hit on a module whose files are gone.
enum SharedFetcher {
    nonisolated(unsafe) private static var url: URL?
    private static let lock = NSLock()

    static func root() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        if let url { return url }
        let created = FileManager.default.temporaryDirectory
            .appendingPathComponent("lathe-ytdlp-shared", isDirectory: true)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: true)
        url = created
        return created
    }
}

private final class FractionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double?] = []
    func record(_ fraction: Double?) {
        lock.lock()
        storage.append(fraction)
        lock.unlock()
    }
    var fractions: [Double?] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
