import Foundation
import LatheCore
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Whether a file can have its tags rewritten where it is.
public enum InPlaceWriteSupport: Sendable, Equatable {
    case supported
    /// Not this file, with a sentence that says why and can be shown as it is.
    case unsupported(reason: String)

    public var isSupported: Bool { self == .supported }

    public var reason: String? {
        if case .unsupported(let reason) = self { return reason }
        return nil
    }
}

/// What ``MetadataWriter/write(_:inPlaceAt:fallback:)`` does with a file it
/// cannot edit where it is.
public enum InPlaceFallback: Sendable, Equatable {
    /// Rewrite it the way ``MetadataWriter/write(_:to:writingTo:)`` does — a
    /// passthrough export into a scratch file beside the original, which then
    /// replaces it. Every sample is copied; the result is the same as before
    /// this path existed.
    case export
    /// Throw instead, leaving the file untouched. For a caller that stages its
    /// own rewrite — a sandboxed app that may write the file and not its
    /// folder — and only wants the cheap path from here.
    case refuse
}

extension MetadataWriter {

    /// Whether ``write(_:inPlaceAt:fallback:)`` would rewrite this file's
    /// `moov` atom in place rather than fall back to a full export.
    ///
    /// It reads the file's atom table and its `moov` — a few small reads, plus
    /// the metadata itself — and answers from the structure alone: an
    /// MP4-family file with one `moov`, not fragmented, whose user-data atoms
    /// this module can take apart and put back. A reason is given for every
    /// refusal, and every refusal is one the export path handles.
    public func canWriteInPlace(at url: URL) -> InPlaceWriteSupport {
        do {
            _ = try MP4InPlace.inspect(url)
            return .supported
        } catch let error as LatheError {
            switch error {
            case let .invalidInput(reason), let .readFailed(_, reason), let .writeFailed(_, reason):
                return .unsupported(reason: reason)
            default:
                return .unsupported(reason: error.localizedDescription)
            }
        } catch {
            return .unsupported(reason: (error as NSError).localizedDescription)
        }
    }

    /// Writes `metadata` into the file where it is, rewriting only its
    /// `moov` atom and leaving every sample where it was.
    ///
    /// Only MP4-family files take this path; see ``MP4InPlace`` for what is
    /// rebuilt, what is copied, and how an interruption at any point still
    /// leaves a readable file. Before anything is committed, the new `moov` is
    /// read back through ``MetadataReader`` — AVFoundation, that is — from a
    /// stub, and the write goes ahead only when every field it carries reads
    /// back as it was given.
    ///
    /// - Parameter fallback: what to do when the file cannot take this path.
    ///   The default exports, exactly as ``write(_:to:writingTo:)`` would, and
    ///   replaces the original.
    /// - Returns: the result, with ``MetadataWriteResult/wroteInPlace`` saying
    ///   which path ran and ``MetadataWriteResult/bytesWritten`` how much it
    ///   wrote — the `moov` twice, plus a few headers, when it ran in place.
    @discardableResult
    public func write(
        _ metadata: MediaMetadata, inPlaceAt url: URL, fallback: InPlaceFallback = .export
    ) async throws -> MetadataWriteResult {
        try await writeInPlace(metadata, at: url, fallback: fallback).result
    }

    /// The write, with the engine's own report beside the result, and the
    /// seams a test interrupts it through.
    func writeInPlace(
        _ metadata: MediaMetadata, at url: URL, fallback: InPlaceFallback = .export,
        hooks: MP4InPlace.Hooks = MP4InPlace.Hooks()
    ) async throws -> (result: MetadataWriteResult, report: MP4InPlace.Report?) {
        let inspection: MP4InPlace.Inspection
        let moov: Data
        do {
            inspection = try MP4InPlace.inspect(url)
            moov = try MP4InPlace.buildMoov(inspection, metadata: metadata)
            try await Self.verifyReadBack(of: moov, inspection: inspection, metadata: metadata)
        } catch let error as LatheError {
            guard fallback == .export else { throw error }
            return (try await exportInPlace(metadata, at: url), nil)
        }

        let report = try MP4InPlace.commit(inspection, moov: moov, rebuild: { padding in
            try MP4InPlace.buildMoov(inspection, metadata: metadata, padding: padding)
        }, hooks: hooks)
        let result = MetadataWriteResult(
            output: url,
            store: .iTunesAtoms,
            inputByteCount: inspection.length,
            outputByteCount: report.fileLength,
            wroteInPlace: true,
            bytesWritten: report.bytesWritten
        )
        return (result, report)
    }

    /// Reads, mutates and writes in place — ``update(_:writingTo:_:)`` for a
    /// file that is to stay where it is.
    @discardableResult
    public func update(
        inPlaceAt url: URL, fallback: InPlaceFallback = .export, _ edit: (inout MediaMetadata) -> Void
    ) async throws -> MetadataWriteResult {
        var metadata = try await MetadataReader().read(url)
        edit(&metadata)
        return try await write(metadata, inPlaceAt: url, fallback: fallback)
    }

    /// The fallback: the export this module has always done, into a scratch
    /// file beside the original, which then takes its place.
    private func exportInPlace(_ metadata: MediaMetadata, at url: URL) async throws -> MetadataWriteResult {
        let scratch = url.deletingLastPathComponent()
            .appendingPathComponent(".lathe-\(UUID().uuidString).\(url.pathExtension)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        var result = try await write(metadata, to: url, writingTo: scratch)
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: scratch)
        } catch {
            throw LatheError.writeFailed(
                path: url.lastPathComponent, reason: (error as NSError).localizedDescription
            )
        }
        result.output = url
        return result
    }

    #if canImport(AVFoundation)
    /// Reads `moov` back the way every consumer will — through AVFoundation —
    /// and refuses the write unless what comes back is what was asked for.
    ///
    /// The stub is `ftyp` and the new `moov` and nothing else. AVFoundation
    /// reads the metadata out of that without ever touching a sample, so this
    /// costs one small file in the temporary directory and no reads of the
    /// film. It is also the check that the fields the atoms were built from are
    /// the ones the reader's table maps: a mismatch here is a disagreement
    /// between the two ends of this module, and the export path knows nothing
    /// of it.
    static func verifyReadBack(of moov: Data, inspection: MP4InPlace.Inspection, metadata: MediaMetadata) async throws {
        let stub = FileManager.default.temporaryDirectory
            .appendingPathComponent("lathe-moov-\(UUID().uuidString)")
            .appendingPathExtension(inspection.url.pathExtension.isEmpty ? "mp4" : inspection.url.pathExtension)
        defer { try? FileManager.default.removeItem(at: stub) }
        var bytes = inspection.ftyp ?? Data()
        bytes.append(moov)
        do {
            try bytes.write(to: stub)
        } catch {
            throw LatheError.writeFailed(path: stub.lastPathComponent, reason: (error as NSError).localizedDescription)
        }
        let read = try await MetadataReader().read(stub)
        if let mismatch = InPlaceReadBack.firstDifference(between: metadata, and: read) {
            throw LatheError.encodingFailed(
                stage: "metadata-in-place", code: nil,
                reason: "the rewritten tags read back differently: \(mismatch)"
            )
        }
    }
    #else
    static func verifyReadBack(of moov: Data, inspection: MP4InPlace.Inspection, metadata: MediaMetadata) async throws {}
    #endif
}

/// What a ``MediaMetadata`` looks like after the container has had it.
///
/// Not every field survives verbatim by design: several creators are one
/// `©ART` atom joined with commas, a date is kept to the second, and the
/// totals in a track or disc number are stored but not read back. The
/// comparison knows those, so that a write is refused for a real
/// disagreement and not for a known normalisation.
enum InPlaceReadBack {

    /// A sentence naming the first field that differs, or `nil` when the two
    /// agree on everything the container carries.
    static func firstDifference(between wanted: MediaMetadata, and read: MediaMetadata) -> String? {
        func text(_ value: String?) -> String? {
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        func check<T: Equatable>(_ name: String, _ expected: T, _ actual: T) -> String? {
            expected == actual ? nil : "\(name): wrote \(String(describing: expected)), read \(String(describing: actual))"
        }

        if let d = check("title", text(wanted.title), text(read.title)) { return d }
        if let d = check("summary", text(wanted.summary), text(read.summary)) { return d }
        if let d = check("long description", text(wanted.longDescription), text(read.longDescription)) { return d }
        let creators = wanted.creators.isEmpty ? nil : wanted.creators.joined(separator: ", ")
        if let d = check("creators", text(creators), text(read.creators.isEmpty ? nil : read.creators.joined(separator: ", "))) { return d }
        if let d = check("genre", text(wanted.genre), text(read.genre)) { return d }
        if let d = check("comment", text(wanted.comment), text(read.comment)) { return d }
        if let d = check("copyright", text(wanted.copyrightNotice), text(read.copyrightNotice)) { return d }
        if let d = check("date", wanted.date.map { Int($0.timeIntervalSince1970) }, read.date.map { Int($0.timeIntervalSince1970) }) { return d }
        if let d = check("kind", wanted.kind, read.kind) { return d }

        let show = wanted.show ?? ShowInfo()
        let readShow = read.show ?? ShowInfo()
        if let d = check("series name", text(show.seriesName), text(readShow.seriesName)) { return d }
        if let d = check("season", show.seasonNumber, readShow.seasonNumber) { return d }
        if let d = check("episode", show.episodeNumber, readShow.episodeNumber) { return d }
        if let d = check("episode ID", text(show.episodeID), text(readShow.episodeID)) { return d }
        if let d = check("network", text(show.network), text(readShow.network)) { return d }

        let track = wanted.track ?? TrackInfo()
        let readTrack = read.track ?? TrackInfo()
        if let d = check("album", text(track.albumName), text(readTrack.albumName)) { return d }
        if let d = check("album artist", text(track.albumArtist), text(readTrack.albumArtist)) { return d }
        if let d = check("composer", text(track.composer), text(readTrack.composer)) { return d }
        if let d = check("track number", track.trackNumber, readTrack.trackNumber) { return d }
        if let d = check("disc number", track.discNumber, readTrack.discNumber) { return d }
        if let d = check("compilation", track.isCompilation, readTrack.isCompilation) { return d }

        if let d = check("artwork count", wanted.artwork.count, read.artwork.count) { return d }
        for (index, (expected, actual)) in zip(wanted.artwork, read.artwork).enumerated() where expected.data != actual.data {
            return "artwork \(index + 1): \(expected.data.count) bytes written, \(actual.data.count) read"
        }
        return nil
    }
}
