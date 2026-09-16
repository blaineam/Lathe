// AV1 is encoded in software by SVT-AV1, so these run a real encode and then
// *decode the result* where this machine can. A file that AVAssetWriter
// accepted is not evidence of anything: a track without a correct `av1C` box
// finishes writing cleanly and decodes to nothing.

@preconcurrency import AVFoundation
import CoreMedia
@preconcurrency import CoreVideo
import Foundation
import LatheCore
import Testing
import VideoToolbox

@testable import LatheAV1

@Suite("AV1 encoding", .serialized)
struct AV1EncoderTests {

    private static func directory(_ prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lathe-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a clip encodes to AV1 that decodes frame for frame, with its audio")
    func encodesAndDecodes() async throws {
        let directory = try Self.directory("av1")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = try await Clips.encodedClip(.init(), in: directory)
        let output = directory.appendingPathComponent("out.mp4")

        let result = try await AV1Encoder().encode(
            source: clip, to: output, options: AV1EncodeOptions(bitrate: 600_000))

        #expect(result.output == output)
        #expect(result.frameCount == 60)
        #expect(result.pixelSize == PixelSize(width: 320, height: 240))
        #expect(result.hasAudio)
        #expect(!result.isTenBit)
        #expect(result.outputByteCount > 0)

        let back = try await Clips.readBack(output)
        #expect(back.codec == kCMVideoCodecType_AV1)
        #expect(back.sampleCount == 60)
        // Decoded where this machine can decode AV1 (M3 / A17 Pro and later;
        // not the Simulator). Where it can, every frame must come back.
        #expect(back.decodedFrames == nil || back.decodedFrames == 60)
        #expect(abs(back.duration - 2.0) < 0.1, "duration \(back.duration)")
        #expect(back.naturalSize == CGSize(width: 320, height: 240))
        #expect(back.hasAudio)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".lathe-") }
        #expect(leftovers.isEmpty, "scratch files were left: \(leftovers)")
    }

    @Test("scaling applies to the coded size and the rotation is carried across")
    func portraitScales() async throws {
        let directory = try Self.directory("av1-portrait")
        defer { try? FileManager.default.removeItem(at: directory) }
        // Stored landscape 640x360 with a 90° rotation: displayed 360x640.
        let clip = try await Clips.encodedClip(
            .init(width: 640, height: 360, frames: 30, audio: false, portrait: true),
            in: directory)
        let output = directory.appendingPathComponent("out.mp4")

        // An 854x480 cap must shrink the *displayed* 640 height to 480, so the
        // coded landscape frame becomes 480x270.
        let result = try await AV1Encoder().encode(
            source: clip, to: output,
            options: AV1EncodeOptions(maxWidth: 854, maxHeight: 480, bitrate: 400_000))
        #expect(result.pixelSize == PixelSize(width: 480, height: 270))
        #expect(!result.hasAudio)

        let back = try await Clips.readBack(output)
        #expect(back.codec == kCMVideoCodecType_AV1)
        #expect(back.sampleCount == 30)
        #expect(back.decodedFrames == nil || back.decodedFrames == 30)
        #expect(back.naturalSize == CGSize(width: 480, height: 270))
        // A quarter turn, compared with tolerance: the file stores exact
        // integers and `rotationAngle(.pi / 2)` does not quite produce them.
        #expect(abs(back.transform.b - 1) < 0.001 && abs(back.transform.c + 1) < 0.001)
        #expect(!back.hasAudio)
    }

    @Test("HLG HDR stays 10-bit HLG")
    func hdrStaysHDR() async throws {
        let directory = try Self.directory("av1-hdr")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = try await Clips.encodedClip(
            .init(width: 320, height: 180, frames: 20, audio: false, hdr: true),
            in: directory)
        let output = directory.appendingPathComponent("out.mp4")

        let result = try await AV1Encoder().encode(
            source: clip, to: output, options: AV1EncodeOptions(bitrate: 400_000))
        #expect(result.isTenBit)

        let back = try await Clips.readBack(output)
        #expect(back.codec == kCMVideoCodecType_AV1)
        #expect(back.sampleCount == 20)
        #expect(back.decodedFrames == nil || back.decodedFrames == 20)
        #expect(back.transfer == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String))
        // high_bitdepth in the av1C box.
        let config = try #require(back.av1Config)
        #expect(config.count > 4 && config[config.startIndex + 2] & 0x40 != 0)
    }

    // MARK: - Refusals

    @Test("a destination that is not .mp4 is refused before anything is read")
    func refusesOtherContainers() async throws {
        let directory = try Self.directory("av1-refuse")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = try await Clips.encodedClip(.init(frames: 4, audio: false), in: directory)
        await #expect(throws: LatheError.self) {
            try await AV1Encoder().encode(
                source: clip, to: directory.appendingPathComponent("out.mov"),
                options: AV1EncodeOptions(bitrate: 400_000))
        }
        await #expect(throws: LatheError.self) {
            try await AV1Encoder().encode(
                source: clip, to: directory.appendingPathComponent("out.mp4"),
                options: AV1EncodeOptions(bitrate: 0))
        }
    }

    @Test("a cancelled encode leaves an existing destination untouched")
    func cancellationKeepsTheOldFile() async throws {
        let directory = try Self.directory("av1-cancel")
        defer { try? FileManager.default.removeItem(at: directory) }
        let clip = try await Clips.encodedClip(.init(frames: 30, audio: false), in: directory)
        let output = directory.appendingPathComponent("out.mp4")
        try Data("previous".utf8).write(to: output)

        let progress = ProgressHandle()
        progress.cancel()
        await #expect(throws: LatheError.self) {
            try await AV1Encoder().encode(
                source: clip, to: output, options: AV1EncodeOptions(bitrate: 400_000),
                progress: progress)
        }
        #expect(try Data(contentsOf: output) == Data("previous".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".lathe-") }
        #expect(leftovers.isEmpty)
    }

    // MARK: - The bitstream details, without an encoder

    @Test("temporal delimiters are stripped and everything else is kept, in order")
    func stripsTemporalDelimiters() {
        // TD (type 2, size 0), sequence header (type 1, 2 bytes), frame (type 6, 3 bytes)
        let td: [UInt8] = [0x12, 0x00]
        let seq: [UInt8] = [0x0A, 0x02, 0xAA, 0xBB]
        let frame: [UInt8] = [0x32, 0x03, 0x01, 0x02, 0x03]
        let stripped = AV1Bitstream.strippingTemporalDelimiters(Data(td + seq + frame))
        #expect(stripped == Data(seq + frame))
        #expect(AV1Bitstream.obus(in: stripped).map(\.type) == [1, 6])
    }

    @Test("av1C carries profile, level and 10-bit flag from the sequence header")
    func configurationRecord() {
        // seq_profile 0, still 0, reduced 0, timing 0, display_delay 0,
        // op count 0, idc 0 (12 bits), level 8 (5 bits), tier 1.
        var bits = "000" + "0" + "0" + "0" + "0" + "00000" + String(repeating: "0", count: 12) + "01000" + "1"
        while bits.count % 8 != 0 { bits += "0" }
        var payload: [UInt8] = []
        var index = bits.startIndex
        while index < bits.endIndex {
            let next = bits.index(index, offsetBy: 8)
            payload.append(UInt8(bits[index..<next], radix: 2)!)
            index = next
        }
        let header = Data([0x0A, UInt8(payload.count)] + payload)

        let info = AV1Bitstream.sequenceInfo(from: header)
        #expect(info == .init(profile: 0, level: 8, tier: 1))

        let record = AV1Bitstream.configurationRecord(sequenceHeader: header, tenBit: true)
        #expect(record[0] == 0x81)
        #expect(record[1] == 8)
        #expect(record[2] == 0x80 | 0x40 | 0x08 | 0x04)
        #expect(record.suffix(from: 4) == header)
    }

    @Test("the coded size scales against the displayed size and stays even")
    func codedSize() {
        let quarterTurn = CGAffineTransform(rotationAngle: .pi / 2)
        let size = AV1Engine.codedSize(
            natural: CGSize(width: 1920, height: 1080), transform: quarterTurn,
            maxDisplay: CGSize(width: 854, height: 480))
        // Displayed 1080x1920; fitting 854x480 is a quarter, so 480x270 coded.
        #expect(size.width == 480 && size.height == 270)
        let untouched = AV1Engine.codedSize(
            natural: CGSize(width: 641, height: 361), transform: .identity,
            maxDisplay: CGSize(width: 4000, height: 4000))
        #expect(untouched.width == 640 && untouched.height == 360)
    }
}

/// Clips built on demand, so the suite carries no binary media.
enum Clips {
    struct ClipOptions {
        var width = 320
        var height = 240
        var frames = 60
        var fps: Int32 = 30
        var audio = true
        var codec: AVVideoCodecType = .h264
        /// Rotates the display 90°, as a portrait phone recording is stored.
        var portrait = false
        /// A 10-bit HLG HEVC clip, as an iPhone records HDR.
        var hdr = false
    }

    /// A clip with moving content and, optionally, a tone.
    static func encodedClip(_ options: ClipOptions = ClipOptions(), in directory: URL) async throws -> URL {
        let url = directory.appendingPathComponent("clip-\(UUID().uuidString.prefix(6)).mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        var settings: [String: Any] = [
            AVVideoCodecKey: options.hdr ? AVVideoCodecType.hevc : options.codec,
            AVVideoWidthKey: options.width, AVVideoHeightKey: options.height,
        ]
        if options.hdr {
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
            ]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        if options.portrait {
            input.transform = CGAffineTransform(rotationAngle: .pi / 2)
        }
        let format = options.hdr
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_32BGRA
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: options.width,
                kCVPixelBufferHeightKey as String: options.height,
            ])
        writer.add(input)

        var audioInput: AVAssetWriterInput?
        if options.audio {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ])
            audio.expectsMediaDataInRealTime = false
            writer.add(audio)
            audioInput = audio
        }

        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        // Both tracks fed from `requestMediaDataWhenReady`, each on its own
        // queue. Polling `isReadyForMoreMediaData` from a loop that feeds them
        // in turn stalls intermittently — the writer holds one track back
        // until the other catches up, on a schedule the loop cannot see.
        // Each is only touched from its own track's serial queue.
        nonisolated(unsafe) let pool = try #require(adaptor.pixelBufferPool)
        nonisolated(unsafe) let tone = options.audio
            ? try toneSamples(seconds: Double(options.frames) / Double(options.fps))
            : []
        nonisolated(unsafe) let videoTrack = input
        nonisolated(unsafe) let pixelAdaptor = adaptor
        nonisolated(unsafe) let audioTrack = audioInput
        let frames = options.frames, fps = options.fps
        let width = options.width, height = options.height

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    let next = Counter()
                    videoTrack.requestMediaDataWhenReady(on: DispatchQueue(label: "fixture.video")) {
                        while videoTrack.isReadyForMoreMediaData, next.value < frames {
                            let frame = next.value
                            var buffer: CVPixelBuffer?
                            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
                            guard let pixels = buffer else { break }
                            fill(pixels, frame: frame, width: width, height: height)
                            pixelAdaptor.append(pixels, withPresentationTime:
                                CMTime(value: CMTimeValue(frame), timescale: fps))
                            next.value += 1
                        }
                        if next.value >= frames {
                            videoTrack.markAsFinished()
                            done.resume()
                        }
                    }
                }
            }
            if audioTrack != nil {
                group.addTask {
                    let audioInput = audioTrack!
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        let next = Counter()
                        audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "fixture.audio")) {
                            while audioInput.isReadyForMoreMediaData, next.value < tone.count {
                                audioInput.append(tone[next.value])
                                next.value += 1
                            }
                            if next.value >= tone.count {
                                audioInput.markAsFinished()
                                done.resume()
                            }
                        }
                    }
                }
            }
        }

        await writer.finishWriting()
        #expect(writer.status == .completed, "fixture clip failed: \(String(describing: writer.error))")
        return url
    }

    /// A position shared with a writer's callback queue, which only ever
    /// touches it from that one serial queue.
    private final class Counter: @unchecked Sendable {
        var value = 0
    }

    private static func fill(_ pixels: CVPixelBuffer, frame: Int, width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        if CVPixelBufferGetPlaneCount(pixels) == 2 {
            // 10-bit, MSB-aligned: a horizontal ramp that moves.
            let y = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt16.self)
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) / 2
            for row in 0..<height {
                for col in 0..<width {
                    let value = UInt16(64 + ((col + frame * 4) % width) * 800 / width)
                    y[row * yStride + col] = value << 6
                }
            }
            let uv = CVPixelBufferGetBaseAddressOfPlane(pixels, 1)!.assumingMemoryBound(to: UInt16.self)
            let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) / 2
            for row in 0..<(height / 2) {
                for col in 0..<(width / 2) {
                    uv[row * uvStride + col * 2] = UInt16(512 + (row % 64)) << 6
                    uv[row * uvStride + col * 2 + 1] = UInt16(512 - (col % 64)) << 6
                }
            }
            return
        }
        let base = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        for row in 0..<height {
            for col in 0..<width {
                let offset = row * stride + col * 4
                base[offset] = UInt8((col + frame * 5) & 0xFF)
                base[offset + 1] = UInt8((row * 2 + frame) & 0xFF)
                base[offset + 2] = UInt8((col ^ row) & 0xFF)
                base[offset + 3] = 0xFF
            }
        }
    }

    private static func toneSamples(seconds: Double) throws -> [CMSampleBuffer] {
        let rate = 44_100.0
        var format = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
            mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var description: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &format, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description)
        let audioFormat = try #require(description)

        let chunk = 1470
        let total = Int(seconds * rate)
        var written = 0
        var result: [CMSampleBuffer] = []
        while written < total {
            let count = min(chunk, total - written)
            var samples = [Int16](repeating: 0, count: count)
            for i in 0..<count {
                samples[i] = Int16(sin(Double(written + i) * 2 * .pi * 440 / rate) * 8000)
            }
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: count * 2,
                blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                dataLength: count * 2, flags: kCMBlockBufferAssureMemoryNowFlag,
                blockBufferOut: &block)
            let blockBuffer = try #require(block)
            samples.withUnsafeBytes {
                _ = CMBlockBufferReplaceDataBytes(
                    with: $0.baseAddress!, blockBuffer: blockBuffer,
                    offsetIntoDestination: 0, dataLength: count * 2)
            }
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: blockBuffer, formatDescription: audioFormat,
                sampleCount: count,
                presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: 44_100),
                packetDescriptions: nil, sampleBufferOut: &sample)
            result.append(try #require(sample))
            written += count
        }
        return result
    }

    /// Every decoded video frame of `url`, counted, plus what the track says
    /// about itself.
    struct VideoReadback {
        var codec: FourCharCode
        /// Samples in the track, counted without decoding.
        var sampleCount: Int
        /// Frames that decoded, or nil where this machine has no decoder for
        /// the codec — AV1 on the iOS Simulator and on Macs before M3.
        var decodedFrames: Int?
        var duration: Double
        var naturalSize: CGSize
        var transform: CGAffineTransform
        var hasAudio: Bool
        var transfer: String?
        /// The `av1C` box, for an AV1 track.
        var av1Config: Data?
    }

    static func readBack(_ url: URL) async throws -> VideoReadback {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        let extensions = CMFormatDescriptionGetExtensions(format) as? [CFString: Any] ?? [:]

        let passthrough = try AVAssetReader(asset: asset)
        let raw = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        passthrough.add(raw)
        #expect(passthrough.startReading())
        var samples = 0
        while let sample = raw.copyNextSampleBuffer() {
            samples += CMSampleBufferGetNumSamples(sample)
        }
        #expect(passthrough.status == .completed)

        let codec = CMFormatDescriptionGetMediaSubType(format)
        var decoded: Int?
        if codec != kCMVideoCodecType_AV1 || VTIsHardwareDecodeSupported(codec) {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            reader.add(output)
            #expect(reader.startReading())
            var count = 0
            while let sample = output.copyNextSampleBuffer() {
                if CMSampleBufferGetImageBuffer(sample) != nil { count += 1 }
            }
            #expect(reader.status == .completed, "decode failed: \(String(describing: reader.error))")
            decoded = count
        }

        return VideoReadback(
            codec: codec,
            sampleCount: samples,
            decodedFrames: decoded,
            duration: try await asset.load(.duration).seconds,
            naturalSize: try await track.load(.naturalSize),
            transform: try await track.load(.preferredTransform),
            hasAudio: !(try await asset.loadTracks(withMediaType: .audio)).isEmpty,
            transfer: extensions[kCMFormatDescriptionExtension_TransferFunction] as? String,
            av1Config: (extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms]
                as? [String: Any])?["av1C"] as? Data)
    }
}
