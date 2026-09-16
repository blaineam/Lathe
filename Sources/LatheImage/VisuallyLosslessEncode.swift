import Foundation
import LatheCore

/// A still encoded at the lowest quality that still looks like its source.
public struct VisuallyLosslessImageResult: Sendable, Equatable {
    public var encode: ImageEncodeResult
    /// The quality that was chosen.
    public var quality: Double
    public var similarity: VisualSimilarity
    /// Every quality tried, in order.
    public var attempts: [QualitySearch.Attempt]
}

extension ImageEncoder {

    /// Encodes `source` at the lowest quality whose result cannot be told
    /// apart from it, chosen for this picture alone.
    ///
    /// Each quality the search tries is encoded to a scratch file beside
    /// `destination` and compared with the source at the output's size; only
    /// the chosen one is moved into place. A busy photograph usually settles
    /// lower than a smooth one — that is the point of deciding per picture.
    ///
    /// - Returns: `nil` when nothing in `search.range` stays within
    ///   `search.threshold`. Nothing is written in that case, and whatever was
    ///   at `destination` is untouched.
    /// - Throws: whatever ``encode(_:progress:)`` throws, and
    ///   ``LatheError/cancelled(atUnit:)``.
    public func encodeVisuallyLossless(
        source: URL,
        to destination: URL,
        format: ImageFormat,
        resize: ResizeTarget = .none,
        metadata: MetadataPolicy = .preserveAll,
        orientation: OrientationStrategy = .preserveTag,
        forcePreserve: MetadataForcePreserve = .default,
        search: QualitySearch = QualitySearch(),
        progress: ProgressHandle = .ignoring()
    ) async throws -> VisuallyLosslessImageResult? {
        let reference = try VisualComparison.Reference(url: source)
        let directory = destination.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var scratch: [URL] = []
        defer { for url in scratch { try? FileManager.default.removeItem(at: url) } }

        let outcome = try await search.run(progress: progress) { quality in
            let candidate = directory.appendingPathComponent(
                ".lathe-\(UUID().uuidString).\(format.preferredFilenameExtension)")
            scratch.append(candidate)
            let result = try encode(ImageEncodeRequest(
                source: source, destination: candidate, format: format,
                quality: .quality(quality), resize: resize, metadata: metadata,
                forcePreserve: forcePreserve, orientation: orientation))
            return ((candidate, result), try reference.similarity(ofImageAt: candidate))
        }

        guard let (chosen, result) = outcome.output, let quality = outcome.value,
              let similarity = outcome.similarity
        else { return nil }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: chosen)
            } else {
                try FileManager.default.moveItem(at: chosen, to: destination)
            }
        } catch {
            throw LatheError.writeFailed(
                path: destination.lastPathComponent, reason: (error as NSError).localizedDescription)
        }
        var encoded = result
        encoded.output = destination
        return VisuallyLosslessImageResult(
            encode: encoded, quality: quality, similarity: similarity, attempts: outcome.attempts)
    }
}
