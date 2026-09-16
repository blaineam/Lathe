import AVFoundation
import CoreGraphics
import Foundation
import LatheCore
import LatheFixtures
import LatheImage
import Testing

@testable import LatheVideo

/// Assembling stills into a video, and the ways a movie that was written is not
/// the movie that was asked for: a duration one frame short, a size the codec
/// quietly changed, frames in the wrong order, a partial file left behind.
///
/// Every assertion reads the produced **file** back through `AVAsset` — the
/// duration and the size come from the container, not from the result the writer
/// returned, and the frames come back out through `FrameExtractor`, which is the
/// operation this one reverses.
@Suite("Video from frames")
struct FrameVideoWriterTests {

    private let writer = FrameVideoWriter()

    private func temporaryDirectory(_ label: String) throws -> URL {
        try DocumentFixtures.makeTemporaryDirectory("video-\(label)")
    }

    // MARK: - The round trip

    /// **The headline: frames in, a playable movie out, at the length asked
    /// for.**
    ///
    /// Twenty-four frames at 24 fps is one second. The classic off-by-one here
    /// is a movie that reports 23/24 of a second, because the session was ended
    /// at the last frame's presentation time rather than one frame duration
    /// after it — so the last frame has no duration and is not really there.
    @Test("twenty-four frames at 24 fps is a one-second movie")
    func roundTrip() async throws {
        let directory = try temporaryDirectory("roundtrip")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 24, in: directory, size: CGSize(width: 96, height: 64))
        let frames = try FrameSequence.contentsOfDirectory(directory)
        let output = directory.appendingPathComponent("out.mp4")

        let result = try await writer.write(frames, to: output, codec: .h264, frameRate: 24)

        #expect(result.frameCount == 24)
        #expect(result.pixelSize == PixelSize(width: 96, height: 64))
        #expect(result.outputByteCount > 0)

        let asset = AVURLAsset(url: output)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        #expect(abs(duration - 1.0) < 0.02,
                "got \(duration)s; a movie one frame short is the usual endSession bug")

        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
        let size = try await tracks[0].load(.naturalSize)
        #expect(size == CGSize(width: 96, height: 64))
    }

    /// **The frames come back out in the order they went in.**
    ///
    /// Counted frames and a correct duration would both survive a writer that
    /// shuffled or duplicated, so the pixels are what is checked: each fixture
    /// frame is its own flat grey, and pulling three of them back out with
    /// `FrameExtractor` — the operation this one reverses — must find them
    /// increasing.
    @Test("the frames come back out of the movie in the order they went in")
    func frameOrderSurvives() async throws {
        let directory = try temporaryDirectory("order")
        defer { try? FileManager.default.removeItem(at: directory) }

        let count = 10
        try FrameFixtures.stills(count: count, in: directory, size: CGSize(width: 96, height: 64))
        let frames = try FrameSequence.contentsOfDirectory(directory)
        let output = directory.appendingPathComponent("out.mov")

        try await writer.write(
            frames, to: output, codec: .hevc, frameRate: 10, quality: .quality(1.0)
        )

        // Sampled at the middle of frames 1, 5 and 10, so a rounding error at a
        // boundary is not what is being measured.
        let extractor = FrameExtractor()
        for index in [0, 4, 9] {
            let seconds = (Double(index) + 0.5) / 10
            let data = try await extractor.grayscaleFrame(
                from: output, atSeconds: seconds, size: 8
            )
            let mean = Double(data.reduce(0) { $0 + Int($1) }) / Double(data.count) / 255
            let expected = Double(FrameFixtures.gray(index, of: count))
            #expect(abs(mean - expected) < 0.08,
                    "frame \(index + 1) reads \(mean), expected \(expected)")
        }
    }

    /// Every codec in the shared vocabulary writes something playable. The
    /// vocabulary is `VideoTranscoder`'s, reused rather than reinvented, so this
    /// also pins that the two agree.
    @Test("every codec in the vocabulary writes a real track",
          arguments: VideoCodec.allCases)
    func everyCodec(_ codec: VideoCodec) async throws {
        let directory = try temporaryDirectory("codec-\(codec.rawValue)")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 6, in: directory, size: CGSize(width: 64, height: 64))
        let frames = try FrameSequence.contentsOfDirectory(directory)
        // .mov for all three: it is the only container that holds HEVC with
        // alpha, and using one container keeps this about the codec.
        let output = directory.appendingPathComponent("out.mov")

        let result = try await writer.write(frames, to: output, codec: codec, frameRate: 6)
        #expect(result.codec == codec)
        #expect(abs(result.duration - 1.0) < 0.05)

        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
    }

    // MARK: - Sizes

    /// **An odd canvas is rounded down to even, and the result says so.**
    ///
    /// H.264 and HEVC encode in macroblocks; an odd width or height is either
    /// refused or silently padded. Rounding down means no row of invented pixels
    /// is ever added, and reporting the rounded size means a caller that cares
    /// can see the odd pixel go instead of discovering it downstream.
    @Test("an odd-sized frame produces an even-sized track, and the result admits it")
    func oddSizesAreEvened() async throws {
        let directory = try temporaryDirectory("odd")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 4, in: directory, size: CGSize(width: 65, height: 49))
        let frames = try FrameSequence.contentsOfDirectory(directory)
        let output = directory.appendingPathComponent("out.mp4")

        let result = try await writer.write(frames, to: output, frameRate: 4)
        #expect(result.pixelSize == PixelSize(width: 64, height: 48))

        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        #expect(try await tracks[0].load(.naturalSize) == CGSize(width: 64, height: 48))
    }

    /// A video has one coded size, so mismatched frames are letterboxed onto the
    /// first frame's canvas rather than stretched into it.
    @Test("frames of different sizes are letterboxed into one track size")
    func mismatchedSizesAreFitted() async throws {
        let directory = try temporaryDirectory("mismatch")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 3, in: directory, sizes: [
            CGSize(width: 96, height: 64),
            CGSize(width: 32, height: 32),
            CGSize(width: 200, height: 40),
        ])
        let frames = try FrameSequence.contentsOfDirectory(directory)
        let output = directory.appendingPathComponent("out.mp4")

        let result = try await writer.write(frames, to: output, frameRate: 3)
        #expect(result.pixelSize == PixelSize(width: 96, height: 64))

        let tracks = try await AVURLAsset(url: output).loadTracks(withMediaType: .video)
        #expect(try await tracks[0].load(.naturalSize) == CGSize(width: 96, height: 64))
    }

    @Test("requireUniform refuses a mismatched run rather than letterboxing it")
    func requireUniformRefuses() async throws {
        let directory = try temporaryDirectory("uniform")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 2, in: directory, sizes: [
            CGSize(width: 96, height: 64), CGSize(width: 64, height: 64),
        ])
        let frames = try FrameSequence.contentsOfDirectory(directory)

        await #expect(throws: LatheError.self) {
            try await writer.write(
                frames, to: directory.appendingPathComponent("out.mp4"),
                frameRate: 2, canvas: .requireUniform
            )
        }
    }

    // MARK: - Awkward inputs

    /// **Zero frames is an error, not a zero-duration movie.** `AVAssetWriter`
    /// writes one perfectly happily, and nothing downstream can do anything with
    /// it.
    @Test("no frames is refused rather than written as an empty movie")
    func emptySequenceIsRefused() async throws {
        let directory = try temporaryDirectory("empty")
        defer { try? FileManager.default.removeItem(at: directory) }

        let output = directory.appendingPathComponent("out.mp4")
        await #expect(throws: LatheError.self) {
            try await writer.write(FrameSequence([]), to: output, frameRate: 30)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    /// One frame is a legal movie: one frame duration long.
    @Test("one frame at 4 fps is a quarter-second movie")
    func singleFrame() async throws {
        let directory = try temporaryDirectory("single")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 1, in: directory, size: CGSize(width: 64, height: 64))
        let frames = try FrameSequence.contentsOfDirectory(directory)
        let output = directory.appendingPathComponent("out.mp4")

        let result = try await writer.write(frames, to: output, frameRate: 4)
        #expect(result.frameCount == 1)
        #expect(abs(result.duration - 0.25) < 0.02)
    }

    /// A zero frame rate is a division by zero, not an idiom. Unlike an
    /// animation's zero *delay*, there is no value it could be clamped to.
    @Test("a frame rate of zero, or infinity, is refused by name")
    func zeroFrameRateIsRefused() async throws {
        let directory = try temporaryDirectory("rate")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 2, in: directory)
        let frames = try FrameSequence.contentsOfDirectory(directory)
        let output = directory.appendingPathComponent("out.mp4")

        for rate in [0.0, -24.0, Double.infinity, Double.nan] {
            await #expect(throws: LatheError.self) {
                try await writer.write(frames, to: output, frameRate: rate)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    /// A non-integral rate is not rounded into an integral one. 23.976 fps is a
    /// real thing to ask for and a movie that came out at 24 would drift.
    @Test("a non-integral frame rate is honoured rather than rounded")
    func nonIntegralFrameRate() async throws {
        let directory = try temporaryDirectory("ntsc")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 24, in: directory, size: CGSize(width: 64, height: 64))
        let frames = try FrameSequence.contentsOfDirectory(directory)
        let output = directory.appendingPathComponent("out.mp4")

        let rate = 24_000.0 / 1_001.0
        let result = try await writer.write(frames, to: output, frameRate: rate)
        let expected = 24 / rate
        #expect(abs(result.duration - expected) < 0.01,
                "got \(result.duration)s, expected \(expected)s")
    }

    /// An extension naming no container is refused before anything is created —
    /// the same `fileType(for:)` the transcoder uses, so the two agree about
    /// what Lathe writes.
    @Test("an extension that names no container is refused")
    func unknownContainer() async throws {
        let directory = try temporaryDirectory("container")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 2, in: directory)
        let frames = try FrameSequence.contentsOfDirectory(directory)

        await #expect(throws: LatheError.self) {
            try await writer.write(
                frames, to: directory.appendingPathComponent("out.mkv"), frameRate: 2
            )
        }
    }

    /// `.lossless` means "re-encode nothing", and there is nothing here that was
    /// ever encoded. Refused rather than reinterpreted as "quality 1.0", which
    /// is the reinterpretation that quietly makes files larger than their
    /// sources.
    @Test("a lossless quality target is refused, because there is nothing to leave alone")
    func losslessIsRefused() async throws {
        let directory = try temporaryDirectory("lossless")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 2, in: directory)
        let frames = try FrameSequence.contentsOfDirectory(directory)

        await #expect(throws: LatheError.self) {
            try await writer.write(
                frames, to: directory.appendingPathComponent("out.mp4"),
                frameRate: 2, quality: .lossless
            )
        }
    }

    // MARK: - Settings

    /// The compression dictionary is built by name, and the names are the
    /// raw-string ones `VTKey` owns — so a rename there is caught here rather
    /// than becoming a silently ignored setting.
    @Test("a bitrate target reaches AVFoundation, and a quality target reaches VideoToolbox")
    func settingsCarryTheQualityTarget() {
        let size = PixelSize(width: 64, height: 48)

        let byQuality = FrameVideoWriter.outputSettings(
            codec: .h264, size: size, quality: .quality(0.9), frameRate: 30
        )
        let compression = byQuality[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
        #expect(compression[VTKey.quality] as? Double == 0.9)
        #expect(compression[VTKey.expectedFrameRate] as? Double == 30)
        #expect(byQuality[AVVideoWidthKey] as? Int == 64)

        let byBitrate = FrameVideoWriter.outputSettings(
            codec: .hevc, size: size, quality: .averageBitrate(750_000), frameRate: 30
        )
        let bitrateProps = byBitrate[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
        #expect(bitrateProps[AVVideoAverageBitRateKey] as? Int == 750_000)
        #expect(bitrateProps[VTKey.quality] == nil, "a bitrate target must not also set a quality")

        // The alpha mode is only set for the codec that has one to describe;
        // setting it elsewhere is how a player gets a dark fringe around edges.
        let alpha = FrameVideoWriter.outputSettings(
            codec: .hevcWithAlpha, size: size, quality: .quality(0.5), frameRate: 30
        )[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
        #expect(alpha[VTKey.alphaChannelMode] as? String == "PremultipliedAlpha")
        #expect(compression[VTKey.alphaChannelMode] == nil)
    }

    // MARK: - Cancellation

    /// Cancellation unwinds without leaving a partial movie where the caller's
    /// previous one was.
    @Test("cancelling part way leaves the destination as it was")
    func cancellationLeavesNothingBehind() async throws {
        let directory = try temporaryDirectory("cancel")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 12, in: directory, size: CGSize(width: 64, height: 64))
        let frames = try FrameSequence.contentsOfDirectory(directory)
        let output = directory.appendingPathComponent("out.mp4")
        try Data("previous".utf8).write(to: output)

        let handle = ProgressHandle(throttle: .unthrottled)
        handle.cancel()

        await #expect(throws: LatheError.self) {
            try await writer.write(frames, to: output, frameRate: 12, progress: handle)
        }
        #expect(try Data(contentsOf: output) == Data("previous".utf8))

        // And no scratch file is left beside it.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".lathe-") }
        #expect(leftovers.isEmpty, "a cancelled encode left \(leftovers) behind")
    }

    /// **A stalled encoder has to end in an error, not in a hang.**
    ///
    /// `isReadyForMoreMediaData` staying false is what a machine with no
    /// usable video encoder looks like from in here, and it is
    /// indistinguishable from an encoder that is merely behind. The
    /// unbounded version of this loop sat in a CI job for six hours before
    /// the runner killed it, reporting nothing — the failure mode a timeout
    /// exists to convert into a sentence.
    ///
    /// A timeout of zero forces the decision on the first frame that is not
    /// instantly accepted, which is the only way to exercise the path without
    /// a machine that genuinely cannot encode.
    @Test("a stalled encoder is reported rather than waited on forever")
    func stallTimeoutIsEnforced() async throws {
        let directory = try temporaryDirectory("stall")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 40, in: directory, size: CGSize(width: 96, height: 64))
        let frames = try FrameSequence.contentsOfDirectory(directory)
        let output = directory.appendingPathComponent("out.mp4")

        let writer = FrameVideoWriter(stallTimeout: .zero)
        do {
            _ = try await writer.write(frames, to: output, codec: .h264, frameRate: 30)
            // Accepting every frame without ever going busy is a legitimate
            // outcome on a fast machine, so this is not a failure — the
            // assertion that matters is that it finished at all.
        } catch let error as LatheError {
            // And if it did go busy, the message has to name the cause rather
            // than being a bare timeout.
            #expect(String(describing: error).contains("never became ready"))
        }
    }

}
