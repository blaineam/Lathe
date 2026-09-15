import Foundation
import LatheAudio
import LatheCore
import LatheDoc
import LatheImage
import LatheMeta
import LatheVideo

/// Runs the queue.
///
/// Work is placed through ``BulkRun``, so the app inherits the library's own
/// lane policy rather than inventing one: two videos at a time because the Mac
/// has a small fixed number of encoders, images scaled to the cores, and the
/// whole pool shrinking when the machine is hot or on battery.
@MainActor
@Observable
final class Runner {
    var jobs: [Job] = []
    var operation: Operation = .compress
    var isRunning = false
    /// Where results go. `nil` means beside the original.
    var destinationDirectory: URL?
    var lastSummary: String?

    private let pool = ResourcePool.automatic

    func add(_ urls: [URL]) {
        for url in urls where !jobs.contains(where: { $0.source == url }) {
            let job = Job(source: url)
            job.kind = MediaKind.of(url)
            jobs.append(job)
        }
    }

    func clear() {
        guard !isRunning else { return }
        jobs.removeAll()
        lastSummary = nil
    }

    func run() async {
        guard !isRunning, !jobs.isEmpty else { return }
        isRunning = true
        defer { isRunning = false }

        let operation = self.operation
        let destination = self.destinationDirectory
        let started = Date()

        let items = jobs.map { job in
            BulkRun.Item(job, workload: job.kind.workload)
        }

        let report = await BulkRun(pool: pool).run(items) { job in
            await MainActor.run { job.state = .running(fraction: 0) }
            do {
                let summary = try await Self.perform(operation, on: job, into: destination)
                await MainActor.run { job.state = .done(summary: summary) }
            } catch {
                let message = (error as? LatheError)?.errorDescription ?? "\(error)"
                await MainActor.run { job.state = .failed(message) }
            }
        }

        let done = jobs.filter { if case .done = $0.state { return true } else { return false } }
        let failed = report.failures.count
        let elapsed = Date().timeIntervalSince(started)
        lastSummary = "\(done.count) of \(jobs.count) in \(String(format: "%.1f", elapsed))s"
            + (failed > 0 ? ", \(failed) failed" : "")
    }

    // MARK: - The work

    private nonisolated static func perform(
        _ operation: Operation, on job: Job, into directory: URL?
    ) async throws -> String {
        let source = await job.source
        let kind = await job.kind

        switch operation {
        case .inspect:
            return try await inspect(source, kind: kind)

        case .stripLocation:
            let output = try destination(for: source, suffix: "-no-location", into: directory)
            let result = try await MetadataWriter().update(source, writingTo: output) {
                $0.location = nil
            }
            await MainActor.run {
                job.outputURL = output
                job.outputBytes = Int(result.outputByteCount)
            }
            return "location removed, nothing re-encoded"

        case .compress:
            return try await compress(source, kind: kind, job: job, into: directory)
        }
    }

    private nonisolated static func compress(
        _ source: URL, kind: MediaKind, job: Job, into directory: URL?
    ) async throws -> String {
        switch kind {
        case .video:
            let output = try destination(for: source, suffix: "-hevc", extension: "mov", into: directory)
            let result = try await VideoTranscoder().transcode(
                source: source, to: output, codec: .hevc, quality: .quality(0.65)
            )
            await MainActor.run {
                job.outputURL = output
                job.outputBytes = Int(result.outputByteCount)
            }
            var note = "HEVC \(result.pixelSize.width)×\(result.pixelSize.height)"
            if result.preservedChapterCount > 0 {
                note += ", \(result.preservedChapterCount) chapters kept"
            }
            return note

        case .image:
            let output = try destination(for: source, suffix: "-heic", extension: "heic", into: directory)
            let result = try await ImageEncoder().encode(
                source: source, to: output, format: .heic, quality: .quality(0.8)
            )
            await MainActor.run {
                job.outputURL = output
                job.outputBytes = Int(result.outputByteCount)
            }
            return "HEIC \(result.pixelSize.width)×\(result.pixelSize.height)"

        case .audio:
            let output = try destination(for: source, suffix: "-aac", extension: "m4a", into: directory)
            let result = try await AudioTranscoder().transcode(
                source: source, to: output, codec: .aac, quality: .quality(0.6)
            )
            await MainActor.run {
                job.outputURL = output
                job.outputBytes = Int(result.outputByteCount)
            }
            guard result.outcome.wasTranscoded else {
                // A skip is a decision the library made on purpose — re-encoding
                // an already-lossy file to save nothing is the trap the rule
                // exists to avoid — so it is reported rather than hidden.
                return "left alone: \(result.outcome)"
            }
            var note = "AAC"
            if result.preservedChapterCount > 0 {
                note += ", \(result.preservedChapterCount) chapters kept"
            }
            return note

        case .document, .unknown:
            throw LatheError.invalidInput(
                reason: "\(source.lastPathComponent) is not something this can compress yet"
            )
        }
    }

    private nonisolated static func inspect(_ source: URL, kind: MediaKind) async throws -> String {
        switch kind {
        case .video, .audio:
            let info = try await MediaProbe().probe(url: source)
            let metadata = try? await MetadataReader().read(source)
            var parts = ["\(String(format: "%.1f", info.duration))s"]
            if info.hasVideoTrack { parts.append("video") }
            if info.hasAudioTrack { parts.append("audio") }
            if let title = metadata?.title { parts.append("“\(title)”") }
            return parts.joined(separator: ", ")

        case .image:
            let metadata = try await MetadataReader().read(source)
            var parts: [String] = []
            if let title = metadata.title { parts.append("“\(title)”") }
            if metadata.location != nil { parts.append("has location") }
            if let date = metadata.date {
                parts.append(date.formatted(date: .abbreviated, time: .omitted))
            }
            return parts.isEmpty ? "no metadata" : parts.joined(separator: ", ")

        case .document:
            let info = try DocumentInspector().inspect(source)
            return "\(info.kind), \(info.pageCount) page(s)"

        case .unknown:
            let store = try MetadataReader().store(of: source)
            return "\(store)"
        }
    }

    /// Where a result goes, never overwriting the input.
    private nonisolated static func destination(
        for source: URL, suffix: String, extension newExtension: String? = nil, into directory: URL?
    ) throws -> URL {
        let folder = directory ?? source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent + suffix
        let ext = newExtension ?? source.pathExtension
        var candidate = folder.appendingPathComponent(base).appendingPathExtension(ext)

        // Never clobber. A batch run twice should produce a second file, not
        // quietly replace the first — the user can delete, the app cannot undo.
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)-\(counter)").appendingPathExtension(ext)
            counter += 1
        }
        return candidate
    }
}

private extension MediaKind {
    /// Which pool lane this contends for.
    var workload: Workload {
        switch self {
        case .video: return .video
        case .image: return .image
        case .audio: return .audio
        case .document: return .document
        case .unknown: return .document
        }
    }
}
