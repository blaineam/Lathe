import Foundation
import LatheCore

/// File-level plumbing shared by the document module.
///
/// The rules encoded here are the same two `ImageEncoder` and `VideoTranscoder`
/// follow, and they are restated rather than imported because they are module
/// boundaries: `LatheImage`'s copies are internal to that module, and promoting
/// them into `LatheCore` would put file-system policy in the target that is
/// deliberately free of I/O.
///
/// 1. **Local files only.** Anything that ingests media from a network URL lives
///    outside this package; see the licence policy in the README.
/// 2. **Never leave a partial output.** Work goes to a sibling temporary file
///    that is moved into place only once it is complete, so a cancellation or a
///    failure leaves the destination exactly as it was — including leaving a
///    *previous* file intact.
enum DocumentFiles {

    static func requireReadableFile(at url: URL) throws {
        guard url.isFileURL else {
            throw LatheError.invalidInput(reason: "LatheDoc reads local files only")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw LatheError.readFailed(path: url.lastPathComponent, reason: "no such file")
        }
        guard !isDirectory.boolValue else {
            throw LatheError.readFailed(path: url.lastPathComponent, reason: "is a directory")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw LatheError.readFailed(path: url.lastPathComponent, reason: "not readable")
        }
    }

    static func byteCount(of url: URL) -> UInt64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0.map(UInt64.init) }
    }

    /// The file's first `count` bytes, or fewer if it is shorter.
    ///
    /// A handle read rather than `Data(contentsOf:)`: sniffing a document's type
    /// must not depend on being able to hold the document.
    static func leadingBytes(of url: URL, count: Int, name: String) throws -> [UInt8] {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return [UInt8](try handle.read(upToCount: count) ?? Data())
        } catch {
            throw LatheError.readFailed(path: name, reason: (error as NSError).localizedDescription)
        }
    }

    /// Runs `body` against a sibling scratch URL and moves the result into place.
    ///
    /// A sibling rather than the system temporary directory, because `moveItem`
    /// across volumes is a copy and the destination is where the caller already
    /// decided there is room.
    ///
    /// - Returns: the byte count of the file now at `destination`.
    @discardableResult
    static func writingAtomically(
        to destination: URL,
        pathExtension: String,
        stage: String,
        _ body: (URL) throws -> Void
    ) throws -> UInt64 {
        let directory = destination.deletingLastPathComponent()
        let scratch = directory.appendingPathComponent(
            ".lathe-\(UUID().uuidString).\(pathExtension)"
        )
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: scratch) } }

        try body(scratch)

        let size = byteCount(of: scratch) ?? 0
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
        return size
    }
}
