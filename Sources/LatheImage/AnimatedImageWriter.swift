import CoreGraphics
import Foundation
import ImageIO
import LatheCore

/// How long each frame is on screen.
///
/// Three spellings of one thing, because callers arrive holding three different
/// numbers: a fixed delay (the GIF idiom), a frame rate (what a video-derived
/// run has), or the delays read off an animation being rebuilt
/// (``ImageFrameInfo/frameDelays``, which exists so the round trip does not go
/// through an average).
public enum FrameDelays: Sendable, Equatable {

    /// The same delay for every frame, in seconds.
    case uniform(seconds: TimeInterval)

    /// Frames per second, converted to a uniform delay.
    ///
    /// Convenience rather than a different mechanism — an animated image has no
    /// frame rate, only delays, and pretending otherwise is how a 23.976 fps
    /// source becomes a 24 fps GIF that drifts.
    case framesPerSecond(Double)

    /// One delay per frame, in order. Must be exactly as long as the sequence.
    case perFrame([TimeInterval])

    /// The delays for `count` frames, clamped, or a refusal.
    ///
    /// ## Zero is clamped here; a zero frame rate is refused
    ///
    /// The two look like the same mistake and are not:
    ///
    /// - **A zero delay is a real idiom.** GIFs in the wild routinely store 0 or
    ///   1 hundredths meaning "as fast as you can", and every renderer clamps it
    ///   rather than refusing the file. Writing that literal zero would produce
    ///   an animation whose duration reads back as
    ///   ``ImageInspector/zeroDelayReplacement`` per frame anyway — so the clamp
    ///   is applied at write time instead, which is what makes a write followed
    ///   by an ``ImageInspector/inspect(_:)`` agree about the duration rather
    ///   than differ by a factor of ten.
    /// - **A zero frame rate is not an idiom, it is a division by zero.** There
    ///   is no delay it could mean, so it is refused by name.
    ///
    /// A negative delay is refused in both spellings: it is not a fast frame, it
    /// is a wrong number.
    func resolve(frameCount: Int) throws -> [TimeInterval] {
        let raw: [TimeInterval]
        switch self {
        case let .uniform(seconds):
            guard seconds >= 0 else {
                throw LatheError.invalidConfiguration(
                    reason: "a frame delay cannot be negative, got \(seconds)s"
                )
            }
            raw = Array(repeating: seconds, count: frameCount)

        case let .framesPerSecond(rate):
            guard rate > 0, rate.isFinite else {
                throw LatheError.invalidConfiguration(
                    reason: "the frame rate must be positive and finite, got \(rate)"
                )
            }
            raw = Array(repeating: 1 / rate, count: frameCount)

        case let .perFrame(delays):
            guard delays.count == frameCount else {
                throw LatheError.invalidConfiguration(
                    reason: "\(delays.count) delays were given for \(frameCount) frames; "
                        + "FrameDelays.perFrame needs exactly one each"
                )
            }
            if let bad = delays.first(where: { $0 < 0 || !$0.isFinite }) {
                throw LatheError.invalidConfiguration(
                    reason: "a frame delay cannot be negative or infinite, got \(bad)s"
                )
            }
            raw = delays
        }

        return raw.map { $0 <= ImageInspector.zeroDelayThreshold
            ? ImageInspector.zeroDelayReplacement
            : $0
        }
    }
}

/// What an animation write actually produced.
///
/// The frame count and duration are what was **written**, not what was asked
/// for: the delays here are post-clamp, so a caller that asked for a zero delay
/// reads back the hundred milliseconds the file really carries.
public struct AnimatedImageResult: Sendable, Equatable {
    public var output: URL
    public var format: ImageFormat
    public var frameCount: Int
    /// One pass, in seconds — the sum of the written delays. The same meaning
    /// ``ImageFrameInfo/duration`` has, so the two are comparable.
    public var duration: TimeInterval
    /// As written. **`0` means forever**, the container convention, carried
    /// through rather than translated.
    public var loopCount: Int
    /// The canvas every frame was composed onto.
    public var pixelSize: PixelSize
    public var outputByteCount: UInt64
    public var wallTime: TimeInterval

    public init(
        output: URL,
        format: ImageFormat,
        frameCount: Int,
        duration: TimeInterval,
        loopCount: Int,
        pixelSize: PixelSize,
        outputByteCount: UInt64,
        wallTime: TimeInterval
    ) {
        self.output = output
        self.format = format
        self.frameCount = frameCount
        self.duration = duration
        self.loopCount = loopCount
        self.pixelSize = pixelSize
        self.outputByteCount = outputByteCount
        self.wallTime = wallTime
    }
}

/// Assembles a run of stills into one animated image: GIF, APNG, animated WebP,
/// or an animated HEIC sequence.
///
/// The reverse of ``FrameExtractor``'s `frames(from:into:)`, and deliberately
/// the same vocabulary at the seam — a directory of zero-padded stills goes in
/// through ``FrameSequence/contentsOfDirectory(_:)`` and comes back out as one
/// file.
///
/// ```swift
/// let frames = try FrameSequence.contentsOfDirectory(stills)
/// try AnimatedImageWriter().write(
///     frames, to: output, format: .gif, delays: .framesPerSecond(12)
/// )
/// ```
///
/// ## Which formats, and why the list is not a list
///
/// Two questions are asked before anything is created, and they are different
/// questions:
///
/// 1. **Does the format have somewhere to put per-frame timing?**
///    ``AnimationContainer`` answers that, and it is a property of the format
///    rather than of this machine. AVIF is the interesting refusal — it is
///    ``ImageFormat/isAnimatable`` and ImageIO exposes no timing dictionary for
///    it, so a "success" here would be a burst, not an animation.
/// 2. **Can this system encode it — as an animation?**
///    ``EncodeSupport/canEncodeAnimated(_:)`` answers that, by attempting a
///    destination rather than by consulting a version number. The package's
///    standing rule: never branch on an OS release.
///
/// The practical answer today is GIF, APNG, WebP and HEICS everywhere, but
/// nothing here writes that down — a system that gains or loses one is handled
/// by the probe, on the day.
///
/// ## Two backends, one contract
///
/// GIF, APNG and HEICS are written by `CGImageDestination`. **WebP is written
/// by the vendored libwebp's `WebPAnimEncoder`** (see ``WebPAnimationEncoder``),
/// because ImageIO reads animated WebP and writes no WebP at all. Which one runs
/// is ``EncodeSupport/backend(for:)``, exactly as for a still, and the caller
/// cannot tell: the same delays, the same clamp, the same loop convention, the
/// same canvas composition, the same atomic write, the same progress stages.
///
/// What differs is stated rather than hidden:
///
/// - **WebP honours ``QualityTarget/lossless``**, and `.quality(_:)` means a
///   lossy WebP at that quality — the same mapping ``ImageEncoder`` uses for a
///   WebP still. GIF and APNG have no quality to set.
/// - **WebP merges consecutive identical frames** into one longer frame, so
///   ``AnimatedImageResult/frameCount`` can be smaller than the input. The
///   result reports the file, not the request; the duration is unchanged.
/// - **WebP's limits are its own**: a loop count above 65535 and a single delay
///   above about 4.6 hours are refused, because the container has 16 and 24 bits
///   for them.
public struct AnimatedImageWriter: Sendable {

    public init() {}

    /// Writes `frames` as one animated image.
    ///
    /// Atomic: the work goes to a sibling scratch file that replaces
    /// `destination` only once it is complete, so a failure part way leaves
    /// whatever was there before intact rather than a truncated animation.
    ///
    /// - Parameters:
    ///   - frames: the stills, in order. Empty is refused; see
    ///     ``FrameSequence/requireFrames(forWriting:)``.
    ///   - destination: where to write. The **`format` argument decides the
    ///     format**, not this extension — but a mismatch between them is refused
    ///     rather than written, because a `.gif` that is really an APNG is a file
    ///     that opens nowhere its name suggests it should.
    ///   - format: `.gif`, `.png` (APNG), `.webp` or `.heics`, subject to the
    ///     two checks above.
    ///   - delays: see ``FrameDelays``, including what happens to a zero.
    ///   - loopCount: `0` — the default — means loop forever, which is the
    ///     container convention and what almost every animation wants. Negative
    ///     is refused.
    ///   - canvas: what to do about frames that are not all the same size. See
    ///     ``FrameCanvas``.
    ///   - quality: honoured by HEICS, and by WebP — which also honours
    ///     ``QualityTarget/lossless``. GIF and APNG ignore it.
    ///   - progress: reported per frame under the stage name `"frames"`, and a
    ///     cancellation checkpoint at each one.
    ///
    /// - Throws: ``LatheError/invalidInput(reason:)`` for an empty sequence or an
    ///   unreadable frame; ``LatheError/invalidConfiguration(reason:)`` for a
    ///   format with nowhere to put timing, a mismatched extension, a bad
    ///   delay, or a loop count the container cannot store;
    ///   ``LatheError/encodeUnavailable(format:)`` when this system cannot write
    ///   the format; ``LatheError/encodingFailed(stage:code:reason:)`` when the
    ///   encoder itself fails; ``LatheError/cancelled(atUnit:)`` when progress
    ///   says stop.
    @discardableResult
    public func write(
        _ frames: FrameSequence,
        to destination: URL,
        format: ImageFormat,
        delays: FrameDelays = .uniform(seconds: 0.1),
        loopCount: Int = 0,
        canvas: FrameCanvas = .fitFirstFrame,
        quality: QualityTarget = .quality(0.8),
        progress: ProgressHandle = .ignoring()
    ) throws -> AnimatedImageResult {
        let started = Date()
        let urls = try frames.requireFrames(forWriting: "an animation")

        // MARK: Refuse before creating anything.
        //
        // Capability first, in the order the two questions actually differ:
        // "this format cannot be animated" is a fact about the format and is the
        // same answer on every machine, so it comes before the probe rather than
        // being folded into it.
        guard let container = AnimationContainer.holding(format) else {
            throw LatheError.invalidConfiguration(
                reason: "\(format.description) has no per-frame timing to write; an animation "
                    + "needs GIF, APNG (png), WebP or HEICS"
            )
        }
        // Encodability first: a format this system cannot write at all fails as
        // `encodeUnavailable`, which tells the caller to pick another format.
        try EncodeSupport.shared.requireEncodable(format)
        guard EncodeSupport.shared.canEncodeAnimated(format),
              let backend = EncodeSupport.shared.backend(for: format) else {
            // Encodable, with a timing dictionary, and still not animatable:
            // a built-in still encoder with no animation encoder beside it.
            // Nothing reaches this today; the message says what is missing
            // rather than blaming the OS.
            throw LatheError.unsupportedOnThisPlatform(
                feature: "writing an animated \(format.description) (this package encodes it "
                    + "one frame at a time only)"
            )
        }
        guard loopCount >= 0 else {
            throw LatheError.invalidConfiguration(
                reason: "a loop count cannot be negative, got \(loopCount); 0 means forever"
            )
        }

        // The extension is checked rather than corrected. Writing APNG bytes to
        // a file called `.gif` succeeds at every layer here and fails in the
        // caller's viewer, which is the worst place to find out.
        if let named = ImageFormat.named(byFilenameExtension: destination.pathExtension),
           named != format {
            throw LatheError.invalidConfiguration(
                reason: "\(destination.lastPathComponent) is named a \(named.description) but "
                    + "\(format.description) was asked for; an animation whose extension lies "
                    + "opens nowhere"
            )
        }

        let resolvedDelays = try delays.resolve(frameCount: urls.count)
        let size = try FrameReader.resolveCanvas(canvas, for: urls)
        guard !size.isEmpty else {
            throw LatheError.invalidConfiguration(reason: "the canvas resolved to \(size)")
        }

        // MARK: Write.
        let written: (bytes: UInt64, frameCount: Int, duration: TimeInterval)
        switch backend {
        case .imageIO:
            guard let typeIdentifier = EncodeSupport.shared.destinationTypeIdentifier(for: format) else {
                throw LatheError.encodeUnavailable(format: format.description)
            }
            let bytes = try writeViaImageIO(
                urls, to: destination, format: format, typeIdentifier: typeIdentifier,
                container: container, delays: resolvedDelays, loopCount: loopCount,
                canvas: size, quality: quality, progress: progress
            )
            written = (bytes, urls.count, resolvedDelays.reduce(0, +))

        case .builtIn:
            // Only WebP reaches here. See the type's documentation.
            var output: WebPAnimationEncoder.Output?
            let bytes = try ImageEncoder.writingAtomically(to: destination, format: format) { scratch in
                let encoded = try WebPAnimationEncoder.encode(
                    canvas: size, delays: resolvedDelays, loopCount: loopCount, quality: quality,
                    frame: { index in
                        try progress.checkCancellation()
                        return try FrameReader.compose(try FrameReader.decode(urls[index]), onto: size)
                    },
                    didAdd: { index in
                        try Self.reportFrame(index, of: urls.count, to: progress)
                    }
                )
                try encoded.data.write(to: scratch, options: .atomic)
                output = encoded
            }
            guard let output else {
                throw LatheError.encodingFailed(
                    stage: "encode", code: nil, reason: "the WebP animation produced no output"
                )
            }
            // The file's own frame count and duration: merging can make the
            // first smaller than the request, and millisecond rounding can move
            // the second by a hair. A one-frame result is a still and reports
            // the requested delay, as the ImageIO path does.
            written = (bytes, output.frameCount,
                       output.frameCount > 1 ? output.duration : resolvedDelays.reduce(0, +))
        }

        return AnimatedImageResult(
            output: destination,
            format: format,
            frameCount: written.frameCount,
            duration: written.duration,
            loopCount: loopCount,
            pixelSize: size,
            outputByteCount: written.bytes,
            wallTime: Date().timeIntervalSince(started)
        )
    }

    /// The ImageIO backend: GIF, APNG and HEICS.
    private func writeViaImageIO(
        _ urls: [URL],
        to destination: URL,
        format: ImageFormat,
        typeIdentifier: String,
        container: AnimationContainer,
        delays: [TimeInterval],
        loopCount: Int,
        canvas size: PixelSize,
        quality: QualityTarget,
        progress: ProgressHandle
    ) throws -> UInt64 {
        try ImageEncoder.writingAtomically(to: destination, format: format) { scratch in
            guard let sink = CGImageDestinationCreateWithURL(
                scratch as CFURL, typeIdentifier as CFString, urls.count, nil
            ) else {
                // The probe said this format encodes, so the destination is at
                // fault — a directory that is not writable.
                throw LatheError.writeFailed(
                    path: destination.lastPathComponent,
                    reason: "ImageIO would not open a \(format.description) destination there"
                )
            }

            // The loop count is a **file** property, not a frame property, and
            // setting it per frame — which ImageIO accepts without complaint —
            // produces an animation that plays exactly once.
            CGImageDestinationSetProperties(sink, [
                container.dictionaryKey: [container.loopKey: loopCount] as CFDictionary,
            ] as CFDictionary)

            for (index, url) in urls.enumerated() {
                try progress.checkCancellation()

                let image = try FrameReader.compose(try FrameReader.decode(url), onto: size)

                var frameProperties: [CFString: Any] = [
                    container.dictionaryKey: [
                        container.delayKey: delays[index],
                    ] as CFDictionary,
                ]
                if format.isLossyByDefault, let normalised = quality.normalisedQuality {
                    frameProperties[kCGImageDestinationLossyCompressionQuality] = normalised
                }
                CGImageDestinationAddImage(sink, image, frameProperties as CFDictionary)

                try Self.reportFrame(index, of: urls.count, to: progress)
            }

            guard CGImageDestinationFinalize(sink) else {
                throw LatheError.encodingFailed(
                    stage: "encode", code: nil,
                    reason: "ImageIO could not finalise a \(urls.count)-frame \(format.description)"
                )
            }
        }
    }

    /// One `"frames"` tick, and a cancellation checkpoint.
    private static func reportFrame(_ index: Int, of count: Int, to progress: ProgressHandle) throws {
        guard progress.report(LatheProgress(
            fraction: Double(index + 1) / Double(count),
            stage: "frames",
            unitIndex: UInt64(index + 1),
            unitCount: UInt64(count))) else {
            throw LatheError.cancelled(atUnit: UInt64(index + 1))
        }
    }

    /// The same write, off the cooperative pool and with `Task` cancellation
    /// wired in.
    ///
    /// The synchronous form above is the one to call from inside a batch that is
    /// already running on ``LatheWork``'s queue; this is the one to call from an
    /// app. The same split ``ImageEncoder`` makes, for the same reason.
    @discardableResult
    public func write(
        _ frames: FrameSequence,
        to destination: URL,
        format: ImageFormat,
        delays: FrameDelays = .uniform(seconds: 0.1),
        loopCount: Int = 0,
        canvas: FrameCanvas = .fitFirstFrame,
        quality: QualityTarget = .quality(0.8),
        reporting sink: (any ProgressSink)?
    ) async throws -> AnimatedImageResult {
        try await LatheWork.run(reporting: sink) { progress in
            try self.write(
                frames, to: destination, format: format, delays: delays,
                loopCount: loopCount, canvas: canvas, quality: quality, progress: progress
            )
        }
    }
}
