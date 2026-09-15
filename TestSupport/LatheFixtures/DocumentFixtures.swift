import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit

/// Synthetic documents, generated at run time.
///
/// The same rule as ``MediaFixtures``: **no binary media is committed to this
/// repository**, so every PDF, comic archive and animated page the document
/// suite needs is built here from first principles. That buys the same three
/// things — properties that are known rather than measured, nothing whose
/// provenance has to be explained, and a legible failure at generation rather
/// than a confusing one at assertion — and it buys one more that matters
/// specifically for page counting:
///
/// **The archives are written by hand, so the awkward members are real.** A
/// `__MACOSX/._page.jpg` resource fork, a bare directory entry, a `ComicInfo.xml`
/// and a deliberately corrupt page are all things a real archive contains and
/// none of them can be produced reliably by asking the system to zip a folder.
/// The writer below is 80 lines of stored-method ZIP, which is a small price for
/// fixtures that contain exactly what the test claims they contain.
public enum DocumentFixtures {

    // MARK: - Images

    /// A solid-colour PNG.
    public static func solidPNG(
        size: CGSize = CGSize(width: 64, height: 96),
        gray: CGFloat = 0.5
    ) throws -> Data {
        let image = try bitmap(size: size) { context in
            context.setFillColor(gray: gray, alpha: 1)
            context.fill(CGRect(origin: .zero, size: size))
        }
        return try encode(image, as: "public.png", frames: [[:]])
    }

    /// A solid-colour JPEG.
    ///
    /// JPEG specifically, because the metadata tests have to prove that an edit
    /// did not re-encode, and JPEG is the format where re-encoding is both
    /// lossy and provable: the entropy-coded scan after the `SOS` marker changes
    /// if a single DCT coefficient was recomputed, and does not if the bytes
    /// were copied.
    public static func solidJPEG(
        size: CGSize = CGSize(width: 64, height: 96),
        gray: CGFloat = 0.5
    ) throws -> Data {
        let image = try bitmap(size: size) { context in
            context.setFillColor(gray: gray, alpha: 1)
            context.fill(CGRect(origin: .zero, size: size))
        }
        return try encode(image, as: "public.jpeg", frames: [[:]])
    }

    /// A PNG with `text` drawn large and black on white.
    ///
    /// Drawn big on purpose. The OCR round-trip has to assert on the words that
    /// come back, and a fixture that is marginal for the recogniser produces a
    /// test that fails for reasons having nothing to do with the code under
    /// test.
    ///
    /// - Parameter originFraction: where the text's baseline sits, as a fraction
    ///   of the image, measured from the **top-left** the way a reader sees it.
    ///   Used by the geometry tests, which need the text somewhere other than the
    ///   middle.
    public static func textPNG(
        _ text: String,
        size: CGSize = CGSize(width: 1_600, height: 620),
        fontSize: CGFloat = 64,
        originFraction: CGPoint = CGPoint(x: 0.05, y: 0.25)
    ) throws -> Data {
        let image = try bitmap(size: size) { context in
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(origin: .zero, size: size))

            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: text,
                attributes: [
                    kCTFontAttributeName as NSAttributedString.Key: font,
                    kCTForegroundColorAttributeName as NSAttributedString.Key:
                        CGColor(gray: 0, alpha: 1),
                ]
            ))
            context.setTextDrawingMode(.fill)
            context.textMatrix = .identity
            // Core Graphics is bottom-left; the parameter is top-left, because
            // that is how a person describes where text is on a page.
            context.textPosition = CGPoint(
                x: size.width * originFraction.x,
                y: size.height * (1 - originFraction.y)
            )
            CTLineDraw(line, context)
        }
        return try encode(image, as: "public.png", frames: [[:]])
    }

    /// An animated GIF of `frameCount` visibly different frames.
    ///
    /// The headline page-counting fixture: a comic archive of these has as many
    /// pages as it has files, and `frameCount` times as many frames.
    public static func animatedGIF(
        frameCount: Int = 30,
        size: CGSize = CGSize(width: 48, height: 64),
        delay: Double = 0.05
    ) throws -> Data {
        precondition(frameCount >= 1)
        var frames: [[CFString: Any]] = []
        var images: [CGImage] = []
        for index in 0..<frameCount {
            images.append(try bitmap(size: size) { context in
                context.setFillColor(
                    gray: CGFloat(index) / CGFloat(max(1, frameCount - 1)), alpha: 1
                )
                context.fill(CGRect(origin: .zero, size: size))
            })
            frames.append([
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay] as CFDictionary,
            ])
        }
        return try encode(
            images, as: "com.compuserve.gif", frames: frames,
            container: [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0] as CFDictionary,
            ]
        )
    }

    // MARK: - PDFs

    /// A PDF of `pageCount` pages containing shapes and no text at all.
    public static func shapesPDF(
        pageCount: Int,
        size: CGSize = CGSize(width: 300, height: 400)
    ) throws -> Data {
        try pdf { context in
            for index in 0..<pageCount {
                beginPage(context, box: CGRect(origin: .zero, size: size))
                context.setFillColor(gray: CGFloat(index % 5) / 5.0, alpha: 1)
                context.fill(CGRect(x: 20, y: 20, width: size.width - 40, height: size.height - 40))
                context.endPDFPage()
            }
        }
    }

    /// A born-digital PDF: real, visible, extractable text drawn as glyphs.
    public static func textPDF(
        _ text: String,
        pageCount: Int = 1,
        size: CGSize = CGSize(width: 400, height: 300)
    ) throws -> Data {
        try pdf { context in
            for _ in 0..<pageCount {
                beginPage(context, box: CGRect(origin: .zero, size: size))
                let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
                let line = CTLineCreateWithAttributedString(NSAttributedString(
                    string: text,
                    attributes: [
                        kCTFontAttributeName as NSAttributedString.Key: font,
                        kCTForegroundColorAttributeName as NSAttributedString.Key:
                            CGColor(gray: 0, alpha: 1),
                    ]
                ))
                context.setTextDrawingMode(.fill)
                context.textMatrix = .identity
                context.textPosition = CGPoint(x: 30, y: size.height - 80)
                CTLineDraw(line, context)
                context.endPDFPage()
            }
        }
    }

    /// A PDF whose every page says which page it is.
    ///
    /// Exists for the editing tests, which have to assert that page 3 of the
    /// output is page 3 of the source. A fixture with identical pages cannot
    /// tell a correct reorder from one that did nothing, so each page here
    /// carries its own marker and the assertion reads the markers back.
    ///
    /// - Parameter labels: one label per page, drawn large. `PAGE-1` and so on
    ///   by default.
    public static func labelledPDF(
        labels: [String],
        size: CGSize = CGSize(width: 400, height: 300)
    ) throws -> Data {
        try pdf { context in
            for label in labels {
                beginPage(context, box: CGRect(origin: .zero, size: size))
                let font = CTFontCreateWithName("Helvetica" as CFString, 36, nil)
                let line = CTLineCreateWithAttributedString(NSAttributedString(
                    string: label,
                    attributes: [
                        kCTFontAttributeName as NSAttributedString.Key: font,
                        kCTForegroundColorAttributeName as NSAttributedString.Key:
                            CGColor(gray: 0, alpha: 1),
                    ]
                ))
                context.setTextDrawingMode(.fill)
                context.textMatrix = .identity
                context.textPosition = CGPoint(x: 30, y: size.height - 80)
                CTLineDraw(line, context)
                context.endPDFPage()
            }
        }
    }

    /// `labelledPDF` with the conventional `PAGE-1`… labels.
    public static func numberedPDF(
        pageCount: Int,
        prefix: String = "PAGE",
        size: CGSize = CGSize(width: 400, height: 300)
    ) throws -> Data {
        try labelledPDF(labels: (1...pageCount).map { "\(prefix)-\($0)" }, size: size)
    }

    /// A one-page "scan": an image PDF, optionally with a non-zero MediaBox
    /// origin and a `/Rotate`.
    ///
    /// Both of those are the things a text layer's geometry gets wrong, and
    /// neither can be produced by the obvious `CGPDFContext` page — the origin
    /// because nobody passes a non-zero one by accident, and the rotation
    /// because `CGPDFContext` has no API for `/Rotate` at all. PDFKit does, so
    /// the page is written first and rotated second.
    ///
    /// - Parameters:
    ///   - mediaBoxOrigin: written into `/MediaBox` verbatim. The page content is
    ///     drawn at that origin, so the *visible* page is unchanged and only the
    ///     coordinates move.
    ///   - rotation: degrees, a multiple of 90, applied as `/Rotate`.
    public static func scanPDF(
        image imageData: Data,
        pageSize: CGSize? = nil,
        mediaBoxOrigin: CGPoint = .zero,
        rotation: Int = 0
    ) throws -> Data {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw FixtureError.writeFailed("scan image would not decode") }

        let size = pageSize ?? CGSize(width: image.width, height: image.height)
        let box = CGRect(origin: mediaBoxOrigin, size: size)

        let flat = try pdf { context in
            beginPage(context, box: box)
            context.draw(image, in: box)
            context.endPDFPage()
        }

        guard rotation % 360 != 0 else { return flat }
        guard let document = PDFDocument(data: flat), let page = document.page(at: 0) else {
            throw FixtureError.writeFailed("PDFKit would not reopen the scan fixture")
        }
        page.rotation = rotation
        guard let rotated = document.dataRepresentation() else {
            throw FixtureError.writeFailed("PDFKit would not rewrite the rotated scan fixture")
        }
        return rotated
    }

    // MARK: - Comic archives

    /// One member of a fixture archive.
    public struct ArchiveEntry: Sendable {
        public var name: String
        public var data: Data

        public init(name: String, data: Data = Data()) {
            self.name = name
            self.data = data
        }

        /// A folder entry: a ZIP records one as a zero-byte member whose name
        /// ends in a slash.
        public static func directory(_ name: String) -> ArchiveEntry {
            ArchiveEntry(name: name.hasSuffix("/") ? name : name + "/")
        }
    }

    /// A ZIP archive containing exactly `entries`, in that order, stored
    /// uncompressed.
    ///
    /// Stored rather than deflated so the fixture writer has no compressor to be
    /// wrong about; the reader under test handles both, and the deflate path is
    /// covered by round-tripping a real archive through it elsewhere.
    public static func zipArchive(_ entries: [ArchiveEntry]) -> Data {
        var output = Data()
        var central = Data()
        var offsets: [UInt32] = []

        for entry in entries {
            let name = Array(entry.name.utf8)
            let crc = crc32(entry.data)
            offsets.append(UInt32(output.count))

            output.append(u32(0x0403_4B50))          // local file header
            output.append(u16(20))                   // version needed
            output.append(u16(0x0800))               // UTF-8 names
            output.append(u16(0))                    // stored
            output.append(u16(0)); output.append(u16(0))   // time, date
            output.append(u32(crc))
            output.append(u32(UInt32(entry.data.count)))
            output.append(u32(UInt32(entry.data.count)))
            output.append(u16(UInt16(name.count)))
            output.append(u16(0))                    // no extra field
            output.append(contentsOf: name)
            output.append(entry.data)
        }

        for (index, entry) in entries.enumerated() {
            let name = Array(entry.name.utf8)
            central.append(u32(0x0201_4B50))         // central file header
            central.append(u16(20))                  // version made by
            central.append(u16(20))                  // version needed
            central.append(u16(0x0800))
            central.append(u16(0))
            central.append(u16(0)); central.append(u16(0))
            central.append(u32(crc32(entry.data)))
            central.append(u32(UInt32(entry.data.count)))
            central.append(u32(UInt32(entry.data.count)))
            central.append(u16(UInt16(name.count)))
            central.append(u16(0))                   // extra
            central.append(u16(0))                   // comment
            central.append(u16(0))                   // disk start
            central.append(u16(0))                   // internal attrs
            // The MS-DOS directory bit, for folder entries. Real writers set it
            // and a reader that only looks at the trailing slash still gets
            // these right — which is the point of setting it here.
            central.append(u32(entry.name.hasSuffix("/") ? 0x10 : 0))
            central.append(u32(offsets[index]))
            central.append(contentsOf: name)
        }

        let centralOffset = UInt32(output.count)
        output.append(central)
        output.append(u32(0x0605_4B50))              // end of central directory
        output.append(u16(0)); output.append(u16(0)) // disk numbers
        output.append(u16(UInt16(entries.count)))
        output.append(u16(UInt16(entries.count)))
        output.append(u32(UInt32(central.count)))
        output.append(u32(centralOffset))
        output.append(u16(0))                        // no archive comment
        return output
    }

    // MARK: - Writing fixtures out

    /// A fresh directory that the caller is expected to remove.
    public static func makeTemporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lathe-doc-\(label)-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw FixtureError.writeFailed("temporary directory: \(error)")
        }
        return url
    }

    @discardableResult
    public static func write(_ data: Data, to url: URL) throws -> URL {
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw FixtureError.writeFailed("\(url.lastPathComponent): \(error)")
        }
        return url
    }

    // MARK: - Drawing plumbing

    private static func bitmap(size: CGSize, _ body: (CGContext) -> Void) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: Int(size.width.rounded()),
            height: Int(size.height.rounded()),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw FixtureError.writerUnavailable("no \(size) bitmap context")
        }
        body(context)
        guard let image = context.makeImage() else {
            throw FixtureError.writeFailed("bitmap produced no image")
        }
        return image
    }

    private static func encode(
        _ image: CGImage,
        as typeIdentifier: String,
        frames: [[CFString: Any]]
    ) throws -> Data {
        try encode([image], as: typeIdentifier, frames: frames)
    }

    private static func encode(
        _ images: [CGImage],
        as typeIdentifier: String,
        frames: [[CFString: Any]],
        container: [CFString: Any] = [:]
    ) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, typeIdentifier as CFString, images.count, nil
        ) else {
            throw FixtureError.writerUnavailable("ImageIO will not write \(typeIdentifier) here")
        }
        if !container.isEmpty {
            CGImageDestinationSetProperties(destination, container as CFDictionary)
        }
        for (index, image) in images.enumerated() {
            CGImageDestinationAddImage(
                destination, image, (frames[min(index, frames.count - 1)]) as CFDictionary
            )
        }
        guard CGImageDestinationFinalize(destination) else {
            throw FixtureError.writeFailed("ImageIO would not finalise \(typeIdentifier)")
        }
        return data as Data
    }

    private static func pdf(_ body: (CGContext) -> Void) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil)
        else {
            throw FixtureError.writerUnavailable("no Core Graphics PDF context")
        }
        body(context)
        context.closePDF()
        guard data.length > 0 else { throw FixtureError.writeFailed("empty PDF") }
        return data as Data
    }

    private static func beginPage(_ context: CGContext, box: CGRect) {
        var mediaBox = box
        let boxData = withUnsafeBytes(of: &mediaBox) { Data($0) } as CFData
        context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
    }

    // MARK: - Bytes

    private static func u16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    private static func u32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF),
        ])
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 != 0 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    /// The real thing, not a zero. A reader that verifies CRCs must be able to
    /// verify these, and a fixture that ships zeros would pass against a reader
    /// that checks nothing and fail the day one is added.
    static func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xFFFF_FFFF
        for byte in data {
            value = crcTable[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
        }
        return value ^ 0xFFFF_FFFF
    }
}
