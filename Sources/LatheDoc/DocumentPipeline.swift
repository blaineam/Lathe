import Foundation
import LatheCore
import LatheImage

/// How to treat a PDF that claims PDF/A conformance in its XMP.
///
/// The rule that matters: **never emit a non-conformant file that still claims
/// conformance.**
public enum PDFAClaimPolicy: Sendable, Equatable {
    /// Restrict to PDF/A-safe filters (Flate only) and keep the claim.
    case preserveConformance
    /// Recompress freely and strip the `pdfaid` claim.
    case stripClaim
    /// Refuse the file and tell the caller.
    case refuse
}

/// Options for recompressing the images inside a PDF.
///
/// The field order mirrors the order the operations must happen in, because
/// getting it wrong produces silently-worse output:
///
/// 1. Externalize inline images **first**, or scanner PDFs skip their biggest
///    images entirely.
/// 2. Decide **per image** from `effectiveDPI = pixelWidth / (drawnWidthPt / 72)`.
///    Never upsample.
/// 3. Skip `/ImageMask` and 1-bit stencils — JPEG makes them bigger *and*
///    visibly worse.
/// 4. Treat `(image, /SMask)` as **one unit**: resize both, never JPEG an alpha
///    channel.
/// 5. Deduplicate by object generation — a logo on 40 pages is usually one
///    object.
/// 6. PDF has no HEIC/WebP/AVIF/JXL. See ``ImageFormat/isLegalInsidePDF``.
/// 7. A file claiming PDF/A conformance must either keep it or drop the claim —
///    see ``PDFAClaimPolicy``.
public struct PDFRecompressOptions: Sendable, Equatable {
    /// Step 1. Off only for tests that want to prove the difference.
    public var externalizeInlineImages: Bool
    /// Step 2. Images already at or below this are left alone.
    public var maxEffectiveDPI: Double
    /// Step 3.
    public var skipImageMasksAndStencils: Bool
    /// Step 4.
    public var treatSMaskAsSingleUnit: Bool
    /// Step 5.
    public var deduplicateSharedImageObjects: Bool
    /// Step 6. Baseline JPEG 4:2:0 at q≈0.7 is the default for good reason.
    public var jpegQuality: Double
    /// Step 7.
    public var pdfAClaim: PDFAClaimPolicy
    public var metadata: MetadataPolicy

    public init(
        externalizeInlineImages: Bool = true,
        maxEffectiveDPI: Double = 200,
        skipImageMasksAndStencils: Bool = true,
        treatSMaskAsSingleUnit: Bool = true,
        deduplicateSharedImageObjects: Bool = true,
        jpegQuality: Double = 0.7,
        pdfAClaim: PDFAClaimPolicy = .stripClaim,
        metadata: MetadataPolicy = .preserveAll
    ) {
        self.externalizeInlineImages = externalizeInlineImages
        self.maxEffectiveDPI = maxEffectiveDPI
        self.skipImageMasksAndStencils = skipImageMasksAndStencils
        self.treatSMaskAsSingleUnit = treatSMaskAsSingleUnit
        self.deduplicateSharedImageObjects = deduplicateSharedImageObjects
        self.jpegQuality = jpegQuality
        self.pdfAClaim = pdfAClaim
        self.metadata = metadata
    }
}

public struct PDFRecompressResult: Sendable, Equatable {
    public var output: URL
    public var pageCount: Int
    public var imagesConsidered: Int
    public var imagesRecompressed: Int
    public var imagesSkipped: Int
    public var inputByteCount: UInt64
    public var outputByteCount: UInt64
    public var wallTime: TimeInterval

    public init(
        output: URL,
        pageCount: Int,
        imagesConsidered: Int,
        imagesRecompressed: Int,
        imagesSkipped: Int,
        inputByteCount: UInt64,
        outputByteCount: UInt64,
        wallTime: TimeInterval
    ) {
        self.output = output
        self.pageCount = pageCount
        self.imagesConsidered = imagesConsidered
        self.imagesRecompressed = imagesRecompressed
        self.imagesSkipped = imagesSkipped
        self.inputByteCount = inputByteCount
        self.outputByteCount = outputByteCount
        self.wallTime = wallTime
    }
}

/// PDF image recompression.
///
/// Not yet implemented; Core Graphics analysis + ImageIO encode + a permissively
/// licensed PDF writer is the intended backing.
///
/// Cancellation granularity is **one PDF page**, stated honestly: PDF libraries
/// generally do not poll for cancellation internally. Driving the writer through
/// a streaming data provider makes it per-stream responsive, which is a
/// mitigation rather than a fix.
public protocol PDFRecompressor: Sendable {
    func recompress(
        source: URL,
        destination: URL,
        options: PDFRecompressOptions,
        progress: ProgressHandle
    ) throws -> PDFRecompressResult
}

/// PDF document attributes — Title, Author, Subject, Keywords.
///
/// Not yet implemented. Doing this in-process rather than by spawning a
/// command-line tool also removes a whole class of argument-injection bug by
/// construction: a library call has no argv.
///
/// Note the split: PDFKit's `documentAttributes` reaches the **Info dictionary
/// only**. The XMP `/Metadata` stream has no PDFKit API at all, and needs a
/// lower-level PDF writer.
public protocol PDFMetadataEditor: Sendable {
    func readAttributes(_ url: URL) throws -> [String: String]
    func writeAttributes(_ attributes: [String: String], to url: URL) throws
    func applyMetadataPolicy(_ policy: MetadataPolicy, to url: URL) throws
}

/// OCR injection — searchable text over an unchanged page image.
///
/// Not yet implemented; Vision's `VNRecognizeTextRequest` plus `CGPDFContext`
/// invisible text (text render mode 3) is the intended backing. Doing it with
/// system frameworks avoids both a large external toolchain and its licence
/// footprint.
public protocol PDFTextLayerInjector: Sendable {
    func addSearchableTextLayer(
        source: URL,
        destination: URL,
        languages: [String],
        progress: ProgressHandle
    ) throws -> PDFRecompressResult
}

/// Comic archives.
///
/// Not yet implemented. The intended backing is a permissively licensed ZIP
/// library for CBZ, and libarchive's **independently written BSD-2 RAR readers**
/// for CBR — no proprietary unrar code is involved, which is what keeps CBR
/// support distributable.
///
/// `ComicInfo.xml` must survive the round trip; losing it silently breaks every
/// reader's series metadata.
public protocol ComicArchiveRecompressor: Sendable {
    func recompress(
        source: URL,
        destination: URL,
        imageFormat: ImageFormat,
        quality: QualityTarget,
        resize: ResizeTarget,
        progress: ProgressHandle
    ) throws -> PDFRecompressResult

    /// CBR → CBZ.
    func convertToZIP(source: URL, destination: URL, progress: ProgressHandle) throws -> URL
}

// MARK: - Scaffold implementations

/// Throws ``LatheError/notImplemented(feature:)`` for everything.
public struct UnimplementedDocumentPipeline: PDFRecompressor, PDFMetadataEditor, PDFTextLayerInjector, ComicArchiveRecompressor {

    public init() {}

    public func recompress(
        source: URL,
        destination: URL,
        options: PDFRecompressOptions,
        progress: ProgressHandle
    ) throws -> PDFRecompressResult {
        throw LatheError.todo("PDFRecompressor.recompress(...)")
    }

    public func readAttributes(_ url: URL) throws -> [String: String] {
        throw LatheError.todo("PDFMetadataEditor.readAttributes(_:)")
    }

    public func writeAttributes(_ attributes: [String: String], to url: URL) throws {
        throw LatheError.todo("PDFMetadataEditor.writeAttributes(_:to:)")
    }

    public func applyMetadataPolicy(_ policy: MetadataPolicy, to url: URL) throws {
        throw LatheError.todo("PDFMetadataEditor.applyMetadataPolicy(_:to:)")
    }

    public func addSearchableTextLayer(
        source: URL,
        destination: URL,
        languages: [String],
        progress: ProgressHandle
    ) throws -> PDFRecompressResult {
        throw LatheError.todo("PDFTextLayerInjector.addSearchableTextLayer(...)")
    }

    public func recompress(
        source: URL,
        destination: URL,
        imageFormat: ImageFormat,
        quality: QualityTarget,
        resize: ResizeTarget,
        progress: ProgressHandle
    ) throws -> PDFRecompressResult {
        throw LatheError.todo("ComicArchiveRecompressor.recompress(...)")
    }

    public func convertToZIP(source: URL, destination: URL, progress: ProgressHandle) throws -> URL {
        throw LatheError.todo("ComicArchiveRecompressor.convertToZIP(...)")
    }
}
