import Foundation
import LatheCore
#if canImport(AVFoundation)
import AVFoundation
#endif
#if canImport(ImageIO)
import ImageIO
import UniformTypeIdentifiers
#endif
#if canImport(PDFKit)
import PDFKit
#endif

/// Writes metadata into a file **without re-encoding what the file contains.**
///
/// ## The requirement that shapes everything here
///
/// Someone who wants a corrected title must not be given a re-encoded film.
/// Metadata injection has to be a container rewrite: the samples, the scan data,
/// the page content streams all come across untouched, and only the part of the
/// file that describes them changes. That is not an optimisation — a metadata
/// tool that silently costs a generation of quality is worse than no tool,
/// because the damage is invisible until it has been applied to a library.
///
/// So each backend uses the one API that copies rather than encodes:
///
/// | Store | How | What is copied |
/// |---|---|---|
/// | MP4 family | `AVAssetExportSession` at the passthrough preset, and ``ChapterWriter`` when the export drops the chapters | Every sample, bit for bit |
/// | Stills | `CGImageDestinationAddImageFromSource` | The encoded image data, DCT coefficients included |
/// | PDF | PDFKit document attributes | The page tree |
///
/// The tests assert this rather than assuming it: they compare the compressed
/// payloads before and after, not the rendered result.
///
/// ## Writing replaces; it does not merge
///
/// ``write(_:to:writingTo:)`` puts exactly the given ``MediaMetadata`` into the
/// output. Merging by default would make removing a field impossible — there
/// would be no way to express "no comment" that differed from "leave the comment
/// alone". ``MetadataReader`` captures unmapped fields in
/// ``MediaMetadata/custom``, so the read-modify-write in ``update(_:writingTo:_:)``
/// preserves what it did not touch, and that is where merging belongs.
public struct MetadataWriter: Sendable {

    public init() {}

    /// Writes `source` to `destination` carrying `metadata`, leaving the media
    /// itself untouched.
    @discardableResult
    public func write(
        _ metadata: MediaMetadata, to source: URL, writingTo destination: URL
    ) async throws -> MetadataWriteResult {
        try MetaFiles.requireReadableFile(at: source)
        try MetaFiles.requireDistinct(source: source, destination: destination)

        let store = try MetadataStore.detect(at: source)
        let inputBytes = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0

        var unrepresented: [String] = []
        var removedTrailingV1 = false
        var restoredChapters = 0
        var droppedTracks: [String] = []
        let outputBytes: UInt64
        switch store {
        case .iTunesAtoms:
            let written = try await writeContainer(metadata, source: source, destination: destination)
            outputBytes = written.bytes
            restoredChapters = written.restoredChapters
            droppedTracks = written.droppedTracks
        case .imageProperties:
            outputBytes = try writeImage(metadata, source: source, destination: destination)
        case .pdfInfo:
            outputBytes = try writePDF(metadata, source: source, destination: destination)
        case .id3:
            // Not a container rewrite: an MP3 has no container. The tag is a
            // block bolted to the front of the MPEG frames, so this emits a new
            // one and copies the audio across byte for byte. See ``ID3File``.
            let written = try ID3File.write(metadata, source: source, destination: destination)
            outputBytes = written.bytes
            unrepresented = written.unrepresented
            removedTrailingV1 = written.removedTrailingV1
        }

        return MetadataWriteResult(
            output: destination,
            store: store,
            inputByteCount: UInt64(inputBytes),
            outputByteCount: outputBytes,
            unrepresentedFields: unrepresented,
            removedTrailingID3v1: removedTrailingV1,
            restoredChapterCount: restoredChapters,
            droppedTracks: droppedTracks
        )
    }

    /// Reads, mutates, and writes — the shape almost every edit actually takes.
    ///
    /// Fields the closure does not touch survive, including ones this module
    /// has no name for, because the read captured them.
    @discardableResult
    public func update(
        _ source: URL,
        writingTo destination: URL,
        _ edit: (inout MediaMetadata) -> Void
    ) async throws -> MetadataWriteResult {
        var metadata = try await MetadataReader().read(source)
        edit(&metadata)
        return try await write(metadata, to: source, writingTo: destination)
    }

    // MARK: - MP4 family

    #if canImport(AVFoundation)
    /// What a container write produced beyond its size: chapters it had to put
    /// back, and tracks that putting them back could not carry.
    private struct ContainerWrite {
        var bytes: UInt64
        var restoredChapters = 0
        var droppedTracks: [String] = []
    }

    /// The passthrough export, and the chapter list it may lose.
    ///
    /// ## The trap
    ///
    /// `AVAssetExportSession` at the passthrough preset copies every sample and
    /// writes the new tags — and, for `.mp4` and `.m4a` output, silently leaves
    /// the chapter track behind. `.mov` and `.m4v` keep theirs. So an ordinary
    /// title edit deleted an audiobook's or a film's chapters, and nothing said
    /// so: the chapter track is a separate text track with a `chap` reference
    /// (see ``LatheCore/ChapterTrack``), and it is simply not in the output.
    ///
    /// ## The fix, and why this shape
    ///
    /// The chapters are read from the source first. The export runs as it
    /// always did — a file with no chapters pays nothing — and its output is
    /// then asked for its chapters. Only when they are gone is the export's
    /// output remuxed by ``ChapterWriter`` with the source's list and the same
    /// tags. Detecting the loss rather than listing the containers that cause
    /// it means a system that fixes (or extends) the export needs no change
    /// here, and a file whose chapters survived is never copied twice.
    ///
    /// The cost is a second copy of a chaptered `.mp4` or `.m4a`, which is
    /// seconds for an audiobook. Remuxing straight from the source instead
    /// would save that copy and give up everything else the export carries
    /// that a remux does not.
    private func writeContainer(
        _ metadata: MediaMetadata, source: URL, destination: URL
    ) async throws -> ContainerWrite {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPresetPassthrough
        ) else {
            throw LatheError.encodeUnavailable(format: "passthrough export for \(source.lastPathComponent)")
        }

        let fileType = try await Self.outputFileType(for: asset, source: source, session: session)
        let items = MetadataItemBuilder.items(for: metadata)
        let chapters = await ChapterTrack.read(from: asset)
        let ext = destination.pathExtension.isEmpty ? source.pathExtension : destination.pathExtension

        guard !chapters.isEmpty else {
            let bytes = try MetaFiles.writingAtomically(
                to: destination, pathExtension: ext, stage: "metadata-passthrough"
            ) { scratch in
                try Self.export(session, to: scratch, fileType: fileType, metadata: items)
            }
            return ContainerWrite(bytes: bytes)
        }

        // The export goes to a scratch file of the container's own extension,
        // because ``ChapterWriter`` chooses its container by extension.
        let exported = TrackRemux.scratchURL(
            beside: destination, prefix: ".lathe-"
        ).deletingPathExtension().appendingPathExtension(Self.pathExtension(for: fileType) ?? ext)
        defer { try? FileManager.default.removeItem(at: exported) }
        try Self.export(session, to: exported, fileType: fileType, metadata: items)

        let kept = await ChapterTrack.read(from: AVURLAsset(url: exported))
        if kept.map(\.title) == chapters.map(\.title) {
            let bytes = try MetaFiles.writingAtomically(
                to: destination, pathExtension: ext, stage: "metadata-passthrough"
            ) { scratch in
                try? FileManager.default.removeItem(at: scratch)
                try FileManager.default.moveItem(at: exported, to: scratch)
            }
            return ContainerWrite(bytes: bytes)
        }

        let restored: ChapterWriteResult
        let rewritten = exported.deletingLastPathComponent()
            .appendingPathComponent(".lathe-chapters-restored-" + exported.lastPathComponent)
        defer { try? FileManager.default.removeItem(at: rewritten) }
        do {
            restored = try await ChapterWriter().write(
                chapters, into: exported, writingTo: rewritten, metadata: items, progress: .ignoring()
            )
        } catch let error as ChapterError {
            throw LatheError.encodingFailed(
                stage: "metadata-chapters", code: nil,
                reason: "the export dropped the file's \(chapters.count) chapters and they could not "
                    + "be put back: \(error.description)"
            )
        }
        let bytes = try MetaFiles.writingAtomically(
            to: destination, pathExtension: ext, stage: "metadata-chapters"
        ) { scratch in
            try? FileManager.default.removeItem(at: scratch)
            try FileManager.default.moveItem(at: rewritten, to: scratch)
        }
        return ContainerWrite(
            bytes: bytes,
            restoredChapters: restored.chapters.count,
            droppedTracks: restored.droppedTracks
        )
    }

    /// Runs the passthrough export to `url`, blocking until it ends.
    private static func export(
        _ session: AVAssetExportSession, to url: URL, fileType: AVFileType, metadata: [AVMetadataItem]
    ) throws {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: Error?
        session.outputURL = url
        session.outputFileType = fileType
        session.metadata = metadata
        session.exportAsynchronously {
            if session.status != .completed {
                failure = session.error ?? LatheError.encodingFailed(
                    stage: "metadata-passthrough", code: nil,
                    reason: "the export ended in state \(session.status.rawValue)"
                )
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let failure {
            throw LatheError.encodingFailed(
                stage: "metadata-passthrough", code: nil,
                reason: (failure as NSError).localizedDescription
            )
        }
    }

    private static func pathExtension(for fileType: AVFileType) -> String? {
        switch fileType {
        case .mp4: "mp4"
        case .m4v: "m4v"
        case .m4a: "m4a"
        case .mov: "mov"
        default: nil
        }
    }

    /// The container to write, preferring the one the source already is.
    ///
    /// Rewriting an `.m4v` as a plain `.mp4` would work and would also drop the
    /// hint some players use to treat it as video rather than audio, so the
    /// source's own type is kept whenever the session will produce it.
    private static func outputFileType(
        for asset: AVURLAsset, source: URL, session: AVAssetExportSession
    ) async throws -> AVFileType {
        let supported = await session.supportedFileTypes
        let byExtension: [String: AVFileType] = [
            "mp4": .mp4, "m4v": .m4v, "m4a": .m4a, "mov": .mov, "qt": .mov,
        ]
        if let preferred = byExtension[source.pathExtension.lowercased()],
           supported.contains(preferred) {
            return preferred
        }
        if let first = supported.first { return first }
        throw LatheError.encodeUnavailable(
            format: "no output container for \(source.lastPathComponent)"
        )
    }
    #else
    private struct ContainerWrite {
        var bytes: UInt64
        var restoredChapters = 0
        var droppedTracks: [String] = []
    }

    private func writeContainer(
        _ metadata: MediaMetadata, source: URL, destination: URL
    ) async throws -> ContainerWrite {
        throw LatheError.encodeUnavailable(format: "container metadata needs AVFoundation")
    }
    #endif

    // MARK: - Stills

    #if canImport(ImageIO)
    private func writeImage(
        _ metadata: MediaMetadata, source: URL, destination: URL
    ) throws -> UInt64 {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let type = CGImageSourceGetType(imageSource)
        else {
            throw LatheError.readFailed(path: source.lastPathComponent, reason: "not a readable image")
        }

        var properties = (CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
            as? [CFString: Any]) ?? [:]
        ImagePropertyBuilder.apply(metadata, to: &properties)

        return try MetaFiles.writingAtomically(
            to: destination,
            pathExtension: destination.pathExtension.isEmpty ? source.pathExtension : destination.pathExtension,
            stage: "metadata-image"
        ) { scratch in
            guard let dest = CGImageDestinationCreateWithURL(scratch as CFURL, type, 1, nil) else {
                throw LatheError.encodeUnavailable(format: String(type))
            }
            // From the SOURCE, not from a decoded CGImage: this copies the
            // encoded bytes and replaces only the property dictionaries, which
            // is what makes the edit lossless. Adding a CGImage instead would
            // re-encode every pixel.
            CGImageDestinationAddImageFromSource(dest, imageSource, 0, properties as CFDictionary)
            guard CGImageDestinationFinalize(dest) else {
                throw LatheError.encodingFailed(
                    stage: "metadata-image", code: nil, reason: "ImageIO declined to finalise"
                )
            }
        }
    }
    #else
    private func writeImage(_ metadata: MediaMetadata, source: URL, destination: URL) throws -> UInt64 {
        throw LatheError.encodeUnavailable(format: "still metadata needs ImageIO")
    }
    #endif

    // MARK: - PDF

    #if canImport(PDFKit)
    private func writePDF(
        _ metadata: MediaMetadata, source: URL, destination: URL
    ) throws -> UInt64 {
        guard let document = PDFDocument(url: source) else {
            throw LatheError.invalidInput(
                reason: "\(source.lastPathComponent) is not a PDF PDFKit can open"
            )
        }
        var attributes = document.documentAttributes ?? [:]
        attributes[PDFDocumentAttribute.titleAttribute] = metadata.title
        attributes[PDFDocumentAttribute.subjectAttribute] = metadata.summary
        attributes[PDFDocumentAttribute.authorAttribute] = metadata.creators.first
        attributes[PDFDocumentAttribute.creationDateAttribute] = metadata.date
        if let keywords = metadata.custom["pdf.Keywords"] {
            attributes[PDFDocumentAttribute.keywordsAttribute] =
                keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        } else {
            attributes[PDFDocumentAttribute.keywordsAttribute] = nil
        }
        attributes[PDFDocumentAttribute.creatorAttribute] = metadata.custom["pdf.Creator"]
        attributes[PDFDocumentAttribute.producerAttribute] = metadata.custom["pdf.Producer"]
        document.documentAttributes = attributes

        return try MetaFiles.writingAtomically(
            to: destination, pathExtension: "pdf", stage: "metadata-pdf"
        ) { scratch in
            guard document.write(to: scratch) else {
                throw LatheError.writeFailed(
                    path: destination.lastPathComponent, reason: "PDFKit declined to write"
                )
            }
        }
    }
    #else
    private func writePDF(_ metadata: MediaMetadata, source: URL, destination: URL) throws -> UInt64 {
        throw LatheError.encodeUnavailable(format: "PDF metadata needs PDFKit")
    }
    #endif
}

/// What a metadata write produced.
public struct MetadataWriteResult: Sendable, Equatable {
    public var output: URL
    public var store: MetadataStore
    public var inputByteCount: UInt64
    public var outputByteCount: UInt64

    /// Fields the destination format has no way to express, named rather than
    /// silently dropped. ID3 has no frame for a series and episode, so writing
    /// television metadata into an MP3 loses it — and a caller who is told can
    /// decide, where a caller who is not finds out months later.
    public var unrepresentedFields: [String]

    /// Whether a trailing 128-byte ID3v1 tag was removed. It is removed rather
    /// than left to disagree with the v2 tag just written — see ``ID3File`` —
    /// and reported because it is a change beyond the one that was asked for.
    public var removedTrailingID3v1: Bool

    /// Chapters the passthrough export dropped and the write put back — the
    /// source's whole list when it did, zero when nothing was lost. Reported
    /// because putting them back is a second copy of the file.
    public var restoredChapterCount: Int

    /// Tracks the chapter-restoring remux could not carry, each with the
    /// reason. Empty unless ``restoredChapterCount`` is non-zero, and empty for
    /// any ordinary MP4 or M4A even then.
    public var droppedTracks: [String]

    public init(
        output: URL,
        store: MetadataStore,
        inputByteCount: UInt64,
        outputByteCount: UInt64,
        unrepresentedFields: [String] = [],
        removedTrailingID3v1: Bool = false,
        restoredChapterCount: Int = 0,
        droppedTracks: [String] = []
    ) {
        self.output = output
        self.store = store
        self.inputByteCount = inputByteCount
        self.outputByteCount = outputByteCount
        self.unrepresentedFields = unrepresentedFields
        self.removedTrailingID3v1 = removedTrailingID3v1
        self.restoredChapterCount = restoredChapterCount
        self.droppedTracks = droppedTracks
    }
}
