import AVFoundation
import CoreMedia
import CoreGraphics
import CoreVideo
import Foundation
import LatheCore

/// Writes one synthetic QuickTime movie: H.264 video, optionally with an AAC
/// audio track.
///
/// Everything here is written to be *predictable* rather than realistic. Frames
/// are flat colour so the encoder's rate control has nothing to argue with and
/// the clip stays tiny; timestamps sit at exact rational positions so the
/// duration a test asserts is the duration that was asked for.
struct MovieWriter {
    let url: URL
    let size: PixelSize
    let frameRate: Int
    let seconds: Double
    let left: FixtureColour
    let right: FixtureColour
    let audio: FixtureAudio
    /// Fills every frame with deterministic pseudo-random pixels instead of flat
    /// colour. A flat frame compresses to almost nothing at *every* quality, so
    /// it cannot tell a working quality knob from a disconnected one; noise that
    /// also changes between frames defeats inter-frame prediction as well.
    let noise: Bool
    /// Written into the track's display matrix, so the clip is stored on one set
    /// of axes and presented on another — the everyday portrait-phone case.
    let rotationDegrees: Int
    /// Container metadata, for testing ``MetadataPolicy`` end to end.
    let creationDate: Date?
    /// ISO 6709, as QuickTime stores a location.
    let location: String?

    /// The audio track is AAC rather than PCM because that is what a QuickTime
    /// file off a camera actually contains, and the audio code under test should
    /// meet a real decoder. Where exact sample *values* matter, the WAV fixtures
    /// are used instead — see `FixtureLibrary.wav(named:seconds:audio:)`.
    private static let audioBitRate = 96_000

    func write() async throws {
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw FixtureError.writerUnavailable("AVAssetWriter: \(error.localizedDescription)")
        }

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height,
            ]
        )
        videoInput.expectsMediaDataInRealTime = false
        if rotationDegrees != 0 {
            videoInput.transform = CGAffineTransform(
                rotationAngle: CGFloat(rotationDegrees) * .pi / 180
            )
        }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height,
            ]
        )
        guard writer.canAdd(videoInput) else {
            throw FixtureError.unsupported("this system will not write H.264 into a .mov")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audio.isPresent {
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: FixtureLibrary.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: Self.audioBitRate,
                ]
            )
            input.expectsMediaDataInRealTime = false
            guard writer.canAdd(input) else {
                throw FixtureError.unsupported("this system will not write AAC into a .mov")
            }
            writer.add(input)
            audioInput = input
        }

        writer.metadata = metadataItems()

        guard writer.startWriting() else {
            throw FixtureError.writerUnavailable(
                writer.error?.localizedDescription ?? "startWriting() refused"
            )
        }
        writer.startSession(atSourceTime: .zero)

        // Each input is driven by its own pump. See `InputPump` for why this is
        // not a loop that polls `isReadyForMoreMediaData`.
        let frameCount = max(1, Int((seconds * Double(frameRate)).rounded()))
        let frameIndex = Counter()
        let videoPump = InputPump(input: videoInput, label: "video") {
            let index = frameIndex.value
            guard index < frameCount else { return false }
            frameIndex.value += 1
            return try appendFrame(index, through: adaptor)
        }

        var audioPump: InputPump?
        if let audioInput {
            let samples = FixtureLibrary.samples(for: audio, seconds: seconds)
            let format = try Self.makeAudioFormat()
            // 100 ms per buffer: enough granularity for the writer to interleave
            // against a 24 fps video track, few enough appends to stay quick.
            let chunk = max(1, Int(FixtureLibrary.sampleRate / 10))
            let offset = Counter()
            audioPump = InputPump(input: audioInput, label: "audio") {
                let start = offset.value
                guard start < samples.count else { return false }
                let take = min(chunk, samples.count - start)
                offset.value += take
                let buffer = try Self.sampleBuffer(
                    from: Array(samples[start..<(start + take)]),
                    startFrame: Int64(start), format: format
                )
                guard audioInput.append(buffer) else {
                    throw FixtureError.writeFailed("an audio buffer at frame \(start) was refused")
                }
                return true
            }
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await videoPump.run() }
            if let audioPump { group.addTask { try await audioPump.run() } }
            try await group.waitForAll()
        }

        writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600))
        await writer.finishWriting()

        guard writer.status == .completed else {
            throw FixtureError.writeFailed(
                writer.error?.localizedDescription ?? "writer finished as \(writer.status.rawValue)"
            )
        }
    }

    // MARK: - Video

    private func appendFrame(
        _ index: Int,
        through adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) throws -> Bool {
        guard let pool = adaptor.pixelBufferPool else {
            throw FixtureError.writerUnavailable("the writer offered no pixel buffer pool")
        }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer
        else {
            throw FixtureError.writeFailed("could not take a pixel buffer from the pool")
        }
        fill(pixelBuffer, frame: index)

        let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(frameRate))
        guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
            throw FixtureError.writeFailed("frame \(index) was refused")
        }
        return true
    }

    /// Fills a BGRA buffer: `left` on the left half, `right` on the right — or
    /// pseudo-random noise when ``noise`` is set.
    private func fill(_ pixelBuffer: CVPixelBuffer, frame index: Int) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let midpoint = width / 2

        for row in 0..<height {
            let line = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for column in 0..<width {
                let pixel = line.advanced(by: column * 4)
                if noise {
                    // xorshift64, seeded from the pixel's position and the frame
                    // number: reproducible across runs and machines, and
                    // different in every frame.
                    var state = UInt64(index &* 2_654_435_761)
                        ^ UInt64(row &* 40_503) ^ UInt64(column &* 2_246_822_519) ^ 0x9E37_79B9
                    state ^= state << 13
                    state ^= state >> 7
                    state ^= state << 17
                    pixel[0] = UInt8(truncatingIfNeeded: state)
                    pixel[1] = UInt8(truncatingIfNeeded: state >> 8)
                    pixel[2] = UInt8(truncatingIfNeeded: state >> 16)
                    pixel[3] = 255
                } else {
                    let colour = column < midpoint ? left : right
                    pixel[0] = colour.blue
                    pixel[1] = colour.green
                    pixel[2] = colour.red
                    pixel[3] = 255
                }
            }
        }
    }

    // MARK: - Metadata

    /// Container metadata, written the way a camera writes it: a QuickTime
    /// creation date as an ISO 8601 string, and a location as ISO 6709.
    private func metadataItems() -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        if let creationDate {
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataCreationDate
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            item.value = ISO8601DateFormatter().string(from: creationDate) as NSString
            items.append(item)
        }
        if let location {
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataLocationISO6709
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            item.value = location as NSString
            items.append(item)
        }
        return items
    }

    // MARK: - Audio

    /// The source format for every audio buffer, created once and reused.
    private static func makeAudioFormat() throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: FixtureLibrary.sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format
        )
        guard status == noErr, let format else {
            throw FixtureError.writeFailed("CMAudioFormatDescriptionCreate returned \(status)")
        }
        return format
    }

    /// Wraps mono Float32 samples in a `CMSampleBuffer` the writer will re-encode.
    private static func sampleBuffer(
        from values: [Float],
        startFrame: Int64,
        format: CMAudioFormatDescription
    ) throws -> CMSampleBuffer {
        let rate = CMTimeScale(FixtureLibrary.sampleRate)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: rate),
            presentationTimeStamp: CMTime(value: startFrame, timescale: rate),
            decodeTimeStamp: .invalid
        )

        var buffer: CMSampleBuffer?
        var status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleCount: CMItemCount(values.count), sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &buffer
        )
        guard status == noErr, let buffer else {
            throw FixtureError.writeFailed("CMSampleBufferCreate returned \(status)")
        }

        var mutable = values
        status = mutable.withUnsafeMutableBufferPointer { samples -> OSStatus in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 1,
                    mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(samples.baseAddress)
                )
            )
            // Copies the samples into a block buffer the sample buffer owns, so
            // `mutable` is free to go out of scope afterwards.
            return CMSampleBufferSetDataBufferFromAudioBufferList(
                buffer, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault,
                flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                bufferList: &list
            )
        }
        guard status == noErr else {
            throw FixtureError.writeFailed(
                "CMSampleBufferSetDataBufferFromAudioBufferList returned \(status)"
            )
        }

        // Required, and easy to miss. `CMSampleBufferCreate` was told
        // `dataReady: false`, so until this call the buffer is a promise of data
        // rather than data, and the writer will not consume it.
        status = CMSampleBufferSetDataReady(buffer)
        guard status == noErr else {
            throw FixtureError.writeFailed("CMSampleBufferSetDataReady returned \(status)")
        }
        return buffer
    }
}

/// A mutable counter owned by one serial queue.
private final class Counter: @unchecked Sendable {
    var value = 0
}

/// Feeds one `AVAssetWriterInput` until its source is exhausted.
///
/// **Why this is not a `while !input.isReadyForMoreMediaData { sleep }` loop.**
/// That shape appears to work with a single input and deadlocks with two: the
/// video input goes not-ready part way through and never comes back, while the
/// writer's status stays `.writing` and reports no error at all. Polling is not
/// how the writer expects to be driven —
/// `requestMediaDataWhenReady(on:using:)` is, and with one pump per input the
/// writer schedules both and does its own interleaving. The failure it replaces
/// is worth naming because it is completely silent: nothing fails, the
/// generator simply stops.
private final class InputPump: @unchecked Sendable {

    private let input: AVAssetWriterInput
    private let label: String
    /// Appends one unit. Returns `false` when there is nothing left to append.
    /// Called only on this pump's serial queue.
    private let produce: () throws -> Bool

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var settled = false

    init(input: AVAssetWriterInput, label: String, produce: @escaping () throws -> Bool) {
        self.input = input
        self.label = label
        self.produce = produce
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let queue = DispatchQueue(label: "dev.lathe.fixtures.\(label)")
            input.requestMediaDataWhenReady(on: queue) { [self] in
                do {
                    while input.isReadyForMoreMediaData {
                        if try produce() == false {
                            input.markAsFinished()
                            settle(nil)
                            return
                        }
                    }
                } catch {
                    input.markAsFinished()
                    settle(error)
                }
            }
        }
    }

    /// Resumes the continuation exactly once. The callback can fire again after
    /// `markAsFinished()`, and resuming twice traps.
    private func settle(_ error: (any Error)?) {
        lock.lock()
        guard !settled, let continuation else { lock.unlock(); return }
        settled = true
        self.continuation = nil
        lock.unlock()
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}
