import CoreGraphics
import Foundation
import ImageIO
import LatheCore
import LatheImage

/// How big a PDF page is, given the pixels going on it.
///
/// A PDF measures in **points**, not pixels — 72 to the inch, by definition —
/// and an image has only pixels. Something therefore has to state the
/// relationship, and this is that statement. Getting it wrong is not a rendering
/// bug: the page looks right on screen either way, and prints at the wrong size.
public enum PDFPageSizing: Sendable, Equatable {

    /// One point per pixel. A 1200x1600 frame becomes a 1200x1600-point page.
    ///
    /// The default because it is the only option that needs no information the
    /// caller may not have, and because it is what every "images to PDF" tool
    /// does. On paper it means 72 DPI, so a page meant for printing wants
    /// ``dotsPerInch(_:)`` instead.
    case imagePixels

    /// The frame's pixels interpreted at this resolution: a 1200x1600 frame at
    /// 300 DPI becomes a 4x5.33-inch page — 288x384 points.
    ///
    /// `.dotsPerInch(72)` is ``imagePixels`` exactly, by the definition of a
    /// point.
    case dotsPerInch(Double)

    /// A fixed page, in points, with each frame fitted inside it and centred.
    ///
    /// US Letter is `.fixed(widthPoints: 612, heightPoints: 792)`; A4 is
    /// `.fixed(widthPoints: 595, heightPoints: 842)`. The frames keep their
    /// aspect ratios and are never cropped, so a page of a different shape gets
    /// margins.
    case fixed(widthPoints: Double, heightPoints: Double)

    /// The page box for a frame of `pixels`, and the rect to draw it in.
    ///
    /// - Throws: ``LatheError/invalidConfiguration(reason:)`` for a
    ///   non-positive DPI or page size.
    func page(for pixels: PixelSize) throws -> (box: CGRect, content: CGRect) {
        switch self {
        case .imagePixels:
            let box = CGRect(x: 0, y: 0, width: Double(pixels.width), height: Double(pixels.height))
            return (box, box)

        case let .dotsPerInch(dpi):
            guard dpi > 0, dpi.isFinite else {
                throw LatheError.invalidConfiguration(
                    reason: "a page resolution must be positive and finite, got \(dpi) DPI"
                )
            }
            let box = CGRect(
                x: 0, y: 0,
                width: Double(pixels.width) * 72 / dpi,
                height: Double(pixels.height) * 72 / dpi
            )
            return (box, box)

        case let .fixed(width, height):
            guard width > 0, height > 0, width.isFinite, height.isFinite else {
                throw LatheError.invalidConfiguration(
                    reason: "a fixed page must have a positive size, got \(width)x\(height) points"
                )
            }
            let box = CGRect(x: 0, y: 0, width: width, height: height)
            // The same aspect-fit arithmetic the animation and video composers
            // use, so a frame that is letterboxed into a video and onto a page
            // is letterboxed identically.
            let fitted = FrameReader.fittedRect(
                for: pixels, in: PixelSize(width: Int(width.rounded()), height: Int(height.rounded()))
            )
            return (box, fitted)
        }
    }
}

/// What a frames-to-document write actually produced.
public struct FrameDocumentResult: Sendable, Equatable {
    public var output: URL
    public var kind: DocumentKind
    /// Pages written, which for both writers is one per frame.
    public var pageCount: Int
    public var outputByteCount: UInt64
    public var wallTime: TimeInterval

    public init(
        output: URL,
        kind: DocumentKind,
        pageCount: Int,
        outputByteCount: UInt64,
        wallTime: TimeInterval
    ) {
        self.output = output
        self.kind = kind
        self.pageCount = pageCount
        self.outputByteCount = outputByteCount
        self.wallTime = wallTime
    }
}

/// Assembles a run of stills into a paged document: a PDF, or a comic archive.
///
/// The counterpart to ``DocumentEditor``, which rearranges the pages of a
/// document that already exists. This makes one where there was none.
///
/// ```swift
/// let frames = try FrameSequence.contentsOfDirectory(scans)
/// try FrameDocumentWriter().writePDF(frames, to: book, pageSizing: .dotsPerInch(300))
/// try FrameDocumentWriter().writeComicArchive(frames, to: comic)
/// ```
///
/// ## The two outputs are not the same operation wearing two hats
///
/// They differ in the one way that matters for image quality:
///
/// - **A comic archive carries the frames' bytes across untouched.** A CBZ is a
///   ZIP of images, so the image that goes in is the image that comes out, byte
///   for byte — nothing is decoded, so nothing can be re-encoded. This writer
///   therefore does not take a quality parameter for it, because there is no
///   encode to have an opinion about. The same rule ``ZIPWriter`` already states
///   for rearranging an archive, applied to building one.
/// - **A PDF has to draw.** PDF has no HEIC, no WebP, no AVIF — see
///   ``ImageFormat/isLegalInsidePDF`` — so a frame in any of those formats
///   cannot be embedded as it stands. Rather than embed some formats and
///   re-encode others, which would make the output's quality depend invisibly on
///   the input's format, every frame is drawn into the page context and Core
///   Graphics picks the filter. The trade is stated rather than hidden: a PDF
///   made here is a *rendering* of the frames, and the archive is a *container*
///   for them.
///
/// ## Why `CGPDFContext` and not PDFKit
///
/// PDFKit would build this too, by way of one `PDFPage` per `NSImage`/`UIImage`
/// — and that is the trap, because there is no cross-platform image class to
/// hand it. `PDFPage(image:)` exists on both platforms against two different
/// types, and a module that must compile for iOS and macOS from one source ends
/// up with a `#if` around the only interesting line. `CGPDFContext` takes a
/// `CGImage`, which both platforms have, so there is no conditional to get
/// wrong. PDFKit is still the right tool for *reading* a PDF, which is what the
/// rest of this module uses it for.
public struct FrameDocumentWriter: Sendable {

    public init() {}

    // MARK: - PDF

    /// Writes `frames` as a PDF, one page per frame.
    ///
    /// Atomic through ``DocumentFiles/writingAtomically(to:pathExtension:stage:_:)``:
    /// a failure part way leaves `destination` exactly as it was.
    ///
    /// - Parameters:
    ///   - frames: the pages, in order. Empty is refused — a zero-page PDF is a
    ///     file `CGPDFContext` will happily write and no reader will open.
    ///   - destination: where to write.
    ///   - pageSizing: how pixels become points. See ``PDFPageSizing``, and note
    ///     that the default prints at 72 DPI.
    ///   - progress: reported per page under the stage name `"pages"`.
    ///
    /// - Throws: ``LatheError/invalidInput(reason:)`` for an empty sequence or an
    ///   unreadable frame; ``LatheError/invalidConfiguration(reason:)`` for a
    ///   page size that cannot be honoured; ``LatheError/cancelled(atUnit:)``
    ///   when progress says stop.
    @discardableResult
    public func writePDF(
        _ frames: FrameSequence,
        to destination: URL,
        pageSizing: PDFPageSizing = .imagePixels,
        progress: ProgressHandle = .ignoring()
    ) throws -> FrameDocumentResult {
        let started = Date()
        let urls = try frames.requireFrames(forWriting: "a PDF")

        let bytes = try DocumentFiles.writingAtomically(
            to: destination, pathExtension: "pdf", stage: "pdf"
        ) { scratch in
            guard let consumer = CGDataConsumer(url: scratch as CFURL),
                  // `mediaBox: nil` — the default page box is never used, because
                  // every page below names its own. A document whose pages are
                  // different sizes is ordinary for scans, and a single media box
                  // here would crop all of them to the first one's shape.
                  let context = CGContext(consumer: consumer, mediaBox: nil, nil)
            else {
                throw LatheError.writeFailed(
                    path: destination.lastPathComponent,
                    reason: "Core Graphics would not open a PDF destination there"
                )
            }

            for (index, url) in urls.enumerated() {
                try progress.checkCancellation()

                let image = try FrameReader.decode(url)
                let (box, content) = try pageSizing.page(
                    for: PixelSize(width: image.width, height: image.height)
                )

                // The media box travels as raw bytes of a `CGRect` inside a
                // `CFData`, which is the only shape `beginPDFPage` accepts for
                // it — a `CGRect` boxed as a value does not survive the
                // dictionary, and the page silently comes out letter-sized.
                var mediaBox = box
                let boxData = withUnsafeBytes(of: &mediaBox) { Data($0) } as CFData
                context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
                context.interpolationQuality = .high
                context.draw(image, in: content)
                context.endPDFPage()

                guard progress.report(LatheProgress(
                    fraction: Double(index + 1) / Double(urls.count),
                    stage: "pages",
                    unitIndex: UInt64(index + 1),
                    unitCount: UInt64(urls.count))) else {
                    throw LatheError.cancelled(atUnit: UInt64(index + 1))
                }
            }

            context.closePDF()
        }

        return FrameDocumentResult(
            output: destination,
            kind: .pdf,
            pageCount: urls.count,
            outputByteCount: bytes,
            wallTime: Date().timeIntervalSince(started)
        )
    }

    // MARK: - Comic archive

    /// Writes `frames` as a comic archive — a ZIP of the images, in order.
    ///
    /// ## The names are rewritten, and that is the feature
    ///
    /// **Comic readers sort entries by name.** Archive order is not display
    /// order in any reader worth naming, so an archive built out of
    /// `scan.jpg`, `IMG_0042.jpg`, `a.jpg` displays in an order that has nothing
    /// to do with the sequence the caller handed over — while looking perfectly
    /// correct in a hex dump. Every entry is therefore renamed
    /// `page-001.jpg`…, zero-padded to the width of the count so that page 10
    /// follows page 9 rather than page 1. The same rule ``DocumentEditor``
    /// follows when it rearranges one.
    ///
    /// Each frame keeps its own extension, because the bytes are its own: a run
    /// of mixed PNG and JPEG frames produces an archive of mixed PNG and JPEG
    /// pages, which every reader handles and which costs no re-encode.
    ///
    /// ## Stored, not deflated
    ///
    /// The members go in uncompressed. A JPEG or PNG is already compressed, so
    /// deflating it spends CPU to make it very slightly *larger*; see
    /// ``ZIPWriter/Member/stored(name:data:modified:externalAttributes:)``.
    ///
    /// - Parameters:
    ///   - frames: the pages, in order. Empty is refused.
    ///   - destination: where to write. Conventionally `.cbz`.
    ///   - progress: reported per page under the stage name `"pages"`.
    ///
    /// - Throws: ``LatheError/invalidInput(reason:)`` for an empty sequence, for
    ///   a frame that is not an image a reader would display, or for an archive
    ///   that would need ZIP64; ``LatheError/readFailed(path:reason:)`` for a
    ///   frame that cannot be read; ``LatheError/cancelled(atUnit:)`` when
    ///   progress says stop.
    @discardableResult
    public func writeComicArchive(
        _ frames: FrameSequence,
        to destination: URL,
        progress: ProgressHandle = .ignoring()
    ) throws -> FrameDocumentResult {
        let started = Date()
        let urls = try frames.requireFrames(forWriting: "a comic archive")

        let width = String(urls.count).count
        var members: [ZIPWriter.Member] = []
        members.reserveCapacity(urls.count)

        for (index, url) in urls.enumerated() {
            try progress.checkCancellation()
            try DocumentFiles.requireReadableFile(at: url)

            // The same allowlist `DocumentInspector` counts pages with, applied
            // on the way in. Building an archive whose pages a reader will then
            // decline to show is a failure that only appears in somebody else's
            // app, so it is caught here instead.
            guard let format = ImageFormat.named(byFilenameExtension: url.pathExtension),
                  format != .pdf
            else {
                throw LatheError.invalidInput(
                    reason: "\(url.lastPathComponent) is not an image a comic reader shows; a "
                        + "comic archive's pages must be images"
                )
            }

            let data: Data
            do {
                data = try Data(contentsOf: url, options: .mappedIfSafe)
            } catch {
                throw LatheError.readFailed(
                    path: url.lastPathComponent, reason: (error as NSError).localizedDescription
                )
            }

            members.append(ZIPWriter.Member.stored(
                name: String(format: "page-%0\(width)d", index + 1)
                    + "." + url.pathExtension.lowercased(),
                data: data
            ))

            guard progress.report(LatheProgress(
                fraction: Double(index + 1) / Double(urls.count),
                stage: "pages",
                unitIndex: UInt64(index + 1),
                unitCount: UInt64(urls.count))) else {
                throw LatheError.cancelled(atUnit: UInt64(index + 1))
            }
        }

        try ZIPWriter.write(members, to: destination, name: destination.lastPathComponent)

        return FrameDocumentResult(
            output: destination,
            kind: .comicArchiveZIP,
            pageCount: members.count,
            outputByteCount: DocumentFiles.byteCount(of: destination) ?? 0,
            wallTime: Date().timeIntervalSince(started)
        )
    }
}
