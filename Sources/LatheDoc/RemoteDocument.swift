import Foundation
import LatheCore

/// Reading a document that lives at a URL.
///
/// ## Counting pages without downloading the archive
///
/// A ZIP's index is at its END. Locally that makes page counting cost the same
/// for a two-gigabyte comic as for a two-megabyte one, which ``ZIPDirectory``
/// has always claimed — and over a network the claim only holds if the reader
/// asks for the end of the file rather than all of it. So a remote comic archive
/// is counted with **two range requests**: one for the tail, which holds the
/// end-of-central-directory record, and one for the index it points at.
///
/// A PDF gets no such shortcut. Its cross-reference table is also at the end,
/// but PDFKit offers no way to hand it bytes progressively, so a remote PDF is
/// staged to a temporary file. That is a real download, and it is bounded.
///
/// Both paths read the URL they are given and neither goes looking for one — see
/// ``MediaSource``.
public extension DocumentInspector {

    /// Page count for a document on disk or at a plain URL.
    func pageCount(
        of source: MediaSource,
        transport: any MediaDataTransport = URLSessionMediaTransport(),
        limits: RemoteLimits = .standard
    ) async throws -> Int {
        try await inspect(source, transport: transport, limits: limits).pageCount
    }

    /// ``pageCount(of:transport:limits:)`` plus what the file turned out to be.
    func inspect(
        _ source: MediaSource,
        transport: any MediaDataTransport = URLSessionMediaTransport(),
        limits: RemoteLimits = .standard
    ) async throws -> DocumentPageInfo {
        guard source.isRemote else {
            return try inspect(source.url)
        }
        let name = source.suggestedName

        // Sixteen bytes decide what this is, so a URL that ends in `.pdf` and
        // serves a comic archive is read as a comic archive.
        let head = try await transport.range(source.url, offset: 0, length: 16, limits: limits)
        switch try DocumentInspector.kind(ofLeadingBytes: [UInt8](head), name: name) {
        case .comicArchiveZIP:
            return try await inspectRemoteArchive(source.url, name: name, transport: transport, limits: limits)
        case .pdf:
            return try await source.withLocalFile(transport: transport, limits: limits) { staged in
                try inspect(staged)
            }
        }
    }

    /// Two range requests, or a fall back to downloading if the server will not
    /// serve ranges.
    private func inspectRemoteArchive(
        _ url: URL, name: String, transport: any MediaDataTransport, limits: RemoteLimits
    ) async throws -> DocumentPageInfo {
        let total = try await transport.length(url, limits: limits)
        guard total > 0 else {
            throw LatheError.readFailed(path: name, reason: "the server did not say how large it is")
        }

        // 64 KiB of tail covers the 22-byte end record plus a comment of up to
        // 65535 bytes, which is the largest the format allows — so one request
        // is enough to find it however much comment the archive carries.
        let tailLength = Int(min(total, 64 * 1024))
        let tailOffset = total - Int64(tailLength)
        let tail = try await transport.range(url, offset: tailOffset, length: tailLength, limits: limits)
        guard tail.count == tailLength else {
            // A server that ignored the range gave us something else entirely;
            // the honest fallback is to download and read it as a file.
            return try await MediaSource(url).withLocalFile(transport: transport, limits: limits) {
                try inspect($0)
            }
        }

        let located = try ZIPDirectory.locateCentralDirectory(
            inTail: tail, tailOffset: UInt64(tailOffset), fileSize: UInt64(total), name: name
        )
        guard located.size > 0, located.size <= UInt64(limits.maximumByteCount) else {
            throw LatheError.invalidInput(reason: "\(name) has an implausible central directory")
        }

        // The index is frequently inside the tail already, for an archive of a
        // few hundred pages — in which case the second request is skipped and a
        // whole comic is counted in one round trip.
        let directory: Data
        if located.offset >= UInt64(tailOffset),
           located.offset + located.size <= UInt64(total) {
            let start = Int(located.offset - UInt64(tailOffset))
            let end = start + Int(located.size)
            if end <= tail.count {
                directory = tail.subdata(in: start..<end)
            } else {
                directory = try await transport.range(
                    url, offset: Int64(located.offset), length: Int(located.size), limits: limits
                )
            }
        } else {
            directory = try await transport.range(
                url, offset: Int64(located.offset), length: Int(located.size), limits: limits
            )
        }

        let entries = try ZIPDirectory.parseCentralDirectory(directory, entryCount: located.entryCount)
        let pages = entries.filter(DocumentInspector.isPage)
        return DocumentPageInfo(
            kind: .comicArchiveZIP,
            pageCount: pages.count,
            excludedEntryCount: entries.count - pages.count
        )
    }
}
