import Foundation
import LatheCore

/// Which of the four incompatible metadata systems a file uses.
///
/// Chosen by sniffing the bytes rather than trusting the filename: a `.m4v` and
/// a `.mp4` and a `.mov` are one store, an `.mp3` is a different one, and a file
/// whose extension lies would otherwise be edited in the wrong vocabulary and
/// come back blank.
public enum MetadataStore: Sendable, Equatable, CustomStringConvertible {
    /// iTunes-style atoms in `moov/udta/meta/ilst` — MP4, M4V, M4A, MOV.
    case iTunesAtoms
    /// ID3v2 frames, prepended to the MPEG audio.
    case id3
    /// EXIF, IPTC and XMP dictionaries in a still image.
    case imageProperties
    /// A PDF's Info dictionary.
    case pdfInfo

    public var description: String {
        switch self {
        case .iTunesAtoms: return "iTunes-style atoms"
        case .id3: return "ID3v2"
        case .imageProperties: return "EXIF/IPTC/XMP"
        case .pdfInfo: return "PDF document attributes"
        }
    }

    /// The store the file's leading bytes imply.
    ///
    /// - Throws: ``LatheError/invalidInput(reason:)`` naming what the file
    ///   appears to be, for anything with no metadata store this package edits.
    public static func detect(at url: URL, name: String? = nil) throws -> MetadataStore {
        let label = name ?? url.lastPathComponent
        guard url.isFileURL else {
            throw LatheError.invalidInput(reason: "LatheMeta reads local files only")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            throw LatheError.readFailed(path: label, reason: "no such file")
        }

        let magic = try leadingBytes(of: url, count: 16, name: label)

        if magic.starts(with: Array("%PDF-".utf8)) { return .pdfInfo }

        // ISO base media: a `ftyp` box at offset 4. The box's size precedes it,
        // so the brand is at 8 and the type at 4 — which is why this looks past
        // the first four bytes rather than at them.
        if magic.count >= 8, Array(magic[4..<8]) == Array("ftyp".utf8) { return .iTunesAtoms }

        // A QuickTime movie that leads with `moov` or `mdat` rather than `ftyp`.
        if magic.count >= 8 {
            let box = Array(magic[4..<8])
            if box == Array("moov".utf8) || box == Array("mdat".utf8) { return .iTunesAtoms }
        }

        // ID3v2 tag, or a bare MPEG frame sync for an MP3 with no tag yet.
        if magic.starts(with: Array("ID3".utf8)) { return .id3 }
        if magic.count >= 2, magic[0] == 0xFF, (magic[1] & 0xE0) == 0xE0 { return .id3 }

        if ArtworkFormat(sniffing: Data(magic)) != nil { return .imageProperties }
        // HEIC and AVIF are ISO base media too, but their brand says image; they
        // are caught by the ftyp check above and handled as iTunes atoms, which
        // is wrong for them. Name the brand so that is a clear refusal for now.
        if magic.count >= 12 {
            let brand = String(decoding: magic[8..<12], as: UTF8.self)
            if ["heic", "heix", "mif1", "avif"].contains(brand) {
                throw LatheError.invalidInput(
                    reason: "\(label) is a \(brand) image; LatheMeta edits JPEG and PNG stills, "
                        + "and ISO-image metadata is not implemented"
                )
            }
        }
        // TIFF, both byte orders.
        if magic.count >= 4 {
            let header = Array(magic[0..<4])
            if header == [0x49, 0x49, 0x2A, 0x00] || header == [0x4D, 0x4D, 0x00, 0x2A] {
                return .imageProperties
            }
        }

        throw LatheError.invalidInput(
            reason: "\(label) has no metadata store LatheMeta edits (expected an MP4-family file, "
                + "an MP3, a JPEG, a PNG, a TIFF or a PDF)"
        )
    }

    private static func leadingBytes(of url: URL, count: Int, name: String) throws -> [UInt8] {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return [UInt8](try handle.read(upToCount: count) ?? Data())
        } catch {
            throw LatheError.readFailed(path: name, reason: (error as NSError).localizedDescription)
        }
    }
}

/// File plumbing shared by the metadata module.
///
/// Restated rather than imported for the same reason ``LatheDoc`` restates it:
/// these are module boundaries, and the rule — never leave a partial output —
/// is small enough that sharing it would cost more than repeating it.
enum MetaFiles {

    static func requireReadableFile(at url: URL) throws {
        guard url.isFileURL else {
            throw LatheError.invalidInput(reason: "LatheMeta reads local files only")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw LatheError.readFailed(path: url.lastPathComponent, reason: "no such file")
        }
        guard !isDirectory.boolValue else {
            throw LatheError.readFailed(path: url.lastPathComponent, reason: "is a directory")
        }
    }

    /// Refuses a destination that is the source, including when the two are the
    /// same file spelled differently.
    ///
    /// Metadata editing is the operation most likely to be asked for in place —
    /// "just fix the title" — and an in-place write through a temporary file is
    /// a feature this module can add deliberately later. Silently truncating the
    /// input while reading it is not that feature.
    static func requireDistinct(source: URL, destination: URL) throws {
        guard source.standardizedFileURL != destination.standardizedFileURL else {
            throw LatheError.invalidInput(
                reason: "\(destination.lastPathComponent) is both the source and the destination; "
                    + "write the result somewhere else and move it into place"
            )
        }
    }

    @discardableResult
    static func writingAtomically(
        to destination: URL,
        pathExtension: String,
        stage: String,
        _ body: (URL) throws -> Void
    ) throws -> UInt64 {
        let directory = destination.deletingLastPathComponent()
        let scratch = directory.appendingPathComponent(".lathe-\(UUID().uuidString).\(pathExtension)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: scratch) } }

        try body(scratch)

        let size = (try? scratch.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
        guard size > 0 else {
            throw LatheError.encodingFailed(
                stage: stage, code: nil, reason: "the writer finished but produced no bytes"
            )
        }
        do {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: scratch)
        } catch {
            throw LatheError.writeFailed(
                path: destination.lastPathComponent,
                reason: (error as NSError).localizedDescription
            )
        }
        keep = true
        return UInt64(size)
    }
}
