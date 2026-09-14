import CoreGraphics
import CoreText
import Foundation
import ImageIO
import LatheCore
import LatheImage
import PDFKit
import Vision

/// Where the invisible text is positioned: one run per word, or one per line.
public enum TextLayerPlacement: Sendable, Equatable, CaseIterable {
    /// One invisible run per word, each stretched to the word's own box.
    ///
    /// The default. A reader highlighting a search hit draws the run's box, so
    /// per-word placement is the difference between highlighting the word and
    /// highlighting the paragraph it is in.
    case perWord
    /// One invisible run per recognised line.
    ///
    /// Cheaper, and the right choice where Vision's per-word geometry is poor —
    /// dense script, heavy skew — because a slightly wrong line beats a set of
    /// confidently wrong words.
    case perLine
}

/// How to build a searchable text layer.
public struct PDFTextLayerOptions: Sendable, Equatable {

    /// BCP-47 language identifiers, most preferred first. Empty means "let
    /// Vision choose".
    ///
    /// Resolved against ``VisionTextSupport`` before the request runs, so an
    /// entry this system does not support is dropped rather than failing the
    /// whole document.
    public var languages: [String]

    public var accuracy: TextRecognitionAccuracy

    /// Vision's dictionary-based correction. On, because a text layer is for
    /// searching; off is better when the page is mostly identifiers, part
    /// numbers or code, where correction invents plausible words.
    public var usesLanguageCorrection: Bool

    /// Leave pages that already have extractable text alone.
    ///
    /// **On by default, and this is the important default.** Re-OCR'ing a
    /// born-digital PDF adds a *second* text layer that does not line up with
    /// the first: every search then finds each word twice, selection picks up
    /// doubled characters, and copy-paste comes out interleaved. The page still
    /// looks perfect, so the damage is only ever discovered by somebody using
    /// the file.
    public var skipPagesWithText: Bool

    /// How many non-whitespace characters a page must already have before
    /// ``skipPagesWithText`` counts it as having text.
    ///
    /// Not zero. A scanned page routinely carries a handful of real characters —
    /// a stamped page number, a form's fixed caption, an OCR'd header from a
    /// previous tool — and treating those as "this page has text" leaves the
    /// scan unsearchable for the sake of one word.
    public var existingTextThreshold: Int

    public var placement: TextLayerPlacement

    /// Recognitions below this confidence are dropped. `0...1`.
    public var minimumConfidence: Float

    /// The resolution page content is rasterised at before it reaches Vision.
    ///
    /// Only used for PDF input — an image or a comic page is handed to Vision at
    /// its own resolution, with no resample in between. 200 is a deliberate
    /// middle: 72 loses small type outright, and 400 quadruples the pixels for a
    /// gain that stops being visible once the glyphs are a comfortable size for
    /// the recogniser.
    public var rasterDPI: Double

    public init(
        languages: [String] = [],
        accuracy: TextRecognitionAccuracy = .accurate,
        usesLanguageCorrection: Bool = true,
        skipPagesWithText: Bool = true,
        existingTextThreshold: Int = 8,
        placement: TextLayerPlacement = .perWord,
        minimumConfidence: Float = 0.2,
        rasterDPI: Double = 200
    ) {
        self.languages = languages
        self.accuracy = accuracy
        self.usesLanguageCorrection = usesLanguageCorrection
        self.skipPagesWithText = skipPagesWithText
        self.existingTextThreshold = existingTextThreshold
        self.placement = placement
        self.minimumConfidence = minimumConfidence
        self.rasterDPI = rasterDPI
    }
}

/// What a text-layer pass did.
public struct PDFTextLayerResult: Sendable, Equatable {
    public var output: URL
    /// Pages in the finished document. Equal to the source's page count — a
    /// text layer never adds or drops a page.
    public var pageCount: Int
    /// Pages Vision was run over.
    public var pagesRecognised: Int
    /// Pages left alone because they already had text. See
    /// ``PDFTextLayerOptions/skipPagesWithText``.
    public var pagesSkipped: Int
    /// Invisible runs written — words under ``TextLayerPlacement/perWord``,
    /// lines under ``TextLayerPlacement/perLine``. Zero on a page of pictures is
    /// the correct answer, not a failure.
    public var textRunCount: Int
    /// What Vision was actually asked for, after
    /// ``VisionTextSupport/resolve(languages:accuracy:)``. Empty means Vision
    /// chose.
    public var recognitionLanguages: [String]
    /// The `VNRecognizeTextRequest` revision that produced the layer.
    public var recognitionRevision: Int
    public var inputByteCount: UInt64
    public var outputByteCount: UInt64
    public var wallTime: TimeInterval

    public init(
        output: URL,
        pageCount: Int,
        pagesRecognised: Int,
        pagesSkipped: Int,
        textRunCount: Int,
        recognitionLanguages: [String],
        recognitionRevision: Int,
        inputByteCount: UInt64,
        outputByteCount: UInt64,
        wallTime: TimeInterval
    ) {
        self.output = output
        self.pageCount = pageCount
        self.pagesRecognised = pagesRecognised
        self.pagesSkipped = pagesSkipped
        self.textRunCount = textRunCount
        self.recognitionLanguages = recognitionLanguages
        self.recognitionRevision = recognitionRevision
        self.inputByteCount = inputByteCount
        self.outputByteCount = outputByteCount
        self.wallTime = wallTime
    }
}

/// Makes a document searchable: on-device OCR, written back as an **invisible**
/// text layer over an unchanged page.
///
/// ```swift
/// let result = try await PDFTextLayerWriter().addTextLayer(source: scan, to: searchable)
/// print(result.pagesRecognised, result.textRunCount)
/// ```
///
/// Takes a PDF, a still image, or a ZIP comic archive; always writes a PDF.
/// Vision recognises, Core Graphics writes, nothing leaves the device and no
/// subprocess is spawned.
///
/// ## The geometry, which is the part that goes wrong silently
///
/// Vision reports normalised coordinates with the origin at **bottom-left**.
/// PDF user space is also bottom-left, which makes the mapping look like a
/// multiplication — and it is not, because a PDF page carries two things a
/// normalised box knows nothing about:
///
/// - a **`/Rotate`** of 0, 90, 180 or 270, which a viewer applies and a content
///   stream does not, so the page a reader sees can be the transpose of the page
///   the coordinates describe; and
/// - a **MediaBox with a non-zero origin**, which is legal, common in
///   print-ready files, and shifts every coordinate on the page.
///
/// Getting either wrong puts the text somewhere other than under its glyphs.
/// That failure is *invisible by construction* — the page still looks right,
/// because the text is meant to be unseeable — so it is discovered by a person
/// searching a document and finding nothing, months later, with no reason to
/// suspect the geometry.
///
/// This writer removes the problem rather than compensating for it. **Each
/// output page is emitted normalised**: its MediaBox is `(0, 0, w, h)` where
/// `w × h` is the size a viewer sees, and the source page's content is drawn
/// into it through `CGPDFPage.getDrawingTransform(_:rect:rotate:preserveAspectRatio:)`,
/// which is the one API that already knows both the rotation and the box origin.
/// The rotation is therefore *baked into the content* instead of being carried
/// as a key, and the text layer's coordinates are then exactly
/// `normalised × pageSize` — a multiplication, honestly this time, against a
/// frame both halves agree on.
///
/// ## Invisible, specifically
///
/// The runs are drawn with `CGContext.setTextDrawingMode(.invisible)` — PDF text
/// render mode **3**, `3 Tr` in the content stream. Mode 3 is the one that
/// renders nothing while leaving the glyphs in the stream for extraction and
/// search; a transparent fill colour would also look right and would *not*
/// survive a flatten, and drawing white-on-white is visible the moment the page
/// behind it is not white.
///
/// Each run is set in Helvetica at roughly the height of its observed box and
/// then scaled horizontally to that box's width, so a reader's selection
/// rectangle lands on the glyphs rather than near them.
///
/// ## What it costs
///
/// Annotations do not survive. `CGContextDrawPDFPage` draws a page's content
/// stream; links, form fields and comments are not content, and this writer does
/// not copy them. For the documents this feature exists for — scans, photographs
/// of pages, comic archives — there are none. For a born-digital PDF there often
/// are, which is one more reason ``PDFTextLayerOptions/skipPagesWithText`` is on
/// by default: a page that is skipped is still redrawn, so a document that is
/// entirely skipped comes back with its text intact and its annotations gone.
/// Passing a file with annotations through this writer is not what it is for.
///
/// ## Progress and cancellation
///
/// Per page, through ``ProgressHandle`` — so cancel latency is one page, which
/// for an accurate-level recognition is a second or two. The document is built
/// in a sibling temporary file and moved into place only when it is complete:
/// **a cancelled run leaves no output at all**, rather than a truncated PDF that
/// every "does the file exist" check reads as a success.
public struct PDFTextLayerWriter: Sendable {

    public init() {}

    // MARK: - Entry points

    /// Add a searchable text layer to a document.
    ///
    /// - Parameters:
    ///   - source: a PDF, a still image, or a ZIP comic archive. A local file.
    ///   - destination: where to write the PDF. Left untouched on failure.
    ///   - options: see ``PDFTextLayerOptions``.
    ///   - sink: receives per-page progress; returning `false` from it cancels.
    @discardableResult
    public func addTextLayer(
        source: URL,
        to destination: URL,
        options: PDFTextLayerOptions = PDFTextLayerOptions(),
        reporting sink: (any ProgressSink)? = nil
    ) async throws -> PDFTextLayerResult {
        try await LatheWork.run(reporting: sink) { progress in
            try Self.perform(source: source, destination: destination, options: options, progress: progress)
        }
    }

    /// The same pass against a handle the caller already owns.
    ///
    /// Synchronous and blocking: the form to call from inside a batch already
    /// running on ``LatheWork``'s queue.
    @discardableResult
    public func addTextLayer(
        source: URL,
        to destination: URL,
        options: PDFTextLayerOptions = PDFTextLayerOptions(),
        progress: ProgressHandle
    ) throws -> PDFTextLayerResult {
        try Self.perform(source: source, destination: destination, options: options, progress: progress)
    }

    // MARK: - The pass

    /// The longest side, in pixels, a page is rasterised to before Vision sees
    /// it.
    ///
    /// A cap rather than a target: `rasterDPI` decides the size and this only
    /// stops a poster-sized MediaBox at 200 DPI from asking for a bitmap nobody
    /// has the memory for. Vision's own recogniser downsamples internally well
    /// before this, so the cap costs nothing in accuracy and prevents a jetsam
    /// on iOS.
    static let maximumRasterPixels = 4_000

    private static func perform(
        source: URL,
        destination: URL,
        options: PDFTextLayerOptions,
        progress: ProgressHandle
    ) throws -> PDFTextLayerResult {
        let started = Date()
        try DocumentFiles.requireReadableFile(at: source)
        guard (0...1).contains(Double(options.minimumConfidence)) else {
            throw LatheError.invalidConfiguration(reason: "minimumConfidence must be within 0...1")
        }
        guard options.rasterDPI >= 36 else {
            throw LatheError.invalidConfiguration(
                reason: "rasterDPI \(options.rasterDPI) is below the 36 DPI floor; nothing "
                    + "recognises text at that size"
            )
        }

        let inputByteCount = DocumentFiles.byteCount(of: source) ?? 0

        try progress.checkpoint(LatheProgress(fraction: nil, stage: "read"))
        let pages = try SourceDocument(url: source)
        guard pages.count > 0 else {
            throw LatheError.invalidInput(reason: "\(source.lastPathComponent) has no pages")
        }

        let languages = VisionTextSupport.shared.resolve(
            languages: options.languages, accuracy: options.accuracy
        )
        let revision = VisionTextSupport.shared.currentRevision

        var recognised = 0
        var skipped = 0
        var runCount = 0

        let outputByteCount = try DocumentFiles.writingAtomically(
            to: destination, pathExtension: "pdf", stage: "write"
        ) { scratch in
            guard let consumer = CGDataConsumer(url: scratch as CFURL),
                  let context = CGContext(consumer: consumer, mediaBox: nil, nil)
            else {
                throw LatheError.writeFailed(
                    path: scratch.lastPathComponent, reason: "Core Graphics would not open a PDF context"
                )
            }

            for index in 0..<pages.count {
                try progress.checkpoint(LatheProgress(
                    stage: "page", unitIndex: UInt64(index), unitCount: UInt64(pages.count)
                ))

                let page = try pages.page(at: index)
                var runs: [TextRun] = []

                let hasText = options.skipPagesWithText
                    && page.extractableTextLength >= options.existingTextThreshold
                if hasText {
                    skipped += 1
                } else {
                    let image = try rasterise(page, dpi: options.rasterDPI)
                    try progress.checkCancellation()
                    runs = try recognise(
                        image, options: options, languages: languages, page: index
                    )
                    recognised += 1
                    runCount += runs.count
                }

                try write(page, runs: runs, into: context)
            }

            context.closePDF()
        }

        progress.report(LatheProgress(
            stage: "page", unitIndex: UInt64(pages.count), unitCount: UInt64(pages.count)
        ))

        return PDFTextLayerResult(
            output: destination,
            pageCount: pages.count,
            pagesRecognised: recognised,
            pagesSkipped: skipped,
            textRunCount: runCount,
            recognitionLanguages: languages,
            recognitionRevision: revision,
            inputByteCount: inputByteCount,
            outputByteCount: outputByteCount,
            wallTime: Date().timeIntervalSince(started)
        )
    }

    // MARK: - Rasterise

    /// Draws a page into a bitmap for Vision.
    ///
    /// An image page is handed over as it is: it is already pixels, and
    /// resampling it to a nominal DPI would only throw detail away before the
    /// recogniser sees it.
    private static func rasterise(_ page: SourcePage, dpi: Double) throws -> CGImage {
        if case let .image(image) = page.content { return image }

        let size = page.displayedSize
        let requested = dpi / 72.0
        let longest = max(size.width, size.height) * requested
        let scale = longest > Double(maximumRasterPixels)
            ? Double(maximumRasterPixels) / max(size.width, size.height)
            : requested

        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw LatheError.encodingFailed(
                stage: "raster", code: nil,
                reason: "could not create a \(width)x\(height) drawing context for page rendering"
            )
        }

        // White, not transparent. A PDF page's background is the paper, which the
        // content stream does not draw; leaving it clear gives Vision black text
        // on black.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        page.draw(into: context)

        guard let image = context.makeImage() else {
            throw LatheError.encodingFailed(
                stage: "raster", code: nil, reason: "page rendering produced no image"
            )
        }
        return image
    }

    // MARK: - Recognise

    private static func recognise(
        _ image: CGImage,
        options: PDFTextLayerOptions,
        languages: [String],
        page index: Int
    ) throws -> [TextRun] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = options.accuracy.visionLevel
        request.usesLanguageCorrection = options.usesLanguageCorrection
        if !languages.isEmpty { request.recognitionLanguages = languages }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw LatheError.encodingFailed(
                stage: "recognise", code: Int32((error as NSError).code),
                reason: "Vision could not recognise text on page \(index + 1): "
                    + (error as NSError).localizedDescription
            )
        }

        let observations = request.results ?? []
        var runs: [TextRun] = []
        runs.reserveCapacity(observations.count)

        for observation in observations {
            guard let candidate = observation.topCandidates(1).first,
                  candidate.confidence >= options.minimumConfidence
            else { continue }

            switch options.placement {
            case .perLine:
                runs.append(TextRun(text: candidate.string, box: observation.boundingBox))
            case .perWord:
                let before = runs.count
                for range in wordRanges(of: candidate.string) {
                    // `boundingBox(for:)` returns a *quad*, which is how Vision
                    // says the word is not axis-aligned on a skewed page. The
                    // enclosing rect is what a text run can be drawn into; the
                    // skew is lost, and losing it is right — an invisible run
                    // rotated to match would put its selection rectangle at an
                    // angle no reader draws.
                    guard let quad = try? candidate.boundingBox(for: range) else { continue }
                    runs.append(TextRun(
                        text: String(candidate.string[range]), box: quad.boundingBox
                    ))
                }
                // A candidate whose per-word geometry Vision declined entirely
                // still belongs in the layer; one line-sized run beats a missing
                // sentence. Compared against this observation's own count, not
                // against the page's — by the second line `runs` is never empty
                // and the fallback would never fire again.
                if runs.count == before {
                    runs.append(TextRun(text: candidate.string, box: observation.boundingBox))
                }
            }
        }
        return runs
    }

    /// Word ranges, by whitespace.
    ///
    /// Deliberately not `enumerateSubstrings(in:options:.byWords)`: that splits
    /// on linguistic word boundaries, so `part-number/7` becomes four runs whose
    /// boxes Vision cannot give separately anyway, and hyphens and slashes are
    /// dropped from the layer entirely. Whitespace splitting keeps a run equal to
    /// what a person would double-click.
    private static func wordRanges(of string: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var index = string.startIndex
        while index < string.endIndex {
            let isSpace = string[index].isWhitespace
            if isSpace {
                if let from = start { ranges.append(from..<index); start = nil }
            } else if start == nil {
                start = index
            }
            index = string.index(after: index)
        }
        if let from = start { ranges.append(from..<string.endIndex) }
        return ranges
    }

    // MARK: - Write

    private static let textLayerFontName = "Helvetica"

    private static func write(_ page: SourcePage, runs: [TextRun], into context: CGContext) throws {
        let size = page.displayedSize
        var mediaBox = CGRect(origin: .zero, size: size)
        let boxData = withUnsafeBytes(of: &mediaBox) { Data($0) } as CFData

        context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
        context.saveGState()
        page.draw(into: context)
        context.restoreGState()

        for run in runs {
            draw(run, pageSize: size, into: context)
        }

        context.endPDFPage()
    }

    /// One invisible run, positioned and stretched onto its observed box.
    private static func draw(_ run: TextRun, pageSize: CGSize, into context: CGContext) {
        guard !run.text.isEmpty else { return }

        // The whole mapping, and it is a multiplication only because the page
        // being written was normalised first. See the type's documentation.
        let rect = CGRect(
            x: run.box.minX * pageSize.width,
            y: run.box.minY * pageSize.height,
            width: run.box.width * pageSize.width,
            height: run.box.height * pageSize.height
        )
        guard rect.width > 0.5, rect.height > 0.5, rect.maxX > 0, rect.maxY > 0 else { return }

        let font = CTFontCreateWithName(textLayerFontName as CFString, rect.height, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key: font,
        ]
        let measured = CTLineCreateWithAttributedString(
            NSAttributedString(string: run.text, attributes: attributes)
        )

        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let natural = CGFloat(CTLineGetTypographicBounds(measured, &ascent, &descent, &leading))
        guard natural > 0 else { return }

        // A trailing space, drawn but not measured.
        //
        // Each run is its own text object at its own position, and PDF text
        // extraction does not invent a separator between two of them — so a
        // per-word layer without this comes back out of `PDFDocument.string` as
        // `lathemakesdocumentssearchable`. It is measured without the space so
        // the horizontal stretch still matches the *word's* box; the space
        // simply trails off the end of it.
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: run.text + " ", attributes: attributes)
        )

        context.saveGState()
        // Text render mode 3 — `3 Tr`. The glyphs reach the content stream and
        // reach nothing else. Set inside the save so it cannot leak into the
        // next page's content drawing.
        context.setTextDrawingMode(.invisible)
        // The baseline sits a descent above the box's bottom edge, because
        // Vision's box encloses the descenders and PDF positions text from the
        // baseline.
        context.translateBy(x: rect.minX, y: rect.minY + descent)
        // Stretch to the observed width so a reader's selection rectangle covers
        // the glyphs rather than a Helvetica-shaped approximation of them.
        context.scaleBy(x: rect.width / natural, y: 1)
        context.textMatrix = .identity
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

// MARK: - Runs

/// One recognised run and its **normalised**, bottom-left-origin box, straight
/// from Vision. Denormalised only at the moment it is drawn, against the page it
/// is drawn onto.
private struct TextRun {
    let text: String
    let box: CGRect
}

// MARK: - Sources

/// One page of whatever was handed in, reduced to the two things the writer
/// needs: how big it is when a person looks at it, and how to draw it upright.
struct SourcePage {

    enum Content {
        /// A PDF page and the transform that puts its content upright inside a
        /// zero-origin box of ``SourcePage/displayedSize``. The transform is
        /// where `/Rotate` and a non-zero MediaBox origin both go.
        case pdf(CGPDFPage, transform: CGAffineTransform)
        case image(CGImage)
    }

    let content: Content
    /// The page as a viewer sees it, in PDF points.
    let displayedSize: CGSize
    /// How many non-whitespace characters the source page already yields.
    let extractableTextLength: Int

    func draw(into context: CGContext) {
        switch content {
        case let .pdf(page, transform):
            context.saveGState()
            context.concatenate(transform)
            context.drawPDFPage(page)
            context.restoreGState()
        case let .image(image):
            context.draw(image, in: CGRect(origin: .zero, size: displayedSize))
        }
    }
}

/// The page list, for each of the three input shapes.
struct SourceDocument {

    private enum Backing {
        case pdf(PDFDocument)
        case image(URL)
        case archive(url: URL, name: String, entries: [ZIPEntry])
    }

    private let backing: Backing
    let count: Int

    init(url: URL) throws {
        let name = url.lastPathComponent

        // A PDF or a ZIP is recognised by its bytes; anything else is offered to
        // ImageIO, which is the only thing that can say whether a file is an
        // image it can read. Note the order: a `.pdf` extension on a JPEG, and a
        // `.jpg` on a PDF, both land correctly. A container this package
        // deliberately does not read — RAR, a spanned ZIP — is refused here
        // rather than falling through to "not an image", which would name the
        // wrong problem.
        switch try DocumentInspector.sniff(url, name: name) {
        case .pdf:
            guard let document = PDFDocument(url: url) else {
                throw LatheError.invalidInput(reason: "\(name) is not a PDF PDFKit can open")
            }
            guard !document.isLocked else {
                throw LatheError.invalidInput(
                    reason: "\(name) is password-protected; its pages cannot be drawn"
                )
            }
            backing = .pdf(document)
            count = document.pageCount

        case .zip:
            // Name order, not archive order. A ZIP records entries in whatever
            // order the writer walked the directory, and every comic reader sorts
            // by name — `localizedStandardCompare` so `page10` follows `page9`
            // rather than `page1`.
            let entries = try ZIPDirectory.entries(of: url, name: name)
                .filter(DocumentInspector.isPage)
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            backing = .archive(url: url, name: name, entries: entries)
            count = entries.count

        case .rar:
            throw LatheError.invalidInput(
                reason: "\(name) is a RAR archive (CBR). LatheDoc reads PDF, images and "
                    + "ZIP-based comic archives; RAR needs a separate reader and is not implemented"
            )

        case .spannedZip:
            throw LatheError.invalidInput(reason: "\(name) is a spanned ZIP archive")

        case .other:
            // Not a container this package knows, which for the OCR path is the
            // ordinary case rather than a failure: a single image is a
            // one-page document. Whether it *is* an image is ImageIO's call,
            // made when the page is built.
            backing = .image(url)
            count = 1
        }
    }

    func page(at index: Int) throws -> SourcePage {
        switch backing {
        case let .pdf(document):
            guard let page = document.page(at: index), let reference = page.pageRef else {
                throw LatheError.invalidInput(reason: "page \(index + 1) could not be opened")
            }
            return Self.pdfPage(reference, existingText: page.string)

        case let .image(url):
            let data = try Data(contentsOf: url)
            return try Self.imagePage(data, name: url.lastPathComponent)

        case let .archive(url, name, entries):
            let entry = entries[index]
            let data = try ZIPDirectory.extract(entry, from: url, name: name)
            return try Self.imagePage(data, name: entry.baseName)
        }
    }

    // MARK: - Building a page

    private static func pdfPage(_ page: CGPDFPage, existingText: String?) -> SourcePage {
        let mediaBox = page.getBoxRect(.mediaBox)
        // `/Rotate` is documented as a multiple of 90 and is not always one in
        // the wild; rounding to the nearest quarter turn is what viewers do, and
        // is what `getDrawingTransform` will apply.
        let quarterTurns = ((Int(page.rotationAngle) / 90) % 4 + 4) % 4
        let displayed = quarterTurns % 2 == 1
            ? CGSize(width: mediaBox.height, height: mediaBox.width)
            : mediaBox.size
        let target = CGRect(origin: .zero, size: displayed)

        // The one call that already knows about both the rotation and the box
        // origin. Writing this transform by hand is how the text layer ends up
        // 36 points down and a quarter turn out on exactly the files that carry
        // a print bleed.
        let transform = page.getDrawingTransform(
            .mediaBox, rect: target, rotate: 0, preserveAspectRatio: true
        )

        let text = existingText ?? ""
        return SourcePage(
            content: .pdf(page, transform: transform),
            displayedSize: displayed.width > 0 && displayed.height > 0
                ? displayed
                : CGSize(width: 612, height: 792),
            extractableTextLength: text.reduce(into: 0) { $0 += $1.isWhitespace ? 0 : 1 }
        )
    }

    private static func imagePage(_ data: Data, name: String) throws -> SourcePage {
        guard let source = CGImageSourceCreateWithData(
            data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary
        ), CGImageSourceGetCount(source) > 0, CGImageSourceGetType(source) != nil else {
            throw LatheError.invalidInput(reason: "\(name) is not an image ImageIO can read")
        }

        // Frame 0, always. An animated page is one page, and its first frame is
        // the one a reader shows — see `DocumentInspector`.
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary) else {
            throw LatheError.encodingFailed(
                stage: "decode", code: nil,
                reason: "ImageIO read \(name)'s headers but could not decode it"
            )
        }

        // Pixels become points through the image's own DPI where it states one,
        // so a 300 DPI A4 scan comes out as an A4 page rather than a 2480-point
        // one. Where it does not, 1 pixel is 1 point, which is what every viewer
        // assumes for an image with no resolution of its own.
        let rawProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
        let properties = (rawProperties as NSDictionary?) as? [CFString: Any] ?? [:]
        let dpi = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
        let scale = dpi >= 36 ? 72.0 / dpi : 1.0

        return SourcePage(
            content: .image(image),
            displayedSize: CGSize(
                width: max(1, Double(image.width) * scale),
                height: max(1, Double(image.height) * scale)
            ),
            // An image carries no text layer to preserve, so there is never
            // anything to skip. Stated rather than implied: `skipPagesWithText`
            // is about not double-layering a born-digital PDF.
            extractableTextLength: 0
        )
    }
}
