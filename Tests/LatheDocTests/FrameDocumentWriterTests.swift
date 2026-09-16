import CoreGraphics
import Foundation
import LatheCore
import LatheFixtures
import LatheImage
import Testing

#if canImport(PDFKit)
import PDFKit
#endif

@testable import LatheDoc

/// Assembling stills into a paged document, and the two ways it goes wrong
/// invisibly: a comic archive whose reader shows the pages in a different order
/// from the one that was written, and a PDF that looks right on screen and
/// prints at the wrong size.
///
/// Every assertion reads the produced file back — through `PDFDocument` for page
/// counts and boxes, through `ZIPDirectory` for archive members — rather than
/// trusting the writer's own result.
@Suite("Documents from frames")
struct FrameDocumentWriterTests {

    private let writer = FrameDocumentWriter()
    private let inspector = DocumentInspector()

    private func temporaryDirectory(_ label: String) throws -> URL {
        try DocumentFixtures.makeTemporaryDirectory("compose-\(label)")
    }

    // MARK: - PDF

    /// **The headline: one page per frame, at the size the frame implies.**
    @Test("a run of stills becomes a PDF of the same length")
    func pdfRoundTrip() throws {
        let directory = try temporaryDirectory("pdf")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 5, in: directory, size: CGSize(width: 120, height: 90))
        let frames = try FrameSequence.contentsOfDirectory(directory)
        let output = directory.appendingPathComponent("out.pdf")

        let result = try writer.writePDF(frames, to: output)
        #expect(result.pageCount == 5)
        #expect(result.kind == .pdf)
        #expect(result.outputByteCount > 0)

        // Counted by the module's own inspector, which is PDFKit underneath —
        // the same path anything downstream would take.
        #expect(try inspector.pageCount(of: output) == 5)
        #expect(try inspector.inspect(output).kind == .pdf)

        #if canImport(PDFKit)
        guard let document = PDFDocument(url: output) else {
            Issue.record("PDFKit would not open the written PDF")
            return
        }
        #expect(document.pageCount == 5)
        let box = document.page(at: 0)!.bounds(for: .mediaBox)
        #expect(abs(box.width - 120) < 0.5)
        #expect(abs(box.height - 90) < 0.5)
        #endif
    }

    /// **A PDF measures in points and an image has only pixels**, so the
    /// relationship has to be stated. Getting it wrong is not a rendering bug:
    /// the page looks identical on screen either way and prints at the wrong
    /// size.
    ///
    /// A 300x300 frame at 300 DPI is a one-inch page — 72 points.
    @Test("a resolution turns pixels into a page of the right physical size")
    func pdfPageSizing() throws {
        let directory = try temporaryDirectory("dpi")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 1, in: directory, size: CGSize(width: 300, height: 300))
        let frames = try FrameSequence.contentsOfDirectory(directory)

        #if canImport(PDFKit)
        let atDPI = directory.appendingPathComponent("dpi.pdf")
        try writer.writePDF(frames, to: atDPI, pageSizing: .dotsPerInch(300))
        let dpiBox = PDFDocument(url: atDPI)!.page(at: 0)!.bounds(for: .mediaBox)
        #expect(abs(dpiBox.width - 72) < 0.5, "300 pixels at 300 DPI is one inch")
        #expect(abs(dpiBox.height - 72) < 0.5)

        // 72 DPI is the definition of a point, so it must be identical to
        // `.imagePixels`. If these two ever disagree the arithmetic is wrong.
        let atPixels = directory.appendingPathComponent("pixels.pdf")
        try writer.writePDF(frames, to: atPixels, pageSizing: .imagePixels)
        let pixelBox = PDFDocument(url: atPixels)!.page(at: 0)!.bounds(for: .mediaBox)

        let at72 = directory.appendingPathComponent("72.pdf")
        try writer.writePDF(frames, to: at72, pageSizing: .dotsPerInch(72))
        #expect(PDFDocument(url: at72)!.page(at: 0)!.bounds(for: .mediaBox) == pixelBox)
        #expect(abs(pixelBox.width - 300) < 0.5)
        #endif
    }

    /// A fixed page keeps its size whatever shape the frames are, and the frames
    /// are fitted inside rather than cropped to it.
    @Test("a fixed page size is honoured for every frame, whatever its shape")
    func pdfFixedPages() throws {
        let directory = try temporaryDirectory("letter")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 3, in: directory, sizes: [
            CGSize(width: 100, height: 400),
            CGSize(width: 400, height: 100),
            CGSize(width: 200, height: 200),
        ])
        let frames = try FrameSequence.contentsOfDirectory(directory)
        let output = directory.appendingPathComponent("out.pdf")

        try writer.writePDF(
            frames, to: output, pageSizing: .fixed(widthPoints: 612, heightPoints: 792)
        )

        #if canImport(PDFKit)
        let document = PDFDocument(url: output)!
        #expect(document.pageCount == 3)
        for index in 0..<3 {
            let box = document.page(at: index)!.bounds(for: .mediaBox)
            #expect(abs(box.width - 612) < 0.5, "page \(index + 1) is \(box.width) wide")
            #expect(abs(box.height - 792) < 0.5)
        }
        #endif
    }

    /// Different-sized frames each get their own page. A single media box for
    /// the document would crop every page to the first one's shape, which for a
    /// run of scans is exactly the wrong answer.
    @Test("frames of different sizes each get a page of their own size")
    func pdfPagesAreIndependentlySized() throws {
        let directory = try temporaryDirectory("mixed")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 2, in: directory, sizes: [
            CGSize(width: 100, height: 200), CGSize(width: 300, height: 150),
        ])
        let frames = try FrameSequence.contentsOfDirectory(directory)
        let output = directory.appendingPathComponent("out.pdf")
        try writer.writePDF(frames, to: output)

        #if canImport(PDFKit)
        let document = PDFDocument(url: output)!
        let first = document.page(at: 0)!.bounds(for: .mediaBox)
        let second = document.page(at: 1)!.bounds(for: .mediaBox)
        #expect(abs(first.width - 100) < 0.5 && abs(first.height - 200) < 0.5)
        #expect(abs(second.width - 300) < 0.5 && abs(second.height - 150) < 0.5)
        #endif
    }

    /// **Zero frames is an error, not a zero-page PDF.** `CGPDFContext` writes
    /// one happily and no reader will open it.
    @Test("no frames is refused rather than written as a pageless PDF")
    func pdfEmptyIsRefused() throws {
        let directory = try temporaryDirectory("pdf-empty")
        defer { try? FileManager.default.removeItem(at: directory) }

        let output = directory.appendingPathComponent("out.pdf")
        #expect(throws: LatheError.self) {
            try writer.writePDF(FrameSequence([]), to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("one frame is a one-page PDF")
    func pdfSinglePage() throws {
        let directory = try temporaryDirectory("pdf-single")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 1, in: directory)
        let frames = try FrameSequence.contentsOfDirectory(directory)
        let output = directory.appendingPathComponent("out.pdf")

        #expect(try writer.writePDF(frames, to: output).pageCount == 1)
        #expect(try inspector.pageCount(of: output) == 1)
    }

    @Test("a page resolution of zero is refused rather than dividing by it")
    func pdfZeroDPI() throws {
        let directory = try temporaryDirectory("pdf-dpi-zero")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 2, in: directory)
        let frames = try FrameSequence.contentsOfDirectory(directory)

        for sizing: PDFPageSizing in [
            .dotsPerInch(0), .dotsPerInch(-300),
            .fixed(widthPoints: 0, heightPoints: 100),
        ] {
            #expect(throws: LatheError.self) {
                try writer.writePDF(
                    frames, to: directory.appendingPathComponent("out.pdf"), pageSizing: sizing
                )
            }
        }
    }

    /// A failure part way must leave the caller's previous document intact —
    /// the whole reason the write goes through a scratch file.
    @Test("cancelling a PDF leaves the destination as it was")
    func pdfCancellation() throws {
        let directory = try temporaryDirectory("pdf-cancel")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 8, in: directory)
        let frames = try FrameSequence.contentsOfDirectory(directory)
        let output = directory.appendingPathComponent("out.pdf")
        try Data("previous".utf8).write(to: output)

        let handle = ProgressHandle(throttle: .unthrottled)
        handle.cancel()

        #expect(throws: LatheError.self) {
            try writer.writePDF(frames, to: output, progress: handle)
        }
        #expect(try Data(contentsOf: output) == Data("previous".utf8))
    }

    // MARK: - Comic archive

    /// **The pages go in byte for byte.**
    ///
    /// A CBZ is a ZIP of images, so there is no encode to have an opinion about
    /// and no reason for a single bit to change. A writer that decoded and
    /// re-encoded would produce an archive that looks identical in every reader
    /// and has quietly spent a generation of quality on every page; comparing
    /// the bytes is the only way to know it did not happen.
    @Test("a comic archive carries the frames' bytes across untouched")
    func comicPagesAreVerbatim() throws {
        let directory = try temporaryDirectory("cbz")
        defer { try? FileManager.default.removeItem(at: directory) }

        let sources = try FrameFixtures.stills(count: 4, in: directory, fileExtension: "jpg")
        let originals = try sources.map { try Data(contentsOf: $0) }
        let frames = FrameSequence(sources)
        let output = directory.appendingPathComponent("out.cbz")

        let result = try writer.writeComicArchive(frames, to: output)
        #expect(result.pageCount == 4)
        #expect(result.kind == .comicArchiveZIP)

        let entries = try ZIPDirectory.entries(of: output, name: "out.cbz")
            .filter(DocumentInspector.isPage)
            .sorted { $0.name < $1.name }
        #expect(entries.count == 4)

        let pages = try entries.map { try ZIPDirectory.extract($0, from: output, name: "out.cbz") }
        #expect(pages == originals, "a page must be bit-for-bit the image it came from")
    }

    /// **Comic readers sort by name, so the names have to carry the order.**
    ///
    /// Archive order is not display order in any reader worth naming, and the
    /// padding is what makes page 10 follow page 9 rather than page 1. The
    /// source names here are deliberately hostile — `z`, `a`, `m` — so a writer
    /// that kept them would be caught.
    @Test("pages are renamed and padded, so a reader sorting by name sees the order given")
    func comicNamesCarryTheOrder() throws {
        let directory = try temporaryDirectory("cbz-order")
        defer { try? FileManager.default.removeItem(at: directory) }

        var sources: [URL] = []
        var originals: [Data] = []
        for (index, stem) in ["z", "a", "m", "b", "q", "c", "y", "d", "n", "e", "p"].enumerated() {
            let data = try DocumentFixtures.solidPNG(gray: CGFloat(index + 1) / 13)
            originals.append(data)
            sources.append(try DocumentFixtures.write(
                data, to: directory.appendingPathComponent("\(stem).png")
            ))
        }

        let output = directory.appendingPathComponent("out.cbz")
        try writer.writeComicArchive(FrameSequence(sources), to: output)

        let entries = try ZIPDirectory.entries(of: output, name: "out.cbz")
            .filter(DocumentInspector.isPage)
        let names = entries.map(\.name)
        #expect(names == names.sorted(), "archive order and name order must agree")
        #expect(names.first == "page-01.png")
        #expect(names.last == "page-11.png", "eleven pages need two digits, or 10 sorts before 2")

        let inNameOrder = try entries
            .sorted { $0.name < $1.name }
            .map { try ZIPDirectory.extract($0, from: output, name: "out.cbz") }
        #expect(inNameOrder == originals,
                "a reader sorting by name must see the sequence that was handed over")
    }

    /// Each frame keeps its own extension, because the bytes are its own. A run
    /// of mixed formats is an archive of mixed formats, at no re-encode.
    @Test("a mixed-format run keeps each page's own format")
    func comicKeepsPerPageFormats() throws {
        let directory = try temporaryDirectory("cbz-mixed")
        defer { try? FileManager.default.removeItem(at: directory) }

        let png = try DocumentFixtures.write(
            try DocumentFixtures.solidPNG(gray: 0.3),
            to: directory.appendingPathComponent("a.png")
        )
        let jpeg = try DocumentFixtures.write(
            try DocumentFixtures.solidJPEG(gray: 0.7),
            to: directory.appendingPathComponent("b.jpg")
        )
        let output = directory.appendingPathComponent("out.cbz")
        try writer.writeComicArchive(FrameSequence([png, jpeg]), to: output)

        let names = try ZIPDirectory.entries(of: output, name: "out.cbz")
            .map(\.name).sorted()
        #expect(names == ["page-1.png", "page-2.jpg"])
    }

    /// The archive is counted by the module's own inspector, which is what
    /// anything downstream would use.
    @Test("the written archive counts as a comic with the right number of pages")
    func comicIsCountedAsWritten() throws {
        let directory = try temporaryDirectory("cbz-count")
        defer { try? FileManager.default.removeItem(at: directory) }

        let sources = try FrameFixtures.stills(count: 7, in: directory)
        let output = directory.appendingPathComponent("out.cbz")
        try writer.writeComicArchive(FrameSequence(sources), to: output)

        let info = try inspector.inspect(output)
        #expect(info.kind == .comicArchiveZIP)
        #expect(info.pageCount == 7)
    }

    /// **Zero frames is an error, not an empty archive.** `ZIPWriter` already
    /// refuses one; this checks the refusal reaches the caller rather than being
    /// swallowed into a zero-page CBZ.
    @Test("no frames is refused rather than written as an empty archive")
    func comicEmptyIsRefused() throws {
        let directory = try temporaryDirectory("cbz-empty")
        defer { try? FileManager.default.removeItem(at: directory) }

        let output = directory.appendingPathComponent("out.cbz")
        #expect(throws: LatheError.self) {
            try writer.writeComicArchive(FrameSequence([]), to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("one frame is a one-page archive")
    func comicSinglePage() throws {
        let directory = try temporaryDirectory("cbz-single")
        defer { try? FileManager.default.removeItem(at: directory) }

        let sources = try FrameFixtures.stills(count: 1, in: directory)
        let output = directory.appendingPathComponent("out.cbz")

        #expect(try writer.writeComicArchive(FrameSequence(sources), to: output).pageCount == 1)
        #expect(try inspector.pageCount(of: output) == 1)
    }

    /// A frame that is not an image would become a page no reader shows, so it
    /// is refused here rather than in somebody else's app.
    @Test("a non-image frame is refused rather than archived as an invisible page")
    func comicRefusesNonImages() throws {
        let directory = try temporaryDirectory("cbz-junk")
        defer { try? FileManager.default.removeItem(at: directory) }

        let page = try DocumentFixtures.write(
            try DocumentFixtures.solidPNG(), to: directory.appendingPathComponent("a.png")
        )
        let notes = directory.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: notes)

        #expect(throws: LatheError.self) {
            try writer.writeComicArchive(
                FrameSequence([page, notes]), to: directory.appendingPathComponent("out.cbz")
            )
        }
    }

    /// Frames of different sizes are ordinary for a comic: a page is its own
    /// size and nothing has to agree.
    @Test("a comic archive takes frames of different sizes without comment")
    func comicTakesMismatchedSizes() throws {
        let directory = try temporaryDirectory("cbz-sizes")
        defer { try? FileManager.default.removeItem(at: directory) }

        let sources = try FrameFixtures.stills(count: 3, in: directory, sizes: [
            CGSize(width: 100, height: 200),
            CGSize(width: 40, height: 40),
            CGSize(width: 300, height: 90),
        ])
        let output = directory.appendingPathComponent("out.cbz")
        #expect(try writer.writeComicArchive(FrameSequence(sources), to: output).pageCount == 3)
    }

    // MARK: - The seam with the rest of the package

    /// The two writers are fed by the same ``FrameSequence``, and a directory
    /// listing feeds both — which is the whole point of the shared vocabulary.
    @Test("one directory listing feeds both a PDF and a comic archive")
    func oneSequenceFeedsBoth() throws {
        let directory = try temporaryDirectory("both")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 4, in: directory)
        let frames = try FrameSequence.contentsOfDirectory(directory)

        let pdf = directory.appendingPathComponent("out.pdf")
        let cbz = directory.appendingPathComponent("out.cbz")
        #expect(try writer.writePDF(frames, to: pdf).pageCount == 4)
        #expect(try writer.writeComicArchive(frames, to: cbz).pageCount == 4)
        #expect(try inspector.pageCount(of: pdf) == 4)
        #expect(try inspector.pageCount(of: cbz) == 4)
    }
}
