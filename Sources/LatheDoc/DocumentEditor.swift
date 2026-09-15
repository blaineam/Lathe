import Foundation
import LatheCore
#if canImport(PDFKit)
import PDFKit
#endif

/// Rearranges the pages of a document.
///
/// ## One operation, not four
///
/// Reordering, deleting, inserting and merging look like four features and are
/// one: each describes a new document whose pages are drawn, in some order,
/// from one or more existing ones. ``assemble(_:into:)`` takes exactly that —
/// a list of ``PageReference`` — and the four named operations are convenience
/// spellings that build the list. That is why merging several PDFs needs no
/// separate code path, and why an edit that both drops a page and moves another
/// is a single pass rather than two rewrites.
///
/// It also makes the whole module testable against one invariant: the output's
/// page *n* is the source page the caller named, and nothing else changed.
///
/// ## Nothing is re-encoded
///
/// A comic archive is rewritten by copying each page's stored bytes verbatim —
/// see ``ZIPWriter`` — so the images in the result are bit-for-bit the images
/// in the source. A PDF is rewritten through PDFKit's own page objects, which
/// carry their content streams across rather than re-rendering them.
///
/// This matters because the alternative is silent: a reorder that re-encodes
/// looks identical in a viewer and has quietly cost a generation of quality on
/// every page.
public struct DocumentEditor: Sendable {

    public init() {}

    // MARK: - Assembling

    /// Builds a document at `destination` whose pages are `pages`, in order.
    ///
    /// Every source must be the same kind as every other, and the destination is
    /// that kind: this rearranges pages, it does not convert between formats.
    /// Mixing a PDF and a comic archive is refused by name rather than half
    /// handled.
    ///
    /// Writing is atomic — a failure part-way leaves `destination` exactly as it
    /// was, including leaving a previous file there intact.
    @discardableResult
    public func assemble(_ pages: [PageReference], into destination: URL) throws -> DocumentEditResult {
        guard !pages.isEmpty else {
            throw LatheError.invalidInput(
                reason: "a document needs at least one page; an edit that removes them all is a "
                    + "deletion, not an edit"
            )
        }

        // Distinct sources, in first-seen order, each opened once however many
        // of its pages are used.
        var sources: [URL] = []
        for page in pages where !sources.contains(page.source) {
            sources.append(page.source)
        }

        var kind: DocumentKind?
        var inputBytes: UInt64 = 0
        for source in sources {
            try DocumentFiles.requireReadableFile(at: source)
            let sourceKind = try DocumentInspector.kind(of: source, name: source.lastPathComponent)
            if let kind, kind != sourceKind {
                throw LatheError.invalidInput(
                    reason: "cannot assemble a \(kind) and a \(sourceKind) into one document; "
                        + "rearranging pages is not format conversion"
                )
            }
            kind = sourceKind
            inputBytes += DocumentFiles.byteCount(of: source) ?? 0
        }
        guard let kind else {
            throw LatheError.invalidInput(reason: "no sources to assemble")
        }

        // Standardised, because "/a/./b.cbz" and "/a/b.cbz" are the same file
        // and comparing the URLs as given would not say so — and the failure
        // that slips through is the destructive one.
        let target = destination.standardizedFileURL
        for page in pages where page.source.standardizedFileURL == target {
            throw LatheError.invalidInput(
                reason: "\(destination.lastPathComponent) is both a source and the destination; "
                    + "an edit cannot overwrite the file it is reading"
            )
        }

        let outputBytes: UInt64
        var droppedEntries: [String] = []
        switch kind {
        case .pdf:
            outputBytes = try assemblePDF(pages, into: destination)
        case .comicArchiveZIP:
            outputBytes = try assembleComic(pages, into: destination, droppedEntries: &droppedEntries)
        }

        return DocumentEditResult(
            output: destination,
            kind: kind,
            pageCount: pages.count,
            sourceCount: sources.count,
            inputByteCount: inputBytes,
            outputByteCount: outputBytes,
            droppedEntries: droppedEntries
        )
    }

    // MARK: - The named operations

    /// Every page of `source`, in order — the starting point for an edit the
    /// caller then rearranges.
    public func pages(of source: URL) throws -> [PageReference] {
        let count = try DocumentInspector().pageCount(of: source)
        return (0..<count).map { PageReference(source: source, index: $0) }
    }

    /// Writes `source` with its pages in the order given by `order`, which lists
    /// source page indices.
    ///
    /// `order` must be a permutation of the document's pages: every page named
    /// once. A list that drops or repeats one is refused, because "reorder" that
    /// silently deletes is the kind of data loss a caller finds out about later.
    /// Use ``removePages(_:from:writingTo:)`` to drop pages, or
    /// ``assemble(_:into:)`` to repeat them.
    @discardableResult
    public func reorderPages(
        of source: URL, to order: [Int], writingTo destination: URL
    ) throws -> DocumentEditResult {
        let count = try DocumentInspector().pageCount(of: source)
        try Self.requireInRange(order, count: count, of: source)

        guard Set(order).count == order.count, order.count == count else {
            throw LatheError.invalidInput(
                reason: "reordering \(source.lastPathComponent) needs each of its \(count) pages "
                    + "exactly once; got \(order.count) indices covering \(Set(order).count) pages"
            )
        }
        return try assemble(order.map { PageReference(source: source, index: $0) }, into: destination)
    }

    /// Writes `source` without the pages at `indices`.
    @discardableResult
    public func removePages(
        _ indices: [Int], from source: URL, writingTo destination: URL
    ) throws -> DocumentEditResult {
        let count = try DocumentInspector().pageCount(of: source)
        try Self.requireInRange(indices, count: count, of: source)

        let dropped = Set(indices)
        let kept = (0..<count).filter { !dropped.contains($0) }
        guard !kept.isEmpty else {
            throw LatheError.invalidInput(
                reason: "removing every page of \(source.lastPathComponent) would leave no "
                    + "document; delete the file instead"
            )
        }
        return try assemble(kept.map { PageReference(source: source, index: $0) }, into: destination)
    }

    /// Writes `sources` end to end as one document.
    @discardableResult
    public func merge(_ sources: [URL], into destination: URL) throws -> DocumentEditResult {
        guard sources.count >= 2 else {
            throw LatheError.invalidInput(reason: "merging needs at least two documents")
        }
        var pages: [PageReference] = []
        for source in sources {
            pages.append(contentsOf: try self.pages(of: source))
        }
        return try assemble(pages, into: destination)
    }

    /// Writes `target` with every page of `inserted` placed before its page
    /// `index`. An `index` equal to the page count appends.
    @discardableResult
    public func insert(
        _ inserted: URL, at index: Int, into target: URL, writingTo destination: URL
    ) throws -> DocumentEditResult {
        let existing = try pages(of: target)
        guard index >= 0, index <= existing.count else {
            throw LatheError.invalidInput(
                reason: "cannot insert at page \(index) of a \(existing.count)-page document; "
                    + "valid positions are 0 through \(existing.count)"
            )
        }
        var pages = existing
        pages.insert(contentsOf: try self.pages(of: inserted), at: index)
        return try assemble(pages, into: destination)
    }

    private static func requireInRange(_ indices: [Int], count: Int, of source: URL) throws {
        for index in indices where index < 0 || index >= count {
            throw LatheError.invalidInput(
                reason: "page \(index) is outside \(source.lastPathComponent), which has \(count) "
                    + "pages (valid indices are 0 through \(count - 1))"
            )
        }
    }

    // MARK: - PDF

    private func assemblePDF(_ pages: [PageReference], into destination: URL) throws -> UInt64 {
        #if canImport(PDFKit)
        var documents: [URL: PDFDocument] = [:]
        for page in pages where documents[page.source] == nil {
            guard let document = PDFDocument(url: page.source) else {
                throw LatheError.invalidInput(
                    reason: "\(page.source.lastPathComponent) is not a PDF PDFKit can open"
                )
            }
            // An encrypted document opens and reports a page count while handing
            // back nothing for any page, so the output would be a PDF of the
            // right length made entirely of nothing. Refuse here rather than
            // write that.
            if document.isEncrypted && document.isLocked {
                throw LatheError.invalidInput(
                    reason: "\(page.source.lastPathComponent) is locked; its pages cannot be read"
                )
            }
            documents[page.source] = document
        }

        let output = PDFDocument()
        for (position, page) in pages.enumerated() {
            guard let document = documents[page.source] else { continue }
            guard page.index >= 0, page.index < document.pageCount,
                  let sourcePage = document.page(at: page.index)
            else {
                throw LatheError.invalidInput(
                    reason: "page \(page.index) is outside \(page.source.lastPathComponent), "
                        + "which has \(document.pageCount) pages"
                )
            }
            // A copy, because inserting a page object that belongs to another
            // open document moves it out of that document — and a source used
            // twice would then lose the page on its second use.
            guard let copy = sourcePage.copy() as? PDFPage else {
                throw LatheError.encodingFailed(
                    stage: "pdf-page-copy", code: nil,
                    reason: "page \(page.index) of \(page.source.lastPathComponent) could not be copied"
                )
            }
            output.insert(copy, at: position)
        }

        return try DocumentFiles.writingAtomically(
            to: destination, pathExtension: "pdf", stage: "pdf-assemble"
        ) { scratch in
            guard output.write(to: scratch) else {
                throw LatheError.writeFailed(
                    path: destination.lastPathComponent, reason: "PDFKit declined to write the document"
                )
            }
        }
        #else
        throw LatheError.encodingUnavailable(format: "PDF editing needs PDFKit")
        #endif
    }

    // MARK: - Comic archives

    private func assembleComic(
        _ pages: [PageReference], into destination: URL, droppedEntries: inout [String]
    ) throws -> UInt64 {
        var directories: [URL: [ZIPEntry]] = [:]
        for page in pages where directories[page.source] == nil {
            directories[page.source] = try ZIPDirectory.entries(
                of: page.source, name: page.source.lastPathComponent
            )
        }
        droppedEntries = directories.values.flatMap { entries in
            entries.filter { !DocumentInspector.isPage($0) && !$0.isDirectory }.map(\.name)
        }.sorted()

        // Pages are numbered from 1 and zero-padded to a width the whole
        // document shares, because a comic reader orders by NAME, not by the
        // order entries happen to sit in the archive. An edit that moved the
        // bytes and kept the names would appear to have done nothing. Padding to
        // a fixed width is what keeps page 10 after page 9 rather than after
        // page 1.
        let width = max(3, String(pages.count).count)
        var members: [ZIPWriter.Member] = []
        members.reserveCapacity(pages.count)

        for (position, page) in pages.enumerated() {
            let name = page.source.lastPathComponent
            guard let entries = directories[page.source] else { continue }
            // Sorted by name, because that is the order a reader shows and
            // therefore the order "page 3" means. The central directory's order
            // is whatever the writing tool happened to emit, and an archive
            // whose entries were appended out of order would otherwise make
            // every index refer to a different page than the one the caller saw.
            let imagePages = entries.filter(DocumentInspector.isPage).sorted { $0.name < $1.name }
            guard page.index >= 0, page.index < imagePages.count else {
                throw LatheError.invalidInput(
                    reason: "page \(page.index) is outside \(name), which has \(imagePages.count) pages"
                )
            }
            let entry = imagePages[page.index]
            let payload = try ZIPDirectory.rawPayload(entry, from: page.source, name: name)

            let number = String(format: "%0\(width)d", position + 1)
            let suffix = entry.fileExtension.isEmpty ? "" : ".\(entry.fileExtension)"
            members.append(ZIPWriter.Member(
                name: number + suffix,
                payload: payload,
                method: entry.compressionMethod,
                crc32: entry.crc32,
                uncompressedSize: entry.uncompressedSize,
                modificationTime: entry.modificationTime,
                modificationDate: entry.modificationDate,
                externalAttributes: entry.externalAttributes
            ))
        }

        return try DocumentFiles.writingAtomically(
            to: destination, pathExtension: "cbz", stage: "comic-assemble"
        ) { scratch in
            try ZIPWriter.write(members, to: scratch, name: destination.lastPathComponent)
        }
    }
}

/// One page of the document being built, named by where it comes from.
public struct PageReference: Sendable, Equatable, Hashable {
    /// The document the page is taken from.
    public var source: URL
    /// The page's zero-based index within `source`.
    ///
    /// For a comic archive this counts *pages* — the image entries — not archive
    /// members, so it matches what ``DocumentInspector/pageCount(of:)`` reports
    /// and what a reader shows. A `ComicInfo.xml` sitting between two images
    /// does not shift the numbering.
    public var index: Int

    public init(source: URL, index: Int) {
        self.source = source
        self.index = index
    }
}

/// What an edit produced.
public struct DocumentEditResult: Sendable, Equatable {
    public var output: URL
    public var kind: DocumentKind
    public var pageCount: Int
    /// How many distinct documents the pages came from. `1` for a reorder or a
    /// deletion, more for a merge.
    public var sourceCount: Int
    public var inputByteCount: UInt64
    public var outputByteCount: UInt64
    /// Archive members the edit did not carry across — `ComicInfo.xml`, reader
    /// sidecars, resource forks. Empty for a PDF.
    ///
    /// Reported rather than silently discarded. Carrying a `ComicInfo.xml`
    /// through unchanged would be worse than dropping it: it records a page
    /// count and per-page entries, so after pages are removed or reordered it
    /// describes a document that no longer exists, and an archive that disagrees
    /// with itself is harder to notice than one that is missing a file. Until
    /// this module can rewrite that metadata rather than invalidate it, the
    /// caller is told what was left behind and can decide.
    public var droppedEntries: [String]

    public init(
        output: URL,
        kind: DocumentKind,
        pageCount: Int,
        sourceCount: Int,
        inputByteCount: UInt64,
        outputByteCount: UInt64,
        droppedEntries: [String] = []
    ) {
        self.output = output
        self.kind = kind
        self.pageCount = pageCount
        self.sourceCount = sourceCount
        self.inputByteCount = inputByteCount
        self.outputByteCount = outputByteCount
        self.droppedEntries = droppedEntries
    }
}
