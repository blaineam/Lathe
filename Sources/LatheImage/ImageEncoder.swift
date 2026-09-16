import CoreGraphics
import Foundation
import ImageIO
import LatheCore

/// Re-encodes a still image: format, quality, aspect-fit downscale and metadata
/// policy, in one pass, on the device, with no subprocess.
///
/// ```swift
/// let result = try await ImageEncoder().encode(
///     source: heic, to: jpeg,
///     format: .jpeg, quality: .quality(0.7),
///     resize: .longestSide(2048), metadata: .stripLocation
/// )
/// ```
///
/// ## Four things it refuses to get wrong
///
/// **It never enlarges.** The target size comes from
/// ``ResizeTarget/resolve(from:)``, which clamps to the source, and the encoder
/// takes the scaling path *only* when the resolved target is strictly smaller.
/// Note what is not used anywhere below:
/// `kCGImageDestinationImageMaxPixelSize`. That key is the obvious way to do
/// this and it upsamples without complaint when the number you hand it exceeds
/// the image — a "make thumbnails at most 2048px" batch silently turns a
/// 300-pixel avatar into a blurry 2048-pixel one. Resolving the size first and
/// scaling explicitly means the enlarging case cannot be reached.
///
/// **It never produces a 0-byte file.** The format is checked against
/// ``EncodeSupport`` before anything is created, and the encode itself happens
/// into a temporary file that is moved into place only after `Finalize`
/// succeeds. A failure — unsupported format, cancellation, a codec error — thus
/// leaves `destination` exactly as it found it, rather than leaving an empty
/// file that every "does the output exist" check will read as success.
///
/// **It never silently rotates a photo.** See ``OrientationStrategy``. Both
/// strategies are implemented and the default is the conservative one; when the
/// destination format cannot store an orientation tag at all, the pixels are
/// rotated instead of the tag being dropped.
///
/// **Metadata is written, not inherited.** See ``ImageMetadata``.
///
/// ## Two backends, one contract
///
/// Almost everything here is ImageIO. **WebP is not** — ImageIO reads it and
/// cannot write it (``EncodeSupport`` proves that by trying), so WebP is encoded
/// by the vendored libwebp in ``WebPEncoder``. The routing is
/// ``EncodeSupport/backend(for:)`` and it is invisible to the caller: same
/// ``QualityTarget``, same ``ResizeTarget``, same ``MetadataPolicy``, same
/// ``ProgressHandle``, same ``ImageEncodeResult``, same downscale-only rule, same
/// never-leave-a-partial-file rule.
///
/// Two differences are real and are not papered over:
///
/// - ``QualityTarget/lossless`` **is honoured for WebP** and refused for
///   everything else. For an ImageIO format "re-encode nothing" is a
///   contradiction in terms for an encoder — that is a metadata rewrite, which
///   Lathe does not offer. libwebp, uniquely here, has a genuine
///   lossless coder, so `.lossless` selects it and the pixels survive exactly.
/// - **A WebP's metadata goes through libwebp's muxer**, not ImageIO: the same
///   policy-filtered dictionary is serialised into `EXIF`/`XMP ` chunks. The
///   orientation tag survives, so ``OrientationStrategy/preserveTag`` is
///   honoured for WebP as for HEIC. No ICC profile is written; WebP pixels are
///   converted to sRGB instead. See ``WebPEncoder``.
///
/// ## Progress and cancellation
///
/// The `async` entry point runs the encode through ``LatheWork``, so the
/// blocking ImageIO work happens off the cooperative pool and `Task`
/// cancellation reaches it. Progress is reported per stage — `probe`, `read`,
/// `decode`, `scale`, `encode` — and every stage boundary is a cancellation
/// checkpoint. Cancel latency is therefore one stage, which for a single still
/// image is the whole job's granularity; a caller encoding a directory should
/// hold its own ``ProgressHandle`` across the batch and use the synchronous
/// entry point.
public struct ImageEncoder: Sendable {

    public init() {}

    // MARK: - Entry points

    /// Encode one still image.
    ///
    /// - Parameters:
    ///   - source: the image to read. A local file; see the licence policy for
    ///     why nothing here takes a network URL.
    ///   - destination: where to write. Overwritten if it exists, and left
    ///     untouched if the encode fails.
    ///   - format: the output format. Checked against ``EncodeSupport`` before
    ///     anything is created.
    ///   - quality: ``QualityTarget/quality(_:)`` is honoured for formats that
    ///     are lossy by default, and ``QualityTarget/lossless`` for WebP. See the
    ///     note below.
    ///   - resize: `nil` and ``ResizeTarget/none`` both mean "leave the pixel
    ///     dimensions alone" — the optional is here because the parameter reads
    ///     better that way, not because they differ. (Swift resolves a literal
    ///     `.none` against `ResizeTarget?` to `Optional.none`, so the two
    ///     spellings are genuinely indistinguishable at the call site; making
    ///     them mean different things would be a trap.)
    ///   - metadata: what to carry across. See ``MetadataPolicy``.
    ///   - orientation: how EXIF orientation is honoured. See
    ///     ``OrientationStrategy``.
    ///   - forcePreserve: keys restored after any strip, because removing them
    ///     breaks the file rather than anonymising it.
    ///   - sink: receives progress; returning `false` from it cancels.
    ///
    /// - Throws: ``LatheError/encodeUnavailable(format:)`` when this system
    ///   cannot write `format`; ``LatheError/invalidConfiguration(reason:)`` for
    ///   a contradictory request; ``LatheError/cancelled(atUnit:)`` when the
    ///   sink or the enclosing `Task` says stop.
    ///
    /// > Important: **quality 1.0 is not lossless.** For HEIC and AVIF a quality
    /// > of 1.0 still quantises, and it routinely produces a *larger* file than
    /// > the source — re-encoding an already-compressed JPEG at 1.0 is the
    /// > classic way to make a photo library bigger. The encoder honours the
    /// > request rather than second-guessing it, and logs when the output grew;
    /// > ``ImageEncodeResult/inputByteCount`` and
    /// > ``ImageEncodeResult/outputByteCount`` let a caller keep the smaller of
    /// > the two. If the intent is genuinely "do not re-encode", that is a
    /// > metadata rewrite, not an encode, and not something this type does.
    @discardableResult
    public func encode(
        source: URL,
        to destination: URL,
        format: ImageFormat,
        quality: QualityTarget = .quality(0.7),
        resize: ResizeTarget? = nil,
        metadata: MetadataPolicy = .preserveAll,
        orientation: OrientationStrategy = .preserveTag,
        forcePreserve: MetadataForcePreserve = .default,
        reporting sink: (any ProgressSink)? = nil
    ) async throws -> ImageEncodeResult {
        let request = ImageEncodeRequest(
            source: source,
            destination: destination,
            format: format,
            quality: quality,
            resize: resize ?? .none,
            metadata: metadata,
            forcePreserve: forcePreserve,
            orientation: orientation
        )
        return try await LatheWork.run(reporting: sink) { progress in
            try Self.perform(request, progress: progress)
        }
    }

    /// The same encode against a request the caller already has, and a handle it
    /// already owns.
    ///
    /// Synchronous and blocking: this is the form to call from inside a batch
    /// that is already running on ``LatheWork``'s queue, so a thousand images do
    /// not each pay for their own hop.
    @discardableResult
    public func encode(
        _ request: ImageEncodeRequest,
        progress: ProgressHandle = .ignoring()
    ) throws -> ImageEncodeResult {
        try Self.perform(request, progress: progress)
    }

    // MARK: - The encode

    private static let stageCount: UInt64 = 5

    private static func perform(
        _ request: ImageEncodeRequest,
        progress: ProgressHandle
    ) throws -> ImageEncodeResult {
        let started = Date()

        // Stage 0 — refuse before creating anything.
        //
        // Capability first, deliberately: `CGImageDestinationCreateWithURL`
        // returning nil for an unwritable format is easy to ignore, and the file
        // it does not create is easy to mistake for a successful empty encode.
        // Runtime-probed, never version-gated. See `EncodeSupport`.
        try progress.checkpoint(LatheProgress(stage: "probe", unitIndex: 0, unitCount: stageCount))
        try EncodeSupport.shared.requireEncodable(request.format)
        guard let backend = EncodeSupport.shared.backend(for: request.format) else {
            throw LatheError.encodeUnavailable(format: request.format.description)
        }
        if case .lossless = request.quality, backend == .imageIO {
            throw LatheError.invalidConfiguration(
                reason: "QualityTarget.lossless means \"re-encode nothing\", which an ImageIO "
                    + "encode cannot honour. Copying encoded data through while rewriting "
                    + "metadata is a rewrite (CGImageDestinationCopyImageSource), not an encode; "
                    + "this is CGImageDestinationAddImage, "
                    + "and it re-encodes by definition. (WebP is the exception: libwebp has a "
                    + "real lossless coder, so .lossless selects it.)"
            )
        }

        // Stage 1 — open the source and learn its geometry.
        try progress.checkpoint(LatheProgress(stage: "read", unitIndex: 1, unitCount: stageCount))
        try requireReadableFile(at: request.source)
        let inputByteCount = byteCount(of: request.source) ?? 0

        // `kCGImageSourceShouldCache: false`: the decoded bitmap is used once and
        // handed straight to the encoder, so ImageIO's cache would only hold a
        // second copy of a potentially very large image alive.
        guard let imageSource = CGImageSourceCreateWithURL(
            request.source as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        ), CGImageSourceGetCount(imageSource) > 0 else {
            throw LatheError.invalidInput(
                reason: "\(request.source.lastPathComponent) is not an image ImageIO can read"
            )
        }

        let sourceProperties = ImageMetadata.sourceProperties(of: imageSource)
        let storedSize = try storedPixelSize(from: sourceProperties, source: request.source)
        let sourceOrientation = orientation(from: sourceProperties)

        // The size arithmetic runs against the size a *viewer* sees, not the
        // size on disk. For a portrait photo stored landscape with a rotation
        // tag those differ by a transpose, and resolving `.fit(1000x2000)`
        // against the stored axes gives a differently-shaped result from the one
        // the caller drew on screen.
        let displaySize = sourceOrientation.swapsAxes
            ? PixelSize(width: storedSize.height, height: storedSize.width)
            : storedSize
        let targetDisplaySize = request.resize.resolve(from: displaySize)

        // Baking is forced — not merely preferred — when the destination cannot
        // hold the tag. Writing PNG while "preserving" an orientation tag that
        // PNG has nowhere to put is how a batch convert lands every portrait
        // photo on its side, and it looks like a success from every angle except
        // the user's.
        let strategy: OrientationStrategy
        if sourceOrientation == .up {
            strategy = .preserveTag          // nothing to rotate; skip the redraw
        } else if request.format.canStoreOrientationTag {
            strategy = request.orientation
        } else {
            if request.orientation == .preserveTag {
                LatheLog.image.debug(
                    """
                    \(request.format.description, privacy: .public) cannot store an orientation \
                    tag; baking orientation \(sourceOrientation.rawValue, privacy: .public) into \
                    the pixels instead of dropping it
                    """
                )
            }
            strategy = .bake
        }

        // The decoded pixels always arrive on the *stored* axes, so that is the
        // size to scale them to — whatever happens afterwards. Under `.bake` the
        // rotation then transposes them back into `targetDisplaySize`; under
        // `.preserveTag` they stay put and the viewer's transpose does it.
        // Scaling to the display size first and rotating second would squash the
        // image by its aspect ratio, twice, and still report a plausible number.
        let targetStoredSize = sourceOrientation.swapsAxes
            ? PixelSize(width: targetDisplaySize.height, height: targetDisplaySize.width)
            : targetDisplaySize

        // Stage 2 — decode.
        try progress.checkpoint(LatheProgress(stage: "decode", unitIndex: 2, unitCount: stageCount))
        let decoded = try decode(
            imageSource,
            storedSize: storedSize,
            targetStoredSize: targetStoredSize,
            source: request.source
        )

        // Stage 3 — geometry: exact scale, then the orientation bake if asked.
        try progress.checkpoint(LatheProgress(stage: "scale", unitIndex: 3, unitCount: stageCount))
        var image = try exactly(targetStoredSize, from: decoded)
        if strategy == .bake {
            image = try baking(sourceOrientation, into: image)
        }

        // Stage 4 — metadata, then write.
        try progress.checkpoint(LatheProgress(stage: "encode", unitIndex: 4, unitCount: stageCount))

        // The same dictionary for both backends: ImageIO writes it directly, and
        // the WebP encoder serialises it into EXIF/XMP chunks. One policy
        // resolver, so `.stripLocation` removes the same things from a WebP as
        // from a HEIC.
        let properties = ImageMetadata.properties(
            for: request.metadata,
            from: sourceProperties,
            forcePreserve: request.forcePreserve,
            // `.bake` rotated the pixels, so the tag must become "already
            // upright". Writing the original value here is the double-rotation
            // bug, and it is why these two strategies are an enum rather than a
            // pair of booleans somebody can set both of.
            orientation: strategy == .bake ? .up : sourceOrientation
        )

        let outputByteCount: UInt64
        switch backend {
        case .imageIO:
            guard let typeIdentifier = EncodeSupport.shared
                .destinationTypeIdentifier(for: request.format)
            else {
                throw LatheError.encodeUnavailable(format: request.format.description)
            }
            var properties = properties
            if request.format.isLossyByDefault, let normalised = request.quality.normalizedQuality {
                properties[kCGImageDestinationLossyCompressionQuality] = normalised
            }
            outputByteCount = try writingAtomically(
                to: request.destination, format: request.format
            ) { scratch in
                try writeViaImageIO(
                    image, to: scratch, typeIdentifier: typeIdentifier,
                    format: request.format, properties: properties, progress: progress
                )
            }

        case .builtIn:
            // Only WebP reaches here. The chunks are built from the same
            // dictionary as above; an upright image with nothing to say gets a
            // simple WebP with no chunks at all. See `WebPMetadataChunks`.
            let chunks = try WebPMetadataChunks.carrying(
                properties, pixelSize: PixelSize(width: image.width, height: image.height)
            )
            let encoded = try WebPEncoder.encode(image, quality: request.quality, metadata: chunks)
            try progress.checkCancellation()
            outputByteCount = try writingAtomically(
                to: request.destination, format: request.format
            ) { scratch in
                try encoded.write(to: scratch, options: .atomic)
            }
        }

        // The terminal tick. A UI that never sees unitIndex == unitCount looks
        // stuck at 80% forever; `ProgressHandle` never throttles this one away.
        progress.report(LatheProgress(stage: "encode", unitIndex: stageCount, unitCount: stageCount))

        let pixelSize = PixelSize(width: image.width, height: image.height)
        if outputByteCount > inputByteCount, inputByteCount > 0, request.format.isLossyByDefault {
            // Not an error: the caller may have asked for exactly this. It is
            // logged because the common cause is a quality target near 1.0 on a
            // format that is lossy at every setting, and a recompression batch
            // that grows the library is worth noticing on the first file rather
            // than on the last.
            LatheLog.image.info(
                """
                \(LatheLog.publicPath(request.destination), privacy: .public) grew: \
                \(inputByteCount, privacy: .public) → \(outputByteCount, privacy: .public) bytes \
                at \(request.format.description, privacy: .public) \
                quality \(request.quality.normalizedQuality ?? -1, privacy: .public)
                """
            )
        }

        return ImageEncodeResult(
            output: request.destination,
            format: request.format,
            pixelSize: pixelSize,
            inputByteCount: inputByteCount,
            outputByteCount: outputByteCount,
            wallTime: Date().timeIntervalSince(started),
            // Always false here, and that is the honest answer: this path
            // re-encodes pixels. The flag is for a future lossless rewrite.
            wasLosslessRewrite: false
        )
    }

    // MARK: - Decode

    /// Decodes at or just above the size actually needed.
    ///
    /// Two paths, and which one runs is decided by the already-clamped target
    /// rather than by the caller's request — the downscale path can therefore
    /// never be entered with a target larger than the source, which is the
    /// property that makes `kCGImageSourceThumbnailMaxPixelSize`'s willingness
    /// to upsample unreachable.
    private static func decode(
        _ imageSource: CGImageSource,
        storedSize: PixelSize,
        targetStoredSize: PixelSize,
        source: URL
    ) throws -> CGImage {
        let needsDownscale = targetStoredSize.longestSide < storedSize.longestSide

        let image: CGImage?
        if needsDownscale {
            // Decoding straight to roughly the right size avoids materialising a
            // 48-megapixel bitmap in order to throw 97% of it away, which on iOS
            // is the difference between a thumbnail pass that runs and one that
            // is jetsammed. `…FromImageAlways` because an embedded thumbnail, if
            // any, is the camera's low-quality one and may not even be the same
            // picture. `…WithTransform: false` because orientation is this
            // file's business, applied once, further down.
            image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceThumbnailMaxPixelSize: targetStoredSize.longestSide,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        } else {
            image = CGImageSourceCreateImageAtIndex(imageSource, 0, [
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        }

        guard let image else {
            throw LatheError.encodingFailed(
                stage: "decode", code: nil,
                reason: "ImageIO read \(source.lastPathComponent)'s headers but could not decode it"
            )
        }
        return image
    }

    /// Returns `image` at exactly `target`, redrawing only when it is not
    /// already that size — ImageIO's thumbnail rounding is its own and lands a
    /// pixel off often enough to matter.
    private static func exactly(_ target: PixelSize, from image: CGImage) throws -> CGImage {
        guard image.width != target.width || image.height != target.height else { return image }
        return try redraw(image, into: target, transform: .identity, drawnAt: PixelSize(
            width: target.width, height: target.height
        ))
    }

    // MARK: - Orientation

    /// Rotates/flips the pixels so the image is upright without a tag.
    private static func baking(
        _ orientation: CGImagePropertyOrientation,
        into image: CGImage
    ) throws -> CGImage {
        guard orientation != .up else { return image }
        let stored = PixelSize(width: image.width, height: image.height)
        let display = orientation.swapsAxes
            ? PixelSize(width: stored.height, height: stored.width)
            : stored
        return try redraw(
            image,
            into: display,
            transform: orientation.transform(forStoredSize: stored),
            drawnAt: stored
        )
    }

    /// One drawing primitive for both scaling and orientation.
    ///
    /// - Parameters:
    ///   - canvas: the size of the context to create, i.e. the result's size.
    ///   - transform: applied to the context before drawing.
    ///   - drawnAt: the rect the image is drawn into, in pre-transform
    ///     coordinates.
    private static func redraw(
        _ image: CGImage,
        into canvas: PixelSize,
        transform: CGAffineTransform,
        drawnAt: PixelSize
    ) throws -> CGImage {
        // An RGB context: the drawing path cannot preserve a CMYK or 16-bit
        // source's exact representation, so it converts once, here, rather than
        // in whatever the encoder happens to do. A grayscale or indexed source
        // also lands in RGB. That is a real (small) cost of resizing or baking,
        // and it is the reason both are skipped entirely when neither was asked
        // for: an unresized, tag-preserving encode never reaches this function.
        let sourceSpace = image.colorSpace
        let space = (sourceSpace?.model == .rgb ? sourceSpace : nil) ?? CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: canvas.width,
            height: canvas.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,            // let Core Graphics pick its own alignment
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw LatheError.encodingFailed(
                stage: "scale", code: nil, reason: "could not create a \(canvas) drawing context"
            )
        }
        context.interpolationQuality = .high
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: drawnAt.width, height: drawnAt.height))

        guard let result = context.makeImage() else {
            throw LatheError.encodingFailed(stage: "scale", code: nil, reason: "redraw produced no image")
        }
        return result
    }

    // MARK: - Write

    /// Encodes into a sibling temporary file and moves it into place.
    ///
    /// The move is the point. `CGImageDestinationFinalize` failing — or a
    /// cancellation, or a codec error — leaves a zero-length file behind at
    /// whatever URL the destination was created with, and a caller that checks
    /// only `fileExists` reads that as a success. Encoding beside the target and
    /// renaming means `destination` either holds the previous file or holds a
    /// complete new one, and never holds an empty one.
    ///
    /// A sibling rather than the system temporary directory, because `moveItem`
    /// across volumes is a copy, and the destination is where the caller already
    /// decided there is room.
    ///
    /// Internal rather than private because ``AnimatedImageWriter`` has the same
    /// destination to protect and the same half-written file to avoid leaving
    /// behind. Two encoders in one module each owning a copy of this dance is
    /// how one of them ends up without it.
    static func writingAtomically(
        to destination: URL,
        format: ImageFormat,
        _ body: (URL) throws -> Void
    ) throws -> UInt64 {
        let directory = destination.deletingLastPathComponent()
        let scratch = directory.appendingPathComponent(
            ".lathe-\(UUID().uuidString).\(format.preferredFilenameExtension)"
        )
        // Best effort: a caller may legitimately be writing into a directory that
        // does not exist yet, and failing on `create` rather than on `write`
        // makes for a worse message.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var cleanUp = true
        defer { if cleanUp { try? FileManager.default.removeItem(at: scratch) } }

        try body(scratch)

        let size = byteCount(of: scratch) ?? 0
        guard size > 0 else {
            throw LatheError.encodingFailed(
                stage: "encode", code: nil,
                reason: "\(format.description) finalised but produced no bytes"
            )
        }

        do {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: scratch)
        } catch {
            throw LatheError.writeFailed(
                path: destination.lastPathComponent,
                reason: (error as NSError).localizedDescription
            )
        }
        cleanUp = false
        return size
    }

    /// The ImageIO half of the encode. Writes into whatever URL it is handed —
    /// the temporary-file dance belongs to ``writingAtomically(to:format:_:)``.
    private static func writeViaImageIO(
        _ image: CGImage,
        to scratch: URL,
        typeIdentifier: String,
        format: ImageFormat,
        properties: [CFString: Any],
        progress: ProgressHandle
    ) throws {
        guard let sink = CGImageDestinationCreateWithURL(
            scratch as CFURL, typeIdentifier as CFString, 1, nil
        ) else {
            // The capability probe already said this format encodes, so reaching
            // here means the destination is at fault.
            throw LatheError.writeFailed(
                path: scratch.lastPathComponent,
                reason: "ImageIO would not open a \(format.description) destination in "
                    + "\(scratch.deletingLastPathComponent().lastPathComponent)"
            )
        }

        CGImageDestinationAddImage(sink, image, properties as CFDictionary)

        // Last cancellation checkpoint before the expensive part commits. After
        // `Finalize` there is a real file, and throwing it away would be work
        // done and discarded rather than work avoided.
        try progress.checkCancellation()

        guard CGImageDestinationFinalize(sink) else {
            // Name the one cause that is otherwise unguessable. Measured, not
            // assumed: ImageIO's AVIF encoder refuses a lossy quality of
            // *exactly* 1.0 — `Finalize` returns false and writes nothing —
            // while 0.999 encodes fine, and every other lossy format here
            // accepts 1.0. The likeliest reading is that 1.0 asks for lossless
            // AV1, which that encoder does not implement, and it fails rather
            // than degrading. Clamping silently would be worse: a caller who
            // asked for maximum quality should be told it was not available, not
            // handed a slightly different file and no mention of it.
            let quality = (properties[kCGImageDestinationLossyCompressionQuality] as? Double) ?? -1
            let hint = quality >= 1
                ? " — note that this encoder was asked for a lossy quality of exactly 1.0, "
                    + "which some ImageIO encoders (AVIF, observed) reject outright; "
                    + "0.99 is the practical maximum"
                : ""
            throw LatheError.encodingFailed(
                stage: "encode", code: nil,
                reason: "ImageIO could not finalise \(format.description)\(hint)"
            )
        }
    }

    // MARK: - Files

    static func requireReadableFile(at url: URL) throws {
        guard url.isFileURL else {
            // Deliberate: anything that ingests media from a network URL lives
            // outside this package. See the licence policy in the README.
            throw LatheError.invalidInput(reason: "ImageEncoder reads local files only")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw LatheError.readFailed(path: url.lastPathComponent, reason: "no such file")
        }
        guard !isDirectory.boolValue else {
            throw LatheError.readFailed(path: url.lastPathComponent, reason: "is a directory")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw LatheError.readFailed(path: url.lastPathComponent, reason: "not readable")
        }
    }

    static func byteCount(of url: URL) -> UInt64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0.map(UInt64.init) }
    }

    private static func storedPixelSize(
        from properties: [CFString: Any],
        source: URL
    ) throws -> PixelSize {
        // Width and height as *stored*: `CGImageSourceCopyPropertiesAtIndex`
        // reports the pixel dimensions before the orientation tag is applied,
        // which is the same convention `CGImageSourceCreateImageAtIndex` decodes
        // in. Mixing the two conventions is the portrait-photo bug.
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let size = PixelSize(width: width, height: height)
        guard !size.isEmpty else {
            throw LatheError.invalidInput(
                reason: "\(source.lastPathComponent) reports no pixel dimensions"
            )
        }
        return size
    }

    private static func orientation(from properties: [CFString: Any]) -> CGImagePropertyOrientation {
        guard let raw = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value,
              let orientation = CGImagePropertyOrientation(rawValue: raw)
        else { return .up }
        return orientation
    }
}

// MARK: - Orientation arithmetic

extension CGImagePropertyOrientation {

    /// Whether displaying this orientation transposes the image's axes.
    var swapsAxes: Bool {
        switch self {
        case .up, .upMirrored, .down, .downMirrored: false
        case .left, .leftMirrored, .right, .rightMirrored: true
        @unknown default: false
        }
    }

    /// The transform that maps stored pixels onto display pixels, for a Core
    /// Graphics context whose origin is bottom-left and whose size is the
    /// *display* size.
    ///
    /// Derived rather than copied, and worth stating how, because every one of
    /// these eight is a plausible-looking place for a sign error that only shows
    /// up on somebody's holiday photos:
    ///
    /// `CGContext.draw(_:in:)` puts the image's first row along the *top* of the
    /// rect, so stored pixel (column `c`, row `r`) sits at `(c, sH - r)` in the
    /// pre-transform space. Each EXIF orientation states where the 0th row and
    /// 0th column belong, which fixes the display coordinate of that same pixel;
    /// the transform below is the affine map between the two. The four mirrored
    /// cases have determinant −1, which is the arithmetic signature of a
    /// reflection and a quick way to check the table has not been scrambled.
    func transform(forStoredSize stored: PixelSize) -> CGAffineTransform {
        let w = CGFloat(stored.width), h = CGFloat(stored.height)
        switch self {
        case .up:            return .identity
        case .upMirrored:    return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case .down:          return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case .downMirrored:  return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case .leftMirrored:  return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case .right:         return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case .rightMirrored: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .left:          return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        @unknown default:    return .identity
        }
    }
}

// MARK: - Formats and orientation

/// Whether this system's ImageIO actually round-trips an orientation tag
/// through a given format.
///
/// A hard-coded table was the first answer here and it was wrong within a day:
/// PNG has no EXIF block in the classic sense and "obviously" cannot carry an
/// orientation, and current ImageIO writes one into the `eXIf` chunk and reads
/// it straight back. Which is the same lesson ``EncodeSupport`` is built around
/// — **ask the system, never the calendar** — so this asks the same way, by
/// attempting the exact thing it is asking about: write a tiny image with
/// orientation 6 into a scratch buffer, read the buffer back, and see whether
/// the 6 survived. Once per process, cached.
///
/// The answer is deliberately consumed asymmetrically by ``ImageEncoder``. A
/// format wrongly reported as *unable* costs one unnecessary pixel rotation,
/// which is invisible in the output. A format wrongly reported as *able* drops
/// the tag on the floor and lands the picture on its side. So anything the probe
/// cannot demonstrate is treated as unable.
enum OrientationTagSupport {

    /// The orientation used for the probe. Any non-`up` value would do; 6 is the
    /// one a phone writes for a portrait photo, which makes a failure here the
    /// same failure a user would hit.
    private static let probeValue: UInt32 = CGImagePropertyOrientation.right.rawValue

    static func isPreserved(by format: ImageFormat) -> Bool {
        cached.contains(format)
    }

    private static let cached: Set<ImageFormat> = {
        let support = EncodeSupport.shared
        var preserved: Set<ImageFormat> = []
        guard let image = probeImage() else { return preserved }

        // Every encodable format, through the backend that would really write
        // it. The ImageIO ones round-trip through a `CGImageDestination`; the
        // built-in ones through their own encoder — which for WebP means the
        // muxer's EXIF chunk. Either way the read-back is ImageIO's, because
        // that is what a viewer of the file will use.
        for format in support.supportedFormats {
            guard let written = probeBytes(format, image: image, support: support),
                  let source = CGImageSourceCreateWithData(written as CFData, nil),
                  CGImageSourceGetCount(source) > 0
            else { continue }

            let properties = ImageMetadata.sourceProperties(of: source)
            if (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value == probeValue {
                preserved.insert(format)
            }
        }

        LatheLog.capability.info(
            """
            orientation-tag probe: \(preserved.count, privacy: .public) of \
            \(support.supportedFormats.count, privacy: .public) encodable formats keep the tag \
            (\(preserved.map(\.description).sorted().joined(separator: ", "), privacy: .public))
            """
        )
        return preserved
    }()

    /// `image` written as `format` with the probe orientation, or `nil`.
    private static func probeBytes(
        _ format: ImageFormat,
        image: CGImage,
        support: EncodeSupport
    ) -> Data? {
        let tagged: [CFString: Any] = [kCGImagePropertyOrientation: probeValue]
        switch support.backend(for: format) {
        case .imageIO:
            guard let uti = support.destinationTypeIdentifier(for: format) else { return nil }
            let buffer = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                buffer as CFMutableData, uti as CFString, 1, nil
            ) else { return nil }
            CGImageDestinationAddImage(destination, image, tagged as CFDictionary)
            guard CGImageDestinationFinalize(destination), buffer.length > 0 else { return nil }
            return buffer as Data

        case .builtIn where format == .webp:
            let size = PixelSize(width: image.width, height: image.height)
            guard let chunks = try? WebPMetadataChunks.carrying(tagged, pixelSize: size) else {
                return nil
            }
            return try? WebPEncoder.encode(image, quality: .lossless, metadata: chunks)

        case .builtIn, nil:
            return nil
        }
    }

    /// 2x2 opaque RGBA. Small enough that no encoder objects, and large enough
    /// that none of them treats it as degenerate.
    private static func probeImage() -> CGImage? {
        let pixels: [UInt8] = [
            255, 0, 0, 255, 0, 255, 0, 255,
            0, 0, 255, 255, 255, 255, 0, 255,
        ]
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

extension ImageFormat {

    /// Whether the format has somewhere to put an EXIF orientation tag *on this
    /// system*. Runtime-probed; see ``OrientationTagSupport``.
    var canStoreOrientationTag: Bool {
        OrientationTagSupport.isPreserved(by: self)
    }
}
