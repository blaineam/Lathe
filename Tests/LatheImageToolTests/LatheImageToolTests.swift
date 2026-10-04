#if os(macOS)
import CoreGraphics
import Foundation
import ImageIO
import LatheCore
import LatheImage
import Testing

@testable import LatheImageTool

@Suite("lathe-image arguments")
struct OptionsTests {

    @Test("the defaults search for a visually lossless AVIF")
    func defaults() throws {
        let options = try Options.parse(["a.jpg"])
        #expect(options.format == .avif)
        #expect(options.quality == .visuallyLossless(QualitySearch()))
        #expect(options.resize == .none)
        #expect(options.metadata == .preserveAll)
        #expect(options.inputs.map(\.lastPathComponent) == ["a.jpg"])
    }

    @Test("search flags tune the search")
    func searchFlags() throws {
        let options = try Options.parse([
            "--min-ssim", "0.97", "--min-region-ssim", "0.92", "--range", "0.3-0.9", "a.jpg",
        ])
        let expected = QualitySearch(
            threshold: VisualThreshold(minimumSimilarity: 0.97, minimumRegionSimilarity: 0.92),
            range: 0.3...0.9)
        #expect(options.quality == .visuallyLossless(expected))
    }

    @Test("a fixed quality replaces the search, and refuses search flags")
    func fixedQuality() throws {
        #expect(try Options.parse(["--quality", "0.6", "a.png"]).quality == .fixed(0.6))
        #expect(throws: Options.UsageError.self) {
            try Options.parse(["--quality", "0.6", "--min-ssim", "0.9", "a.png"])
        }
    }

    @Test("sizes, metadata, jobs and switches")
    func flags() throws {
        let options = try Options.parse([
            "--max-side", "2048", "--metadata", "strip", "--jobs", "3",
            "--only-if-smaller", "--skip-existing", "--format", "HEIC", "a.png",
        ])
        #expect(options.resize == .longestSide(2048))
        #expect(options.metadata == .stripAll)
        #expect(options.jobs == 3)
        #expect(options.onlyIfSmaller && options.skipExisting)
        #expect(options.format == .heic)
        #expect(try Options.parse(["--metadata", "strip-location", "a"]).metadata == .stripLocation)
    }

    @Test("bad input is a usage error, not a crash", arguments: [
        [], ["--format", "bmp", "a"], ["--quality", "2", "a"], ["--range", "0.9-0.1", "a"],
        ["--max-side", "0", "a"], ["--jobs", "x", "a"], ["--bogus", "a"], ["--metadata", "some", "a"],
        ["--base", "/tmp", "a"], ["--quality"],
    ])
    func usageErrors(arguments: [String]) {
        #expect(throws: Options.UsageError.self) { try Options.parse(arguments) }
    }

    @Test("a dash reads more paths from standard input")
    func standardInput() throws {
        let options = try Options.parse(["a.jpg", "-"], readStandardInput: { ["b.jpg", "c d.png"] })
        #expect(options.inputs.map(\.lastPathComponent) == ["a.jpg", "b.jpg", "c d.png"])
    }

    @Test("outputs land beside the source, or mirrored under --output-dir")
    func destinations() throws {
        let beside = try Options.parse(["/site/slides/one.jpg"])
        #expect(beside.destination(for: URL(fileURLWithPath: "/site/slides/one.jpg")).path
                == "/site/slides/one.avif")

        let mirrored = try Options.parse(["--output-dir", "/out", "--base", "/site", "x"])
        #expect(mirrored.destination(for: URL(fileURLWithPath: "/site/panos/p/two.png")).path
                == "/out/panos/p/two.avif")
        // Outside the base, only the name is kept.
        #expect(mirrored.destination(for: URL(fileURLWithPath: "/elsewhere/three.jpg")).path
                == "/out/three.avif")
        // A base given with a trailing slash means the same thing.
        let slashed = try Options.parse(["--output-dir", "/out", "--base", "/site/", "--format", "jpeg", "x"])
        #expect(slashed.destination(for: URL(fileURLWithPath: "/site/a/b.png")).path == "/out/a/b.jpg")
    }
}

@Suite("lathe-image jobs")
struct JobTests {

    static func withPicture(
        width: Int = 301, height: Int = 201, _ body: (URL, URL) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lathe-image-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for x in 0..<width {
            let t = CGFloat(x) / CGFloat(width)
            context.setFillColor(CGColor(red: t, green: 0.4, blue: 1 - t, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        let image = try #require(context.makeImage())
        let source = directory.appendingPathComponent("picture.png")
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        try await body(directory, source)
    }

    @Test("a fixed-quality job writes and reports",
          .enabled(if: EncodeSupport.shared.canEncode(.avif)))
    func fixed() async throws {
        try await Self.withPicture { directory, source in
            let options = try Options.parse(["--quality", "0.6", source.path])
            let report = await Job(source: source, options: options).run()
            #expect(report.status == .written, "\(report.error ?? "")")
            #expect(report.output == directory.appendingPathComponent("picture.avif").path)
            // Even dimensions: the library's AVIF rule, reported as written.
            #expect(report.width == 300 && report.height == 200)
            #expect(report.quality == 0.6)
            #expect((report.outputBytes ?? 0) > 0)
            #expect(FileManager.default.fileExists(atPath: report.output))
        }
    }

    @Test("a search job reports what it settled on",
          .enabled(if: EncodeSupport.shared.canEncode(.avif)))
    func search() async throws {
        try await Self.withPicture { _, source in
            let options = try Options.parse(["--metadata", "strip", source.path])
            let report = await Job(source: source, options: options).run()
            #expect(report.status == .written, "\(report.error ?? "")")
            let ssim = try #require(report.ssim)
            #expect(ssim >= VisualThreshold.visuallyLossless.minimumSimilarity)
            #expect(report.quality != nil && (report.attempts ?? 0) > 0)
        }
    }

    @Test("--skip-existing leaves an output alone")
    func skipExisting() async throws {
        try await Self.withPicture { directory, source in
            let existing = directory.appendingPathComponent("picture.avif")
            try Data("keep".utf8).write(to: existing)
            let options = try Options.parse(["--skip-existing", source.path])
            let report = await Job(source: source, options: options).run()
            #expect(report.status == .skipped)
            #expect(try Data(contentsOf: existing) == Data("keep".utf8))
        }
    }

    @Test("--only-if-smaller discards an output that grew",
          .enabled(if: EncodeSupport.shared.canEncode(.heic)))
    func onlyIfSmaller() async throws {
        // A flat 16 × 16 PNG is a few dozen bytes; no HEIC container is that small.
        try await Self.withPicture(width: 16, height: 16) { directory, source in
            let options = try Options.parse(["--only-if-smaller", "--format", "heic", "--quality", "0.9", source.path])
            let report = await Job(source: source, options: options).run()
            #expect(report.status == .keptSource, "\(report)")
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("picture.heic").path))
        }
    }

    @Test("an output that would overwrite its source is refused")
    func refusesInPlace() async throws {
        try await Self.withPicture { _, source in
            let before = try Data(contentsOf: source)
            let options = try Options.parse(["--format", "png", source.path])
            let report = await Job(source: source, options: options).run()
            #expect(report.status == .failed)
            #expect(report.error?.contains("overwrite its source") == true)
            #expect(try Data(contentsOf: source) == before)
        }
    }

    @Test("a missing file fails its own job and no other")
    func missing() async throws {
        try await Self.withPicture { directory, source in
            let options = try Options.parse(["--quality", "0.5", "--format", "jpeg", source.path])
            let missing = directory.appendingPathComponent("nope.png")
            var reports: [Report] = []
            await runAll(
                [Job(source: missing, options: options), Job(source: source, options: options)],
                width: 2
            ) { reports.append($0) }
            #expect(reports.count == 2)
            #expect(reports.first { $0.source == missing.path }?.status == .failed)
            #expect(reports.first { $0.source == source.path }?.status == .written)
        }
    }

    @Test("the summary totals only what was written")
    func summary() {
        var summary = Summary()
        summary.add(Report(source: "a", output: "a.avif", status: .written, inputBytes: 1000, outputBytes: 400))
        summary.add(Report(source: "b", output: "b.avif", status: .keptSource, inputBytes: 10, outputBytes: 20))
        summary.add(Report(source: "c", output: "c.avif", status: .failed, error: "x"))
        #expect(summary.failed == 1)
        #expect(summary.inputBytes == 1000 && summary.outputBytes == 400)
        #expect(summary.description.hasPrefix("1 written, 1 kept-source, 1 failed"))
        #expect(summary.description.contains("60.0% smaller"))
    }
}

#endif
