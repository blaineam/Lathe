@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import LatheCore
import SvtAv1Enc
import VideoToolbox

/// The encode itself: decode, hand planes to SVT-AV1, wrap its packets as MP4
/// samples. ``AV1Encoder`` is the public face of it.
///
/// # Shape of the pipeline
///
/// `AVAssetReader` decodes → pixel buffers are scaled if needed → planes are
/// handed to SVT-AV1 → each output packet (one AV1 *temporal unit*) is wrapped
/// in a `CMSampleBuffer` and passed through `AVAssetWriter` into an MP4, with
/// the source audio passed through beside it. Nothing is written to disk but the
/// output.
///
/// # Traps
///
/// - **An MP4 AV1 sample must not carry temporal-delimiter OBUs**, and SVT-AV1
///   starts every packet with one. They are stripped in ``AV1Bitstream``.
/// - **The `av1C` box is built by hand.** AVFoundation will not derive it; a
///   format description without it is accepted by the writer and produces a
///   file nothing can decode. The level and tier in it are read out of the
///   encoder's own sequence header rather than assumed.
/// - **The coded size is the track's natural size, not its display size.** A
///   portrait phone video is a landscape bitstream with a rotation, so scaling
///   is computed against `naturalSize` and the transform is carried across.
/// - **Timestamps are the source's.** SVT-AV1 is a constant-frame-rate
///   encoder and is given frame indices; each packet's index is mapped back to
///   the presentation time of the frame that went in, so a variable-frame-rate
///   phone recording keeps its timing.
actor AV1Engine {

    // MARK: - Configuration

    struct Configuration: Sendable {
        /// The largest the picture may be *as displayed*. The encoder scales the
        /// coded frame by the same factor; it never enlarges.
        var width: Int
        var height: Int
        var frameRate: Float
        /// Target bits per second (SVT-AV1's VBR mode).
        var bitrate: Int
        /// SVT-AV1 preset, 0...13: lower is slower and smaller.
        var preset: Int = AV1Engine.defaultPreset
    }

    /// Preset 10 on a phone and 8 on a Mac.
    ///
    /// Measured rather than guessed: below 8 the encode time roughly doubles per
    /// step for a few percent of size, which on a CPU-only path is the
    /// difference between a batch that finishes overnight and one that does not.
    /// A phone gets two steps faster again, because it also has a thermal
    /// budget.
    static var defaultPreset: Int {
        #if os(iOS)
        return 10
        #else
        return 8
        #endif
    }

    // MARK: - Encoding

    /// Encodes the video of `asset` to AV1 in an MP4 at `outputURL`, passing
    /// the audio through. `outputURL` is written directly; the public entry
    /// point is what makes the write atomic.
    func encode(
        asset: AVAsset,
        to outputURL: URL,
        config: Configuration,
        progress: ProgressHandle
    ) async throws -> Summary {
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw LatheError.invalidInput(reason: "the source has no video to encode")
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let nominalRate = try await videoTrack.load(.nominalFrameRate)
        let duration = try await asset.load(.duration).seconds
        let sourceFormat = try await videoTrack.load(.formatDescriptions).first
        let color = SourceColor(sourceFormat)
        // HDR stays 10-bit whatever the HDR setting says: truncating PQ or HLG
        // to 8 bits without tone mapping bands and shifts colour, which is
        // worse than a file slightly larger than asked for.
        let tenBit = color.isHDR || color.bitsPerComponent > 8

        // MARK: Sizes
        let coded = Self.codedSize(
            natural: naturalSize, transform: transform,
            maxDisplay: CGSize(width: config.width, height: config.height))
        guard coded.width >= 16, coded.height >= 16 else {
            throw LatheError.encodingFailed(stage: "av1", code: nil, reason: 
                "a \(coded.width)×\(coded.height) picture is too small to encode")
        }

        let frameRate = Double(config.frameRate > 0 ? config.frameRate
                               : (nominalRate > 0 ? nominalRate : 30))
        let expectedFrames = max(1, Int((duration * frameRate).rounded()))

        // MARK: Reader
        let reader = try AVAssetReader(asset: asset)
        let pixelFormat = tenBit
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw LatheError.readFailed(path: "the source", reason: "its video could not be read") }
        reader.add(videoOutput)

        // MARK: Encoder
        let encoder = try SVTSession(
            width: coded.width, height: coded.height,
            frameRate: frameRate, bitrate: config.bitrate,
            preset: config.preset, tenBit: tenBit, color: color)
        defer { encoder.close() }

        let sequenceHeader = try encoder.sequenceHeader()
        let formatDescription = try AV1Bitstream.formatDescription(
            sequenceHeader: sequenceHeader,
            width: coded.width, height: coded.height,
            tenBit: tenBit, color: color)

        // MARK: Writer
        try? FileManager.default.removeItem(at: outputURL)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoInput = AVAssetWriterInput(
            mediaType: .video, outputSettings: nil, sourceFormatHint: formatDescription)
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = transform
        guard writer.canAdd(videoInput) else {
            throw LatheError.encodingFailed(stage: "av1", code: nil, reason: "the MP4 writer refused an AV1 track")
        }
        writer.add(videoInput)

        let audio = try await AudioCarrier.attach(asset: asset, reader: reader, writer: writer)

        guard reader.startReading() else {
            throw LatheError.readFailed(path: "the source", reason: "its video could not be read")
        }
        guard writer.startWriting() else {
            throw LatheError.encodingFailed(stage: "av1", code: nil, reason: 
                writer.error?.localizedDescription ?? "the MP4 writer did not start")
        }
        writer.startSession(atSourceTime: .zero)

        // MARK: Loop
        var timeline = FrameTimeline()
        var scaler: PixelScaler?
        var sent = 0
        var firstTime: CMTime?


        do {
            while let sample = videoOutput.copyNextSampleBuffer() {
                try Task.checkCancellation()
                try progress.checkCancellation()
                guard var pixels = CMSampleBufferGetImageBuffer(sample) else { continue }

                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                // Shifted only if the track starts before zero: a video that
                // starts a frame late must stay a frame late, or it drifts
                // from the audio passed through beside it.
                let origin = firstTime ?? (CMTimeCompare(pts, .zero) < 0 ? pts : .zero)
                firstTime = origin
                timeline.record(index: sent, time: CMTimeSubtract(pts, origin))

                if CVPixelBufferGetWidth(pixels) != coded.width
                    || CVPixelBufferGetHeight(pixels) != coded.height {
                    if scaler == nil {
                        scaler = try PixelScaler(
                            width: coded.width, height: coded.height, format: pixelFormat)
                    }
                    pixels = try scaler!.scale(pixels)
                }

                try encoder.send(pixels, index: sent)
                sent += 1
                try await drain(
                encoder, final: false, timeline: &timeline, format: formatDescription,
                to: videoInput, writer: writer, audio: audio)
                _ = progress.report(LatheProgress(
                    fraction: min(0.99, Double(sent) / Double(expectedFrames)),
                    stage: "av1", unitIndex: UInt64(sent), unitCount: UInt64(expectedFrames)))
            }

            if reader.status == .failed {
                throw LatheError.encodingFailed(stage: "av1", code: nil, reason:
                    reader.error?.localizedDescription ?? "the source could not be read")
            }
            guard sent > 0 else { throw LatheError.invalidInput(reason: "the source has no video to encode") }

            timeline.finish(end: CMTime(seconds: duration, preferredTimescale: 600))
            try encoder.sendEndOfStream()
            try await drain(
                encoder, final: true, timeline: &timeline, format: formatDescription,
                to: videoInput, writer: writer, audio: audio)
            videoInput.markAsFinished()

            if let audio {
                try await audio.pump(until: .positiveInfinity, writer: writer)
                audio.finish()
            }

            await writer.finishWriting()
            guard writer.status == .completed else {
                throw LatheError.encodingFailed(stage: "av1", code: nil, reason: 
                    writer.error?.localizedDescription ?? "the MP4 could not be finished")
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        _ = progress.report(LatheProgress(
            fraction: 1, stage: "av1", unitIndex: UInt64(sent), unitCount: UInt64(sent)))
        return Summary(
            width: coded.width, height: coded.height, frameCount: sent,
            tenBit: tenBit, hasAudio: audio != nil)
    }

    struct Summary {
        var width: Int
        var height: Int
        var frameCount: Int
        var tenBit: Bool
        var hasAudio: Bool
    }

    /// Every packet the encoder has ready, into the writer, with the audio
    /// kept level. With `final`, waits for the rest of the stream.
    private func drain(
        _ encoder: SVTSession,
        final: Bool,
        timeline: inout FrameTimeline,
        format: CMFormatDescription,
        to input: AVAssetWriterInput,
        writer: AVAssetWriter,
        audio: AudioCarrier?
    ) async throws {
        while let packet = try encoder.nextPacket(final: final) {
            try await append(
                packet, timeline: &timeline, format: format,
                to: input, writer: writer, audio: audio)
            if let audio {
                try await audio.pump(until: timeline.lastAppended, writer: writer)
            }
            if packet.isEndOfStream { break }
        }
    }

    /// One temporal unit into the writer, at the time of the frame it shows.
    private func append(
        _ packet: SVTSession.Packet,
        timeline: inout FrameTimeline,
        format: CMFormatDescription,
        to input: AVAssetWriterInput,
        writer: AVAssetWriter,
        audio: AudioCarrier?
    ) async throws {
        let payload = AV1Bitstream.strippingTemporalDelimiters(packet.data)
        guard !payload.isEmpty else { return }

        let timing = timeline.timing(forIndex: packet.index)
        let sample = try AV1Bitstream.sampleBuffer(
            payload, format: format, timing: timing, isSync: packet.isKeyFrame)

        while !input.isReadyForMoreMediaData {
            if writer.status == .failed {
                throw LatheError.encodingFailed(stage: "av1", code: nil, reason: 
                    writer.error?.localizedDescription ?? "the MP4 writer failed")
            }
            // The writer holds video back until the audio catches up, so
            // waiting without feeding it audio is a deadlock. Lead by a second.
            if let audio {
                try await audio.pump(
                    until: CMTimeAdd(timing.presentationTimeStamp, CMTime(value: 1, timescale: 1)),
                    writer: writer)
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        guard input.append(sample) else {
            throw LatheError.encodingFailed(stage: "av1", code: nil, reason: 
                writer.error?.localizedDescription ?? "the MP4 writer refused a frame")
        }
        timeline.lastAppended = CMTimeAdd(timing.presentationTimeStamp, timing.duration)
    }

    /// The size to encode at: the natural size, scaled by whatever brings the
    /// *displayed* size inside `maxDisplay`, rounded down to even.
    static func codedSize(
        natural: CGSize, transform: CGAffineTransform, maxDisplay: CGSize
    ) -> (width: Int, height: Int) {
        let shown = natural.applying(transform)
        let shownWidth = abs(shown.width), shownHeight = abs(shown.height)
        var scale = 1.0
        if shownWidth > 0, shownHeight > 0, maxDisplay.width > 0, maxDisplay.height > 0 {
            scale = min(1, Double(maxDisplay.width / shownWidth),
                        Double(maxDisplay.height / shownHeight))
        }
        let width = Int((natural.width * scale).rounded(.down))
        let height = Int((natural.height * scale).rounded(.down))
        return (width - width % 2, height - height % 2)
    }
}

// MARK: - The SVT-AV1 session

/// One encoder instance, owned by one encode.
///
/// A class rather than a struct so `close()` can be made idempotent and so the
/// plane buffers — allocated once per encode, since SVT-AV1 copies its input —
/// have one owner.
/// `@unchecked Sendable`: one encode owns it and calls it one step at a time,
/// from the engine's actor. It is never touched concurrently.
private final class SVTSession: @unchecked Sendable {

    struct Packet {
        var data: Data
        var index: Int
        var isKeyFrame: Bool
        var isEndOfStream: Bool
    }

    private var handle: UnsafeMutablePointer<EbComponentType>?
    private let width: Int
    private let height: Int
    private let tenBit: Bool
    private var luma: UnsafeMutableRawPointer
    private var cb: UnsafeMutableRawPointer
    private var cr: UnsafeMutableRawPointer
    private var closed = false

    init(width: Int, height: Int, frameRate: Double, bitrate: Int,
         preset: Int, tenBit: Bool, color: SourceColor) throws {
        self.width = width
        self.height = height
        self.tenBit = tenBit

        var config = EbSvtAv1EncConfiguration()
        var created: UnsafeMutablePointer<EbComponentType>?
        try Self.check(svt_av1_enc_init_handle(&created, &config), "create the encoder")
        handle = created

        config.enc_mode = Int8(clamping: min(max(preset, 0), 13))
        config.source_width = UInt32(width)
        config.source_height = UInt32(height)
        // A rational rather than a rounded integer, so 29.97 is 29.97.
        config.frame_rate_numerator = UInt32((frameRate * 1000).rounded())
        config.frame_rate_denominator = 1000
        config.encoder_bit_depth = tenBit ? 10 : 8
        config.encoder_color_format = EB_YUV420
        config.rate_control_mode = UInt8(SVT_AV1_RC_MODE_VBR.rawValue)
        config.target_bit_rate = UInt32(clamping: max(bitrate, 100_000))
        config.color_primaries = EbColorPrimaries(rawValue: color.primaries)
        config.transfer_characteristics = EbTransferCharacteristics(rawValue: color.transfer)
        config.matrix_coefficients = EbMatrixCoefficients(rawValue: color.matrix)
        config.color_range = EB_CR_STUDIO_RANGE
        // A key frame every five seconds or so: seeking in a long AV1 file
        // otherwise means decoding from the start of a very long GOP.
        config.intra_period_length = Int32(max(1, Int((frameRate * 5).rounded())) - 1)

        let lumaSize = width * height * (tenBit ? 2 : 1)
        let chromaSize = (width / 2) * (height / 2) * (tenBit ? 2 : 1)
        luma = .allocate(byteCount: lumaSize, alignment: 32)
        cb = .allocate(byteCount: chromaSize, alignment: 32)
        cr = .allocate(byteCount: chromaSize, alignment: 32)

        do {
            try Self.check(svt_av1_enc_set_parameter(handle, &config), "configure the encoder")
            try Self.check(svt_av1_enc_init(handle), "start the encoder")
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    func close() {
        guard !closed else { return }
        closed = true
        if let handle {
            _ = svt_av1_enc_deinit(handle)
            _ = svt_av1_enc_deinit_handle(handle)
        }
        handle = nil
        luma.deallocate()
        cb.deallocate()
        cr.deallocate()
    }

    /// The sequence header OBU, which the `av1C` box carries.
    func sequenceHeader() throws -> Data {
        var buffer: UnsafeMutablePointer<EbBufferHeaderType>?
        try Self.check(svt_av1_enc_stream_header(handle, &buffer), "produce a sequence header")
        defer { _ = svt_av1_enc_stream_header_release(buffer) }
        guard let buffer, let bytes = buffer.pointee.p_buffer, buffer.pointee.n_filled_len > 0 else {
            throw LatheError.encodingFailed(stage: "av1", code: nil, reason: "the encoder produced no sequence header")
        }
        return Data(bytes: bytes, count: Int(buffer.pointee.n_filled_len))
    }

    /// Copies one decoded frame into the encoder.
    func send(_ pixels: CVPixelBuffer, index: Int) throws {
        try copyPlanes(from: pixels)

        let lumaSize = width * height * (tenBit ? 2 : 1)
        let chromaSize = (width / 2) * (height / 2) * (tenBit ? 2 : 1)
        var io = EbSvtIOFormat()
        io.luma = luma.assumingMemoryBound(to: UInt8.self)
        io.cb = cb.assumingMemoryBound(to: UInt8.self)
        io.cr = cr.assumingMemoryBound(to: UInt8.self)
        // Strides are in samples, not bytes, for high bit depth.
        io.y_stride = UInt32(width)
        io.cb_stride = UInt32(width / 2)
        io.cr_stride = UInt32(width / 2)

        try withUnsafeMutablePointer(to: &io) { ioPointer in
            var header = EbBufferHeaderType()
            header.size = UInt32(MemoryLayout<EbBufferHeaderType>.size)
            header.p_buffer = UnsafeMutableRawPointer(ioPointer).assumingMemoryBound(to: UInt8.self)
            header.n_filled_len = UInt32(lumaSize + 2 * chromaSize)
            header.n_alloc_len = header.n_filled_len
            header.pts = Int64(index)
            header.pic_type = EB_AV1_INVALID_PICTURE
            header.flags = 0
            try Self.check(svt_av1_enc_send_picture(handle, &header), "accept frame \(index)")
        }
    }

    func sendEndOfStream() throws {
        var header = EbBufferHeaderType()
        header.size = UInt32(MemoryLayout<EbBufferHeaderType>.size)
        header.flags = UInt32(EB_BUFFERFLAG_EOS)
        header.pic_type = EB_AV1_INVALID_PICTURE
        try Self.check(svt_av1_enc_send_picture(handle, &header), "finish the stream")
    }

    /// The next finished packet, or nil when none is ready. With `final`, the
    /// call blocks until the encoder has one, and the last carries
    /// ``Packet/isEndOfStream``.
    func nextPacket(final: Bool) throws -> Packet? {
        var buffer: UnsafeMutablePointer<EbBufferHeaderType>?
        let status = svt_av1_enc_get_packet(handle, &buffer, final ? 1 : 0)
        if status == EB_NoErrorEmptyQueue { return nil }
        try Self.check(status, "produce a packet")
        guard let packet = buffer else { return nil }
        defer { svt_av1_enc_release_out_buffer(&buffer) }

        let header = packet.pointee
        // The upper 28 bits of `flags` are error bits (upstream's
        // EB_BUFFERFLAG_ERROR_MASK, spelled out because a macro with a line
        // continuation does not reliably import).
        if header.flags & 0xFFFF_FFF0 != 0 {
            throw LatheError.encodingFailed(stage: "av1", code: nil, reason: "the encoder reported an error in its output")
        }
        let data: Data
        if let bytes = header.p_buffer, header.n_filled_len > 0 {
            data = Data(bytes: bytes, count: Int(header.n_filled_len))
        } else {
            data = Data()
        }
        return Packet(
            data: data,
            index: Int(header.pts),
            isKeyFrame: header.pic_type == EB_AV1_KEY_PICTURE,
            isEndOfStream: header.flags & UInt32(EB_BUFFERFLAG_EOS) != 0)
    }

    // MARK: Planes

    /// Bi-planar (NV12 / P010) in, planar out — SVT-AV1 wants separate Cb and
    /// Cr planes, and 10-bit samples as little-endian values rather than the
    /// most-significant-bit-aligned ones Core Video stores.
    private func copyPlanes(from pixels: CVPixelBuffer) throws {
        guard CVPixelBufferGetPlaneCount(pixels) == 2,
              CVPixelBufferGetWidth(pixels) == width,
              CVPixelBufferGetHeight(pixels) == height
        else {
            throw LatheError.encodingFailed(stage: "av1", code: nil, reason: "a decoded frame had an unexpected layout")
        }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }

        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixels, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixels, 1)
        else { throw LatheError.encodingFailed(stage: "av1", code: nil, reason: "a decoded frame had no pixels") }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 1)
        let chromaWidth = width / 2, chromaHeight = height / 2

        if tenBit {
            let y = luma.assumingMemoryBound(to: UInt16.self)
            let u = cb.assumingMemoryBound(to: UInt16.self)
            let v = cr.assumingMemoryBound(to: UInt16.self)
            let ySource = yBase.assumingMemoryBound(to: UInt16.self)
            let uvSource = uvBase.assumingMemoryBound(to: UInt16.self)
            for row in 0..<height {
                let from = ySource + row * (yStride / 2)
                let to = y + row * width
                for col in 0..<width { to[col] = from[col] >> 6 }
            }
            for row in 0..<chromaHeight {
                let from = uvSource + row * (uvStride / 2)
                let toU = u + row * chromaWidth, toV = v + row * chromaWidth
                for col in 0..<chromaWidth {
                    toU[col] = from[col * 2] >> 6
                    toV[col] = from[col * 2 + 1] >> 6
                }
            }
        } else {
            let y = luma.assumingMemoryBound(to: UInt8.self)
            let u = cb.assumingMemoryBound(to: UInt8.self)
            let v = cr.assumingMemoryBound(to: UInt8.self)
            let ySource = yBase.assumingMemoryBound(to: UInt8.self)
            let uvSource = uvBase.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                (y + row * width).update(from: ySource + row * yStride, count: width)
            }
            for row in 0..<chromaHeight {
                let from = uvSource + row * uvStride
                let toU = u + row * chromaWidth, toV = v + row * chromaWidth
                for col in 0..<chromaWidth {
                    toU[col] = from[col * 2]
                    toV[col] = from[col * 2 + 1]
                }
            }
        }
    }

    private static func check(_ status: EbErrorType, _ what: String) throws {
        guard status == EB_ErrorNone else {
            throw LatheError.encodingFailed(stage: "av1", code: nil, reason: 
                "SVT-AV1 could not \(what) (0x\(String(UInt32(truncatingIfNeeded: status.rawValue), radix: 16)))")
        }
    }
}

// MARK: - Timing

/// Frame index ↔ source presentation time.
private struct FrameTimeline: Sendable {
    private var times: [CMTime] = []
    private var end: CMTime = .invalid
    var lastAppended: CMTime = .zero

    mutating func record(index: Int, time: CMTime) {
        if index == times.count { times.append(time) }
    }

    mutating func finish(end: CMTime) { self.end = end }

    func timing(forIndex index: Int) -> CMSampleTimingInfo {
        let clamped = min(max(index, 0), max(times.count - 1, 0))
        let start = times.isEmpty ? .zero : times[clamped]
        var next: CMTime
        if clamped + 1 < times.count {
            next = times[clamped + 1]
        } else if end.isValid, CMTimeCompare(end, start) > 0 {
            next = end
        } else if clamped > 0 {
            // No end to measure against yet: repeat the previous frame's length.
            next = CMTimeAdd(start, CMTimeSubtract(start, times[clamped - 1]))
        } else {
            next = CMTimeAdd(start, CMTime(value: 1, timescale: 30))
        }
        return CMSampleTimingInfo(
            duration: CMTimeSubtract(next, start),
            presentationTimeStamp: start,
            decodeTimeStamp: .invalid)
    }
}

// MARK: - Scaling

private final class PixelScaler: @unchecked Sendable {
    private let session: VTPixelTransferSession
    private let pool: CVPixelBufferPool

    init(width: Int, height: Int, format: OSType) throws {
        var created: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &created) == noErr,
              let created
        else { throw LatheError.encodingFailed(stage: "av1", code: nil, reason: "could not create a scaler") }
        session = created
        VTSessionSetProperty(session, key: kVTPixelTransferPropertyKey_ScalingMode,
                             value: kVTScalingMode_Normal)

        var madePool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey: format,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary, &madePool)
        guard let madePool else {
            throw LatheError.encodingFailed(stage: "av1", code: nil, reason: "could not allocate scaled frames")
        }
        pool = madePool
    }

    deinit { VTPixelTransferSessionInvalidate(session) }

    func scale(_ source: CVPixelBuffer) throws -> CVPixelBuffer {
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        guard let output,
              VTPixelTransferSessionTransferImage(session, from: source, to: output) == noErr
        else { throw LatheError.encodingFailed(stage: "av1", code: nil, reason: "could not scale a frame") }
        return output
    }
}

// MARK: - Audio

/// The source's audio, passed through where the MP4 container accepts it and
/// re-encoded to AAC where it does not (PCM in a `.mov`, for instance).
/// `@unchecked Sendable` for the same reason as ``SVTSession``: owned by one
/// encode and driven serially from the engine's actor.
private final class AudioCarrier: @unchecked Sendable {
    private let output: AVAssetReaderTrackOutput
    private let input: AVAssetWriterInput
    private var pending: CMSampleBuffer?
    private var exhausted = false
    private var finished = false

    private init(output: AVAssetReaderTrackOutput, input: AVAssetWriterInput) {
        self.output = output
        self.input = input
    }

    static func attach(
        asset: AVAsset, reader: AVAssetReader, writer: AVAssetWriter
    ) async throws -> AudioCarrier? {
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }
        let hint = try await track.load(.formatDescriptions).first

        // Passthrough first: it costs nothing and keeps the audio bit-exact.
        let passthrough = AVAssetWriterInput(
            mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
        passthrough.expectsMediaDataInRealTime = false
        let rawOutput = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        if writer.canAdd(passthrough), reader.canAdd(rawOutput) {
            writer.add(passthrough)
            reader.add(rawOutput)
            return AudioCarrier(output: rawOutput, input: passthrough)
        }

        let decoded = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
        ])
        let channels = hint.flatMap {
            CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame
        } ?? 2
        let aac = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: min(max(Int(channels), 1), 2),
            AVSampleRateKey: 48_000,
            AVEncoderBitRateKey: 160_000,
        ])
        aac.expectsMediaDataInRealTime = false
        guard writer.canAdd(aac), reader.canAdd(decoded) else { return nil }
        writer.add(aac)
        reader.add(decoded)
        return AudioCarrier(output: decoded, input: aac)
    }

    /// Appends audio up to `time`, so the two tracks stay interleaved — a
    /// writer given all the video first can stop accepting it while it waits
    /// for audio that is never coming.
    func pump(until time: CMTime, writer: AVAssetWriter) async throws {
        while !exhausted {
            if pending == nil {
                pending = output.copyNextSampleBuffer()
                if pending == nil {
                    // Closed the moment it runs out, not at the end: a writer
                    // holding an audio track with neither more data nor an end
                    // stops accepting video — the same stall as never feeding it.
                    exhausted = true
                    finish()
                    return
                }
            }
            guard let sample = pending else { return }
            let at = CMSampleBufferGetPresentationTimeStamp(sample)
            if time.isNumeric, CMTimeCompare(at, time) > 0 { return }
            if !input.isReadyForMoreMediaData {
                if time.isNumeric { return }
                if writer.status == .failed { return }
                try await Task.sleep(for: .milliseconds(2))
                continue
            }
            _ = input.append(sample)
            pending = nil
        }
    }

    func finish() {
        guard !finished else { return }
        finished = true
        input.markAsFinished()
    }
}

// MARK: - Colour

/// The source's colour description, as H.273 code points.
struct SourceColor: Sendable, Equatable {
    var primaries: UInt32 = 1
    var transfer: UInt32 = 1
    var matrix: UInt32 = 1
    var bitsPerComponent = 8

    var isHDR: Bool { transfer == 16 || transfer == 18 }

    init(primaries: UInt32 = 1, transfer: UInt32 = 1, matrix: UInt32 = 1, bitsPerComponent: Int = 8) {
        self.primaries = primaries
        self.transfer = transfer
        self.matrix = matrix
        self.bitsPerComponent = bitsPerComponent
    }

    init(_ format: CMFormatDescription?) {
        guard let format,
              let ext = CMFormatDescriptionGetExtensions(format) as? [CFString: Any]
        else { return }

        func code(_ key: CFString, _ table: [CFString: UInt32], default fallback: UInt32) -> UInt32 {
            guard let name = ext[key] as? String else { return fallback }
            return table.first { ($0.key as String) == name }?.value ?? fallback
        }
        primaries = code(kCMFormatDescriptionExtension_ColorPrimaries, [
            kCVImageBufferColorPrimaries_ITU_R_2020: 9,
            kCVImageBufferColorPrimaries_P3_D65: 12,
            kCVImageBufferColorPrimaries_SMPTE_C: 6,
            kCVImageBufferColorPrimaries_EBU_3213: 5,
        ], default: 1)
        transfer = code(kCMFormatDescriptionExtension_TransferFunction, [
            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ: 16,
            kCVImageBufferTransferFunction_ITU_R_2100_HLG: 18,
            kCVImageBufferTransferFunction_sRGB: 13,
            kCVImageBufferTransferFunction_Linear: 8,
            kCVImageBufferTransferFunction_ITU_R_2020: 14,
        ], default: 1)
        matrix = code(kCMFormatDescriptionExtension_YCbCrMatrix, [
            kCVImageBufferYCbCrMatrix_ITU_R_2020: 9,
            kCVImageBufferYCbCrMatrix_ITU_R_601_4: 6,
        ], default: 1)
        if let depth = ext["BitsPerComponent" as CFString] as? Int { bitsPerComponent = depth }
    }

    /// The same, spelled the way a Core Media format description wants it.
    var formatExtensions: [CFString: Any] {
        let primariesName: CFString = switch primaries {
        case 9: kCVImageBufferColorPrimaries_ITU_R_2020
        case 12: kCVImageBufferColorPrimaries_P3_D65
        case 6: kCVImageBufferColorPrimaries_SMPTE_C
        case 5: kCVImageBufferColorPrimaries_EBU_3213
        default: kCVImageBufferColorPrimaries_ITU_R_709_2
        }
        let transferName: CFString = switch transfer {
        case 16: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case 18: kCVImageBufferTransferFunction_ITU_R_2100_HLG
        case 13: kCVImageBufferTransferFunction_sRGB
        case 8: kCVImageBufferTransferFunction_Linear
        case 14: kCVImageBufferTransferFunction_ITU_R_2020
        default: kCVImageBufferTransferFunction_ITU_R_709_2
        }
        let matrixName: CFString = switch matrix {
        case 9: kCVImageBufferYCbCrMatrix_ITU_R_2020
        case 6: kCVImageBufferYCbCrMatrix_ITU_R_601_4
        default: kCVImageBufferYCbCrMatrix_ITU_R_709_2
        }
        return [
            kCMFormatDescriptionExtension_ColorPrimaries: primariesName,
            kCMFormatDescriptionExtension_TransferFunction: transferName,
            kCMFormatDescriptionExtension_YCbCrMatrix: matrixName,
            kCMFormatDescriptionExtension_FullRangeVideo: false,
        ]
    }
}

// MARK: - Bitstream

/// The AV1-in-ISOBMFF details: OBU parsing, the `av1C` box, and sample
/// buffers.
enum AV1Bitstream {

    struct OBU: Equatable {
        var type: UInt8
        /// The whole OBU, header included.
        var range: Range<Int>
    }

    static let sequenceHeaderType: UInt8 = 1
    static let temporalDelimiterType: UInt8 = 2
    static let paddingType: UInt8 = 15

    /// Splits a run of OBUs. Every OBU SVT-AV1 writes has its size field set;
    /// one without is taken to run to the end, which is what the spec says.
    static func obus(in data: Data) -> [OBU] {
        let bytes = [UInt8](data)
        var result: [OBU] = []
        var offset = 0
        while offset < bytes.count {
            let header = bytes[offset]
            let type = (header >> 3) & 0x0F
            let hasExtension = header & 0x04 != 0
            let hasSize = header & 0x02 != 0
            var cursor = offset + 1 + (hasExtension ? 1 : 0)
            var payloadSize = bytes.count - cursor
            if hasSize {
                guard let (value, length) = leb128(bytes, at: cursor) else { break }
                cursor += length
                payloadSize = Int(value)
            }
            let end = cursor + payloadSize
            guard end <= bytes.count, end > offset else { break }
            result.append(OBU(type: type, range: offset..<end))
            offset = end
        }
        return result
    }

    static func leb128(_ bytes: [UInt8], at start: Int) -> (UInt64, Int)? {
        var value: UInt64 = 0
        for i in 0..<8 {
            guard start + i < bytes.count else { return nil }
            let byte = bytes[start + i]
            value |= UInt64(byte & 0x7F) << (UInt64(i) * 7)
            if byte & 0x80 == 0 { return (value, i + 1) }
        }
        return nil
    }

    /// The sample payload an MP4 wants: temporal delimiters and padding gone.
    static func strippingTemporalDelimiters(_ data: Data) -> Data {
        let units = obus(in: data)
        guard units.contains(where: { $0.type == temporalDelimiterType || $0.type == paddingType })
        else { return data }
        var out = Data(capacity: data.count)
        let base = data.startIndex
        for unit in units where unit.type != temporalDelimiterType && unit.type != paddingType {
            out.append(data[(base + unit.range.lowerBound)..<(base + unit.range.upperBound)])
        }
        return out
    }

    /// Profile, level and tier of operating point 0, read from a sequence
    /// header OBU's payload.
    struct SequenceInfo: Equatable {
        var profile: UInt8
        var level: UInt8
        var tier: UInt8
    }

    static func sequenceInfo(from data: Data) -> SequenceInfo? {
        guard let unit = obus(in: data).first(where: { $0.type == sequenceHeaderType }) else {
            return nil
        }
        let bytes = [UInt8](data)
        // Skip the OBU header and size field to reach the payload.
        var cursor = unit.range.lowerBound + 1 + ((bytes[unit.range.lowerBound] & 0x04) != 0 ? 1 : 0)
        if bytes[unit.range.lowerBound] & 0x02 != 0 {
            guard let (_, length) = leb128(bytes, at: cursor) else { return nil }
            cursor += length
        }
        var reader = BitReader(bytes: Array(bytes[cursor..<unit.range.upperBound]))
        guard let profile = reader.read(3) else { return nil }
        _ = reader.read(1) // still_picture
        guard let reduced = reader.read(1) else { return nil }
        if reduced == 1 {
            guard let level = reader.read(5) else { return nil }
            return SequenceInfo(profile: UInt8(profile), level: UInt8(level), tier: 0)
        }
        guard let timingPresent = reader.read(1) else { return nil }
        var decoderModelPresent: UInt32 = 0
        if timingPresent == 1 {
            _ = reader.read(32); _ = reader.read(32)
            if reader.read(1) == 1 { _ = reader.uvlc() }
            decoderModelPresent = reader.read(1) ?? 0
            if decoderModelPresent == 1 {
                _ = reader.read(5); _ = reader.read(32); _ = reader.read(5); _ = reader.read(5)
            }
        }
        _ = reader.read(1) // initial_display_delay_present_flag
        _ = reader.read(5) // operating_points_cnt_minus_1
        _ = reader.read(12) // operating_point_idc[0]
        guard let level = reader.read(5) else { return nil }
        let tier = level > 7 ? (reader.read(1) ?? 0) : 0
        return SequenceInfo(profile: UInt8(profile), level: UInt8(level), tier: UInt8(tier))
    }

    /// The `av1C` box body (AV1-ISOBMFF §2.3.3).
    static func configurationRecord(sequenceHeader: Data, tenBit: Bool) -> Data {
        let info = sequenceInfo(from: sequenceHeader)
            ?? SequenceInfo(profile: 0, level: 31, tier: 0)
        var record = Data()
        record.append(0x81) // marker, version 1
        record.append((info.profile << 5) | (info.level & 0x1F))
        // tier, high_bitdepth, twelve_bit, monochrome, subsampling x/y, chroma position
        record.append((info.tier << 7) | (tenBit ? 0x40 : 0) | 0x08 | 0x04)
        record.append(0x00) // no initial presentation delay
        // Only the sequence header travels in configOBUs.
        if let unit = obus(in: sequenceHeader).first(where: { $0.type == sequenceHeaderType }) {
            let base = sequenceHeader.startIndex
            record.append(sequenceHeader[(base + unit.range.lowerBound)..<(base + unit.range.upperBound)])
        }
        return record
    }

    static func formatDescription(
        sequenceHeader: Data, width: Int, height: Int, tenBit: Bool, color: SourceColor
    ) throws -> CMFormatDescription {
        var extensions = color.formatExtensions
        extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms] = [
            "av1C": configurationRecord(sequenceHeader: sequenceHeader, tenBit: tenBit),
        ] as CFDictionary
        extensions[kCMFormatDescriptionExtension_Depth] = 24
        extensions[kCMFormatDescriptionExtension_FormatName] = "AOMedia Video 1"

        var description: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: kCMVideoCodecType_AV1,
            width: Int32(width), height: Int32(height),
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &description)
        guard status == noErr, let description else {
            throw LatheError.encodingFailed(stage: "av1", code: nil, reason: "could not describe the AV1 track (\(status))")
        }
        return description
    }

    static func sampleBuffer(
        _ payload: Data, format: CMFormatDescription, timing: CMSampleTimingInfo, isSync: Bool
    ) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: payload.count,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
            dataLength: payload.count, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        guard status == noErr, let block else {
            throw LatheError.encodingFailed(stage: "av1", code: nil, reason: "could not allocate a sample (\(status))")
        }
        status = payload.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: payload.count)
        }
        guard status == noErr else {
            throw LatheError.encodingFailed(stage: "av1", code: nil, reason: "could not fill a sample (\(status))")
        }

        var timingInfo = timing
        var size = payload.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else {
            throw LatheError.encodingFailed(stage: "av1", code: nil, reason: "could not wrap a sample (\(status))")
        }
        if !isSync,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

private struct BitReader {
    let bytes: [UInt8]
    var position = 0

    mutating func read(_ count: Int) -> UInt32? {
        var value: UInt32 = 0
        for _ in 0..<count {
            let byte = position / 8
            guard byte < bytes.count else { return nil }
            let bit = (bytes[byte] >> (7 - UInt8(position % 8))) & 1
            value = (value << 1) | UInt32(bit)
            position += 1
        }
        return value
    }

    mutating func uvlc() -> UInt32? {
        var leadingZeros = 0
        while true {
            guard let bit = read(1) else { return nil }
            if bit == 1 { break }
            leadingZeros += 1
            if leadingZeros >= 32 { return UInt32.max }
        }
        return read(leadingZeros)
    }
}

