import Foundation
import LatheCore
import LatheFixtures
import Testing

#if canImport(PDFKit)
import PDFKit
#endif

@testable import LatheDoc

/// Rearranging pages, and the ways a rearrangement silently does the wrong
/// thing: losing a page, re-encoding one, or appearing to have worked because
/// the viewer sorts differently from the file.
@Suite("Document editing")
struct DocumentEditorTests {

    private let editor = DocumentEditor()
    private let inspector = DocumentInspector()

    // MARK: - Rig

    /// A CBZ whose pages are distinguishable by their bytes.
    ///
    /// Each page is a solid PNG of a different grey, so "page 3 of the output is
    /// page 3 of the source" is a byte comparison rather than a guess. Identical
    /// pages could not tell a correct reorder from one that did nothing.
    private func makeComic(
        in directory: URL, named name: String, pageCount: Int, extras: [DocumentFixtures.ArchiveEntry] = []
    ) throws -> (url: URL, pages: [Data]) {
        var pages: [Data] = []
        var entries: [DocumentFixtures.ArchiveEntry] = []
        for index in 0..<pageCount {
            let png = try DocumentFixtures.solidPNG(gray: CGFloat(index) / CGFloat(pageCount + 1))
            pages.append(png)
            entries.append(DocumentFixtures.ArchiveEntry(
                name: String(format: "p%03d.png", index), data: png
            ))
        }
        let url = try DocumentFixtures.write(
            DocumentFixtures.zipArchive(entries + extras),
            to: directory.appendingPathComponent(name)
        )
        return (url, pages)
    }

    /// The image bytes of a comic archive, in the order a reader would show
    /// them — sorted by name, which is the ordering that actually matters.
    private func comicPages(of url: URL) throws -> [Data] {
        let name = url.lastPathComponent
        let entries = try ZIPDirectory.entries(of: url, name: name)
            .filter(DocumentInspector.isPage)
            .sorted { $0.name < $1.name }
        return try entries.map { try ZIPDirectory.extract($0, from: url, name: name) }
    }

    #if canImport(PDFKit)
    /// The text of each page, which for a labelled fixture names the page.
    private func pdfLabels(of url: URL) throws -> [String] {
        guard let document = PDFDocument(url: url) else {
            Issue.record("could not open \(url.lastPathComponent)")
            return []
        }
        return (0..<document.pageCount).map { index in
            (document.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    #endif

    // MARK: - The headline: a reorder a reader actually sees

    /// **Reordering a comic archive has to rename its pages.**
    ///
    /// Comic readers sort entries by name. An edit that moved the bytes into a
    /// new archive order and kept `p000.png`, `p001.png`… would look completely
    /// correct in a hex dump and completely unchanged in every reader — the
    /// worst kind of bug, because the file really did change and the change
    /// really is invisible.
    @Test("reordering a comic renames its pages, so a reader sees the new order")
    func comicReorderRenames() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("reorder")
        defer { try? FileManager.default.removeItem(at: directory) }

        let (source, pages) = try makeComic(in: directory, named: "in.cbz", pageCount: 5)
        let output = directory.appendingPathComponent("out.cbz")

        let result = try editor.reorderPages(of: source, to: [4, 3, 2, 1, 0], writingTo: output)
        #expect(result.pageCount == 5)
        #expect(result.kind == .comicArchiveZIP)

        let reordered = try comicPages(of: output)
        #expect(reordered == pages.reversed(), "a reader sorting by name must see the new order")
    }

    /// The other half of the same guarantee: the names must sort numerically,
    /// which for a string sort means zero padding. Page 10 after page 9, not
    /// after page 1.
    @Test("page names are padded so ten pages sort in order, not lexically")
    func comicNamesSortNumerically() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("padding")
        defer { try? FileManager.default.removeItem(at: directory) }

        let (source, pages) = try makeComic(in: directory, named: "in.cbz", pageCount: 12)
        let output = directory.appendingPathComponent("out.cbz")
        try editor.reorderPages(of: source, to: Array((0..<12).reversed()), writingTo: output)

        let names = try ZIPDirectory.entries(of: output, name: "out.cbz").map(\.name)
        #expect(names == names.sorted(), "archive order and name order must agree")
        #expect(try comicPages(of: output) == pages.reversed())
    }

    // MARK: - Nothing is re-encoded

    /// **The pages come out bit-for-bit as they went in.**
    ///
    /// A reorder that decodes and re-encodes looks identical in a viewer and has
    /// quietly spent a generation of quality on every page. The only way to know
    /// it did not happen is to compare the bytes.
    @Test("rearranging a comic does not re-encode a single page")
    func comicPagesAreCopiedVerbatim() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("verbatim")
        defer { try? FileManager.default.removeItem(at: directory) }

        let (source, pages) = try makeComic(in: directory, named: "in.cbz", pageCount: 4)
        let output = directory.appendingPathComponent("out.cbz")
        try editor.removePages([1], from: source, writingTo: output)

        let kept = try comicPages(of: output)
        #expect(kept == [pages[0], pages[2], pages[3]])

        // The decoded bytes matching is most of the claim. The rest is that the
        // STORED bytes match too: a page copied verbatim keeps its compression
        // method and its payload, so the archive was re-indexed and the images
        // were never touched at all.
        let before = try ZIPDirectory.entries(of: source, name: "in.cbz")
            .filter(DocumentInspector.isPage)
            .sorted { $0.name < $1.name }
        let after = try ZIPDirectory.entries(of: output, name: "out.cbz")
            .filter(DocumentInspector.isPage)
            .sorted { $0.name < $1.name }
        let survivors = [before[0], before[2], before[3]]

        #expect(after.map(\.compressionMethod) == survivors.map(\.compressionMethod))
        #expect(after.map(\.compressedSize) == survivors.map(\.compressedSize))
        for (new, old) in zip(after, survivors) {
            let newBytes = try ZIPDirectory.rawPayload(new, from: output, name: "out.cbz")
            let oldBytes = try ZIPDirectory.rawPayload(old, from: source, name: "in.cbz")
            #expect(newBytes == oldBytes, "page \(new.name) was re-encoded, not copied")
        }
    }

    /// The timestamps ride along too, so rearranging an archive does not restamp
    /// every page to the moment of the edit.
    @Test("a page keeps the timestamp it had")
    func comicKeepsTimestamps() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("stamps")
        defer { try? FileManager.default.removeItem(at: directory) }

        let (source, _) = try makeComic(in: directory, named: "in.cbz", pageCount: 3)
        let output = directory.appendingPathComponent("out.cbz")
        try editor.reorderPages(of: source, to: [2, 1, 0], writingTo: output)

        let before = try ZIPDirectory.entries(of: source, name: "in.cbz").filter(DocumentInspector.isPage)
        let after = try ZIPDirectory.entries(of: output, name: "out.cbz").filter(DocumentInspector.isPage)
        #expect(after.map(\.modificationDate) == before.reversed().map(\.modificationDate))
        #expect(after.map(\.crc32) == before.reversed().map(\.crc32))
    }

    // MARK: - Page indices mean pages

    /// A `ComicInfo.xml` between two images must not shift the numbering: page
    /// 1 is the second *image*, not the second archive member.
    @Test("archive junk does not shift the page numbering")
    func nonPageEntriesDoNotShiftIndices() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("junk")
        defer { try? FileManager.default.removeItem(at: directory) }

        let (source, pages) = try makeComic(
            in: directory, named: "in.cbz", pageCount: 3,
            extras: [
                DocumentFixtures.ArchiveEntry(name: "ComicInfo.xml", data: Data("<x/>".utf8)),
                DocumentFixtures.ArchiveEntry(name: ".DS_Store", data: Data([0, 1])),
            ]
        )
        #expect(try inspector.pageCount(of: source) == 3)

        let output = directory.appendingPathComponent("out.cbz")
        try editor.removePages([0], from: source, writingTo: output)
        #expect(try comicPages(of: output) == [pages[1], pages[2]])
    }

    /// **"Page 3" means the third page a READER shows.**
    ///
    /// The central directory lists entries in whatever order the writing tool
    /// emitted, and a reader ignores that and sorts by name. An archive whose
    /// two orders disagree — a page appended after the fact, say — would make
    /// every index refer to a different page than the caller was looking at,
    /// and the edit would come out shuffled in a way that looks like the
    /// caller's mistake.
    @Test("page indices follow the order a reader shows, not the archive's order")
    func indicesFollowReadingOrder() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("shuffled-archive")
        defer { try? FileManager.default.removeItem(at: directory) }

        // Three pages stored in an order that is NOT their name order.
        var greys: [CGFloat] = [0.1, 0.5, 0.9]
        var byName: [String: Data] = [:]
        for (index, grey) in greys.enumerated() {
            byName[String(format: "p%03d.png", index)] = try DocumentFixtures.solidPNG(gray: grey)
        }
        let archiveOrder = ["p002.png", "p000.png", "p001.png"]
        let source = try DocumentFixtures.write(
            DocumentFixtures.zipArchive(archiveOrder.map {
                DocumentFixtures.ArchiveEntry(name: $0, data: byName[$0]!)
            }),
            to: directory.appendingPathComponent("in.cbz")
        )
        greys.removeAll()

        // Page 0 is p000.png — the first by name — not p002.png, which happens
        // to sit first in the file.
        let output = directory.appendingPathComponent("out.cbz")
        try editor.removePages([1, 2], from: source, writingTo: output)

        let kept = try comicPages(of: output)
        #expect(kept.count == 1)
        #expect(kept.first == byName["p000.png"], "index 0 took the wrong page")
    }

    /// Entries an edit cannot carry across are reported rather than vanishing.
    ///
    /// A `ComicInfo.xml` records a page count and per-page entries, so carrying
    /// it through a reorder unchanged would describe a document that no longer
    /// exists — an archive that disagrees with itself, which is harder to spot
    /// than one that is missing a file. Dropping it is the current answer;
    /// dropping it *silently* would not be.
    @Test("entries the edit cannot carry across are named in the result")
    func droppedEntriesAreReported() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("dropped")
        defer { try? FileManager.default.removeItem(at: directory) }

        let (source, _) = try makeComic(
            in: directory, named: "in.cbz", pageCount: 3,
            extras: [
                DocumentFixtures.ArchiveEntry(name: "ComicInfo.xml", data: Data("<x/>".utf8)),
                DocumentFixtures.ArchiveEntry(name: "credits.txt", data: Data("hi".utf8)),
            ]
        )
        let output = directory.appendingPathComponent("out.cbz")
        let result = try editor.reorderPages(of: source, to: [2, 1, 0], writingTo: output)

        #expect(result.droppedEntries == ["ComicInfo.xml", "credits.txt"])
        let names = try ZIPDirectory.entries(of: output, name: "out.cbz").map(\.name)
        #expect(!names.contains("ComicInfo.xml"))
    }

    /// An archive with nothing but pages loses nothing, so the report is empty
    /// rather than noisy.
    @Test("an archive of nothing but pages reports no losses")
    func noDroppedEntriesWhenThereAreNone() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("clean")
        defer { try? FileManager.default.removeItem(at: directory) }

        let (source, _) = try makeComic(in: directory, named: "in.cbz", pageCount: 2)
        let output = directory.appendingPathComponent("out.cbz")
        let result = try editor.reorderPages(of: source, to: [1, 0], writingTo: output)
        #expect(result.droppedEntries.isEmpty)
    }

    /// The same path spelled two ways is the same file, and the check has to say
    /// so — the case that slips through is the destructive one.
    @Test("an unnormalised path to the source is still the source")
    func inPlaceIsRefusedThroughAnAliasedPath() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("aliased")
        defer { try? FileManager.default.removeItem(at: directory) }

        let (source, _) = try makeComic(in: directory, named: "in.cbz", pageCount: 2)
        let aliased = directory.appendingPathComponent("./in.cbz")

        #expect(throws: LatheError.self) {
            try editor.reorderPages(of: source, to: [1, 0], writingTo: aliased)
        }
        #expect(try inspector.pageCount(of: source) == 2)
    }

    // MARK: - PDF

    @Test("reordering a PDF moves the pages a reader sees")
    func pdfReorder() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("pdf-reorder")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try DocumentFixtures.write(
            try DocumentFixtures.numberedPDF(pageCount: 4),
            to: directory.appendingPathComponent("in.pdf")
        )
        let output = directory.appendingPathComponent("out.pdf")
        let result = try editor.reorderPages(of: source, to: [3, 0, 2, 1], writingTo: output)

        #expect(result.kind == .pdf)
        #expect(result.pageCount == 4)
        #if canImport(PDFKit)
        #expect(try pdfLabels(of: output) == ["PAGE-4", "PAGE-1", "PAGE-3", "PAGE-2"])
        #endif
    }

    @Test("removing PDF pages leaves the rest in order")
    func pdfRemove() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("pdf-remove")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try DocumentFixtures.write(
            try DocumentFixtures.numberedPDF(pageCount: 5),
            to: directory.appendingPathComponent("in.pdf")
        )
        let output = directory.appendingPathComponent("out.pdf")
        let result = try editor.removePages([1, 3], from: source, writingTo: output)

        #expect(result.pageCount == 3)
        #expect(try inspector.pageCount(of: output) == 3)
        #if canImport(PDFKit)
        #expect(try pdfLabels(of: output) == ["PAGE-1", "PAGE-3", "PAGE-5"])
        #endif
    }

    @Test("merging PDFs concatenates them in the order given")
    func pdfMerge() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("pdf-merge")
        defer { try? FileManager.default.removeItem(at: directory) }

        let a = try DocumentFixtures.write(
            try DocumentFixtures.labelledPDF(labels: ["A-1", "A-2"]),
            to: directory.appendingPathComponent("a.pdf")
        )
        let b = try DocumentFixtures.write(
            try DocumentFixtures.labelledPDF(labels: ["B-1"]),
            to: directory.appendingPathComponent("b.pdf")
        )
        let output = directory.appendingPathComponent("out.pdf")
        let result = try editor.merge([a, b, a], into: output)

        #expect(result.pageCount == 5)
        #expect(result.sourceCount == 2, "the same document used twice is one source")
        #if canImport(PDFKit)
        #expect(try pdfLabels(of: output) == ["A-1", "A-2", "B-1", "A-1", "A-2"])
        #endif
    }

    /// Using one source twice must not empty it the first time. PDFKit's insert
    /// MOVES a page object out of its document, so a naive merge loses the
    /// second copy — and produces a document of the right length with a blank
    /// in it.
    @Test("a source used twice contributes its pages both times")
    func pdfSourceReusedKeepsItsPages() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("pdf-reuse")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try DocumentFixtures.write(
            try DocumentFixtures.numberedPDF(pageCount: 2),
            to: directory.appendingPathComponent("in.pdf")
        )
        let output = directory.appendingPathComponent("out.pdf")
        let pages = try editor.pages(of: source)
        try editor.assemble(pages + pages, into: output)

        #if canImport(PDFKit)
        #expect(try pdfLabels(of: output) == ["PAGE-1", "PAGE-2", "PAGE-1", "PAGE-2"])
        #endif
        // And the source is untouched.
        #expect(try inspector.pageCount(of: source) == 2)
    }

    @Test("inserting places a document before the page named, and at the end")
    func pdfInsert() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("pdf-insert")
        defer { try? FileManager.default.removeItem(at: directory) }

        let target = try DocumentFixtures.write(
            try DocumentFixtures.labelledPDF(labels: ["T-1", "T-2"]),
            to: directory.appendingPathComponent("t.pdf")
        )
        let inserted = try DocumentFixtures.write(
            try DocumentFixtures.labelledPDF(labels: ["I-1"]),
            to: directory.appendingPathComponent("i.pdf")
        )

        let middle = directory.appendingPathComponent("middle.pdf")
        try editor.insert(inserted, at: 1, into: target, writingTo: middle)
        #if canImport(PDFKit)
        #expect(try pdfLabels(of: middle) == ["T-1", "I-1", "T-2"])
        #endif

        let end = directory.appendingPathComponent("end.pdf")
        try editor.insert(inserted, at: 2, into: target, writingTo: end)
        #if canImport(PDFKit)
        #expect(try pdfLabels(of: end) == ["T-1", "T-2", "I-1"])
        #endif
    }

    // MARK: - Refusals

    /// A "reorder" that drops a page is data loss wearing the name of a
    /// rearrangement. The caller who meant to delete has a function for it.
    @Test("a reorder that is not a permutation is refused, not silently applied")
    func reorderMustBeAPermutation() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("perm")
        defer { try? FileManager.default.removeItem(at: directory) }

        let (source, _) = try makeComic(in: directory, named: "in.cbz", pageCount: 4)
        let output = directory.appendingPathComponent("out.cbz")

        #expect(throws: LatheError.self) {
            try editor.reorderPages(of: source, to: [0, 1, 2], writingTo: output)      // drops one
        }
        #expect(throws: LatheError.self) {
            try editor.reorderPages(of: source, to: [0, 0, 1, 2], writingTo: output)   // repeats one
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("a page index outside the document is refused by number")
    func outOfRangeIsRefused() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("range")
        defer { try? FileManager.default.removeItem(at: directory) }

        let (source, _) = try makeComic(in: directory, named: "in.cbz", pageCount: 3)
        let output = directory.appendingPathComponent("out.cbz")

        #expect(throws: LatheError.self) {
            try editor.removePages([3], from: source, writingTo: output)
        }
        #expect(throws: LatheError.self) {
            try editor.removePages([-1], from: source, writingTo: output)
        }
    }

    @Test("an edit that would leave no pages is refused")
    func emptyResultIsRefused() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("empty")
        defer { try? FileManager.default.removeItem(at: directory) }

        let (source, _) = try makeComic(in: directory, named: "in.cbz", pageCount: 2)
        let output = directory.appendingPathComponent("out.cbz")

        #expect(throws: LatheError.self) {
            try editor.removePages([0, 1], from: source, writingTo: output)
        }
        #expect(throws: LatheError.self) {
            try editor.assemble([], into: output)
        }
    }

    /// Rearranging pages is not format conversion, and half-handling a mixed
    /// assembly would produce a file that is neither.
    @Test("a PDF and a comic cannot be assembled into one document")
    func mixedKindsAreRefused() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("mixed")
        defer { try? FileManager.default.removeItem(at: directory) }

        let (comic, _) = try makeComic(in: directory, named: "in.cbz", pageCount: 2)
        let pdf = try DocumentFixtures.write(
            try DocumentFixtures.numberedPDF(pageCount: 2),
            to: directory.appendingPathComponent("in.pdf")
        )
        let output = directory.appendingPathComponent("out.pdf")

        #expect(throws: LatheError.self) {
            try editor.assemble([
                PageReference(source: pdf, index: 0),
                PageReference(source: comic, index: 0),
            ], into: output)
        }
    }

    @Test("an edit cannot overwrite the file it is reading")
    func inPlaceIsRefused() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("inplace")
        defer { try? FileManager.default.removeItem(at: directory) }

        let (source, _) = try makeComic(in: directory, named: "in.cbz", pageCount: 3)
        #expect(throws: LatheError.self) {
            try editor.reorderPages(of: source, to: [2, 1, 0], writingTo: source)
        }
        // And the source still reads as it did.
        #expect(try inspector.pageCount(of: source) == 3)
    }

    /// A failure must leave whatever was at the destination alone. Writing
    /// through a scratch file and moving it into place is what makes that true,
    /// and it is worth asserting because the failure mode — a half-written file
    /// replacing a good one — is unrecoverable.
    @Test("a failed edit leaves an existing destination untouched")
    func failureLeavesTheDestinationAlone() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("atomic")
        defer { try? FileManager.default.removeItem(at: directory) }

        let (source, _) = try makeComic(in: directory, named: "in.cbz", pageCount: 3)
        let output = directory.appendingPathComponent("out.cbz")
        let existing = Data("not a zip, and must survive".utf8)
        try DocumentFixtures.write(existing, to: output)

        #expect(throws: LatheError.self) {
            try editor.removePages([9], from: source, writingTo: output)
        }
        #expect(try Data(contentsOf: output) == existing)
    }

    // MARK: - Round trip

    /// Reordering and reordering back is the identity, which catches an error
    /// that a single pass cannot: a transformation that is consistently wrong.
    @Test("a reorder and its inverse return the original pages")
    func reorderRoundTrips() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("roundtrip")
        defer { try? FileManager.default.removeItem(at: directory) }

        let (source, pages) = try makeComic(in: directory, named: "in.cbz", pageCount: 6)
        let shuffled = directory.appendingPathComponent("shuffled.cbz")
        let restored = directory.appendingPathComponent("restored.cbz")

        let order = [3, 0, 5, 1, 4, 2]
        try editor.reorderPages(of: source, to: order, writingTo: shuffled)

        // The inverse permutation: where each original page ended up.
        var inverse = [Int](repeating: 0, count: order.count)
        for (position, original) in order.enumerated() { inverse[original] = position }
        try editor.reorderPages(of: shuffled, to: inverse, writingTo: restored)

        #expect(try comicPages(of: restored) == pages)
    }
}
