import Foundation
import LatheCore
import LatheImage

/// What happened to one input: a line of the tool's JSON output.
struct Report: Codable, Equatable, Sendable {
    enum Status: String, Codable, Sendable {
        /// The output was written.
        case written
        /// The output was not smaller than its source and was discarded
        /// (`--only-if-smaller`).
        case keptSource = "kept-source"
        /// An output already existed (`--skip-existing`).
        case skipped
        /// No quality in the search range passed the threshold; nothing was
        /// written.
        case noQuality = "no-quality"
        case failed
    }

    var source: String
    var output: String
    var status: Status
    var inputBytes: UInt64?
    var outputBytes: UInt64?
    var width: Int?
    var height: Int?
    var quality: Double?
    var ssim: Double?
    var worstRegionSSIM: Double?
    var attempts: Int?
    var seconds: Double?
    var error: String?
}

/// Encodes one input as `options` describe.
struct Job: Sendable {
    let source: URL
    let destination: URL
    let format: ImageFormat
    let quality: Options.Quality
    let resize: ResizeTarget
    let metadata: MetadataPolicy
    let onlyIfSmaller: Bool
    let skipExisting: Bool

    init(source: URL, options: Options) {
        self.source = source
        destination = options.destination(for: source)
        format = options.format
        quality = options.quality
        resize = options.resize
        metadata = options.metadata
        onlyIfSmaller = options.onlyIfSmaller
        skipExisting = options.skipExisting
    }

    func run() async -> Report {
        let started = Date()
        var report = Report(source: source.path, output: destination.path, status: .failed)
        do {
            // An in-place re-encode would compare the result against itself
            // halfway through the search. Refuse it rather than be clever.
            guard destination.standardizedFileURL != source.standardizedFileURL else {
                throw LatheError.invalidConfiguration(
                    reason: "the output would overwrite its source; use --output-dir")
            }
            if skipExisting, FileManager.default.fileExists(atPath: destination.path) {
                report.status = .skipped
                return report
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

            let encoded: ImageEncodeResult
            switch quality {
            case let .fixed(value):
                encoded = try ImageEncoder().encode(ImageEncodeRequest(
                    source: source, destination: destination, format: format,
                    quality: .quality(value), resize: resize, metadata: metadata))
                report.quality = value
            case let .visuallyLossless(search):
                guard let result = try await ImageEncoder().encodeVisuallyLossless(
                    source: source, to: destination, format: format,
                    resize: resize, metadata: metadata, search: search)
                else {
                    report.status = .noQuality
                    report.inputBytes = byteCount(source)
                    report.seconds = Date().timeIntervalSince(started)
                    return report
                }
                encoded = result.encode
                report.quality = result.quality
                report.ssim = result.similarity.overall
                report.worstRegionSSIM = result.similarity.worstRegion
                report.attempts = result.attempts.count
            }

            report.inputBytes = encoded.inputByteCount
            report.outputBytes = encoded.outputByteCount
            report.width = encoded.pixelSize.width
            report.height = encoded.pixelSize.height
            if onlyIfSmaller, encoded.outputByteCount >= encoded.inputByteCount {
                try FileManager.default.removeItem(at: destination)
                report.status = .keptSource
            } else {
                report.status = .written
            }
        } catch {
            report.status = .failed
            report.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
        report.seconds = Date().timeIntervalSince(started)
        return report
    }

    private func byteCount(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value
    }
}

/// Runs `jobs` with at most `width` in flight, handing each report to
/// `deliver` as it completes (not in input order).
func runAll(
    _ jobs: [Job], width: Int,
    isolation: isolated (any Actor)? = #isolation,
    deliver: (Report) -> Void
) async {
    await withTaskGroup(of: Report.self) { group in
        var pending = jobs.makeIterator()
        for _ in 0..<max(1, width) {
            guard let job = pending.next() else { break }
            group.addTask { await job.run() }
        }
        for await report in group {
            deliver(report)
            if let job = pending.next() {
                group.addTask { await job.run() }
            }
        }
    }
}
