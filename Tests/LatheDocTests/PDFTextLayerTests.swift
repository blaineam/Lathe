import CoreGraphics
import Foundation
import LatheCore
import LatheFixtures
import PDFKit
import Testing

@testable import LatheDoc

/// The OCR text layer: a round trip, not a "did not throw".
///
/// Every assertion here reads the *finished PDF back* — with PDFKit for the
/// text, with Core Graphics for the pixels, and with the raw content stream for
/// the render mode. An invisible text layer is by construction the one feature
/// whose failure cannot be seen, so a test that only checks the call returned
/// would pass for a writer that put every word at the origin.
@Suite("PDF text layer")
struct PDFTextLayerTests {

    private static let phrase = "Lathe makes documents searchable"

    // MARK: - Round trip

    @Test("a scanned page comes back as searchable text")
    func roundTrip() throws {
        try withScan { _, output, result in
            #expect(result.pageCount == 1)
            #expect(result.pagesRecognised == 1)
            #expect(result.pagesSkipped == 0)
            #expect(result.textRunCount > 0)

            let text = try extractedText(of: output).lowercased()
            #expect(text.contains("lathe"))
            #expect(text.contains("documents"))
            #expect(text.contains("searchable"))
        }
    }

    /// Per-line placement puts the whole line in one run. Both placements have
    /// to produce searchable text; only the geometry differs.
    @Test("per-line placement is searchable too")
    func perLinePlacement() throws {
        try withScan(options: PDFTextLayerOptions(placement: .perLine)) { _, output, result in
            #expect(result.textRunCount > 0)
            let text = try extractedText(of: output).lowercased()
            #expect(text.contains("lathe"))
        }
    }

    // MARK: - Invisible, specifically

    /// Two independent checks, because either alone can pass for the wrong
    /// reason: the content stream says the glyphs were drawn in render mode 3,
    /// and the rendered page has the same amount of ink on it as before.
    @Test("the added text is genuinely invisible")
    func invisible() throws {
        try withScan { input, output, _ in
            let streamData = try contentStream(ofPage: 0, in: output)
            let stream = try #require(streamData)
            #expect(contains(stream, "3 Tr"), "no text render mode 3 in the page's content stream")

            let beforeRender = try renderPage(0, of: input, scale: 1)
            let afterRender = try renderPage(0, of: output, scale: 1)
            let before = try #require(beforeRender)
            let after = try #require(afterRender)

            #expect(before.size == after.size)
            // If the layer were drawn in any visible mode the glyph pixels would
            // be drawn twice — the same ink, plus a Helvetica approximation of it
            // stretched over the top. A 5% band is slack for the rasteriser, not
            // for a second copy of the text.
            let growth = Double(after.darkPixels) / Double(max(1, before.darkPixels))
            #expect(growth > 0.95 && growth < 1.05, "ink changed by \(growth)x")
        }
    }

    // MARK: - Geometry

    /// **The assertion the whole geometry section exists for.**
    ///
    /// The word's selection rectangle is compared against where the *ink*
    /// actually is on the finished page, measured from its pixels. Nothing in
    /// the check re-derives the transform the writer used, so a sign error, a
    /// forgotten MediaBox origin or a dropped rotation all fail it.
    @Test("a word's text lands on its glyphs, not at the origin")
    func placement() throws {
        try withScan { _, output, _ in
            try assertTextSitsOnTheInk(in: output)
        }
    }

    /// The same assertion against the two things that make PDF geometry hard: a
    /// page a viewer rotates, and a MediaBox whose origin is not `(0, 0)`.
    ///
    /// Either one, got wrong, puts the layer somewhere plausible and wrong. The
    /// page still looks perfect, so the only symptom is somebody searching a
    /// document years later and finding nothing.
    @Test(
        "rotation and a non-zero MediaBox origin are handled",
        arguments: [0, 90, 180, 270]
    )
    func rotationAndOffsetMediaBox(_ rotation: Int) throws {
        try withScan(
            mediaBoxOrigin: CGPoint(x: 36, y: 72), rotation: rotation
        ) { input, output, result in
            #expect(result.pagesRecognised == 1)

            // The output is normalised: zero origin, no /Rotate, and the size a
            // viewer of the source saw.
            let document = try #require(PDFDocument(url: output))
            let page = try #require(document.page(at: 0))
            let box = page.bounds(for: .mediaBox)
            #expect(page.rotation == 0)
            #expect(abs(box.origin.x) < 0.01 && abs(box.origin.y) < 0.01)

            let source = try #require(PDFDocument(url: input))
            let sourcePage = try #require(source.page(at: 0))
            let sourceBox = sourcePage.bounds(for: .mediaBox)
            let expected = rotation % 180 == 0
                ? sourceBox.size
                : CGSize(width: sourceBox.height, height: sourceBox.width)
            #expect(abs(box.width - expected.width) < 1)
            #expect(abs(box.height - expected.height) < 1)

            try assertTextSitsOnTheInk(in: output)
        }
    }

    // MARK: - Skipping

    /// Re-OCR'ing a born-digital PDF adds a second text layer that does not line
    /// up with the first, and the page still looks perfect.
    @Test("a born-digital PDF is skipped by default")
    func bornDigitalIsSkipped() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("born-digital")
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = try DocumentFixtures.write(
            try DocumentFixtures.textPDF("Already selectable text on this page", pageCount: 2),
            to: directory.appendingPathComponent("digital.pdf")
        )
        let output = directory.appendingPathComponent("digital-ocr.pdf")

        let skipped = try PDFTextLayerWriter().addTextLayer(
            source: input, to: output, progress: .ignoring()
        )
        #expect(skipped.pageCount == 2)
        #expect(skipped.pagesSkipped == 2)
        #expect(skipped.pagesRecognised == 0)
        #expect(skipped.textRunCount == 0)

        // The text it already had survives the redraw.
        let preserved = try extractedText(of: output).lowercased()
        #expect(preserved.contains("selectable"))

        // And the default is a default, not a hard rule.
        let forced = try PDFTextLayerWriter().addTextLayer(
            source: input, to: directory.appendingPathComponent("digital-forced.pdf"),
            options: PDFTextLayerOptions(skipPagesWithText: false), progress: .ignoring()
        )
        #expect(forced.pagesRecognised == 2)
        #expect(forced.pagesSkipped == 0)
    }

    /// A page with a couple of stray characters on it — a stamped number, a
    /// form's caption — is a scan, not a born-digital page.
    @Test("a stray character does not count as an existing text layer")
    func strayCharactersAreNotAText() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("stray")
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = try DocumentFixtures.write(
            try DocumentFixtures.textPDF("7"),
            to: directory.appendingPathComponent("stamped.pdf")
        )
        let result = try PDFTextLayerWriter().addTextLayer(
            source: input, to: directory.appendingPathComponent("stamped-ocr.pdf"),
            progress: .ignoring()
        )
        #expect(result.pagesSkipped == 0)
        #expect(result.pagesRecognised == 1)
    }

    // MARK: - Other inputs

    @Test("an image is a one-page document")
    func imageInput() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("image-input")
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = try DocumentFixtures.write(
            try DocumentFixtures.textPNG(Self.phrase),
            to: directory.appendingPathComponent("scan.png")
        )
        let output = directory.appendingPathComponent("scan.pdf")
        let result = try PDFTextLayerWriter().addTextLayer(
            source: input, to: output, progress: .ignoring()
        )
        #expect(result.pageCount == 1)
        try requireVision(result) {
            let text = try extractedText(of: output).lowercased()
            #expect(text.contains("lathe"))
        }
    }

    /// A comic archive becomes a PDF with one page per *page*, in name order —
    /// and the `__MACOSX` tree does not become pages here either.
    @Test("a comic archive becomes one PDF page per archive page")
    func archiveInput() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("archive-input")
        defer { try? FileManager.default.removeItem(at: directory) }

        let page = try DocumentFixtures.textPNG(
            Self.phrase, size: CGSize(width: 600, height: 400), fontSize: 40
        )
        let input = try DocumentFixtures.write(
            DocumentFixtures.zipArchive([
                DocumentFixtures.ArchiveEntry(name: "002.png", data: page),
                DocumentFixtures.ArchiveEntry(name: "001.png", data: page),
                DocumentFixtures.ArchiveEntry(name: "ComicInfo.xml", data: Data("<x/>".utf8)),
                DocumentFixtures.ArchiveEntry(name: "__MACOSX/._001.png", data: page),
            ]),
            to: directory.appendingPathComponent("comic.cbz")
        )
        let output = directory.appendingPathComponent("comic.pdf")

        let result = try PDFTextLayerWriter().addTextLayer(
            source: input, to: output, progress: .ignoring()
        )
        #expect(result.pageCount == 2)
        #expect(result.pageCount == (try DocumentInspector().pageCount(of: input)))
        let written = try #require(PDFDocument(url: output))
        #expect(written.pageCount == 2)
    }

    // MARK: - Cancellation

    /// A cancelled pass leaves **no** output. Not a truncated PDF, not a
    /// zero-byte one — nothing, so every "does the file exist" check reads the
    /// truth.
    @Test("cancellation leaves no output file")
    func cancellationLeavesNothing() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("cancel")
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = try DocumentFixtures.write(
            try DocumentFixtures.scanPDF(image: try DocumentFixtures.textPNG(Self.phrase)),
            to: directory.appendingPathComponent("scan.pdf")
        )
        let output = directory.appendingPathComponent("scan-ocr.pdf")

        // A previous file at the destination must survive a cancelled run too.
        try DocumentFixtures.write(Data("previous".utf8), to: output)

        let handle = ProgressHandle(
            sink: ClosureProgressSink { _ in false }, throttle: .unthrottled
        )
        #expect(throws: LatheError.self) {
            _ = try PDFTextLayerWriter().addTextLayer(
                source: input, to: output, progress: handle
            )
        }
        #expect(try Data(contentsOf: output) == Data("previous".utf8))

        // And with nothing at the destination to begin with, nothing is left.
        let virgin = directory.appendingPathComponent("virgin.pdf")
        let second = ProgressHandle(
            sink: ClosureProgressSink { _ in false }, throttle: .unthrottled
        )
        #expect(throws: LatheError.self) {
            _ = try PDFTextLayerWriter().addTextLayer(
                source: input, to: virgin, progress: second
            )
        }
        #expect(!FileManager.default.fileExists(atPath: virgin.path))
        // No scratch file left behind either.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".lathe-") }
        #expect(leftovers.isEmpty, "left \(leftovers) behind")
    }

    // MARK: - Configuration

    @Test("a contradictory configuration is refused before anything is written")
    func badConfiguration() throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("config")
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = try DocumentFixtures.write(
            try DocumentFixtures.shapesPDF(pageCount: 1),
            to: directory.appendingPathComponent("in.pdf")
        )
        let output = directory.appendingPathComponent("out.pdf")

        #expect(throws: LatheError.self) {
            _ = try PDFTextLayerWriter().addTextLayer(
                source: input, to: output,
                options: PDFTextLayerOptions(rasterDPI: 10), progress: .ignoring()
            )
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    /// The language probe narrows rather than fails. A wish list of languages
    /// this system has never heard of resolves to "let Vision choose" instead of
    /// making `perform` throw and taking the whole document with it.
    @Test("unsupported languages are dropped, not fatal")
    func languageProbe() {
        let support = VisionTextSupport.shared
        #expect(support.resolve(languages: ["zz-ZZ"], accuracy: .accurate).isEmpty)
        #expect(support.resolve(languages: [], accuracy: .accurate).isEmpty)

        let supported = support.supportedLanguages(accuracy: .accurate)
        if supported.isEmpty {
            // A device with no OCR assets. Recorded, not silently passed.
            Issue.record("Vision reported no supported recognition languages on this machine")
            return
        }
        #expect(support.resolve(languages: [supported[0]], accuracy: .accurate) == [supported[0]])
        // A bare subtag resolves to the system's own spelling of it.
        let subtag = String(supported[0].split(separator: "-")[0])
        #expect(support.resolve(languages: [subtag], accuracy: .accurate) == [supported[0]])
        #expect(support.supportedRevisions.contains(support.currentRevision))
    }

    // MARK: - Harness

    /// Builds a scan, runs the pass, and hands the body the input, the output
    /// and the result — with the Vision-unavailable case turned into a recorded
    /// known issue rather than a red test, the way the media fixtures do.
    private func withScan(
        options: PDFTextLayerOptions = PDFTextLayerOptions(),
        mediaBoxOrigin: CGPoint = .zero,
        rotation: Int = 0,
        _ body: (URL, URL, PDFTextLayerResult) throws -> Void
    ) throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("scan")
        defer { try? FileManager.default.removeItem(at: directory) }

        let input = try DocumentFixtures.write(
            try DocumentFixtures.scanPDF(
                image: try DocumentFixtures.textPNG(Self.phrase),
                mediaBoxOrigin: mediaBoxOrigin,
                rotation: rotation
            ),
            to: directory.appendingPathComponent("scan.pdf")
        )
        let output = directory.appendingPathComponent("scan-ocr.pdf")

        let result = try PDFTextLayerWriter().addTextLayer(
            source: input, to: output, options: options, progress: .ignoring()
        )
        try requireVision(result) { try body(input, output, result) }
    }

    /// Vision recognising nothing at all is a machine problem, not a code
    /// problem: the simulator and some CI images ship without the OCR assets.
    /// Recorded by name instead of quietly passing.
    private func requireVision(
        _ result: PDFTextLayerResult, _ body: () throws -> Void
    ) throws {
        guard result.textRunCount > 0 || result.pagesRecognised == 0 else {
            let message = "Vision recognised nothing on this machine "
                + "(revision \(result.recognitionRevision)); the OCR assertions cannot run here"
            Issue.record(Comment(rawValue: message))
            return
        }
        try body()
    }

    // MARK: - Reading a finished PDF back

    private func extractedText(of url: URL) throws -> String {
        let document = try #require(PDFDocument(url: url))
        return document.string ?? ""
    }

    /// Where a word's invisible run says it is, in the page's own points.
    private func selectionBounds(of word: String, in url: URL) throws -> CGRect? {
        let document = try #require(PDFDocument(url: url))
        guard let page = document.page(at: 0) else { return nil }
        guard let selection = document.findString(word, withOptions: [.caseInsensitive]).first
        else { return nil }
        return selection.bounds(for: page)
    }

    /// The bounding box of the page's visible ink, measured from its pixels.
    ///
    /// Deliberately independent of every transform the writer uses: it renders
    /// the finished page the way a viewer would and looks at what is dark.
    private func inkBounds(ofPage index: Int, in url: URL, scale: CGFloat = 2) throws -> CGRect? {
        guard let render = try renderPage(index, of: url, scale: scale) else { return nil }
        guard let box = render.darkBounds else { return nil }
        return box
    }

    private func assertTextSitsOnTheInk(in url: URL) throws {
        let measuredInk = try inkBounds(ofPage: 0, in: url)
        let measuredWord = try selectionBounds(of: "Lathe", in: url)
        let ink = try #require(measuredInk, "the page has no visible ink")
        let word = try #require(measuredWord, "\"Lathe\" is not in the text layer")

        #expect(word.width > 0 && word.height > 0)
        // Not at the origin: the classic symptom of a dropped transform is every
        // run stacked in the bottom-left corner.
        #expect(word.minX > 1 || word.minY > 1)

        // The word must sit ON the inked region — measured as overlap, not as
        // strict containment.
        //
        // Containment with a fixed slack was tuned on one machine and failed on
        // another by a single point: a glyph's outline and the box a text layer
        // reports for it are not the same rectangle, and how far apart they are
        // depends on the rasteriser. Chasing that with a bigger constant is
        // guessing at somebody else's renderer.
        //
        // Overlap keeps what the test is actually for. The failure it exists to
        // catch — a dropped transform, which stacks every run in the bottom-left
        // corner — produces approximately zero intersection, not ninety-five
        // percent of one.
        let slack: CGFloat = 12
        let generous = ink.insetBy(dx: -slack, dy: -slack)
        let shared = generous.intersection(word)
        let covered = shared.isNull ? 0 : (shared.width * shared.height) / (word.width * word.height)
        #expect(
            covered > 0.9,
            "the run for \"Lathe\" is at \(word), the page's ink is at \(ink), and only \(Int(covered * 100))% of the run sits on it"
        )
    }

    // MARK: - Rasterising and pixel counting

    private struct Render {
        let size: CGSize
        let darkPixels: Int
        let darkBounds: CGRect?
    }

    /// Renders one page the way a viewer would — through PDFKit, which applies
    /// the page's rotation and box itself, rather than through the same
    /// `CGPDFPage` transform the writer uses.
    private func renderPage(_ index: Int, of url: URL, scale: CGFloat) throws -> Render? {
        let document = try #require(PDFDocument(url: url))
        guard let page = document.page(at: index) else { return nil }

        let box = page.bounds(for: .mediaBox)
        let displayed = (page.rotation / 90) % 2 == 1
            ? CGSize(width: box.height, height: box.width)
            : box.size
        let width = max(1, Int((displayed.width * scale).rounded()))
        let height = max(1, Int((displayed.height * scale).rounded()))

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()

        guard let base = context.data else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var dark = 0
        var minX = width, minY = height, maxX = -1, maxY = -1

        for row in 0..<height {
            for column in 0..<width {
                let pixel = row * (width * 4) + column * 4
                // Little-endian ARGB: blue, green, red, alpha.
                let luminance = Int(bytes[pixel]) + Int(bytes[pixel + 1]) + Int(bytes[pixel + 2])
                guard luminance < 3 * 128 else { continue }
                dark += 1
                minX = min(minX, column); maxX = max(maxX, column)
                minY = min(minY, row); maxY = max(maxY, row)
            }
        }

        var darkBounds: CGRect?
        if maxX >= 0 {
            // Bitmap rows run top-down; PDF points run bottom-up.
            let top = CGFloat(height - 1 - minY) / scale
            let bottom = CGFloat(height - 1 - maxY) / scale
            darkBounds = CGRect(
                x: CGFloat(minX) / scale,
                y: bottom,
                width: CGFloat(maxX - minX + 1) / scale,
                height: top - bottom
            )
        }

        return Render(size: displayed, darkPixels: dark, darkBounds: darkBounds)
    }

    // MARK: - Reading the raw content stream

    /// The page's *decoded* content stream.
    ///
    /// `CGPDFStreamCopyData` applies the standard filters, so a Flate-compressed
    /// stream — which is what `CGPDFContext` writes — comes back as the
    /// operators themselves. That is what makes "render mode 3 was used" a
    /// checkable claim rather than a comment.
    private func contentStream(ofPage index: Int, in url: URL) throws -> Data? {
        let document = try #require(CGPDFDocument(url as CFURL))
        guard let page = document.page(at: index + 1),
              let dictionary = page.dictionary
        else { return nil }

        var stream: CGPDFStreamRef?
        if CGPDFDictionaryGetStream(dictionary, "Contents", &stream), let stream {
            var format = CGPDFDataFormat.raw
            return CGPDFStreamCopyData(stream, &format) as Data?
        }

        var array: CGPDFArrayRef?
        guard CGPDFDictionaryGetArray(dictionary, "Contents", &array), let array else { return nil }
        var combined = Data()
        for index in 0..<CGPDFArrayGetCount(array) {
            var element: CGPDFStreamRef?
            guard CGPDFArrayGetStream(array, index, &element), let element else { continue }
            var format = CGPDFDataFormat.raw
            if let data = CGPDFStreamCopyData(element, &format) { combined.append(data as Data) }
        }
        return combined
    }

    private func contains(_ haystack: Data, _ needle: String) -> Bool {
        let pattern = [UInt8](needle.utf8)
        guard haystack.count >= pattern.count else { return false }
        let bytes = [UInt8](haystack)
        for start in 0...(bytes.count - pattern.count) where Array(bytes[start..<(start + pattern.count)]) == pattern {
            return true
        }
        return false
    }
}
