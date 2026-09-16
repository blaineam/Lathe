import Foundation
import LatheCore
import LatheImage
import Testing

@testable import LatheDoc

@Suite("Document API surface")
struct DocumentSurfaceTests {

    /// OCR is tested in `PDFTextLayerTests`. What is worth pinning here is that
    /// the defaults it ships with are the safe ones, because both of these are
    /// choices a caller will only discover were wrong after the file has been
    /// in a library for a year.
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

    /// Only some image formats may be embedded in a PDF.
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
