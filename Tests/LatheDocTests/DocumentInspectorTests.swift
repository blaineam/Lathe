import Foundation
import LatheCore
import LatheFixtures
import LatheImage
import Testing

@testable import LatheDoc

/// Page counting, and the ways a page count goes wrong by producing a plausible
/// number rather than an error.
@Suite("Document page counting")
struct DocumentInspectorTests {

    private let inspector = DocumentInspector()

    // MARK: - The headline

    /// **An animated page is one page.**
    ///
    /// The archive below holds 6 files of 30 frames each. Counted by frames it
    /// is 180 pages; counted by pages it is 6. 180 does not read as a counting
    /// bug to whoever sees it — it reads as a corrupt archive — so it gets
    /// investigated in the importer, the decoder and the database before anybody
    /// looks at the arithmetic.
    @Test("a CBZ of animated GIFs counts one page per file, not per frame")
    func animatedPagesCountOnce() throws {
        let frameCount = 30
        let pageCount = 6
        let gif = try DocumentFixtures.animatedGIF(frameCount: frameCount)

        let directory = try DocumentFixtures.makeTemporaryDirectory("animated")
        defer { try? FileManager.default.removeItem(at: directory) }

        // The fixture really is animated, and really does have that many frames.
        // Asserted rather than assumed, because if ImageIO wrote a still here the
        // headline assertion below would pass for the wrong reason.
        let single = try DocumentFixtures.write(gif, to: directory.appendingPathComponent("f.gif"))
        let frames = try ImageInspector().inspect(single)
        #expect(frames.isAnimated)
        #expect(frames.frameCount == frameCount)

        let archive = try DocumentFixtures.write(
            DocumentFixtures.zipArchive((0..<pageCount).map {
                DocumentFixtures.ArchiveEntry(name: String(format: "page%02d.gif", $0), data: gif)
            }),
            to: directory.appendingPathComponent("animated.cbz")
        )

        #expect(try inspector.pageCount(of: archive) == pageCount)
        #expect(try inspector.pageCount(of: archive) != pageCount * frameCount)
    }

    // MARK: - Exclusions

    /// The `__MACOSX/` tree is the one that ships unnoticed: its members carry
    /// the same extensions as the files they shadow, so a Mac-made archive
    /// counts **double** and a comic reporting 8 pages instead of 4 still looks
    /// like a comic.
    @Test("archive junk, resource forks and folder entries are not pages")
    func exclusions() throws {
        let page = try DocumentFixtures.solidPNG()
        let directory = try DocumentFixtures.makeTemporaryDirectory("junk")
        defer { try? FileManager.default.removeItem(at: directory) }

        let archive = try DocumentFixtures.write(
            DocumentFixtures.zipArchive([
                .directory("pages"),
                DocumentFixtures.ArchiveEntry(name: "pages/001.png", data: page),
                DocumentFixtures.ArchiveEntry(name: "pages/002.png", data: page),
                DocumentFixtures.ArchiveEntry(name: "pages/003.png", data: page),
                DocumentFixtures.ArchiveEntry(name: "pages/004.png", data: page),
                DocumentFixtures.ArchiveEntry(name: "ComicInfo.xml", data: Data("<x/>".utf8)),
                DocumentFixtures.ArchiveEntry(name: ".DS_Store", data: Data([0, 1, 2])),
                DocumentFixtures.ArchiveEntry(name: "Thumbs.db", data: Data([0, 1, 2])),
                .directory("__MACOSX"),
                .directory("__MACOSX/pages"),
                DocumentFixtures.ArchiveEntry(name: "__MACOSX/pages/._001.png", data: page),
                DocumentFixtures.ArchiveEntry(name: "__MACOSX/pages/._002.png", data: page),
                DocumentFixtures.ArchiveEntry(name: "__MACOSX/pages/._003.png", data: page),
                DocumentFixtures.ArchiveEntry(name: "__MACOSX/pages/._004.png", data: page),
                DocumentFixtures.ArchiveEntry(name: "._004.png", data: page),
                DocumentFixtures.ArchiveEntry(name: "credits.txt", data: Data("thanks".utf8)),
            ]),
            to: directory.appendingPathComponent("mac-made.cbz")
        )

        let info = try inspector.inspect(archive)
        #expect(info.kind == .comicArchiveZIP)
        #expect(info.pageCount == 4)
        #expect(info.excludedEntryCount == 12)
    }

    /// `ComicInfo.xml` arrives in whatever case the writing machine used.
    @Test("exclusions are case-insensitive", arguments: ["ComicInfo.xml", "comicinfo.xml", "COMICINFO.XML"])
    func caseInsensitiveExclusions(_ name: String) throws {
        let page = try DocumentFixtures.solidPNG()
        let directory = try DocumentFixtures.makeTemporaryDirectory("case")
        defer { try? FileManager.default.removeItem(at: directory) }

        let archive = try DocumentFixtures.write(
            DocumentFixtures.zipArchive([
                DocumentFixtures.ArchiveEntry(name: "01.png", data: page),
                DocumentFixtures.ArchiveEntry(name: name, data: Data("<x/>".utf8)),
            ]),
            to: directory.appendingPathComponent("case.cbz")
        )
        #expect(try inspector.pageCount(of: archive) == 1)
    }

    /// Nothing is decoded, and this is how that is provable rather than
    /// asserted: a page whose bytes are garbage still counts, because the count
    /// is of pages the archive *claims*.
    @Test("a corrupt page still counts, because nothing opens it")
    func corruptPagesStillCount() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("corrupt")
        defer { try? FileManager.default.removeItem(at: directory) }

        let archive = try DocumentFixtures.write(
            DocumentFixtures.zipArchive([
                DocumentFixtures.ArchiveEntry(name: "01.png", data: try DocumentFixtures.solidPNG()),
                DocumentFixtures.ArchiveEntry(name: "02.jpg", data: Data("not an image at all".utf8)),
                DocumentFixtures.ArchiveEntry(name: "03.jpg", data: Data()),
            ]),
            to: directory.appendingPathComponent("corrupt.cbz")
        )
        #expect(try inspector.pageCount(of: archive) == 3)
    }

    // MARK: - Zero, and not-a-document

    /// Zero is the legitimate answer for an empty archive. An unsupported type
    /// therefore cannot also be zero, or a caller cannot tell "the comic is
    /// empty" from "this is not a comic" — and those lead to opposite recoveries.
    @Test("an empty archive is zero pages, not an error")
    func emptyArchiveIsZero() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("empty")
        defer { try? FileManager.default.removeItem(at: directory) }

        let archive = try DocumentFixtures.write(
            DocumentFixtures.zipArchive([]),
            to: directory.appendingPathComponent("empty.cbz")
        )
        let info = try inspector.inspect(archive)
        #expect(info.pageCount == 0)
        #expect(info.excludedEntryCount == 0)
    }

    /// An archive of nothing but junk is also zero — same answer, same reason.
    @Test("an archive with no image members is zero pages")
    func junkOnlyArchiveIsZero() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("junk-only")
        defer { try? FileManager.default.removeItem(at: directory) }

        let archive = try DocumentFixtures.write(
            DocumentFixtures.zipArchive([
                DocumentFixtures.ArchiveEntry(name: "ComicInfo.xml", data: Data("<x/>".utf8)),
                .directory("pages"),
            ]),
            to: directory.appendingPathComponent("junk-only.cbz")
        )
        #expect(try inspector.pageCount(of: archive) == 0)
    }

    @Test("an unsupported document type is an error, never zero")
    func unsupportedTypesThrow() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("unsupported")
        defer { try? FileManager.default.removeItem(at: directory) }

        let text = try DocumentFixtures.write(
            Data("this is not a comic\n".utf8), to: directory.appendingPathComponent("notes.txt")
        )
        // A RAR wearing a .cbz extension. Extremely common in the wild, and the
        // reason the type is sniffed from the bytes rather than read off the
        // filename.
        let rar = try DocumentFixtures.write(
            Data(Array("Rar!\u{1A}\u{07}\u{00}".utf8) + [0x00, 0x00, 0x00]),
            to: directory.appendingPathComponent("volume.cbz")
        )
        let image = try DocumentFixtures.write(
            try DocumentFixtures.solidPNG(), to: directory.appendingPathComponent("page.png")
        )
        let missing = directory.appendingPathComponent("nothing-here.cbz")

        #expect(throws: LatheError.self) { _ = try inspector.pageCount(of: text) }
        #expect(throws: LatheError.self) { _ = try inspector.pageCount(of: rar) }
        #expect(throws: LatheError.self) { _ = try inspector.pageCount(of: image) }
        #expect(throws: LatheError.self) { _ = try inspector.pageCount(of: missing) }
        #expect(throws: LatheError.self) { _ = try inspector.pageCount(of: directory) }
    }

    /// The RAR refusal says RAR. A caller routing on the message — or a person
    /// reading a log — should not have to guess which of the several "not a
    /// document" cases they hit.
    @Test("a CBR is refused by name")
    func cbrIsNamed() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("cbr")
        defer { try? FileManager.default.removeItem(at: directory) }
        let rar = try DocumentFixtures.write(
            Data(Array("Rar!\u{1A}\u{07}\u{01}\u{00}".utf8)),
            to: directory.appendingPathComponent("volume.cbr")
        )
        do {
            let counted = try inspector.pageCount(of: rar)
            Issue.record("a RAR archive was counted as \(counted) pages")
        } catch let LatheError.invalidInput(reason) {
            #expect(reason.contains("RAR"))
        }
    }

    // MARK: - PDF

    @Test("PDF page count matches the generated document", arguments: [1, 2, 7, 33])
    func pdfPageCount(_ pages: Int) throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("pdf")
        defer { try? FileManager.default.removeItem(at: directory) }

        let pdf = try DocumentFixtures.write(
            try DocumentFixtures.shapesPDF(pageCount: pages),
            to: directory.appendingPathComponent("pages.pdf")
        )
        let info = try inspector.inspect(pdf)
        #expect(info.kind == .pdf)
        #expect(info.pageCount == pages)
        #expect(info.excludedEntryCount == 0)
    }

    /// A `.pdf` extension is a claim; `%PDF-` is a fact. A PDF named `.cbz` is
    /// counted as a PDF and a ZIP named `.pdf` as an archive.
    @Test("the type comes from the bytes, not the extension")
    func extensionIsNotTheType() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("sniff")
        defer { try? FileManager.default.removeItem(at: directory) }

        let pdfNamedCBZ = try DocumentFixtures.write(
            try DocumentFixtures.shapesPDF(pageCount: 3),
            to: directory.appendingPathComponent("actually-a-pdf.cbz")
        )
        let zipNamedPDF = try DocumentFixtures.write(
            DocumentFixtures.zipArchive([
                DocumentFixtures.ArchiveEntry(name: "01.png", data: try DocumentFixtures.solidPNG()),
            ]),
            to: directory.appendingPathComponent("actually-a-zip.pdf")
        )

        #expect(try inspector.inspect(pdfNamedCBZ).kind == .pdf)
        #expect(try inspector.inspect(pdfNamedCBZ).pageCount == 3)
        #expect(try inspector.inspect(zipNamedPDF).kind == .comicArchiveZIP)
        #expect(try inspector.inspect(zipNamedPDF).pageCount == 1)
    }

    // MARK: - The classification rule itself

    @Test("page classification", arguments: [
        ("001.jpg", true),
        ("001.JPEG", true),
        ("sub/dir/002.png", true),
        ("003.gif", true),
        ("004.webp", true),
        ("005.tif", true),
        ("pages/", false),
        ("__MACOSX/._001.jpg", false),
        ("__MACOSX/sub/001.jpg", false),
        ("._001.jpg", false),
        ("ComicInfo.xml", false),
        (".DS_Store", false),
        ("Thumbs.db", false),
        ("desktop.ini", false),
        ("readme.txt", false),
        ("bundled.pdf", false),
        ("noextension", false),
    ])
    func classification(_ name: String, _ isPage: Bool) {
        let entry = ZIPEntry(
            name: name,
            compressionMethod: 8,
            compressedSize: 10,
            uncompressedSize: 10,
            localHeaderOffset: 0,
            externalAttributes: 0
        )
        #expect(DocumentInspector.isPage(entry) == isPage)
    }

    /// A folder entry written without the trailing slash, which some writers do,
    /// is still a folder — the MS-DOS attribute bit says so.
    @Test("a directory entry is recognised from its attributes too")
    func directoryByAttributes() {
        let entry = ZIPEntry(
            name: "pages",
            compressionMethod: 0,
            compressedSize: 0,
            uncompressedSize: 0,
            localHeaderOffset: 0,
            externalAttributes: 0x10
        )
        #expect(entry.isDirectory)
        #expect(!DocumentInspector.isPage(entry))
    }
}
