import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import LatheCore
import UniformTypeIdentifiers

/// Writes one synthetic **audio-only** file: AAC or Apple Lossless in an MPEG-4
/// container, with iTunes-style tags and cover art where a test needs them.
///
/// The movie writer next door cannot stand in for this. A test about audio
/// transcoding needs a file whose *bitrate is known by construction* — the
/// whole lossy-source rule is a comparison against it — and one whose metadata
/// is in the audio keyspaces rather than QuickTime's, because translating
/// between those keyspaces is precisely the thing that goes wrong.
struct AudioFileWriter {
    let url: URL
    let fileType: AVFileType
    /// The encoder settings, exactly as `AVAssetWriterInput` takes them.
    let settings: [String: Any]
    let sampleRate: Double
    let channelCount: Int
    let seconds: Double
    let audio: FixtureAudio
    let metadata: [AVMetadataItem]

    func write() async throws {
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        } catch {
            throw FixtureError.writerUnavailable("AVAssetWriter: \(error.localizedDescription)")
        }
        writer.metadata = metadata

        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw FixtureError.unsupported(
                "this system will not write \(settings[AVFormatIDKey] ?? "that format") into a "
                    + "\(url.pathExtension)"
            )
        }
        writer.add(input)

        guard writer.startWriting() else {
            throw FixtureError.writerUnavailable(
                writer.error?.localizedDescription ?? "startWriting() refused"
            )
        }
        writer.startSession(atSourceTime: .zero)

        let values = FixtureLibrary.interleavedSamples(
            for: audio, seconds: seconds, sampleRate: sampleRate, channels: channelCount
        )
        let format = try makeFormat()
        // 100 ms per buffer: few enough appends to stay quick, small enough that
        // a cancellation test has somewhere to cancel.
        let chunk = max(1, Int(sampleRate / 10))
        let offset = Counter()

        let pump = InputPump(input: input, label: "audio-file") {
            let start = offset.value
            guard start < values.count else { return false }
            let take = min(chunk, values.count - start)
            offset.value += take
            let buffer = try Self.sampleBuffer(
                from: Array(values[start..<(start + take)]),
                startFrame: Int64(start),
                format: format,
                sampleRate: sampleRate,
                channels: channelCount
            )
            guard input.append(buffer) else {
                throw FixtureError.writeFailed("an audio buffer at frame \(start) was refused")
            }
            return true
        }
        try await pump.run()

        writer.endSession(atSourceTime: CMTime(seconds: seconds, preferredTimescale: 600))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw FixtureError.writeFailed(
                writer.error?.localizedDescription ?? "writer finished as \(writer.status.rawValue)"
            )
        }
    }

    /// Interleaved Float32, `channelCount` channels wide.
    ///
    /// Every channel carries the same waveform. That is deliberate for a
    /// downmix test: a downmix of identical channels has a predictable level,
    /// where a downmix of differently-phased channels can cancel, and a test
    /// that fails because its fixture cancelled teaches nothing.
    private func makeFormat() throws -> CMAudioFormatDescription {
        let bytesPerFrame = UInt32(4 * channelCount)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var layout = FixtureLibrary.channelLayout(for: channelCount)
        var format: CMAudioFormatDescription?
        let status = withUnsafeMutablePointer(to: &layout) { pointer -> OSStatus in
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &asbd,
                layoutSize: channelCount > 2 ? MemoryLayout<AudioChannelLayout>.size : 0,
                layout: channelCount > 2 ? pointer : nil,
                magicCookieSize: 0, magicCookie: nil,
                extensions: nil, formatDescriptionOut: &format
            )
        }
        guard status == noErr, let format else {
            throw FixtureError.writeFailed("CMAudioFormatDescriptionCreate returned \(status)")
        }
        return format
    }

    /// Wraps interleaved Float32 samples in a `CMSampleBuffer` the writer will
    /// encode.
    private static func sampleBuffer(
        from values: [Float],
        startFrame: Int64,
        format: CMAudioFormatDescription,
        sampleRate: Double,
        channels: Int
    ) throws -> CMSampleBuffer {
        let rate = CMTimeScale(sampleRate)
        let frames = values.count / max(1, channels)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: rate),
            presentationTimeStamp: CMTime(value: startFrame / Int64(max(1, channels)), timescale: rate),
            decodeTimeStamp: .invalid
        )

        var buffer: CMSampleBuffer?
        var status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleCount: CMItemCount(frames), sampleTimingEntryCount: 1,
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
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: UInt32(samples.count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(samples.baseAddress)
                )
            )
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

        // `dataReady: false` above makes the buffer a promise of data rather
        // than data; the writer will not consume it until this call.
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
/// The same shape as the movie writer's pump, for the same reason: polling
/// `isReadyForMoreMediaData` is not how the writer expects to be driven, and the
/// failure it produces is completely silent. See `MovieWriter`.
private final class InputPump: @unchecked Sendable {

    private let input: AVAssetWriterInput
    private let label: String
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
