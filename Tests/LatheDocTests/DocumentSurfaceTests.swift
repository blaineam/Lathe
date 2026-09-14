import Foundation
import LatheCore
import LatheImage
import Testing

@testable import LatheDoc

@Suite("Document API surface")
struct DocumentSurfaceTests {

    private let source = URL(fileURLWithPath: "/tmp/lathe-test-in.pdf")
    private let destination = URL(fileURLWithPath: "/tmp/lathe-test-out.pdf")

    @Test("PDF recompression reports as not implemented")
    func recompressIsNotImplemented() {
        #expect(throws: LatheError.self) {
            _ = try UnimplementedDocumentPipeline().recompress(
                source: source,
                destination: destination,
                options: PDFRecompressOptions(),
                progress: .ignoring()
            )
        }
    }

    @Test("PDF metadata editing reports as not implemented")
    func metadataIsNotImplemented() {
        let pipeline = UnimplementedDocumentPipeline()
        #expect(throws: LatheError.self) { _ = try pipeline.readAttributes(source) }
        #expect(throws: LatheError.self) { try pipeline.writeAttributes(["Title": "x"], to: source) }
        #expect(throws: LatheError.self) { try pipeline.applyMetadataPolicy(.stripAll, to: source) }
    }

    /// OCR is no longer a stub — see `PDFTextLayerTests`. What is worth pinning
    /// here is that the defaults it ships with are the safe ones, because both
    /// of these are choices a caller will only discover was wrong after the file
    /// has been in a library for a year.
    @Test("text-layer defaults are the safe ones")
    func textLayerDefaults() {
        let options = PDFTextLayerOptions()
        // Re-OCR'ing a born-digital PDF double-layers it, invisibly.
        #expect(options.skipPagesWithText)
        // But not on a single stray stamped character.
        #expect(options.existingTextThreshold > 1)
        #expect(options.accuracy == .accurate)
        #expect(options.placement == .perWord)
        #expect(options.rasterDPI >= 150)
    }

    @Test("comic archive handling reports as not implemented")
    func comicsAreNotImplemented() {
        let pipeline = UnimplementedDocumentPipeline()
        #expect(throws: LatheError.self) {
            _ = try pipeline.recompress(
                source: source, destination: destination,
                imageFormat: .jpeg, quality: .quality(0.7), resize: .none, progress: .ignoring()
            )
        }
        #expect(throws: LatheError.self) {
            _ = try pipeline.convertToZIP(source: source, destination: destination, progress: .ignoring())
        }
    }

    /// The defaults encode the safety rules: never upsample past a sensible DPI,
    /// skip stencils, keep an image and its soft mask together, and do not leave
    /// a false PDF/A claim behind.
    @Test("recompression defaults are the safe ones")
    func safeDefaults() {
        let options = PDFRecompressOptions()
        #expect(options.externalizeInlineImages)
        #expect(options.skipImageMasksAndStencils)
        #expect(options.treatSMaskAsSingleUnit)
        #expect(options.deduplicateSharedImageObjects)
        #expect(options.pdfAClaim == .stripClaim)
        #expect(options.maxEffectiveDPI > 0)
        #expect(options.jpegQuality > 0 && options.jpegQuality <= 1)
    }

    /// A PDF recompressor must only ever be asked for a format PDF can hold.
    @Test("the image formats a PDF can embed are a small set")
    func embeddableFormats() {
        let legal = ImageFormat.allCases.filter(\.isLegalInsidePDF)
        #expect(legal.contains(.jpeg))
        #expect(!legal.contains(.heic))
        #expect(!legal.contains(.webp))
        #expect(!legal.contains(.avif))
        #expect(!legal.contains(.jpegXL))
    }
}
