#if canImport(AVFoundation)
import AVFoundation
import CoreMedia
import Foundation
import LatheCore

/// Puts a chapter list into a file, replaces one, or removes one — **without
/// re-encoding a single video or audio sample.**
///
/// ## Why a remux and not a metadata write
///
/// A chapter list is not metadata. In an MP4-family file it is a separate
/// `tx3g` text track tied to the picture (or the sound) by a `chap` track
/// reference — see ``LatheCore/ChapterTrack`` — so changing it means writing a
/// new container with a different set of tracks. ``MetadataWriter`` has no
/// chapter field for exactly that reason.
///
/// So this copies every video, audio and subtitle track sample for sample,
/// with its language, transform, enabled state and alternate group, carries the
/// file's tags, and adds the new chapter track. It is the same remux
/// ``SubtitleMuxer`` uses (``TrackRemux``), with a chapter list in place of new
/// subtitles — and unlike subtitles, it needs no picture: an audiobook's
/// chapters hang off its sound.
///
/// ## What is not carried
///
/// Per-chapter artwork: ``LatheCore/ChapterTrack`` writes titles only. Text
/// tracks other than the old chapter list, which no player shows. Anything
/// else the destination refuses is named in ``ChapterWriteResult/droppedTracks``;
/// a refused video or audio track fails the write instead, because a chapter
/// edit that quietly removed the picture would be worse than none.
public struct ChapterWriter: Sendable {

    /// The file types an `.mp4` is tried as, in order. See `write`.
    ///
    /// Internal and settable only so a test can go straight to the fallback:
    /// the machines that need it are the ones that do not reproduce the bug on
    /// demand, so without this the fallback's output would be verified only by
    /// whichever CI runner happens to lose the tags.
    var mp4FileTypes: [AVFileType] = [.mp4, .m4v]

    public init() {}

    /// The containers a chapter track can be written into, by extension.
    ///
    /// `.m4b` is absent although it is the audiobook extension: AVFoundation
    /// has no file type for it, and writing one as `.m4a` under the `.m4b` name
    /// would change what the file claims to be without saying so.
    public static let supportedExtensions: [String: AVFileType] = [
        "mp4": .mp4, "m4v": .m4v, "mov": .mov, "qt": .mov, "m4a": .m4a,
    ]

    // MARK: - Support

    /// Whether a file of this name can be given chapters, and a sentence saying
    /// why not when it cannot. Decided from the extension, before anything is
    /// read, so a picker can grey out a file without opening it.
    public static func support(for url: URL) -> ChapterSupport {
        let ext = url.pathExtension.lowercased()
        if supportedExtensions[ext] != nil { return .supported }

        let reason: String
        switch ext {
        case "m4b":
            reason = "AVFoundation has no file type for .m4b, so a chapter track cannot be written "
                + "into one. Rename it to .m4a to edit its chapters."
        case "mp3":
            reason = "MP3 chapters are ID3 CHAP frames, not a track, and LatheMeta does not write them. "
                + "Chapters can be written into MP4, M4V, MOV and M4A files."
        case "mkv", "webm":
            reason = "Apple's frameworks do not write Matroska or WebM. "
                + "Chapters can be written into MP4, M4V, MOV and M4A files."
        case "wav", "aif", "aiff", "caf", "flac", "aac", "ac3":
            reason = "A .\(ext) file has nowhere to put a chapter track. "
                + "Chapters can be written into MP4, M4V, MOV and M4A files."
        case "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff", "gif", "webp", "avif", "pdf":
            reason = "Only video and audio have chapters; there is no timeline in a .\(ext) file to mark."
        case "":
            reason = "A file with no extension cannot be given chapters, because the container "
                + "is chosen by the extension. Use .mp4, .m4v, .mov or .m4a."
        default:
            reason = "Chapters can only be written into MP4, M4V, MOV and M4A files, not .\(ext)."
        }
        return .unsupported(reason: reason)
    }

    // MARK: - Reading

    /// The chapters a file has, in start order. Empty for a file with none,
    /// and for a file AVFoundation cannot read.
    public func read(from url: URL) async throws -> [Chapter] {
        try MetaFiles.requireReadableFile(at: url)
        return await ChapterTrack.read(from: AVURLAsset(url: url))
            .sorted { $0.startSeconds < $1.startSeconds }
    }

    // MARK: - Writing

    /// Writes `source` to `destination` with exactly `chapters` as its chapter
    /// list, and everything else copied.
    ///
    /// - Parameters:
    ///   - chapters: the new list, replacing any the file has. An empty list
    ///     removes them. The list is sorted, overlaps are trimmed, and the last
    ///     chapter is clipped to the file — see
    ///     `normalisedChapters(totalDuration:)`.
    ///   - destination: its extension chooses the container; see
    ///     ``support(for:)``. Must not be `source`.
    ///   - progress: reported against the file's duration under the stage
    ///     `"chapters"`; cancellation is honoured at every sample.
    /// - Throws: ``ChapterError`` for anything about the chapters or the
    ///   container, ``LatheCore/LatheError/cancelled(atUnit:)`` on
    ///   cancellation. `destination` is untouched unless the write succeeds.
    @discardableResult
    public func write(
        _ chapters: [Chapter],
        into source: URL,
        writingTo destination: URL,
        progress: ProgressHandle = .ignoring()
    ) async throws -> ChapterWriteResult {
        try await write(chapters, into: source, writingTo: destination, metadata: nil, progress: progress)
    }

    /// The write, with the file-level tags optionally given rather than copied
    /// from `source` — which is how ``MetadataWriter`` restores chapters a
    /// passthrough export dropped.
    func write(
        _ chapters: [Chapter],
        into source: URL,
        writingTo destination: URL,
        metadata: [AVMetadataItem]?,
        progress: ProgressHandle
    ) async throws -> ChapterWriteResult {
        try MetaFiles.requireReadableFile(at: source)
        guard source.standardizedFileURL.resolvingSymlinksInPath()
                != destination.standardizedFileURL.resolvingSymlinksInPath() else {
            throw ChapterError.destinationIsSource(destination.lastPathComponent)
        }
        let ext = destination.pathExtension.lowercased()
        guard let fileType = Self.supportedExtensions[ext] else {
            throw ChapterError.unsupportedContainer(
                ext.isEmpty ? destination.lastPathComponent : "." + ext,
                reason: Self.support(for: destination).reason ?? ""
            )
        }

        let asset = AVURLAsset(url: source)
        let tracks: [AVAssetTrack]
        let duration: CMTime
        let tags: [AVMetadataItem]
        do {
            tracks = try await asset.load(.tracks)
            duration = try await asset.load(.duration)
            if let metadata {
                tags = metadata
            } else {
                tags = try await asset.load(.metadata)
            }
        } catch {
            throw LatheError.readFailed(
                path: source.lastPathComponent, reason: (error as NSError).localizedDescription
            )
        }
        guard tracks.contains(where: { $0.mediaType == .video || $0.mediaType == .audio }) else {
            throw ChapterError.noMediaTrack(source.lastPathComponent)
        }

        let scratch = TrackRemux.scratchURL(beside: destination, prefix: ".lathe-chapters-")
        defer { try? FileManager.default.removeItem(at: scratch) }

        // An `.mp4` is written as `.mp4` first, and as an M4V-branded file only
        // if that loses the tags.
        //
        // AVAssetWriter's handling of iTunes-style tags in the MPEG-4 file type
        // is not the same on every OS. On macOS 27 an `.mp4` keeps them; on
        // macOS 26 the same call keeps the title and silently drops the
        // artist, the artwork, the track and the episode number — found on the
        // CI runner, not on the machine the code was written on. The M4V file
        // type keeps them everywhere. It is the same ISO container with a
        // different brand, which every player that reads MP4 reads, and the
        // file keeps its `.mp4` name. Checking rather than always choosing M4V
        // means a system that writes MP4 correctly keeps MP4's own brand.
        let attempts = fileType == .mp4 ? mp4FileTypes : [fileType]

        var dropped: [String] = []
        var list: [Chapter] = []
        for (index, attempt) in attempts.enumerated() {
            try? FileManager.default.removeItem(at: scratch)
            let written: Int
            let failure: String?
            do {
                let remux = try TrackRemux(
                    asset: asset, duration: duration, writingTo: scratch, fileType: attempt,
                    metadata: tags, stage: "chapters", progress: progress
                )
                try await remux.copyTracks()
                guard !remux.droppedMedia else {
                    throw ChapterError.mediaRefused(
                        remux.dropped.joined(separator: "; ")
                    )
                }
                if !chapters.isEmpty, let reason = remux.attachChapters(chapters).reason {
                    throw ChapterError.refused(reason)
                }
                remux.groupTracks()
                list = remux.chaptersToWrite
                (written, failure) = try await remux.run()
                dropped = remux.dropped
            } catch let failure as TrackRemux.Failure {
                throw ChapterError.writeFailed(stage: failure.stage, reason: failure.reason)
            }
            guard written == list.count else {
                throw ChapterError.incomplete(written: written, expected: list.count, reason: failure)
            }

            let isLastAttempt = index == attempts.count - 1
            if isLastAttempt { break }
            if await TagSurvival.allKept(tags, in: scratch) { break }
        }

        try TrackRemux.moveIntoPlace(scratch, at: destination)

        let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
        return ChapterWriteResult(
            output: destination,
            chapters: list,
            droppedTracks: dropped,
            outputByteCount: UInt64(bytes)
        )
    }
}

// MARK: - Public types

/// Whether a container can hold chapters.
public enum ChapterSupport: Sendable, Equatable {
    case supported
    /// Not this container, with a sentence that can be shown as it is.
    case unsupported(reason: String)

    public var isSupported: Bool { self == .supported }

    public var reason: String? {
        if case .unsupported(let reason) = self { return reason }
        return nil
    }
}

/// What a chapter write produced.
public struct ChapterWriteResult: Sendable, Equatable {
    public var output: URL
    /// The chapters written, after normalisation: sorted, overlaps trimmed,
    /// clipped to the file. Empty when the write removed them.
    public var chapters: [Chapter]
    /// Tracks from the source that are not in the output, each with the
    /// reason. Empty for any ordinary MP4, MOV or M4A.
    public var droppedTracks: [String]
    public var outputByteCount: UInt64
}

/// What goes wrong writing chapters, separated by what the person should do
/// next — the same shape as ``SubtitleError``.
public enum ChapterError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {

    /// The destination is not a container a chapter track can be written
    /// into. `reason` is ``ChapterWriter/support(for:)``'s sentence.
    case unsupportedContainer(String, reason: String)

    /// The source has neither video nor audio, so there is no timeline to mark.
    case noMediaTrack(String)

    /// The destination is the source.
    case destinationIsSource(String)

    /// The destination container will not hold the source's picture or sound.
    case mediaRefused(String)

    /// The writer would not take a chapter track.
    case refused(String)

    /// Fewer chapters went in than were asked for.
    case incomplete(written: Int, expected: Int, reason: String?)

    /// The writer refused a track or a sample, or failed to finish.
    case writeFailed(stage: String, reason: String)

    public var description: String {
        switch self {
        case let .unsupportedContainer(name, reason):
            return reason.isEmpty ? "\(name) cannot carry chapters" : reason
        case let .noMediaTrack(name):
            return "\(name) has no video or audio to hang chapters on"
        case let .destinationIsSource(name):
            return "\(name) is both the source and the destination"
        case let .mediaRefused(detail):
            return "the destination will not hold this file's media: \(detail)"
        case let .refused(reason):
            return "the chapters could not be added: \(reason)"
        case let .incomplete(written, expected, reason):
            return "only \(written) of \(expected) chapters could be written"
                + (reason.map { ": \($0)" } ?? "")
        case let .writeFailed(stage, reason):
            return "writing chapters failed while \(stage): \(reason)"
        }
    }

    public var errorDescription: String? { description }

    public var recoverySuggestion: String? {
        switch self {
        case .unsupportedContainer:
            return "Write to an .mp4, .m4v, .mov or .m4a file."
        case .noMediaTrack:
            return "Chapters mark points in video or audio. Check that this is the file you meant."
        case .destinationIsSource:
            return "Write the result to a new file and move it into place afterwards."
        case .mediaRefused:
            return "Keep the source's container: write a film to .mp4, .m4v or .mov, "
                + "and audio to .m4a."
        case .refused, .incomplete, .writeFailed:
            return "The source may use a codec this system cannot pass through into the "
                + "chosen container; try writing a .mov instead."
        }
    }
}
#endif
