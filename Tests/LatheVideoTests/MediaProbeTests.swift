import AVFoundation
import Foundation
import LatheCore
import LatheFixtures
import Testing

@testable import LatheVideo

/// Tests for the container probe.
///
/// Fixtures are generated, so their properties are known by construction: a clip
/// asserted to be 160x120 at 24 fps is 160x120 at 24 fps because
/// `LatheFixtures` wrote it that way, not because somebody measured a file once.
@Suite("Media probe", .serialized)
struct MediaProbeTests {

    private let probe = MediaProbe()

    private static let size = PixelSize(width: 160, height: 120)
    private static let frameRate = 24
    private static let seconds: Double = 2

    private func standardMovie(named name: String, audio: FixtureAudio) async -> URL? {
        await fixture(name) {
            try await FixtureLibrary.shared.movie(
                named: name, size: Self.size, frameRate: Self.frameRate,
                seconds: Self.seconds, audio: audio
            )
        }
    }

    // MARK: - Video

    @Test("a video track reports its codec, size, frame rate and bit rate")
    func videoTrackFacts() async throws {
        guard let movie = await standardMovie(named: "probe-video.mov", audio: .none) else { return }

        let info = try await probe.probe(url: movie)

        #expect(abs(info.duration - Self.seconds) < 0.1)
        #expect(info.hasDeterminateDuration)
        #expect(info.hasVideoTrack)
        #expect(!info.hasAudioTrack)
        #expect(!info.isEmptyAsset)
        #expect(info.fileName == "probe-video.mov")
        // The file name only: a full path must not travel inside this type.
        #expect(!info.fileName.contains("/"))
        #expect((info.byteCount ?? 0) > 0)

        let video = try #require(info.primaryVideoTrack)
        #expect(video.kind == .video)
        #expect(video.mediaTypeIdentifier == AVMediaType.video.rawValue)
        // H.264 in a QuickTime container is always `avc1`.
        #expect(video.codecFourCC == "avc1")
        #expect(video.codecName == "h264")
        #expect(video.codedSize == Self.size)
        #expect(video.displaySize == Self.size)      // no rotation in the fixture
        #expect(abs((video.nominalFrameRate ?? 0) - Double(Self.frameRate)) < 0.5)
        #expect((video.estimatedBitRate ?? 0) > 0)
        #expect(video.sampleRate == nil)             // not an audio track
        #expect(video.channelCount == nil)
    }

    @Test("an audio track is detected and described")
    func audioTrackFacts() async throws {
        guard let movie = await standardMovie(
            named: "probe-av.mov", audio: .tone(hertz: 440, amplitude: 0.4)
        ) else { return }

        let info = try await probe.probe(url: movie)
        #expect(info.hasVideoTrack)
        #expect(info.hasAudioTrack)
        #expect(info.tracks.count == 2)

        let audio = try #require(info.audioTracks.first)
        #expect(audio.kind == .audio)
        // Note the trailing space, and note that it is not `mp4a`: for audio
        // tracks AVFoundation's subtype is the CoreAudio format ID rather than
        // the container's sample-description tag. Pinned here because it is
        // surprising enough that somebody will otherwise "fix" it.
        #expect(audio.codecFourCC == "aac ")
        #expect(audio.codecName == "aac")
        #expect(audio.channelCount == 1)
        #expect(abs((audio.sampleRate ?? 0) - FixtureLibrary.sampleRate) < 1)
        #expect(audio.codedSize == nil)              // not a visual track
        #expect(audio.nominalFrameRate == nil)

        // Track indices are distinct and in container order.
        #expect(Set(info.tracks.map(\.index)).count == info.tracks.count)
    }

    @Test("an audio-only file has no video track and is still a valid asset")
    func audioOnly() async throws {
        guard let wav = await fixture("probe-audio-only.wav", {
            try await FixtureLibrary.shared.wav(
                named: "probe-audio-only.wav", seconds: 2,
                audio: .tone(hertz: 440, amplitude: 0.4)
            )
        }) else { return }

        let info = try await probe.probe(url: wav)
        #expect(!info.hasVideoTrack)
        #expect(info.hasAudioTrack)
        #expect(!info.isEmptyAsset)
        #expect(info.pixelSize == nil)
        #expect(abs(info.duration - 2) < 0.1)
        #expect(info.containerName == "wav")

        let audio = try #require(info.audioTracks.first)
        #expect(audio.codecName == "pcm")
        #expect(audio.channelCount == 1)
    }

    // MARK: - Degenerate inputs

    @Test("a zero-duration asset is a fact, not an error")
    func zeroDuration() async throws {
        guard let empty = await fixture("probe-empty.wav", {
            try await FixtureLibrary.shared.emptyWAV(named: "probe-empty.wav")
        }) else { return }

        let info = try await probe.probe(url: empty)
        #expect(info.duration < 0.001)
        #expect(info.hasDeterminateDuration)
        // Whether a header-only WAV carries a zero-length track or no track at
        // all is the container's business; either way there is nothing to play.
        #expect(info.videoTracks.isEmpty)
    }

    @Test("a file that is not media at all is refused, with a reason")
    func notMedia() async throws {
        guard let url = await fixture("probe-not-media.mov", {
            try await FixtureLibrary.shared.notMedia(named: "probe-not-media.mov")
        }) else { return }

        do {
            let info = try await probe.probe(url: url)
            Issue.record("expected a refusal, got \(info)")
        } catch let error as LatheError {
            guard case let .invalidInput(reason) = error else {
                Issue.record("expected .invalidInput, got \(error)")
                return
            }
            #expect(reason.contains("probe-not-media.mov"))
        }
    }

    @Test("a missing file is a read failure, not an invalid input")
    func missingFile() async throws {
        let missing = await FixtureLibrary.shared.scratchURL(named: "nothing-here.mov")
        do {
            _ = try await probe.probe(url: missing)
            Issue.record("expected a refusal")
        } catch let error as LatheError {
            guard case .readFailed = error else {
                Issue.record("expected .readFailed, got \(error)")
                return
            }
        }
    }

    /// A still image is the awkward case: `AVURLAsset` does not uniformly refuse
    /// them, and a caller that treats "the asset opened" as "this is a video"
    /// will try to transcode a photograph.
    ///
    /// Which way a given image goes is the system's business, so both outcomes
    /// are accepted — but **not** the third one, where a caller could mistake it
    /// for playable media. That is the assertion.
    @Test("a still image never looks like playable media")
    func stillImage() async throws {
        guard let png = await fixture("probe-still.png", {
            try await FixtureLibrary.shared.stillImage(named: "probe-still.png")
        }) else { return }

        do {
            let info = try await probe.probe(url: png)
            print("AVURLAsset opened a PNG: \(info.tracks.count) track(s), "
                  + "duration \(info.duration)s, empty=\(info.isEmptyAsset)")
            #expect(info.isEmptyAsset)
            #expect(info.duration < 0.001)
        } catch let error as LatheError {
            guard case .invalidInput = error else {
                Issue.record("expected .invalidInput, got \(error)")
                return
            }
            print("AVURLAsset refused a PNG outright: \(error.errorDescription ?? "")")
        }
    }

    // MARK: - Rotation arithmetic

    /// The transform maths is pure, so it is tested directly rather than by
    /// generating a rotated fixture for every angle.
    @Test("a quarter turn swaps the reported display axes")
    func rotationSwapsAxes() {
        let coded = PixelSize(width: 1920, height: 1080)
        #expect(MediaProbe.applying(.identity, to: coded) == coded)
        #expect(MediaProbe.applying(CGAffineTransform(rotationAngle: .pi), to: coded) == coded)
        for angle in [Double.pi / 2, -Double.pi / 2, 3 * Double.pi / 2] {
            #expect(MediaProbe.applying(CGAffineTransform(rotationAngle: angle), to: coded)
                    == PixelSize(width: 1080, height: 1920))
        }
    }

    // MARK: - Fixture gate

    private func fixture(_ name: String, _ make: () async throws -> URL) async -> URL? {
        do {
            return try await make()
        } catch {
            withKnownIssue("could not generate the fixture \"\(name)\" on this machine: \(error)") {
                Issue.record("fixture generation failed")
            }
            return nil
        }
    }
}
