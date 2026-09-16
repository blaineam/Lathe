@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import LatheCore
import LatheImage

/// Finds the lowest setting at which a video still looks like its source,
/// without encoding the whole video once per guess.
///
/// A few short clips are cut from the source — passthrough, so nothing is
/// re-encoded to get them — and every candidate setting encodes only those.
/// Frames from each encoded clip are compared with the same frames of the
/// clip it came from, and a setting passes only if every compared frame does.
/// The caller then encodes the whole video once, at the value found.
///
/// The encode is the caller's: a hardware transcode at a quality, SVT-AV1 at
/// a bitrate — whatever turns a value in ``QualitySearch/range`` into a
/// file, where a higher value means a more faithful one.
public struct VideoQualitySearch: Sendable, Equatable {
    public var search: QualitySearch
    /// How many clips to cut, spread across the video.
    public var sampleCount: Int
    /// How long each clip is.
    public var sampleSeconds: Double
    /// How many frames of each clip are compared.
    public var framesPerSample: Int

    public init(
        search: QualitySearch = QualitySearch(range: 0.05...1, maximumAttempts: 6),
        sampleCount: Int = 3,
        sampleSeconds: Double = 2,
        framesPerSample: Int = 3
    ) {
        self.search = search
        self.sampleCount = max(1, sampleCount)
        self.sampleSeconds = max(0.5, sampleSeconds)
        self.framesPerSample = max(1, framesPerSample)
    }

    /// Runs the search.
    ///
    /// - Parameters:
    ///   - asset: the video.
    ///   - scratchDirectory: where clips and their encodes are written. They
    ///     are removed before this returns.
    ///   - encodeSample: encodes `sample` at `value` into `output`, which has
    ///     the same extension as the file the caller will finally write.
    /// - Returns: the value found, or an outcome with ``QualitySearch/Outcome/found``
    ///   false when nothing in range looked like the source.
    public func run(
        asset: AVAsset,
        outputExtension: String,
        scratchDirectory: URL = FileManager.default.temporaryDirectory,
        progress: ProgressHandle = .ignoring(),
        encodeSample: @escaping @Sendable (_ sample: URL, _ value: Double, _ output: URL) async throws -> Void
    ) async throws -> QualitySearch.Outcome<Double> {
        let workspace = scratchDirectory.appendingPathComponent("lathe-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
            throw LatheError.invalidInput(reason: "there is no video track to compare")
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw LatheError.invalidInput(reason: "the video has no duration")
        }

        // The clips, and the reference frames from each, prepared once.
        var clips: [(url: URL, times: [CMTime], frames: [CGImage])] = []
        for (index, range) in Self.sampleRanges(
            duration: duration, count: sampleCount, seconds: sampleSeconds).enumerated() {
            let url = workspace.appendingPathComponent("clip-\(index).mov")
            try await Self.cut(asset, range: range, to: url)
            let clipDuration = try await AVURLAsset(url: url).load(.duration).seconds
            let times = (0..<framesPerSample).map { frame in
                CMTime(seconds: clipDuration * (Double(frame) + 0.5) / Double(framesPerSample),
                       preferredTimescale: 600)
            }
            let frames = try await Self.frames(of: AVURLAsset(url: url), at: times)
            clips.append((url, times, frames))
        }

        let outcome = try await search.run(progress: progress) { value -> (output: Double, similarity: VisualSimilarity) in
            var verdict: VisualSimilarity?
            for (index, clip) in clips.enumerated() {
                let output = workspace.appendingPathComponent("encoded-\(index)-\(UUID().uuidString).\(outputExtension)")
                defer { try? FileManager.default.removeItem(at: output) }
                try await encodeSample(clip.url, value, output)
                let encoded = try await Self.frames(of: AVURLAsset(url: output), at: clip.times)
                for (reference, candidate) in zip(clip.frames, encoded) {
                    let similarity = try VisualComparison.similarity(of: candidate, to: reference)
                    verdict = verdict.map { $0.combined(with: similarity) } ?? similarity
                }
                // One failing clip decides it; the rest would only cost time.
                if let verdict, !verdict.meets(search.threshold) { break }
            }
            guard let verdict else {
                throw LatheError.encodingFailed(stage: "search", code: nil, reason: "no frames were compared")
            }
            return (value, verdict)
        }
        return outcome
    }

    // MARK: - Internals

    /// Evenly spread windows, or the whole video when it is too short to
    /// split.
    static func sampleRanges(duration: Double, count: Int, seconds: Double) -> [CMTimeRange] {
        let timescale: CMTimeScale = 600
        if duration <= Double(count) * seconds * 1.5 {
            return [CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: timescale))]
        }
        return (0..<count).map { index in
            let centre = duration * (Double(index) + 0.5) / Double(count)
            let start = min(max(centre - seconds / 2, 0), duration - seconds)
            return CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: timescale),
                duration: CMTime(seconds: seconds, preferredTimescale: timescale))
        }
    }

    static func cut(_ asset: AVAsset, range: CMTimeRange, to url: URL) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw LatheError.encodingFailed(stage: "sample", code: nil, reason: "no passthrough export for this asset")
        }
        session.timeRange = range
        do {
            if #available(macOS 15, iOS 18, *) {
                try await session.export(to: url, as: .mov)
            } else {
                session.outputURL = url
                session.outputFileType = .mov
                await session.export()
                if let error = session.error { throw error }
            }
        } catch {
            throw LatheError.encodingFailed(
                stage: "sample", code: nil, reason: "could not cut a clip: \(error.localizedDescription)")
        }
    }

    static func frames(of asset: AVAsset, at times: [CMTime]) async throws -> [CGImage] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var images: [CGImage] = []
        for time in times {
            do {
                images.append(try await generator.image(at: time).image)
            } catch {
                throw LatheError.encodingFailed(
                    stage: "compare", code: nil,
                    reason: "could not read a frame at \(time.seconds)s: \(error.localizedDescription)")
            }
        }
        return images
    }
}
