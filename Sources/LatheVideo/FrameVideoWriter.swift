import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import LatheCore
import LatheImage

/// What a frames-to-video write actually produced.
///
/// Every number here is what went into the file, not what was asked for: the
/// size is after the even-dimension adjustment codecs impose, and the duration
/// is `frameCount` frame durations rather than a figure the caller supplied.
public struct FrameVideoResult: Sendable, Equatable {
    public var output: URL
    public var codec: VideoCodec

    /// The coded size actually encoded — the canvas after rounding to even
    /// dimensions. See ``FrameVideoWriter`` on why it is rounded.
    public var pixelSize: PixelSize

    /// Frames appended to the encoder, which for this writer is every frame in
    /// the sequence.
    public var frameCount: Int

    /// Frames per second as written.
    public var frameRate: Double

    /// Output duration in seconds, as the written container reports it — read
    /// back rather than computed, so a container that rounded the last frame's
    /// duration says so.
    public var duration: TimeInterval

    public var outputByteCount: UInt64
    public var wallTime: TimeInterval

    public init(
        output: URL,
        codec: VideoCodec,
        pixelSize: PixelSize,
        frameCount: Int,
        frameRate: Double,
        duration: TimeInterval,
        outputByteCount: UInt64,
        wallTime: TimeInterval
    ) {
        self.output = output
        self.codec = codec
        self.pixelSize = pixelSize
        self.frameCount = frameCount
        self.frameRate = frameRate
        self.duration = duration
        self.outputByteCount = outputByteCount
        self.wallTime = wallTime
    }
}

/// Assembles a run of stills into a video file.
///
/// The reverse of ``FrameExtractor``, and the reverse of ``VideoTranscoder`` in
/// the sense that matters here: there is no source asset, so there is no track
/// to copy a transform from, no audio to pass through, no chapter track to
/// carry, and no metadata to preserve. What is left is one video track built out
/// of pictures.
///
/// ```swift
/// let frames = try FrameSequence.contentsOfDirectory(stills)
/// try await FrameVideoWriter().write(frames, to: output, codec: .h264, frameRate: 24)
/// ```
///
/// ## Why `AVAssetWriterInputPixelBufferAdaptor` and not `VideoToolbox`
///
/// ``VideoTranscoder`` drives a `VTCompressionSession` by hand, because it has a
/// decoder on the other side and needs the encoded sample buffers in order to
/// mux them without re-encoding. None of that applies to a pile of PNGs: there
/// is one direction, one track, and nothing to preserve across it. The adaptor
/// is the right level — it owns a `CVPixelBufferPool` sized and formatted for
/// the encoder, which is exactly the allocation this loop would otherwise get
/// subtly wrong.
///
/// The codec vocabulary is still ``VideoCodec``, shared with the transcoder
/// rather than reinvented, so "which codecs does Lathe write" has one answer.
/// The compression knobs reach VideoToolbox as raw-string property names inside
/// `AVVideoCompressionPropertiesKey` — see ``VTKey`` for why they are spelled as
/// strings, which is the same reason here as there.
///
/// ## Even dimensions
///
/// H.264 and HEVC encode in macroblocks and refuse — or silently pad — an odd
/// width or height. The canvas is therefore rounded **down** to even in both
/// axes, by the same ``VideoTranscoder/evenDimensions(_:)`` the transcoder uses.
/// Down rather than up, so no row of invented pixels is ever added; the result
/// is reported in ``FrameVideoResult/pixelSize``, so a caller that cares can see
/// the odd pixel go.
///
/// ## Nothing here is real time
///
/// `expectsMediaDataInRealTime` is `false` and the loop waits on
/// `isReadyForMoreMediaData` rather than dropping frames when it is not.
/// Frame-dropping is correct for a camera, where the next frame is coming
/// whether or not you are ready; it is data loss for a directory of stills,
/// which is not going anywhere.
public struct FrameVideoWriter: Sendable {

    /// How long to wait for the encoder to accept the next frame before
    /// deciding it is not going to.
    ///
    /// Generous on purpose: a large frame on a loaded machine can legitimately
    /// keep the input busy for a while, and turning a slow encode into a
    /// failure would be worse than the hang this replaces. It exists to put a
    /// ceiling on *never*, not to police *slow*.
    public var stallTimeout: Duration

    public init(stallTimeout: Duration = .seconds(30)) {
        self.stallTimeout = stallTimeout
    }

    /// Writes `frames` as a video.
    ///
    /// Atomic: the encode goes to a sibling scratch file that replaces
    /// `destination` only once `finishWriting` has reported success, so a
    /// failure part way leaves whatever was there before intact rather than a
    /// truncated movie.
    ///
    /// - Parameters:
    ///   - frames: the stills, in order. Empty is refused.
    ///   - destination: where to write. The extension picks the container —
    ///     `.mov`, `.mp4`, `.m4v` — through the same
    ///     ``VideoTranscoder/fileType(for:)`` the transcoder uses.
    ///   - codec: see ``VideoCodec``. ``VideoCodec/hevcWithAlpha`` is only
    ///     useful for frames that actually carry alpha, and in practice only
    ///     `.mov` will hold it.
    ///   - frameRate: frames per second. Must be positive and finite — a zero
    ///     frame rate is a division by zero rather than an idiom, and is refused
    ///     by name.
    ///   - canvas: what to do about frames that are not all the same size. See
    ///     ``FrameCanvas``. A video has one coded size, so something must be
    ///     decided.
    ///   - quality: ``QualityTarget/quality(_:)`` and
    ///     ``QualityTarget/constantQualityFactor(_:)`` are forwarded to
    ///     VideoToolbox, ``QualityTarget/averageBitrate(_:)`` to
    ///     `AVVideoAverageBitRateKey`. ``QualityTarget/lossless`` is **refused**:
    ///     it means "re-encode nothing", and there is nothing here that was ever
    ///     encoded to leave alone.
    ///   - progress: reported per frame under the stage name `"frames"`.
    ///
    /// - Throws: ``LatheError/invalidInput(reason:)`` for an empty sequence or an
    ///   unreadable frame; ``LatheError/invalidConfiguration(reason:)`` for a
    ///   frame rate, container or quality target that cannot be honoured;
    ///   ``LatheError/encodeUnavailable(format:)`` when the codec and container
    ///   cannot be combined here; ``LatheError/cancelled(atUnit:)`` when progress
    ///   says stop.
    @discardableResult
    public func write(
        _ frames: FrameSequence,
        to destination: URL,
        codec: VideoCodec = .h264,
        frameRate: Double = 30,
        canvas: FrameCanvas = .fitFirstFrame,
        quality: QualityTarget = .quality(0.7),
        progress: ProgressHandle = .ignoring()
    ) async throws -> FrameVideoResult {
        let started = Date()
        let urls = try frames.requireFrames(forWriting: "a video")

        guard frameRate > 0, frameRate.isFinite else {
            throw LatheError.invalidConfiguration(
                reason: "the frame rate must be positive and finite, got \(frameRate)"
            )
        }
        if case .lossless = quality {
            throw LatheError.invalidConfiguration(
                reason: "QualityTarget.lossless means \"re-encode nothing\", and a video built "
                    + "out of stills has no encoded video to leave alone. Name a quality or a "
                    + "bitrate instead."
            )
        }

        let fileType = try VideoTranscoder.fileType(for: destination)
        let size = VideoTranscoder.evenDimensions(try FrameReader.resolveCanvas(canvas, for: urls))
        guard !size.isEmpty else {
            throw LatheError.invalidConfiguration(reason: "the canvas resolved to \(size)")
        }

        // MARK: The writer.
        let scratch = destination.deletingLastPathComponent()
            .appendingPathComponent(".lathe-\(UUID().uuidString).\(destination.pathExtension)")
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var keepScratch = false
        defer { if !keepScratch { try? FileManager.default.removeItem(at: scratch) } }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: scratch, fileType: fileType)
        } catch {
            throw LatheError.writeFailed(
                path: destination.lastPathComponent,
                reason: (error as NSError).localizedDescription
            )
        }

        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: Self.outputSettings(
                codec: codec, size: size, quality: quality, frameRate: frameRate
            )
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw LatheError.encodeUnavailable(
                format: "\(codec.rawValue) in \(destination.pathExtension)"
            )
        }
        writer.add(input)

        // BGRA for every codec, not only the alpha one. The frames arrive as
        // `CGImage` and have to be drawn somewhere; drawing into a biplanar YCbCr
        // buffer means writing the colour conversion by hand, and getting a
        // Core Graphics context over a 32-bit interleaved buffer is the one
        // arrangement where the conversion is VideoToolbox's problem instead.
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height,
                // IOSurface-backed so the hardware encoder can take the buffer
                // without a trip through main memory.
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary,
            ]
        )

        guard writer.startWriting() else {
            throw LatheError.wrapping(writer.error ?? LatheError.encodingFailed(
                stage: "encode", code: nil, reason: "the writer refused to start"
            ))
        }
        writer.startSession(atSourceTime: .zero)

        // MARK: Timing.
        //
        // One frame duration, computed once and multiplied — rather than
        // `CMTime(seconds: Double(index) / rate, …)` per frame, which re-rounds
        // at every index and makes the spacing jitter by a tick. A large
        // timescale so a non-integral rate (23.976, 29.97) lands within a
        // microsecond of where it belongs.
        let frameDuration = CMTime(seconds: 1 / frameRate, preferredTimescale: 600_000)

        do {
            for (index, url) in urls.enumerated() {
                try progress.checkCancellation()

                // The encoder is behind. Yielding rather than spinning, and
                // the sleep is short enough not to become the bottleneck for a
                // fast codec on a small frame.
                //
                // Bounded, because "behind" and "never going to be ready" look
                // identical from here and only one of them ends. A machine
                // whose VideoToolbox cannot start a session — a virtualised
                // host with no GPU is the usual one — leaves this flag false
                // forever, and an unbounded loop then hangs the caller with no
                // error and nothing in a log. That is not hypothetical: it sat
                // in a CI job for six hours until the runner killed it, which
                // is indistinguishable from a queue that never cleared.
                let deadline = ContinuousClock.now + stallTimeout
                while !input.isReadyForMoreMediaData {
                    if ContinuousClock.now >= deadline {
                        throw LatheError.encodingFailed(
                            stage: "encode", code: nil,
                            reason: "the \(codec.rawValue) encoder never became ready for "
                                + "frame \(index + 1) of \(urls.count) within "
                                + "\(stallTimeout). On a machine with no usable video "
                                + "encoder this never clears."
                        )
                    }
                    try await Task.sleep(nanoseconds: 1_000_000)
                    try progress.checkCancellation()
                }

                guard let pool = adaptor.pixelBufferPool else {
                    throw LatheError.encodingFailed(
                        stage: "encode", code: nil,
                        reason: "the writer gave no pixel buffer pool for \(size) \(codec.rawValue)"
                    )
                }
                let buffer = try Self.buffer(
                    from: pool,
                    holding: try FrameReader.decode(url),
                    size: size,
                    transparentBackground: codec.needsAlpha
                )

                guard adaptor.append(
                    buffer, withPresentationTime: CMTimeMultiply(frameDuration, multiplier: Int32(index))
                ) else {
                    throw LatheError.wrapping(writer.error ?? LatheError.encodingFailed(
                        stage: "encode", code: nil,
                        reason: "frame \(index + 1) was refused by the encoder"
                    ))
                }

                guard progress.report(LatheProgress(
                    fraction: Double(index + 1) / Double(urls.count),
                    stage: "frames",
                    unitIndex: UInt64(index + 1),
                    unitCount: UInt64(urls.count))) else {
                    throw LatheError.cancelled(atUnit: UInt64(index + 1))
                }
            }
        } catch {
            // Tear the writer down before unwinding, or it keeps the scratch
            // file open and the `defer` above deletes a file AVFoundation is
            // still writing to.
            writer.cancelWriting()
            throw error
        }

        input.markAsFinished()
        // The session ends one frame duration after the last frame starts —
        // otherwise the final frame has zero duration and the file is one frame
        // short of the length it visibly is.
        writer.endSession(
            atSourceTime: CMTimeMultiply(frameDuration, multiplier: Int32(urls.count))
        )
        // Bounded for the same reason the ready-loop is. A wedged encoder does
        // not refuse to finish — it simply never calls back, and awaiting that
        // is another way to hang with nothing to show for it. The flush is
        // given longer than a single frame's wait because it is draining
        // everything still in the encoder.
        try await Self.finish(writer, within: stallTimeout * 4)

        guard writer.status == .completed else {
            throw LatheError.wrapping(writer.error ?? LatheError.encodingFailed(
                stage: "encode", code: nil,
                reason: "the writer finished in state \(writer.status.rawValue)"
            ))
        }

        // Measured from the file rather than computed from the loop: the
        // container is what a player will read, and a duration this writer
        // merely asserted would hide a muxer that disagreed.
        let duration = CMTimeGetSeconds(try await AVURLAsset(url: scratch).load(.duration))

        do {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: scratch)
        } catch {
            throw LatheError.writeFailed(
                path: destination.lastPathComponent,
                reason: (error as NSError).localizedDescription
            )
        }
        keepScratch = true

        return FrameVideoResult(
            output: destination,
            codec: codec,
            pixelSize: size,
            frameCount: urls.count,
            frameRate: frameRate,
            duration: duration,
            outputByteCount: (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .flatMap { $0.map(UInt64.init) } ?? 0,
            wallTime: Date().timeIntervalSince(started)
        )
    }

    // MARK: - Settings

    /// The writer input's output settings.
    ///
    /// The compression properties are named by raw string rather than by SDK
    /// constant for the reason ``VTKey`` documents: naming a
    /// `kVTCompressionPropertyKey_…` constant newer than the deployment floor
    /// forces an `#available`, and a version check is what this package refuses
    /// to make codec decisions with. AVFoundation forwards whatever it does not
    /// recognise to the underlying session, so an encoder that does not know a
    /// key ignores it — a fact about this machine rather than a guess from a
    /// calendar.
    static func outputSettings(
        codec: VideoCodec, size: PixelSize, quality: QualityTarget, frameRate: Double
    ) -> [String: Any] {
        var compression: [String: Any] = [
            // A hint the encoder uses for rate control and GOP placement. It is
            // not what sets the frame rate — the presentation timestamps are.
            VTKey.expectedFrameRate: frameRate,
        ]
        switch quality {
        case let .quality(value):
            compression[VTKey.quality] = min(max(value, 0), 1)
        case let .constantQualityFactor(value):
            compression[VTKey.constantQualityFactor] = min(max(value, 0), 1)
        case let .averageBitrate(bits):
            compression[AVVideoAverageBitRateKey] = bits
        case .lossless:
            break   // refused before reaching here
        }
        if codec.needsAlpha {
            // Without this the alpha plane is encoded but nothing records how it
            // relates to the colour, and a player composites a dark fringe
            // around every edge.
            compression[VTKey.alphaChannelMode] = "PremultipliedAlpha"
        }

        return [
            AVVideoCodecKey: codec.assetWriterCodec,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: compression,
        ]
    }

    // MARK: - Pixels

    /// One pooled pixel buffer with `image` drawn into it, letterboxed.
    ///
    /// The buffer is **cleared first, every time**. A pool recycles, so a buffer
    /// handed back here holds an earlier frame's pixels; a letterboxed frame
    /// that does not cover the whole canvas would otherwise show the margins of
    /// the frame from three frames ago, which looks like a decoder bug and is
    /// not one.
    private static func buffer(
        from pool: CVPixelBufferPool,
        holding image: CGImage,
        size: PixelSize,
        transparentBackground: Bool
    ) throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &created)
        guard status == kCVReturnSuccess, let buffer = created else {
            throw LatheError.encodingFailed(
                stage: "encode", code: status, reason: "no \(size) pixel buffer available"
            )
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: size.width,
            height: size.height,
            bitsPerComponent: 8,
            // The pool's own stride, not a computed one. A pooled buffer is
            // padded to the encoder's alignment and assuming `width * 4` writes
            // a sheared image on every size that is not already aligned.
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw LatheError.encodingFailed(
                stage: "encode", code: nil, reason: "no drawing context over a \(size) pixel buffer"
            )
        }

        let canvas = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        if transparentBackground {
            context.clear(canvas)
        } else {
            // Black rather than transparent for a codec with no alpha: the
            // margin is going to be *some* colour once alpha is discarded, and
            // black is the one that reads as letterboxing rather than as a bug.
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(canvas)
        }
        context.interpolationQuality = .high
        context.draw(image, in: FrameReader.fittedRect(
            for: PixelSize(width: image.width, height: image.height), in: size
        ))

        return buffer
    }

    /// Waits for the writer to flush, or gives up and says so.
    ///
    /// `finishWriting()` has no timeout of its own and no way to be cancelled,
    /// so the losing branch here abandons the wait rather than stopping it —
    /// the call is still out there, attached to a writer nothing will read
    /// again. That is the honest trade: a leaked continuation on a machine
    /// that was already never going to produce a file, against a caller hung
    /// forever on the same machine.
    private static func finish(_ writer: AVAssetWriter, within timeout: Duration) async throws {
        // `AVAssetWriter` is not Sendable, and the compiler is right to ask.
        // It is safe here for a reason specific to this call: the writer was
        // created inside `write`, has never been handed to anything else, and
        // by this point the only work left on it is the flush. The timeout
        // branch touches it not at all — it only reports that the flush did
        // not land — so there is exactly one task using the writer.
        nonisolated(unsafe) let flushing = writer
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await flushing.finishWriting()
                return true
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        guard finished else {
            throw LatheError.encodingFailed(
                stage: "encode", code: nil,
                reason: "the encoder did not finish writing within \(timeout). On a "
                    + "machine with no usable video encoder this never completes."
            )
        }
    }
}

extension VideoCodec {
    /// The `AVVideoCodecKey` value for this codec.
    ///
    /// Separate from ``VideoCodec/codecType``, which is the `CMVideoCodecType`
    /// a `VTCompressionSession` is created with. The two are different
    /// vocabularies for the same three codecs, and the transcoder needs the
    /// first while this writer needs the second.
    var assetWriterCodec: AVVideoCodecType {
        switch self {
        case .h264: .h264
        case .hevc: .hevc
        case .hevcWithAlpha: .hevcWithAlpha
        }
    }
}
