import Foundation
import LatheCore
import LatheDoc
import LatheFixtures
import LatheMeta
import Testing

/// Reading media from a plain URL.
///
/// Every test here runs against an in-memory server, because what matters is
/// the *policy* — what is streamed, what is staged, what is refused, and how
/// many requests each costs — and a live URL exercises none of that reliably.
@Suite("Remote sources")
struct RemoteSourceTests {

    /// Serves fixed bytes and records what was asked for, so a test can assert
    /// that counting a comic's pages cost two range requests rather than a
    /// download.
    actor StubTransport: MediaDataTransport {
        struct Call: Equatable {
            var kind: String
            var offset: Int64
            var length: Int
        }

        private let payload: Data
        private let supportsRanges: Bool
        private let reportsLength: Bool
        private(set) var calls: [Call] = []
        private(set) var downloadedBytes: Int64 = 0

        init(payload: Data, supportsRanges: Bool = true, reportsLength: Bool = true) {
            self.payload = payload
            self.supportsRanges = supportsRanges
            self.reportsLength = reportsLength
        }

        func download(
            _ url: URL, to destination: URL, limits: RemoteLimits, progress: ProgressHandle?
        ) async throws {
            calls.append(Call(kind: "download", offset: 0, length: payload.count))
            guard Int64(payload.count) <= limits.maximumByteCount else {
                throw LatheError.invalidInput(reason: "over the limit")
            }
            downloadedBytes += Int64(payload.count)
            try payload.write(to: destination)
        }

        func range(
            _ url: URL, offset: Int64, length: Int, limits: RemoteLimits
        ) async throws -> Data {
            calls.append(Call(kind: "range", offset: offset, length: length))
            guard supportsRanges else { return payload }
            let start = Int(min(Int64(payload.count), max(0, offset)))
            let end = min(payload.count, start + length)
            guard start < end else { return Data() }
            return payload.subdata(in: start..<end)
        }

        func length(_ url: URL, limits: RemoteLimits) async throws -> Int64 {
            calls.append(Call(kind: "length", offset: 0, length: 0))
            return reportsLength ? Int64(payload.count) : 0
        }

        var rangeCallCount: Int { calls.filter { $0.kind == "range" }.count }
        var didDownload: Bool { calls.contains { $0.kind == "download" } }
    }

    // MARK: - What a source is, and is not

    /// The distinction the whole feature rests on: a URL the caller hands over
    /// is read; a scheme nothing can stream is refused by name.
    @Test("http and https and file are read; anything else is refused by name")
    func acceptedSchemes() throws {
        #expect(try MediaSource(URL(string: "https://example.com/clip.mp4")!).isRemote)
        #expect(try MediaSource(URL(string: "http://example.com/clip.mp4")!).isRemote)
        #expect(try !MediaSource(URL(fileURLWithPath: "/tmp/clip.mp4")).isRemote)

        for bad in ["ftp://example.com/x.mp4", "data:text/plain;base64,AA==", "magnet:?xt=urn:btih:x"] {
            #expect(throws: LatheError.self) {
                _ = try MediaSource(URL(string: bad)!)
            }
        }
        // A scheme with no host is nothing anything can fetch, and the failure
        // is far clearer here than as a transport error later.
        #expect(throws: LatheError.self) {
            _ = try MediaSource(URL(string: "https:///no-host")!)
        }
    }

    /// A local source costs nothing: no copy, no temporary file, so wrapping a
    /// call in `withLocalFile` is free when nothing is remote.
    @Test("a local source is passed straight through, not copied")
    func localSourceIsNotCopied() async throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("remote-local")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try DocumentFixtures.write(
            Data("hello".utf8), to: directory.appendingPathComponent("a.bin")
        )

        let source = try MediaSource(file)
        let transport = StubTransport(payload: Data())
        let seen = try await source.withLocalFile(transport: transport) { $0 }

        #expect(seen == file, "a local file was staged instead of used where it is")
        let calls = await transport.calls
        #expect(calls.isEmpty, "a local read touched the network")
    }

    @Test("a missing local file fails as a missing file, not as a network error")
    func missingLocalFile() async throws {
        let source = try MediaSource(URL(fileURLWithPath: "/nonexistent/nope.mp4"))
        await #expect(throws: LatheError.self) {
            try await source.withLocalFile(transport: StubTransport(payload: Data())) { _ in }
        }
    }

    // MARK: - Staging is bounded

    /// A URL is whatever it turns out to be, and a caller that asked for a page
    /// count should not be able to fill the disk by mistyping one.
    @Test("a remote read past the size limit is refused rather than truncated")
    func oversizedRemoteReadIsRefused() async throws {
        let source = try MediaSource(URL(string: "https://example.com/huge.bin")!)
        let transport = StubTransport(payload: Data(repeating: 0, count: 5_000))

        await #expect(throws: LatheError.self) {
            try await source.withLocalFile(
                transport: transport, limits: RemoteLimits(maximumByteCount: 1_000)
            ) { _ in }
        }
    }

    /// The staged file is removed whether the work succeeded or threw — a
    /// temporary file per failed read would quietly fill a device.
    @Test("the staged download is removed afterwards, including after a failure")
    func stagedFileIsCleanedUp() async throws {
        let source = try MediaSource(URL(string: "https://example.com/a.bin")!)
        let transport = StubTransport(payload: Data("some bytes".utf8))

        var stagedPath: String?
        _ = try await source.withLocalFile(transport: transport) { url in
            stagedPath = url.path
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        #expect(!FileManager.default.fileExists(atPath: try #require(stagedPath)))

        var failedPath: String?
        _ = try? await source.withLocalFile(transport: transport) { url in
            failedPath = url.path
            throw LatheError.invalidInput(reason: "the body threw")
        }
        #expect(!FileManager.default.fileExists(atPath: try #require(failedPath)))
    }

    // MARK: - Counting a remote comic without downloading it

    /// **The headline.** A ZIP's index is at its end, so counting the pages of a
    /// remote comic costs a few kilobytes rather than the whole archive. The
    /// module has always claimed this; until there was a way to read a range it
    /// was only true locally.
    @Test("a remote comic archive is counted with range requests, not a download")
    func remoteComicIsCountedByRange() async throws {
        // Padded so the archive is meaningfully larger than the tail a reader
        // fetches, which is the case the optimisation is for.
        var entries = (0..<40).map {
            DocumentFixtures.ArchiveEntry(
                name: String(format: "p%03d.png", $0),
                data: Data(repeating: UInt8($0 % 251), count: 4_096)
            )
        }
        entries.append(DocumentFixtures.ArchiveEntry(name: "ComicInfo.xml", data: Data("<x/>".utf8)))
        let archive = DocumentFixtures.zipArchive(entries)

        let transport = StubTransport(payload: archive)
        let source = try MediaSource(URL(string: "https://example.com/comic.cbz")!)
        let info = try await DocumentInspector().inspect(source, transport: transport)

        #expect(info.kind == .comicArchiveZIP)
        #expect(info.pageCount == 40)
        #expect(info.excludedEntryCount == 1)

        let downloaded = await transport.didDownload
        let ranges = await transport.rangeCallCount
        #expect(!downloaded, "the archive was downloaded to count its pages")
        // A sniff, a length, then the tail — and the index came out of the tail.
        #expect(ranges <= 3, "counting cost \(ranges) range requests")
    }

    /// A server that ignores ranges is not a failure; it is a fall back to
    /// downloading, because the answer still has to be correct.
    @Test("a server that ignores ranges falls back to downloading, and still counts correctly")
    func fallsBackWhenRangesAreIgnored() async throws {
        let archive = DocumentFixtures.zipArchive((0..<5).map {
            DocumentFixtures.ArchiveEntry(name: "p\($0).png", data: Data(repeating: 1, count: 64))
        })
        let transport = StubTransport(payload: archive, supportsRanges: false)
        let source = try MediaSource(URL(string: "https://example.com/comic.cbz")!)

        let info = try await DocumentInspector().inspect(source, transport: transport)
        #expect(info.pageCount == 5)
    }

    // MARK: - The bytes decide, not the extension

    /// A URL that ends in `.pdf` and serves a comic archive is read as a comic
    /// archive. Trusting the extension would produce a confident wrong answer
    /// for a file the server never claimed was a PDF.
    @Test("a remote file is identified by its bytes, not by its URL")
    func remoteKindComesFromBytes() async throws {
        let archive = DocumentFixtures.zipArchive([
            DocumentFixtures.ArchiveEntry(name: "p0.png", data: Data(repeating: 2, count: 32)),
            DocumentFixtures.ArchiveEntry(name: "p1.png", data: Data(repeating: 3, count: 32)),
        ])
        let transport = StubTransport(payload: archive)
        let lying = try MediaSource(URL(string: "https://example.com/looks-like.pdf")!)

        let info = try await DocumentInspector().inspect(lying, transport: transport)
        #expect(info.kind == .comicArchiveZIP)
        #expect(info.pageCount == 2)
    }

    @Test("a remote PDF is staged, because PDFKit cannot be fed a range")
    func remotePDFIsStaged() async throws {
        let pdf = try DocumentFixtures.numberedPDF(pageCount: 4)
        let transport = StubTransport(payload: pdf)
        let source = try MediaSource(URL(string: "https://example.com/doc.pdf")!)

        let info = try await DocumentInspector().inspect(source, transport: transport)
        #expect(info.kind == .pdf)
        #expect(info.pageCount == 4)
        let downloaded = await transport.didDownload
        #expect(downloaded, "a PDF has no range shortcut and must be staged")
    }

    // MARK: - Metadata

    @Test("a remote still's metadata is read after staging it")
    func remoteStillMetadata() async throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("remote-still")
        defer { try? FileManager.default.removeItem(at: directory) }

        // Tag a local JPEG, then serve those exact bytes.
        let plain = try DocumentFixtures.write(
            try DocumentFixtures.solidJPEG(), to: directory.appendingPathComponent("in.jpg")
        )
        let tagged = directory.appendingPathComponent("tagged.jpg")
        try await MetadataWriter().write(
            MediaMetadata(title: "From The Web", creators: ["Someone"]),
            to: plain, writingTo: tagged
        )

        let transport = StubTransport(payload: try Data(contentsOf: tagged))
        let source = try MediaSource(URL(string: "https://example.com/photo.jpg")!)
        let meta = try await MetadataReader().read(source, transport: transport)

        #expect(meta.title == "From The Web")
        #expect(meta.creators.first == "Someone")
    }

    /// The store is decided by the first bytes, so a URL with a misleading
    /// extension is still read in the right vocabulary.
    @Test("the metadata store is chosen from a sixteen-byte range request")
    func remoteStoreIsSniffed() async throws {
        let transport = StubTransport(payload: try DocumentFixtures.numberedPDF(pageCount: 1))
        let source = try MediaSource(URL(string: "https://example.com/not-really.mp4")!)

        let meta = try await MetadataReader().read(source, transport: transport)
        #expect(meta.isEmpty || meta.title == nil)

        let recorded = await transport.calls
        let first = try #require(recorded.first)
        #expect(first.kind == "range")
        #expect(first.length == 16, "identifying the file should cost sixteen bytes")
    }
}
