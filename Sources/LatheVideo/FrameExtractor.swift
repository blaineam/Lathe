import Accelerate
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import LatheCore
import LatheImage

/// How exactly a requested timestamp has to be honoured.
///
/// `AVAssetImageGenerator` takes two independent tolerances, before and after
/// the requested time, and the choice between them is a real trade rather than a
/// detail:
///
/// - **Zero tolerance** means the generator decodes forward from the preceding
///   keyframe to the exact requested frame. On a long GOP — 10 seconds is
///   ordinary for phone video — that is dozens of frames of decode for one
///   output image.
/// - **Infinite tolerance** means it returns the nearest keyframe and is close
///   to free, but the frame you get can be seconds away from the one you asked
///   for. For a thumbnail grid that is usually invisible. For anything that
///   compares two extractions — a perceptual hash, a regression test, a "has
///   this file changed" check — it is fatal, because the frame returned depends
///   on the encoder's keyframe placement rather than on the timestamp.
///
/// The default is ``precise`` for that reason: a wrong-but-fast frame is a
/// correctness bug in every use that compares results, and a caller who is
/// building a contact sheet and knows better can say so.
public enum FrameAccuracy: Sendable, Equatable {
    /// Exactly the requested time. Both tolerances zero.
    case precise
    /// The nearest keyframe, at whatever distance. Both tolerances infinite.
    case nearestKeyframe
    /// Within this many seconds either side.
    case within(seconds: Double)

    var tolerance: CMTime {
        switch self {
        case .precise: .zero
        case .nearestKeyframe: .positiveInfinity
        case let .within(seconds): CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        }
    }
}

/// Pulls single frames out of a video: one for a thumbnail on disk, one as raw
/// grayscale for a perceptual hash.
///
/// The two entry points look similar and are deliberately not the same call with
/// a flag. ``thumbnail(from:to:atSeconds:maxWidth:accuracy:quality:)`` produces a
/// *file* for a person to look at, so it preserves aspect ratio, applies the
/// track's rotation and encodes.
/// ``grayscaleFrame(from:atSeconds:size:accuracy:)`` produces *numbers* for an
/// algorithm, so it squashes to a square, discards colour and never touches the
/// disk.
public struct FrameExtractor: Sendable {

    public init() {}

    // MARK: - Thumbnail

    /// Extract one frame and write it as a still image.
    ///
    /// The output format is chosen from `destination`'s file extension and is
    /// checked against the runtime capability probe **before** anything is
    /// created, so an unwritable format fails as
    /// ``LatheError/encodeUnavailable(format:)`` rather than leaving a 0-byte
    /// file behind. That failure mode is the reason the check is here and not
    /// inside the encode: `CGImageDestinationCreateWithURL` returning `nil` is
    /// easy to ignore, and the file it does not create is easy to mistake for a
    /// successful empty thumbnail.
    ///
    /// - Parameters:
    ///   - source: the video to read.
    ///   - destination: where to write. The extension picks the format —
    ///     `.jpg`, `.png`, `.heic`, `.tiff`, and anything else
    ///     ``ImageFormat/named(byFilenameExtension:)`` recognises and this system
    ///     can encode.
    ///   - atSeconds: the timestamp to extract, clamped into the asset.
    ///   - maxWidth: the longest edge of the output, in pixels. Aspect ratio is
    ///     preserved and the image is **never enlarged** — a frame already
    ///     smaller than `maxWidth` is written at its own size.
    ///   - accuracy: see ``FrameAccuracy``.
    ///   - quality: used only for formats that are lossy by default.
    /// - Returns: the size actually written.
    @discardableResult
    public func thumbnail(
        from source: URL,
        to destination: URL,
        atSeconds seconds: Double,
        maxWidth: Int,
        accuracy: FrameAccuracy = .precise,
        quality: QualityTarget = .quality(0.8)
    ) async throws -> PixelSize {
        guard maxWidth > 0 else {
            throw LatheError.invalidConfiguration(reason: "maxWidth must be positive, got \(maxWidth)")
        }
        guard let format = ImageFormat.named(byFilenameExtension: destination.pathExtension) else {
            throw LatheError.invalidConfiguration(
                reason: "no image format is named by the extension "
                    + "\"\(destination.pathExtension)\"; use one of "
                    + ImageFormat.allCases.map(\.preferredFilenameExtension).joined(separator: ", ")
            )
        }
        // Runtime-probed, never version-gated. See `EncodeSupport`.
        try EncodeSupport.shared.requireEncodable(format)
        guard let typeIdentifier = EncodeSupport.shared.destinationTypeIdentifier(for: format) else {
            throw LatheError.encodeUnavailable(format: format.description)
        }

        let (generator, displaySize) = try await Self.makeGenerator(for: source, accuracy: accuracy)
        let target = ResizeTarget.longestSide(maxWidth).resolve(from: displaySize)

        // A hint, not a contract: the generator fits the frame inside this box
        // while decoding, which avoids materialising a full 4K CGImage to throw
        // most of it away. Its rounding is its own, so the result is still
        // redrawn below if it did not land exactly on `target`.
        generator.maximumSize = CGSize(width: target.width, height: target.height)

        let frame = try await Self.copyFrame(generator, atSeconds: seconds, from: source)
        let image = try Self.exactly(target, from: frame)

        try Self.write(image, to: destination, typeIdentifier: typeIdentifier,
                       format: format, quality: quality)
        return target
    }

    // MARK: - A sequence of frames

    /// How many frames to take, and where from.
    public enum FrameSelection: Sendable, Equatable {
        /// One frame every `seconds`, from the start.
        case everySeconds(Double)
        /// This many frames, spread evenly across the whole thing.
        case count(Int)
        /// Exactly these timestamps.
        case atSeconds([Double])
    }

    /// Extract several frames and write them as numbered stills.
    ///
    /// One generator for the whole run, rather than calling ``thumbnail(from:to:atSeconds:maxWidth:accuracy:quality:)``
    /// in a loop: building it means opening the asset and loading its tracks,
    /// which on a long file is most of the cost and is identical every time.
    ///
    /// Names are zero-padded to the width of the largest index. That is not
    /// cosmetic — everything that displays a folder of images sorts by name,
    /// and `frame-10` sorting between `frame-1` and `frame-2` is the usual way
    /// a contact sheet comes out shuffled.
    ///
    /// - Parameters:
    ///   - source: the video to read.
    ///   - directory: where the stills go. Created if it does not exist.
    ///   - selection: which frames. See ``FrameSelection``.
    ///   - format: the image format to write.
    ///   - basename: the stem of each filename.
    ///   - maxWidth: longest edge, in pixels. Never enlarges.
    ///   - progress: reported per frame, under the stage name `"frames"`.
    /// - Returns: the files written, in order.
    @discardableResult
    public func frames(
        from source: URL,
        into directory: URL,
        selection: FrameSelection,
        format: ImageFormat = .jpeg,
        basename: String = "frame",
        maxWidth: Int = 1920,
        accuracy: FrameAccuracy = .precise,
        quality: QualityTarget = .quality(0.8),
        progress: ProgressHandle = .ignoring()
    ) async throws -> [URL] {
        guard maxWidth > 0 else {
            throw LatheError.invalidConfiguration(
                reason: "maxWidth must be positive, got \(maxWidth)")
        }
        try EncodeSupport.shared.requireEncodable(format)
        guard let typeIdentifier = EncodeSupport.shared.destinationTypeIdentifier(for: format) else {
            throw LatheError.encodeUnavailable(format: format.description)
        }

        let asset = AVURLAsset(url: source)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard duration.isFinite, duration > 0 else {
            throw LatheError.invalidConfiguration(
                reason: "this file has no duration to take frames from")
        }

        let timestamps = try Self.timestamps(for: selection, duration: duration)
        guard !timestamps.isEmpty else {
            throw LatheError.invalidConfiguration(reason: "that selection asks for no frames")
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let (generator, displaySize) = try await Self.makeGenerator(for: source, accuracy: accuracy)
        let target = ResizeTarget.longestSide(maxWidth).resolve(from: displaySize)
        generator.maximumSize = CGSize(width: target.width, height: target.height)

        let width = String(timestamps.count).count
        var written: [URL] = []
        for (index, seconds) in timestamps.enumerated() {
            try progress.checkCancellation()

            let number = String(format: "%0\(width)d", index + 1)
            let url = directory
                .appendingPathComponent("\(basename)-\(number)")
                .appendingPathExtension(format.preferredFilenameExtension)

            let frame = try await Self.copyFrame(generator, atSeconds: seconds, from: source)
            let image = try Self.exactly(target, from: frame)
            try Self.write(image, to: url, typeIdentifier: typeIdentifier,
                           format: format, quality: quality)
            written.append(url)

            guard progress.report(LatheProgress(
                fraction: Double(index + 1) / Double(timestamps.count),
                stage: "frames",
                unitIndex: UInt64(index + 1),
                unitCount: UInt64(timestamps.count))) else {
                throw LatheError.cancelled(atUnit: UInt64(index + 1))
            }
        }
        return written
    }

    /// Turns a selection into timestamps, inside the asset.
    static func timestamps(for selection: FrameSelection, duration: Double) throws -> [Double] {
        switch selection {
        case .everySeconds(let interval):
            guard interval > 0 else {
                throw LatheError.invalidConfiguration(
                    reason: "the interval must be positive, got \(interval)")
            }
            var times: [Double] = []
            var t = 0.0
            while t < duration {
                times.append(t)
                t += interval
            }
            return times

        case .count(let count):
            guard count > 0 else {
                throw LatheError.invalidConfiguration(
                    reason: "the frame count must be positive, got \(count)")
            }
            guard count > 1 else { return [duration / 2] }
            // Spread across the middle of each slice rather than from zero to
            // the very end: the first and last frames of a video are very often
            // black, and a contact sheet that opens and closes on black is the
            // classic way this goes wrong.
            return (0..<count).map { index in
                duration * (Double(index) + 0.5) / Double(count)
            }

        case .atSeconds(let seconds):
            // Clamped rather than refused: a timestamp past the end is an
            // ordinary thing to ask for from a caller that guessed the
            // duration, and the last frame is the honest answer.
            return seconds.map { min(max(0, $0), max(0, duration - 0.001)) }
        }
    }

    // MARK: - Perceptual-hash input

    /// Extract one frame as `size × size` bytes of 8-bit grayscale.
    ///
    /// This is hash input, not an image: it returns `Data` and never writes a
    /// file, because a perceptual hash that round-trips through PNG is a
    /// perceptual hash of a PNG encoder.
    ///
    /// Three choices are deliberate:
    ///
    /// - **The frame is squashed, not cropped.** Aspect ratio is discarded so
    ///   that the same shot in 16:9 and 4:3 hashes similarly, which is what a
    ///   near-duplicate detector wants. A thumbnail wants the opposite; that is
    ///   the other method.
    /// - **vImage, not Core Image.** `CIContext` would work, and for a GPU
    ///   pipeline already holding a context it would be the better answer. Here
    ///   the call is one small frame at a time, where a context's setup
    ///   dominates; `vImage` has no such cost, stays on the CPU and gives
    ///   bit-identical output on every device, which matters when the result
    ///   becomes a hash stored in a database. It also makes the row-padding
    ///   question *visible*: `vImage_Buffer` carries `rowBytes` explicitly, so
    ///   the padding below is stripped on purpose rather than by luck.
    /// - **The frame is decoded at full resolution and scaled once.** Letting
    ///   the generator pre-scale would make the hash depend on its internal
    ///   choice of scaler, which is not part of any contract and could change.
    ///
    /// - Returns: exactly `size * size` bytes, row-major, one byte per pixel,
    ///   with **no row padding**. The count is checked before returning.
    public func grayscaleFrame(
        from source: URL,
        atSeconds seconds: Double,
        size: Int,
        accuracy: FrameAccuracy = .precise
    ) async throws -> Data {
        guard size > 0 else {
            throw LatheError.invalidConfiguration(reason: "size must be positive, got \(size)")
        }

        let (generator, _) = try await Self.makeGenerator(for: source, accuracy: accuracy)
        generator.maximumSize = .zero   // full resolution; see the note above

        let frame = try await Self.copyFrame(generator, atSeconds: seconds, from: source)
        let data = try Self.planar8(from: frame, side: size)

        // The invariant this method sells. A `vImage_Buffer` whose `rowBytes`
        // exceeds its `width` is the normal case, not the exception, so a
        // grayscale extractor that copies `rowBytes * height` bytes out looks
        // correct, passes a smoke test on a 64-pixel-wide frame, and returns
        // garbage on everything else.
        guard data.count == size * size else {
            throw LatheError.encodingFailed(
                stage: "grayscale",
                code: nil,
                reason: "expected \(size * size) bytes, produced \(data.count)"
            )
        }
        return data
    }

    // MARK: - Generator

    private static func makeGenerator(
        for source: URL,
        accuracy: FrameAccuracy
    ) async throws -> (AVAssetImageGenerator, PixelSize) {
        try MediaProbe.requireReadableFile(at: source)

        let asset = AVURLAsset(url: source)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw LatheError.invalidInput(
                reason: "\(source.lastPathComponent) is not a media file AVFoundation can open"
            )
        }
        guard let track = tracks.first else {
            throw LatheError.invalidInput(
                reason: "\(source.lastPathComponent) has no video track to extract a frame from"
            )
        }

        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let coded = PixelSize(width: Int(natural.width.rounded()),
                              height: Int(natural.height.rounded()))
        guard !coded.isEmpty else {
            throw LatheError.invalidInput(
                reason: "\(source.lastPathComponent)'s video track reports a zero size"
            )
        }

        let generator = AVAssetImageGenerator(asset: asset)
        // Without this, every portrait video comes out sideways — the rotation
        // lives in the track's display matrix, not in the pixels.
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = accuracy.tolerance
        generator.requestedTimeToleranceAfter = accuracy.tolerance

        return (generator, MediaProbe.applying(transform, to: coded))
    }

    private static func copyFrame(
        _ generator: AVAssetImageGenerator,
        atSeconds seconds: Double,
        from source: URL
    ) async throws -> CGImage {
        let requested = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        do {
            // The async form, so no thread blocks waiting on a decode.
            let (image, actual) = try await generator.image(at: requested)
            if abs(actual.seconds - requested.seconds) > 0.5 {
                LatheLog.video.debug(
                    """
                    frame for \(LatheLog.publicPath(source), privacy: .public) came back at \
                    \(actual.seconds, privacy: .public)s, \
                    \(requested.seconds, privacy: .public)s was asked for
                    """
                )
            }
            return image
        } catch {
            throw LatheError.encodingFailed(
                stage: "frame extraction",
                code: Int32((error as NSError).code),
                reason: "no frame at \(seconds)s in \(source.lastPathComponent): "
                    + (error as NSError).localizedDescription
            )
        }
    }

    // MARK: - Scaling and encoding

    /// Returns `image` at exactly `target`, redrawing only if it is not already
    /// that size.
    private static func exactly(_ target: PixelSize, from image: CGImage) throws -> CGImage {
        guard image.width != target.width || image.height != target.height else { return image }

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: target.width,
            height: target.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,           // let Core Graphics choose its own alignment
            space: colorSpace.model == .rgb ? colorSpace : CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw LatheError.encodingFailed(
                stage: "scale", code: nil,
                reason: "could not create a \(target) drawing context"
            )
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))

        guard let scaled = context.makeImage() else {
            throw LatheError.encodingFailed(stage: "scale", code: nil, reason: "redraw produced no image")
        }
        return scaled
    }

    private static func write(
        _ image: CGImage,
        to destination: URL,
        typeIdentifier: String,
        format: ImageFormat,
        quality: QualityTarget
    ) throws {
        guard let sink = CGImageDestinationCreateWithURL(
            destination as CFURL, typeIdentifier as CFString, 1, nil
        ) else {
            // The capability probe said this format encodes, so reaching here
            // means the *destination* is at fault — a directory that does not
            // exist, or one that cannot be written to.
            throw LatheError.writeFailed(
                path: destination.lastPathComponent,
                reason: "ImageIO would not open a \(format.description) destination there"
            )
        }

        var properties: [CFString: Any] = [:]
        if format.isLossyByDefault, let normalised = quality.normalisedQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = normalised
        }
        CGImageDestinationAddImage(sink, image, properties as CFDictionary)

        guard CGImageDestinationFinalize(sink) else {
            // Finalize failing leaves a zero-length file behind. Remove it: a
            // caller that checks only for the file's existence must not be told
            // this succeeded.
            try? FileManager.default.removeItem(at: destination)
            throw LatheError.encodingFailed(
                stage: "encode", code: nil,
                reason: "ImageIO could not finalise \(format.description)"
            )
        }
    }

    // MARK: - Grayscale

    /// Converts a `CGImage` to an unpadded `side × side` planar-8 buffer.
    private static func planar8(from image: CGImage, side: Int) throws -> Data {
        // 32-bit XRGB rather than premultiplied ARGB: the alpha channel is
        // ignored by the luminance matrix below, and skipping premultiplication
        // means a frame that does carry alpha is not darkened before it is
        // measured.
        guard var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue),
            renderingIntent: .defaultIntent
        ) else {
            throw LatheError.encodingFailed(
                stage: "grayscale", code: nil, reason: "could not describe an XRGB8888 format"
            )
        }

        var interleaved = vImage_Buffer()
        var status = vImageBuffer_InitWithCGImage(
            &interleaved, &format, nil, image, vImage_Flags(kvImageNoFlags)
        )
        guard status == kvImageNoError else {
            throw LatheError.encodingFailed(
                stage: "grayscale", code: Int32(status), reason: "could not read the frame's pixels"
            )
        }
        defer { free(interleaved.data) }

        // Full-resolution luminance first, then one scale. The other order would
        // scale four channels to throw three of them away.
        var luma = vImage_Buffer()
        status = vImageBuffer_Init(
            &luma, interleaved.height, interleaved.width, 8, vImage_Flags(kvImageNoFlags)
        )
        guard status == kvImageNoError else {
            throw LatheError.encodingFailed(
                stage: "grayscale", code: Int32(status), reason: "could not allocate a luma plane"
            )
        }
        defer { free(luma.data) }

        // Rec. 601 luma over a 4096 divisor: 0.299 R + 0.587 G + 0.114 B, with a
        // zero coefficient for the skipped first channel. 601 rather than 709
        // because this feeds a perceptual hash, where matching the luma most
        // other hash implementations use matters more than matching the video's
        // own colour primaries.
        let matrix: [Int16] = [0, 1225, 2404, 467]
        status = matrix.withUnsafeBufferPointer { coefficients in
            vImageMatrixMultiply_ARGB8888ToPlanar8(
                &interleaved, &luma, coefficients.baseAddress!, 4096, nil, 0,
                vImage_Flags(kvImageNoFlags)
            )
        }
        guard status == kvImageNoError else {
            throw LatheError.encodingFailed(
                stage: "grayscale", code: Int32(status), reason: "luminance conversion failed"
            )
        }

        // The destination's `rowBytes` is set to `side` exactly. vImage accepts
        // any `rowBytes >= width`, and asking for the unpadded value is what
        // makes the returned `Data` `side * side` bytes with nothing to strip —
        // rather than copying out a padded buffer and hoping the consumer knows
        // the stride.
        var output = Data(count: side * side)
        status = output.withUnsafeMutableBytes { raw -> vImage_Error in
            var destination = vImage_Buffer(
                data: raw.baseAddress,
                height: vImagePixelCount(side),
                width: vImagePixelCount(side),
                rowBytes: side
            )
            return vImageScale_Planar8(
                &luma, &destination, nil, vImage_Flags(kvImageHighQualityResampling)
            )
        }
        guard status == kvImageNoError else {
            throw LatheError.encodingFailed(
                stage: "grayscale", code: Int32(status), reason: "scale to \(side)x\(side) failed"
            )
        }
        return output
    }
}
