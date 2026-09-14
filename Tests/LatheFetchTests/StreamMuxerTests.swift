import AVFoundation
import Foundation
import LatheCore
import Testing

@testable import LatheFetch

/// Joining a separately-downloaded video stream and audio stream.
///
/// **Entirely offline.** The two inputs are synthesised here rather than
/// downloaded, which makes the muxer — the piece that replaces `yt-dlp`'s
/// `ffmpeg` call, and therefore the piece iOS depends on — testable on every
/// machine, every run, with no network and no interpreter.
///
/// The fixtures are generated rather than committed, the same rule the video
/// and audio suites follow: no binary media lives in this repository, so there
/// is nothing to keep in step with the encoders and nothing whose provenance
/// has to be explained.
@Suite("Separate video and audio streams mux without re-encoding")
struct StreamMuxerTests {

    // MARK: - Scratch

    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lathe-mux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - The real thing

    @Test("a video-only file and an audio-only file become one file with both tracks")
    func muxesTwoStreams() async throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let videoURL = scratch.appendingPathComponent("video.mp4")
        let audioURL = scratch.appendingPathComponent("audio.m4a")
        let destination = scratch.appendingPathComponent("joined.mp4")

        guard try await MuxFixture.writeVideoOnly(to: videoURL, seconds: 2, frameRate: 30) else {
            withKnownIssue("this machine cannot encode an H.264 fixture") {
                Issue.record("no video encoder")
            }
            return
        }
        guard try MuxFixture.writeAudioOnly(to: audioURL, seconds: 2) else {
            withKnownIssue("this machine cannot encode an AAC fixture") {
                Issue.record("no audio encoder")
            }
            return
        }

        // The premise of the whole exercise: neither input on its own is a
        // watchable file.
        let sourceVideo = AVURLAsset(url: videoURL)
        let sourceAudio = AVURLAsset(url: audioURL)
        #expect(try await sourceVideo.loadTracks(withMediaType: .audio).isEmpty)
        #expect(try await sourceAudio.loadTracks(withMediaType: .video).isEmpty)

        let result = try await StreamMuxer.mux(video: videoURL, audio: audioURL, to: destination)

        let joined = AVURLAsset(url: destination)
        let videoTracks = try await joined.loadTracks(withMediaType: .video)
        let audioTracks = try await joined.loadTracks(withMediaType: .audio)
        #expect(videoTracks.count == 1, "the result has exactly one video track")
        #expect(audioTracks.count == 1, "the result has exactly one audio track")

        let duration = CMTimeGetSeconds(try await joined.load(.duration))
        #expect(abs(duration - 2) < 0.2, "duration came out at \(duration)s, expected ~2s")
        #expect(result.byteCount > 0)
        #expect(abs(result.duration - duration) < 0.05)
    }

    @Test("the samples are passed through, not re-encoded")
    func doesNotReEncode() async throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let videoURL = scratch.appendingPathComponent("video.mp4")
        let audioURL = scratch.appendingPathComponent("audio.m4a")
        let destination = scratch.appendingPathComponent("joined.mp4")

        guard try await MuxFixture.writeVideoOnly(to: videoURL, seconds: 1, frameRate: 30),
            try MuxFixture.writeAudioOnly(to: audioURL, seconds: 1)
        else {
            withKnownIssue("this machine cannot encode the fixtures") { Issue.record("no encoder") }
            return
        }

        let sourceVideoCodec = try await MuxFixture.codec(of: videoURL, mediaType: .video)
        let sourceAudioCodec = try await MuxFixture.codec(of: audioURL, mediaType: .audio)

        _ = try await StreamMuxer.mux(video: videoURL, audio: audioURL, to: destination)

        let joinedVideoCodec = try await MuxFixture.codec(of: destination, mediaType: .video)
        let joinedAudioCodec = try await MuxFixture.codec(of: destination, mediaType: .audio)

        // The four-character code surviving unchanged is the check. A re-encode
        // could in principle land on the same codec, which is why the *bytes*
        // are checked too: a transcode of a two-second clip does not reproduce
        // the source's exact sample sizes.
        #expect(joinedVideoCodec == sourceVideoCodec, "\(sourceVideoCodec) became \(joinedVideoCodec)")
        #expect(joinedAudioCodec == sourceAudioCodec, "\(sourceAudioCodec) became \(joinedAudioCodec)")

        let sourceVideoBytes = try await MuxFixture.encodedByteCount(of: videoURL, mediaType: .video)
        let joinedVideoBytes = try await MuxFixture.encodedByteCount(of: destination, mediaType: .video)
        #expect(
            sourceVideoBytes == joinedVideoBytes,
            "the video track's encoded size changed (\(sourceVideoBytes) → \(joinedVideoBytes)), which means it was re-encoded")
    }

    @Test("the source's rotation survives the join")
    func carriesTransform() async throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let videoURL = scratch.appendingPathComponent("video.mp4")
        let audioURL = scratch.appendingPathComponent("audio.m4a")
        let destination = scratch.appendingPathComponent("joined.mp4")

        // A quarter turn, which is what a phone-shot vertical clip records.
        let rotation = CGAffineTransform(rotationAngle: .pi / 2)
        guard try await MuxFixture.writeVideoOnly(
            to: videoURL, seconds: 1, frameRate: 30, transform: rotation),
            try MuxFixture.writeAudioOnly(to: audioURL, seconds: 1)
        else {
            withKnownIssue("this machine cannot encode the fixtures") { Issue.record("no encoder") }
            return
        }

        _ = try await StreamMuxer.mux(video: videoURL, audio: audioURL, to: destination)

        let track = try #require(
            try await AVURLAsset(url: destination).loadTracks(withMediaType: .video).first)
        let carried = try await track.load(.preferredTransform)
        #expect(abs(carried.b - rotation.b) < 0.001, "the rotation was dropped: \(carried)")
        #expect(abs(carried.c - rotation.c) < 0.001)
    }

    // MARK: - Refusals

    @Test("a file with no video track is refused, and says so")
    func refusesMissingVideoTrack() async throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let audioURL = scratch.appendingPathComponent("audio.m4a")
        let destination = scratch.appendingPathComponent("joined.mp4")
        guard try MuxFixture.writeAudioOnly(to: audioURL, seconds: 1) else {
            withKnownIssue("this machine cannot encode an AAC fixture") { Issue.record("no encoder") }
            return
        }

        let error = await #expect(throws: MediaFetchError.self) {
            try await StreamMuxer.mux(video: audioURL, audio: audioURL, to: destination)
        }
        guard case let .muxingFailed(stage, reason) = error else {
            Issue.record("expected muxingFailed, got \(String(describing: error))")
            return
        }
        #expect(stage == "read")
        #expect(reason.contains("video track"))
        #expect(
            !FileManager.default.fileExists(atPath: destination.path),
            "a refused mux must not leave anything behind")
    }

    @Test("a failed mux leaves the destination untouched")
    func leavesNoPartialFile() async throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        // An existing file at the destination is the case that matters: a mux
        // that failed half way and truncated it would be worse than one that
        // never started.
        let destination = scratch.appendingPathComponent("existing.mp4")
        try Data("not a movie, but it is mine".utf8).write(to: destination)

        let nonsense = scratch.appendingPathComponent("nonsense.mp4")
        try Data(repeating: 0, count: 64).write(to: nonsense)

        _ = await #expect(throws: (any Error).self) {
            try await StreamMuxer.mux(video: nonsense, audio: nonsense, to: destination)
        }

        let survived = try String(contentsOf: destination, encoding: .utf8)
        #expect(survived == "not a movie, but it is mine")

        // And nothing else was left in the directory either.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
            .filter { $0.hasPrefix(".lathe-mux-") }
        #expect(leftovers.isEmpty, "working files were left behind: \(leftovers)")
    }

    @Test("cancelling part way through leaves no file at the destination")
    func honoursCancellation() async throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let videoURL = scratch.appendingPathComponent("video.mp4")
        let audioURL = scratch.appendingPathComponent("audio.m4a")
        let destination = scratch.appendingPathComponent("joined.mp4")

        guard try await MuxFixture.writeVideoOnly(to: videoURL, seconds: 3, frameRate: 30),
            try MuxFixture.writeAudioOnly(to: audioURL, seconds: 3)
        else {
            withKnownIssue("this machine cannot encode the fixtures") { Issue.record("no encoder") }
            return
        }

        // A sink that says stop after a handful of samples. The return value is
        // the cancellation signal, which is the whole of the mechanism.
        let counter = SampleCounter()
        let progress = ProgressHandle(
            sink: ClosureProgressSink { _ in counter.increment() < 3 },
            throttle: .unthrottled)

        let error = await #expect(throws: (any Error).self) {
            try await StreamMuxer.mux(
                video: videoURL, audio: audioURL, to: destination, progress: progress)
        }
        #expect((error as? LatheError)?.isCancellation == true, "got \(String(describing: error))")
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("progress is reported under the mux stage and reaches the end")
    func reportsProgress() async throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }

        let videoURL = scratch.appendingPathComponent("video.mp4")
        let audioURL = scratch.appendingPathComponent("audio.m4a")
        let destination = scratch.appendingPathComponent("joined.mp4")
        guard try await MuxFixture.writeVideoOnly(to: videoURL, seconds: 2, frameRate: 30),
            try MuxFixture.writeAudioOnly(to: audioURL, seconds: 2)
        else {
            withKnownIssue("this machine cannot encode the fixtures") { Issue.record("no encoder") }
            return
        }

        let samples = SampleRecorder()
        let progress = ProgressHandle(
            sink: ObservingProgressSink { samples.record($0) }, throttle: .unthrottled)
        _ = try await StreamMuxer.mux(
            video: videoURL, audio: audioURL, to: destination, progress: progress)

        let recorded = samples.samples
        #expect(!recorded.isEmpty)
        #expect(recorded.allSatisfy { $0.stage == "mux" })
        let last = try #require(recorded.last?.fraction)
        #expect(last > 0.9, "the final fraction was \(last)")
        #expect(
            zip(recorded, recorded.dropFirst()).allSatisfy {
                ($0.1.fraction ?? 0) >= ($0.0.fraction ?? 0)
            },
            "progress went backwards, which means both pumps are reporting")
    }
}

// MARK: - Test helpers

private final class SampleCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

private final class SampleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LatheProgress] = []
    func record(_ sample: LatheProgress) {
        lock.lock()
        storage.append(sample)
        lock.unlock()
    }
    var samples: [LatheProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Generates the two halves of a split download, and reads facts back off them.
///
/// Both are written with the frameworks the muxer itself uses, so a machine
/// that cannot produce a fixture is a machine that could not have run the test
/// anyway — which is why every generator returns `false` rather than throwing,
/// and the tests record a known issue naming the reason.
enum MuxFixture {

    /// An H.264 file with a video track and nothing else.
    static func writeVideoOnly(
        to url: URL,
        seconds: Double,
        frameRate: Int,
        width: Int = 320,
        height: Int = 240,
        transform: CGAffineTransform = .identity
    ) async throws -> Bool {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }

        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ])
        input.expectsMediaDataInRealTime = false
        input.transform = transform
        guard writer.canAdd(input) else { return false }
        writer.add(input)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])

        guard writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(seconds * Double(frameRate))
        let pump = FixturePump(input: input)
        var frame = 0

        try await pump.run { [adaptor] in
            guard frame < frameCount else { return false }
            guard let buffer = makePixelBuffer(width: width, height: height, seed: frame) else {
                return false
            }
            let time = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(frameRate))
            guard adaptor.append(buffer, withPresentationTime: time) else { return false }
            frame += 1
            return true
        }

        await writer.finishWriting()
        return writer.status == .completed
    }

    /// An AAC file with an audio track and nothing else.
    ///
    /// `AVAudioFile` rather than a second `AVAssetWriter`: it is four lines, it
    /// produces exactly the `.m4a` a site publishes as its audio-only
    /// rendition, and it shares no code with the thing under test.
    static func writeAudioOnly(to url: URL, seconds: Double, sampleRate: Double = 44100) throws
        -> Bool
    {
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings),
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        else { return false }

        let frameCount = AVAudioFrameCount(sampleRate * seconds)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return false
        }
        buffer.frameLength = frameCount

        // A 440 Hz tone. Silence would work equally well for the assertions,
        // but a tone makes the fixture audible when somebody is debugging by
        // playing it.
        if let samples = buffer.floatChannelData?[0] {
            for index in 0..<Int(frameCount) {
                samples[index] = 0.25 * sinf(2 * .pi * 440 * Float(index) / Float(sampleRate))
            }
        }
        try file.write(from: buffer)
        return true
    }

    /// The four-character code of a file's first track of a kind.
    static func codec(of url: URL, mediaType: AVMediaType) async throws -> String {
        guard let track = try await AVURLAsset(url: url).loadTracks(withMediaType: mediaType).first,
            let format = try await track.load(.formatDescriptions).first
        else { return "none" }
        return StreamMuxer.fourCharacterCode(CMFormatDescriptionGetMediaSubType(format))
    }

    /// The total size of a track's encoded samples.
    ///
    /// The re-encode check that a codec comparison cannot make on its own: a
    /// transcode lands on different sample sizes even when it lands on the same
    /// codec.
    static func encodedByteCount(of url: URL, mediaType: AVMediaType) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: mediaType).first,
            let reader = try? AVAssetReader(asset: asset)
        else { return 0 }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return 0 }
        reader.add(output)
        reader.startReading()

        var total = 0
        while let sample = output.copyNextSampleBuffer() {
            total += CMSampleBufferGetTotalSampleSize(sample)
        }
        return total
    }

    private static func makePixelBuffer(width: Int, height: Int, seed: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true] as CFDictionary, &buffer)
        guard status == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)

        // A moving gradient. Something has to change between frames or the
        // encoder produces a handful of bytes and the byte-count assertion
        // above stops distinguishing anything.
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = UInt8((x + seed * 7) % 256)
                pixels[offset + 1] = UInt8((y + seed * 3) % 256)
                pixels[offset + 2] = UInt8((x + y + seed) % 256)
                pixels[offset + 3] = 255
            }
        }
        return buffer
    }
}

/// The single-input version of the muxer's own pump.
///
/// Even here, with one input and no possibility of the two-input deadlock, the
/// callback form is used rather than a polling loop — so that nobody reads the
/// fixture writer, concludes polling is fine, and carries that back into the
/// code under test.
private final class FixturePump: @unchecked Sendable {
    private let input: AVAssetWriterInput
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var settled = false

    init(input: AVAssetWriterInput) {
        self.input = input
    }

    func run(_ step: @escaping () -> Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.lock()
            self.continuation = continuation
            lock.unlock()

            let queue = DispatchQueue(label: "dev.lathe.fetch.fixture")
            input.requestMediaDataWhenReady(on: queue) { [self] in
                while input.isReadyForMoreMediaData {
                    if step() == false {
                        input.markAsFinished()
                        settle()
                        return
                    }
                }
            }
        }
    }

    private func settle() {
        lock.lock()
        guard !settled, let continuation else { lock.unlock(); return }
        settled = true
        self.continuation = nil
        lock.unlock()
        continuation.resume()
    }
}
