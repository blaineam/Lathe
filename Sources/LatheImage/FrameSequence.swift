import CoreGraphics
import Foundation
import ImageIO
import LatheCore

// The input side of composition: the frames going in, the canvas they land on,
// and the one decoder that reads them. `LatheVideo` and `LatheDoc` both sit on
// top of `LatheImage`, so this is where a vocabulary all three composers share
// can live without anything depending sideways.

/// An ordered run of image files to be assembled into one thing — an animation,
/// a video, a PDF, a comic archive.
///
/// ## Order is the whole contract
///
/// A sequence is a *list*, and the list's order is the output's order. That is
/// worth stating because the obvious way to build one — ask the file system for
/// a directory's contents — does not produce an order at all:
/// `contentsOfDirectory` is documented as unordered, and on a real volume it
/// comes back in whatever order the directory's b-tree happens to hold.
/// ``contentsOfDirectory(_:)`` therefore sorts, and sorts the way a reader does;
/// see that method for why the sort is not a plain `<`.
///
/// ## Why URLs and not images
///
/// A `CGImage` is a decoded bitmap. A thousand 4K frames held as `CGImage` is
/// something like 25 GB resident, which on iOS is not a slow program but a
/// terminated one. Every composer here therefore decodes one frame at a time and
/// drops it before reading the next, and taking file URLs is what makes that
/// possible rather than merely polite.
public struct FrameSequence: Sendable, Equatable {

    /// The frames, in output order.
    public let frames: [URL]

    /// Takes the frames exactly as given, in the order given.
    public init(_ frames: [URL]) {
        self.frames = frames
    }

    /// Every image directly inside `directory`, in the order a viewer shows
    /// them.
    ///
    /// The pairing for ``FrameExtractor``'s `frames(from:into:)`, which writes
    /// `frame-01`…`frame-12` zero-padded for exactly this reason.
    ///
    /// **The sort is `.localizedStandardCompare`, not `<`.** A plain string sort
    /// puts `frame-10` between `frame-1` and `frame-2`, which is the classic way
    /// an assembled animation comes out shuffled; the standard comparison reads
    /// runs of digits as numbers, so an *unpadded* directory — one somebody else
    /// produced — also comes out right. Padded names sort identically under
    /// both, so nothing that already worked changes.
    ///
    /// Sub-directories are not descended into and non-image files are skipped
    /// rather than refused: `.DS_Store` sitting beside a hundred frames is not an
    /// error, it is Tuesday.
    ///
    /// - Throws: ``LatheError/readFailed(path:reason:)`` if the directory cannot
    ///   be listed.
    public static func contentsOfDirectory(_ directory: URL) throws -> FrameSequence {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )
        } catch {
            throw LatheError.readFailed(
                path: directory.lastPathComponent,
                reason: (error as NSError).localizedDescription
            )
        }

        let images = entries
            .filter { ImageFormat.named(byFilenameExtension: $0.pathExtension) != nil }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        return FrameSequence(images)
    }

    public var count: Int { frames.count }
    public var isEmpty: Bool { frames.isEmpty }

    /// The frames, or a refusal naming what was about to be written.
    ///
    /// **Zero frames is an error, not an empty file.** Every composer here would
    /// otherwise happily produce something: `CGImageDestinationFinalize` writes a
    /// valid zero-frame GIF, `AVAssetWriter` writes a zero-duration movie, and
    /// `CGPDFContext` writes a PDF with no pages. All three are files a caller
    /// will discover are useless somewhere much further downstream, so the
    /// refusal happens here, once, before anything is created.
    ///
    /// - Throws: ``LatheError/invalidInput(reason:)``.
    public func requireFrames(forWriting intent: String) throws -> [URL] {
        guard !frames.isEmpty else {
            throw LatheError.invalidInput(
                reason: "there are no frames to write \(intent) from; a sequence needs at least one"
            )
        }
        return frames
    }
}

/// What a composer does when the frames are not all the same size.
///
/// The question has to be answered because **a video has one coded size for its
/// whole track and an animation has one canvas**. There is no silent option: a
/// differently-sized frame is either fitted, stretched into place by whatever
/// drew it, or refused, and a composer that does not choose has chosen
/// stretching by accident.
///
/// It does not arise for ``FrameDocumentWriter``'s outputs, where a PDF page and
/// a comic page are each their own size and mixing them is ordinary.
public enum FrameCanvas: Sendable, Equatable {

    /// Every frame is drawn into the **first frame's** size, aspect preserved
    /// and centred, with the unused margin left transparent (or black, for a
    /// codec with no alpha).
    ///
    /// The default, because it is a no-op for the case that dominates — frames
    /// pulled out of one video, which are all the same size — and produces a
    /// watchable result rather than a refusal for the case that does not. No
    /// pixel of any frame is cropped away.
    case fitFirstFrame

    /// The same fit, into a canvas the caller names.
    case fixed(PixelSize)

    /// Refuse a run whose frames differ, naming the first frame that does.
    ///
    /// For a caller who would rather be told than have a decision made — a batch
    /// job where a mismatch means the input directory is wrong, not that the
    /// output should be letterboxed.
    case requireUniform
}

/// Reading frames, and putting them on a canvas. Shared by the animation, video
/// and PDF composers.
///
/// Public because `LatheVideo` and `LatheDoc` are separate modules and all three
/// composers must agree about what a frame is; it is plumbing, not a feature.
public enum FrameReader {

    /// The pixel size of `url` **without decoding it**.
    ///
    /// A header read: resolving a canvas from the first frame of a thousand, or
    /// checking that a thousand frames agree, must not cost a thousand decoded
    /// bitmaps. `kCGImageSourceShouldCache: false` keeps ImageIO from
    /// speculatively holding one either.
    ///
    /// - Throws: ``LatheError/invalidInput(reason:)`` if the file is not an
    ///   image, or does not say how big it is.
    public static func pixelSize(of url: URL) throws -> PixelSize {
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary
        ), CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            throw LatheError.invalidInput(
                reason: "\(url.lastPathComponent) is not an image ImageIO can read"
            )
        }
        guard let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0
        else {
            throw LatheError.invalidInput(
                reason: "\(url.lastPathComponent) does not report a pixel size"
            )
        }
        return PixelSize(width: width, height: height)
    }

    /// Decodes one frame.
    ///
    /// - Throws: ``LatheError/readFailed(path:reason:)`` if the file cannot be
    ///   opened, ``LatheError/invalidInput(reason:)`` if it is not an image.
    public static func decode(_ url: URL) throws -> CGImage {
        try ImageEncoder.requireReadableFile(at: url)
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary
        ), CGImageSourceGetCount(source) > 0 else {
            throw LatheError.invalidInput(
                reason: "\(url.lastPathComponent) is not an image ImageIO can read"
            )
        }
        // Index 0 rather than "all of them": a frame of a sequence is one
        // picture, and handing this an animated GIF composes its first frame,
        // which is the only reading of "this file is a frame" that is not a
        // guess about what the caller meant by the other 47.
        guard let image = CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw LatheError.readFailed(
                path: url.lastPathComponent, reason: "ImageIO decoded no image from it"
            )
        }
        return image
    }

    /// Works out the canvas `frames` will be composed onto, reading headers only.
    ///
    /// - Throws: ``LatheError/invalidConfiguration(reason:)`` for
    ///   ``FrameCanvas/requireUniform`` against a run that is not uniform — the
    ///   message names the offending frame and both sizes, because "they are not
    ///   all the same" is not an actionable thing to be told about 900 files.
    public static func resolveCanvas(_ canvas: FrameCanvas, for frames: [URL]) throws -> PixelSize {
        guard let first = frames.first else {
            throw LatheError.invalidInput(reason: "no frames to size a canvas from")
        }

        switch canvas {
        case let .fixed(size):
            guard !size.isEmpty else {
                throw LatheError.invalidConfiguration(
                    reason: "a fixed canvas must have a positive size, got \(size)"
                )
            }
            return size

        case .fitFirstFrame:
            return try pixelSize(of: first)

        case .requireUniform:
            let expected = try pixelSize(of: first)
            for frame in frames.dropFirst() {
                let size = try pixelSize(of: frame)
                guard size == expected else {
                    throw LatheError.invalidConfiguration(
                        reason: "\(frame.lastPathComponent) is \(size) but \(first.lastPathComponent) "
                            + "is \(expected); pass FrameCanvas.fitFirstFrame to letterbox the "
                            + "frames into one canvas instead"
                    )
                }
            }
            return expected
        }
    }

    /// The rectangle `image` occupies inside `canvas`: aspect preserved, centred,
    /// and **never enlarged past the canvas**.
    ///
    /// Split out from the drawing so the video composer — which draws straight
    /// into a `CVPixelBuffer` rather than into a `CGImage` — uses the same
    /// arithmetic as the animation composer instead of a second copy of it.
    public static func fittedRect(for image: PixelSize, in canvas: PixelSize) -> CGRect {
        guard !image.isEmpty, !canvas.isEmpty else {
            return CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height)
        }
        let scale = min(Double(canvas.width) / Double(image.width),
                        Double(canvas.height) / Double(image.height))
        let width = (Double(image.width) * scale).rounded()
        let height = (Double(image.height) * scale).rounded()
        return CGRect(
            x: ((Double(canvas.width) - width) / 2).rounded(),
            y: ((Double(canvas.height) - height) / 2).rounded(),
            width: width,
            height: height
        )
    }

    /// Returns `image` on `canvas`, redrawing **only if it is not already that
    /// size**.
    ///
    /// The early return is not a micro-optimisation. The overwhelmingly common
    /// input is a run of frames that already match, and redrawing each one
    /// through a fresh premultiplied-BGRA context would resample pixels that had
    /// no reason to move — a visible softening of every frame of an animation
    /// whose frames were already the right size.
    ///
    /// - Throws: ``LatheError/encodingFailed(stage:code:reason:)`` if Core
    ///   Graphics will not give a context of that size.
    public static func compose(_ image: CGImage, onto canvas: PixelSize) throws -> CGImage {
        guard image.width != canvas.width || image.height != canvas.height else { return image }

        guard let context = CGContext(
            data: nil,
            width: canvas.width,
            height: canvas.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,           // let Core Graphics choose its own alignment
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw LatheError.encodingFailed(
                stage: "canvas", code: nil,
                reason: "could not create a \(canvas) drawing context"
            )
        }
        context.interpolationQuality = .high
        context.draw(
            image,
            in: fittedRect(for: PixelSize(width: image.width, height: image.height), in: canvas)
        )

        guard let composed = context.makeImage() else {
            throw LatheError.encodingFailed(
                stage: "canvas", code: nil, reason: "composing onto \(canvas) produced no image"
            )
        }
        return composed
    }
}
