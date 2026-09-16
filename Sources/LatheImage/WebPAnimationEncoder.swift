import CoreGraphics
import Foundation
import LatheCore

import CWebP

/// Animated WebP, on top of the vendored libwebp's `WebPAnimEncoder`.
///
/// ImageIO reads animated WebP — frames, per-frame durations and loop count all
/// come back through `kCGImagePropertyWebPDictionary` — and writes none, so this
/// is the write half only. ``AnimatedImageWriter`` routes here; nothing else
/// should.
///
/// ## What `WebPAnimEncoder` does that a hand-rolled muxer would not
///
/// Every frame goes in as a full canvas. The encoder works out the rectangle
/// that actually changed since the previous frame, chooses blend and dispose
/// modes, inserts keyframes so a seek does not have to replay the whole file,
/// and writes each frame as the smallest of the candidates it tried. That is
/// the difference between an animated WebP that is smaller than the GIF and
/// one that is several times larger.
///
/// It also does two things a caller should know about:
///
/// - **Consecutive identical frames are merged** into one frame with the sum of
///   their durations. The animation plays identically; the file holds fewer
///   frames. ``Output/frameCount`` is therefore read back from the assembled
///   file rather than assumed from the input.
/// - **A single frame is written as a still**, with no `ANIM` chunk — the same
///   answer a one-frame GIF gets from ``ImageInspector``: not an animation.
///
/// ## The one byte this file changes after libwebp
///
/// `WebPAnimEncoder` can make a region transparent without storing a single
/// transparent pixel: it disposes the previous frame to the (transparent)
/// background and leaves the region out of the next frame's rectangle. That is
/// exactly what happens to the letterbox margin of a smaller frame following a
/// full-canvas one. libwebp's muxer then sets the `VP8X` *alpha* flag only if
/// some stored bitstream has alpha — so the file says "opaque", and ImageIO,
/// which believes the flag, decodes the margin as **opaque black**. The format
/// allows that reading (the background colour is only a hint), so neither side
/// is wrong, and the picture still is.
///
/// So when any input frame had a non-opaque pixel, the alpha flag is set on the
/// assembled file. That is what the flag is for — the frames do contain
/// transparency — and it is what makes ImageIO decode the margin as the
/// transparent margin every other format in ``AnimatedImageWriter`` produces.
/// `webpinfo` reports it as a warning ("alpha flag is set with no alpha data
/// present"), not an error; a test pins the decoded result.
enum WebPAnimationEncoder {

    /// What was assembled.
    struct Output {
        var data: Data
        /// Frames in the file, after any merging. See the type documentation.
        var frameCount: Int
        /// One pass, in seconds, as the file's millisecond durations sum.
        var duration: TimeInterval
    }

    /// The longest single-frame duration WebP can store: the `ANMF` duration
    /// field is 24 bits of milliseconds.
    static let maximumFrameDuration: TimeInterval = TimeInterval((1 << 24) - 1) / 1000

    /// The largest loop count WebP can store: the `ANIM` field is 16 bits.
    static let maximumLoopCount = Int(UInt16.max)

    /// Encodes `delays.count` frames, asking `frame` for each one in order.
    ///
    /// Frames are pulled one at a time, so only the current canvas and the
    /// encoder's own previous-frame state are in memory — not the whole run.
    ///
    /// - Parameters:
    ///   - canvas: every frame `frame` returns must be exactly this size.
    ///   - delays: seconds, already clamped by ``FrameDelays/resolve(frameCount:)``.
    ///   - loopCount: `0` is forever.
    ///   - quality: as for ``WebPEncoder/encode(_:quality:metadata:)`` —
    ///     ``QualityTarget/lossless`` selects the lossless coder for every frame.
    ///   - frame: returns frame `index`, composed onto `canvas`.
    ///   - didAdd: called after frame `index` is in the encoder. Throw from it to
    ///     cancel.
    static func encode(
        canvas: PixelSize,
        delays: [TimeInterval],
        loopCount: Int,
        quality: QualityTarget,
        frame: (Int) throws -> CGImage,
        didAdd: (Int) throws -> Void
    ) throws -> Output {
        try WebPEncoder.requireEncodableSize(width: canvas.width, height: canvas.height)
        guard (0...maximumLoopCount).contains(loopCount) else {
            throw LatheError.invalidConfiguration(
                reason: "WebP stores a loop count in 16 bits; \(loopCount) is outside "
                    + "0...\(maximumLoopCount) (0 means forever)"
            )
        }
        if let long = delays.first(where: { $0 > maximumFrameDuration }) {
            throw LatheError.invalidConfiguration(
                reason: "WebP stores a frame duration in 24 bits of milliseconds; "
                    + "\(long)s exceeds \(maximumFrameDuration)s"
            )
        }

        // Timestamps are rounded from the running sum, not summed from rounded
        // delays, so a 30 fps run (33.33… ms each) does not drift a frame late
        // every hundred frames.
        var timestamps: [Int] = [0]
        var elapsed: TimeInterval = 0
        for delay in delays {
            elapsed += delay
            timestamps.append(Int((elapsed * 1000).rounded()))
        }
        guard let end = timestamps.last, end <= Int(Int32.max) else {
            throw LatheError.invalidConfiguration(
                reason: "an animated WebP's timeline is limited to \(Int32.max) ms"
            )
        }

        var options = WebPAnimEncoderOptions()
        guard WebPAnimEncoderOptionsInit(&options) != 0 else {
            throw LatheError.encodingFailed(
                stage: "encode", code: nil,
                reason: "WebPAnimEncoderOptionsInit failed (ABI mismatch)"
            )
        }
        options.anim_params.loop_count = Int32(loopCount)
        // Transparent, not upstream's default white: the canvas composer
        // letterboxes onto transparent margins, and a player that honours the
        // background hint should show the same margins every other format does.
        options.anim_params.bgcolor = 0x0000_0000
        // One coder, the one asked for. `allow_mixed` would let the encoder pick
        // lossy for a frame of a `.lossless` request.
        options.allow_mixed = 0

        guard let encoder = WebPAnimEncoderNew(
            Int32(canvas.width), Int32(canvas.height), &options
        ) else {
            throw LatheError.encodingFailed(
                stage: "encode", code: nil,
                reason: "libwebp would not create a \(canvas) animation encoder"
            )
        }
        defer { WebPAnimEncoderDelete(encoder) }

        var config = try WebPEncoder.configuration(for: quality)
        var anyTransparency = false

        for index in delays.indices {
            let image = try frame(index)
            guard image.width == canvas.width, image.height == canvas.height else {
                throw LatheError.encodingFailed(
                    stage: "encode", code: nil,
                    reason: "frame \(index + 1) is \(image.width)x\(image.height), "
                        + "not the \(canvas) canvas"
                )
            }

            var picture = WebPPicture()
            guard WebPPictureInit(&picture) != 0 else {
                throw LatheError.encodingFailed(
                    stage: "encode", code: nil, reason: "WebPPictureInit failed (ABI mismatch)"
                )
            }
            defer { WebPPictureFree(&picture) }
            if try WebPEncoder.importPixels(of: image, into: &picture) {
                anyTransparency = true
            }

            guard WebPAnimEncoderAdd(encoder, &picture, Int32(timestamps[index]), &config) != 0 else {
                throw LatheError.encodingFailed(
                    stage: "encode", code: picture.error_code.rawValue.int32,
                    reason: "libwebp could not add frame \(index + 1): "
                        + errorMessage(of: encoder, picture: picture)
                )
            }
            try didAdd(index)
        }

        // The terminating call carries the end time, which is what gives the
        // last frame its duration.
        guard WebPAnimEncoderAdd(encoder, nil, Int32(end), nil) != 0 else {
            throw LatheError.encodingFailed(
                stage: "encode", code: nil,
                reason: "libwebp could not close the animation: "
                    + (WebPAnimEncoderGetError(encoder).map { String(cString: $0) } ?? "unknown")
            )
        }

        var assembled = WebPData()
        WebPDataInit(&assembled)
        defer { WebPDataClear(&assembled) }
        guard WebPAnimEncoderAssemble(encoder, &assembled) != 0,
              let bytes = assembled.bytes, assembled.size > 0 else {
            throw LatheError.encodingFailed(
                stage: "encode", code: nil,
                reason: "libwebp could not assemble a \(delays.count)-frame WebP: "
                    + (WebPAnimEncoderGetError(encoder).map { String(cString: $0) } ?? "unknown")
            )
        }
        var data = Data(bytes: bytes, count: assembled.size)
        if anyTransparency {
            setAlphaFlag(in: &data)
        }
        let written = try timing(of: data)
        return Output(data: data, frameCount: written.frameCount, duration: written.duration)
    }

    /// Frame count and one-pass duration, read back through the muxer.
    ///
    /// A still (the one-frame case) reports one frame and no duration.
    static func timing(of file: Data) throws -> (frameCount: Int, duration: TimeInterval) {
        try file.withUnsafeBytes { raw in
            var input = WebPData(
                bytes: raw.baseAddress?.assumingMemoryBound(to: UInt8.self), size: raw.count
            )
            guard let mux = WebPMuxCreate(&input, 0) else {
                throw LatheError.encodingFailed(
                    stage: "encode", code: nil,
                    reason: "libwebp's muxer could not read back the animation it assembled"
                )
            }
            defer { WebPMuxDelete(mux) }

            var count: Int32 = 0
            try WebPMux.check(WebPMuxNumChunks(mux, WEBP_CHUNK_ANMF, &count),
                              doing: "counting frames")
            guard count > 0 else { return (1, 0) }

            var milliseconds = 0
            for nth in 1...UInt32(count) {
                var info = WebPMuxFrameInfo()
                try WebPMux.check(WebPMuxGetFrame(mux, nth, &info), doing: "reading frame \(nth)")
                // The muxer synthesises a standalone bitstream for every frame
                // it hands out, whatever `copy_data` said, so it is always
                // ours to free.
                WebPDataClear(&info.bitstream)
                milliseconds += Int(info.duration)
            }
            return (Int(count), TimeInterval(milliseconds) / 1000)
        }
    }

    /// Sets the `VP8X` alpha flag, if the file is extended and it is not set.
    /// See the type documentation for why.
    static func setAlphaFlag(in file: inout Data) {
        // RIFF header (12) + chunk header (8): the flags byte is the first byte
        // of the VP8X payload. A simple file (the one-frame case) has no VP8X
        // and carries alpha in its own bitstream header already.
        let flags = file.startIndex + 20
        guard file.count > 20,
              file[(file.startIndex + 12)..<(file.startIndex + 16)].elementsEqual("VP8X".utf8)
        else { return }
        file[flags] |= alphaFlag
    }

    /// `ALPHA_FLAG` in `mux_types.h`.
    private static let alphaFlag = UInt8(ALPHA_FLAG.rawValue)

    private static func errorMessage(of encoder: OpaquePointer, picture: WebPPicture) -> String {
        if let message = WebPAnimEncoderGetError(encoder) {
            let text = String(cString: message)
            if !text.isEmpty { return text }
        }
        return WebPEncoder.describe(picture.error_code)
    }
}

extension UInt32 {
    fileprivate var int32: Int32 { Int32(bitPattern: self) }
}
