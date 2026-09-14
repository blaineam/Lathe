import Foundation
import LatheCore
import LatheImage
import PDFKit

/// What kind of document a file turned out to be.
///
/// Decided from the file's first bytes rather than its extension. The extension
/// is a claim — `.cbz` files that are actually RAR archives are common enough
/// that every comic reader handles them — and the magic number is a fact.
public enum DocumentKind: Sendable, Equatable, CustomStringConvertible {
    /// A PDF. Pages are counted by PDFKit.
    case pdf
    /// A ZIP-based comic archive: `.cbz`, or a `.zip` of images.
    case comicArchiveZIP

    public var description: String {
        switch self {
        case .pdf: "PDF"
        case .comicArchiveZIP: "CBZ"
        }
    }
}

/// What a document turns out to be, and how many pages it has.
public struct DocumentPageInfo: Sendable, Equatable {

    public let kind: DocumentKind

    /// How many pages a reader will show.
    ///
    /// **An animated page is one page.** See ``DocumentInspector/pageCount(of:)``.
    public let pageCount: Int

    /// Archive members that are not pages — `ComicInfo.xml`, folder entries,
    /// `__MACOSX/` resource forks, `.DS_Store`, `Thumbs.db`, and anything whose
    /// extension does not name an image format.
    ///
    /// Exposed rather than discarded because it is the number that explains a
    /// surprising page count: an archive reporting 20 pages and 20 excluded
    /// entries was almost certainly zipped on a Mac.
    ///
    /// Always `0` for a PDF.
    public let excludedEntryCount: Int

    public init(kind: DocumentKind, pageCount: Int, excludedEntryCount: Int) {
        self.kind = kind
        self.pageCount = pageCount
        self.excludedEntryCount = excludedEntryCount
    }
}

/// Counts the pages in a document without decoding one.
///
/// ```swift
/// let pages = try DocumentInspector().pageCount(of: comic)   // 24, not 8_640
/// ```
///
/// ## An animated page is one page
///
/// This is the rule the whole type is arranged around, and it is not a
/// technicality. A comic archive of 30 animated GIFs, counted by *frames*,
/// reports 900 pages. That number does not read as a counting bug to anyone who
/// sees it — it reads as a corrupt file or a broken import — so it gets
/// investigated in the decoder, in the download, in the database, and not in the
/// one line of arithmetic that produced it.
///
/// Two consequences follow, and they are the implementation:
///
/// - **Archive entries are counted, never opened.** Nothing here calls
///   ``ImageInspector``, `CGImageSourceCreateWithURL`, or any decoder. A page is
///   a file in the archive; how many frames that file would decode to is a
///   different question with a different answer, and ``ImageInspector`` is
///   where it is asked. The happy side effect is cost: the answer comes from the
///   central directory at the end of the archive, so a 2 GB archive costs what a
///   2 MB one costs. A page whose bytes are *corrupt* still counts, which is a
///   property rather than an accident — the count is of pages the archive
///   claims, not of pages that happen to decode today.
///
/// - **A PDF page containing an animated XObject is still one page.** That stays
///   true for the dull reason that nothing here inspects page content:
///   `PDFDocument.pageCount` is the answer.
///
/// ## What is excluded from an archive, and why the last one matters most
///
/// A page is a member whose extension names an image format and which is not one
/// of these:
///
/// - **`__MACOSX/`** — the parallel AppleDouble tree that macOS's own Archive
///   Utility writes beside the real files. Its members carry the *same
///   extensions* as the files they shadow, so an archive made on a Mac counts
///   **double** unless this tree is excluded. It is the exclusion most likely to
///   ship unnoticed, because a comic that reports 48 pages instead of 24 still
///   looks like a comic. Members whose base name begins with `._` are excluded
///   too: the same resource forks reach a flat archive that way.
/// - **`ComicInfo.xml`** — series metadata every comic reader reads, and no
///   reader shows as a page.
/// - **`.DS_Store`, `Thumbs.db`, `desktop.ini`** — the three files an operating
///   system leaves in a folder somebody zipped.
/// - **Folder entries** — a ZIP records directories as zero-byte members.
///
/// ## Zero and "not a document" are different answers
///
/// An empty archive has **0** pages, and that is a correct, ordinary answer. A
/// `.txt` file, or a `.cbr` (which is RAR, not ZIP), therefore cannot also be
/// `0`: it throws ``LatheError/invalidInput(reason:)``. Conflating the two hands
/// a caller a number for a file it cannot read, and "the comic is empty" and
/// "this is not a comic" lead to opposite recovery paths.
public struct DocumentInspector: Sendable {

    public init() {}

    // MARK: - Counting

    /// How many pages a reader will show for this document.
    ///
    /// - Throws: ``LatheError/readFailed(path:reason:)`` if the file cannot be
    ///   opened, ``LatheError/invalidInput(reason:)`` if it is not a document
    ///   type this counts. **An unsupported type is an error, never `0`.**
    public func pageCount(of url: URL) throws -> Int {
        try inspect(url).pageCount
    }

    /// ``pageCount(of:)`` plus what the file turned out to be and how many
    /// archive members were skipped.
    public func inspect(_ url: URL) throws -> DocumentPageInfo {
        try DocumentFiles.requireReadableFile(at: url)
        let name = url.lastPathComponent

        switch try Self.kind(of: url, name: name) {
        case .pdf:
            return DocumentPageInfo(
                kind: .pdf, pageCount: try Self.pdfPageCount(url, name: name), excludedEntryCount: 0
            )
        case .comicArchiveZIP:
            let entries = try ZIPDirectory.entries(of: url, name: name)
            let pages = entries.filter(Self.isPage)
            return DocumentPageInfo(
                kind: .comicArchiveZIP,
                pageCount: pages.count,
                excludedEntryCount: entries.count - pages.count
            )
        }
    }

    // MARK: - PDF

    private static func pdfPageCount(_ url: URL, name: String) throws -> Int {
        guard let document = PDFDocument(url: url) else {
            throw LatheError.invalidInput(reason: "\(name) is not a PDF PDFKit can open")
        }
        // An encrypted PDF opens, reports its page count, and hands back nothing
        // for any page. The count is still the right answer to the question
        // asked, so it is returned rather than refused; the OCR path is where
        // locked has to be an error, and it is one there.
        return document.pageCount
    }

    // MARK: - Archive page rules

    /// Names a reader never shows, compared case-insensitively because a ZIP
    /// preserves whatever case the writing machine used and the same file
    /// arrives as `ComicInfo.xml`, `comicinfo.xml` and `COMICINFO.XML`.
    static let nonPageBaseNames: Set<String> = [
        "comicinfo.xml", ".ds_store", "thumbs.db", "desktop.ini",
    ]

    /// Whether this archive member is a page.
    ///
    /// Written as an **allowlist on the extension** rather than a denylist on the
    /// name. A denylist answers "is this one of the junk files I have met", and
    /// the next reader-specific sidecar — a `.nfo`, a `.txt` credits file, a
    /// `.json` index — is a page under it. An allowlist answers "is this an
    /// image", which is what a page is.
    static func isPage(_ entry: ZIPEntry) -> Bool {
        if entry.isDirectory { return false }
        if entry.name.isEmpty { return false }

        // The resource-fork tree, in both the shapes it arrives in.
        if entry.name.split(separator: "/").contains("__MACOSX") { return false }
        if entry.baseName.hasPrefix("._") { return false }

        if nonPageBaseNames.contains(entry.baseName.lowercased()) { return false }

        // `ImageFormat` already owns the extension-to-format table, including the
        // aliases, so there is one place where "is this an image" is decided.
        // PDF is excluded deliberately: a PDF inside a CBZ is not a page of that
        // CBZ, it is a document of its own.
        guard let format = ImageFormat.named(byFilenameExtension: entry.fileExtension) else {
            return false
        }
        return format != .pdf
    }

    // MARK: - Sniffing

    /// What a file's first bytes say it is.
    ///
    /// Separate from ``DocumentKind`` because the two answer different
    /// questions: `DocumentKind` is the set of things that *have pages to
    /// count*, and this is the set of things the bytes can name — including the
    /// two containers that are refused outright, and the "something else
    /// entirely" that the OCR path legitimately treats as a still image.
    enum SniffedType {
        case pdf
        case zip
        case rar
        case spannedZip
        case other
    }

    /// The first bytes decide. The filename extension is never consulted: a
    /// `.cbz` that is really a RAR is common enough that every comic reader
    /// handles it, and so is a `.zip` full of pages.
    static func sniff(_ url: URL, name: String) throws -> SniffedType {
        let magic = try DocumentFiles.leadingBytes(of: url, count: 8, name: name)

        if magic.starts(with: Array("%PDF-".utf8)) { return .pdf }
        if magic.starts(with: Array("Rar!".utf8)) { return .rar }

        // `PK\u{3}\u{4}` is a local file header; `PK\u{5}\u{6}` is an
        // end-of-central-directory record, which is what an *empty* ZIP archive
        // begins with — and is therefore the byte pattern of the very case this
        // type exists to keep distinct from an error. `PK\u{7}\u{8}` marks a
        // spanned archive.
        if magic.count >= 4, magic[0] == 0x50, magic[1] == 0x4B {
            switch (magic[2], magic[3]) {
            case (0x03, 0x04), (0x05, 0x06): return .zip
            case (0x07, 0x08): return .spannedZip
            default: break
            }
        }

        return .other
    }

    /// The sniffed type as a countable document, or a refusal that names what
    /// the file actually is.
    static func kind(of url: URL, name: String) throws -> DocumentKind {
        switch try sniff(url, name: name) {
        case .pdf:
            return .pdf
        case .zip:
            return .comicArchiveZIP
        case .rar:
            throw LatheError.invalidInput(
                reason: "\(name) is a RAR archive (CBR). LatheDoc counts PDF and ZIP-based comic "
                    + "archives; RAR needs a separate reader and is not implemented"
            )
        case .spannedZip:
            throw LatheError.invalidInput(reason: "\(name) is a spanned ZIP archive")
        case .other:
            throw LatheError.invalidInput(
                reason: "\(name) is not a document LatheDoc can count "
                    + "(expected a PDF or a ZIP-based comic archive)"
            )
        }
    }
}
