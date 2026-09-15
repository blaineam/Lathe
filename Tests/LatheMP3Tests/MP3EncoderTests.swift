import AVFoundation
import Foundation
import LatheCore
import LatheFixtures
import Testing

@testable import LatheMP3

/// MP3 encoding.
///
/// The test that matters is the round trip: encode, then ask **AVFoundation** to
/// decode the result. Apple has an MP3 decoder and no encoder, so the system can
/// check this package's output without being the thing that produced it — which
/// is a stronger check than any assertion about bytes, and the only independent
/// one available.
@Suite("MP3 encoding", .serialized)
struct MP3EncoderTests {

    private let encoder = MP3Encoder()

    // MARK: - The round trip

    /// **The headline: the output is an MP3 the system can play.**
    @Test("an encoded file decodes back as MP3, at the right duration")
    func encodesADecodableFile() async throws {
        guard let source = await fixture("mp3-source.wav", {
            try await FixtureLibrary.shared.wav(
                named: "mp3-source.wav", seconds: 3,
                audio: .noise(amplitude: 0.4), sampleRate: 44_100, channels: 2
            )
        }) else { return }
        let destination = await scratch("mp3-out.mp3")

        let result = try await encoder.encode(source: source, to: destination)

        #expect(result.sampleRate == 44_100)
        #expect(result.channels == 2)
        #expect(result.outputByteCount > 0)
        #expect(result.encoderVersion.contains("3.100"),
                "encoder version was \"\(result.encoderVersion)\"")

        // The independent check: Apple decodes it.
        let asset = AVURLAsset(url: destination)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        #expect(tracks.count == 1, "the system found \(tracks.count) audio tracks in the output")
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 3) < 0.2, "decoded duration was \(duration)s, expected 3s")

        // And it really is MPEG audio rather than something else in a .mp3.
        if let format = try await tracks.first?.load(.formatDescriptions).first,
           let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format) {
            #expect(basic.pointee.mFormatID == kAudioFormatMPEGLayer3,
                    "the output is not MPEG Layer 3")
            #expect(basic.pointee.mSampleRate == 44_100)
        }
    }

    /// **It must actually compress.** An encoder that produced a file the size of
    /// its WAV source would pass a decode check and be useless.
    @Test("the output is far smaller than the uncompressed source")
    func compressesSubstantially() async throws {
        guard let source = await fixture("mp3-size.wav", {
            try await FixtureLibrary.shared.wav(
                named: "mp3-size.wav", seconds: 4,
                audio: .noise(amplitude: 0.4), sampleRate: 44_100, channels: 2
            )
        }) else { return }
        let destination = await scratch("mp3-size-out.mp3")

        let result = try await encoder.encode(source: source, to: destination)
        let ratio = Double(result.outputByteCount) / Double(result.inputByteCount)
        #expect(ratio < 0.5, "the output was \(Int(ratio * 100))% of the source")
        #expect(result.outputByteCount > 1_000, "the output is implausibly small")
    }

    /// A VBR file without a Xing header reports the wrong length in most
    /// players, which looks like a broken file rather than a missing header.
    @Test("the VBR header is written, so the duration is right")
    func writesTheVBRHeader() async throws {
        guard let source = await fixture("mp3-vbr.wav", {
            try await FixtureLibrary.shared.wav(
                named: "mp3-vbr.wav", seconds: 3,
                audio: .noise(amplitude: 0.4), sampleRate: 44_100, channels: 2
            )
        }) else { return }
        let destination = await scratch("mp3-vbr-out.mp3")
        try await encoder.encode(source: source, to: destination)

        // "Xing" or "Info" appears in the first frame of a tagged file.
        let head = try Data(contentsOf: destination).prefix(2_048)
        let hasTag = head.range(of: Data("Xing".utf8)) != nil
            || head.range(of: Data("Info".utf8)) != nil
        #expect(hasTag, "no Xing/Info header — a VBR file without one seeks and reports wrongly")
    }

    // MARK: - Channels

    @Test("a mono request produces one channel")
    func monoProducesOneChannel() async throws {
        guard let source = await fixture("mp3-mono.wav", {
            try await FixtureLibrary.shared.wav(
                named: "mp3-mono.wav", seconds: 2,
                audio: .noise(amplitude: 0.4), sampleRate: 44_100, channels: 2
            )
        }) else { return }
        let destination = await scratch("mp3-mono-out.mp3")

        let result = try await encoder.encode(source: source, to: destination, mode: .mono)
        #expect(result.channels == 1)

        let asset = AVURLAsset(url: destination)
        if let track = try await asset.loadTracks(withMediaType: .audio).first,
           let format = try await track.load(.formatDescriptions).first,
           let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format) {
            #expect(basic.pointee.mChannelsPerFrame == 1)
        }
    }

    /// A mono source must go through LAME's mono entry point. The interleaved
    /// one reads two channels' worth of samples per frame, so a mono block sent
    /// through it runs off the end of the array.
    @Test("a mono source encodes without reading past its samples")
    func monoSourceUsesTheMonoEntryPoint() async throws {
        guard let source = await fixture("mp3-mono-src.wav", {
            try await FixtureLibrary.shared.wav(
                named: "mp3-mono-src.wav", seconds: 2,
                audio: .noise(amplitude: 0.4), sampleRate: 44_100, channels: 1
            )
        }) else { return }
        let destination = await scratch("mp3-mono-src-out.mp3")

        let result = try await encoder.encode(source: source, to: destination)
        #expect(result.channels == 1)
        let duration = try await AVURLAsset(url: destination).load(.duration).seconds
        #expect(abs(duration - 2) < 0.2)
    }

    // MARK: - Quality

    /// Higher quality must produce a bigger file, or the knob is not connected.
    @Test("asking for more quality produces a larger file")
    func qualityChangesTheSize() async throws {
        guard let source = await fixture("mp3-quality.wav", {
            try await FixtureLibrary.shared.wav(
                named: "mp3-quality.wav", seconds: 4,
                audio: .noise(amplitude: 0.4), sampleRate: 44_100, channels: 2
            )
        }) else { return }

        let low = await scratch("mp3-q-low.mp3")
        let high = await scratch("mp3-q-high.mp3")
        let lowResult = try await encoder.encode(source: source, to: low, quality: .quality(0.1))
        let highResult = try await encoder.encode(source: source, to: high, quality: .quality(0.95))

        let note = "quality 0.95 gave \(highResult.outputByteCount) bytes and 0.1 gave "
            + "\(lowResult.outputByteCount) — the knob is inverted or disconnected"
        #expect(highResult.outputByteCount > lowResult.outputByteCount, "\(note)")
    }

    /// **LAME's VBR scale runs the opposite way to every knob in this package.**
    /// 0 is its best and 9 its worst, so a caller asking for 0.9 must not get a
    /// 9 — which is the single most likely mistake in this file.
    @Test("the quality scale is inverted for LAME, not passed through")
    func vbrQualityIsInverted() {
        #expect(LAMEFlags.vbrQuality(from: 1.0) == 0, "the best request must map to LAME's best")
        #expect(LAMEFlags.vbrQuality(from: 0.0) == 9, "the worst request must map to LAME's worst")
        #expect(LAMEFlags.vbrQuality(from: 0.5) == 4)
        // And out-of-range input does not escape the scale.
        #expect(LAMEFlags.vbrQuality(from: 5.0) == 0)
        #expect(LAMEFlags.vbrQuality(from: -1) == 9)
    }

    /// There is no lossless MP3, and encoding one at the highest setting under
    /// that name would be a lossy file wearing the word the caller asked to
    /// avoid.
    @Test("a lossless request is refused rather than silently encoded")
    func losslessIsRefused() async throws {
        guard let source = await fixture("mp3-lossless.wav", {
            try await FixtureLibrary.shared.wav(
                named: "mp3-lossless.wav", seconds: 1,
                audio: .noise(amplitude: 0.4), sampleRate: 44_100, channels: 2
            )
        }) else { return }
        let destination = await scratch("mp3-lossless-out.mp3")

        await #expect(throws: LatheError.self) {
            try await encoder.encode(source: source, to: destination, quality: .lossless)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Sample rates

    /// MP3 is defined for nine sample rates and no others. Handing LAME one it
    /// cannot encode makes it refuse at initialisation with a number rather than
    /// a reason.
    @Test("an unsupported sample rate is moved to the nearest one MP3 defines")
    func unsupportedRatesAreMapped() {
        #expect(MP3Encoder.supportedSampleRate(nearest: 44_100) == 44_100)
        #expect(MP3Encoder.supportedSampleRate(nearest: 48_000) == 48_000)
        // Rounds UP where it can: downsampling discards content nobody asked to
        // lose.
        #expect(MP3Encoder.supportedSampleRate(nearest: 44_000) == 44_100)
        #expect(MP3Encoder.supportedSampleRate(nearest: 20_000) == 22_050)
        // Above everything MP3 defines, 44.1 kHz is the sensible ceiling.
        #expect(MP3Encoder.supportedSampleRate(nearest: 96_000) == 44_100)
        #expect(MP3Encoder.supportedSampleRate(nearest: 192_000) == 44_100)
    }

    // MARK: - The buffer rule

    /// LAME's documented worst case for one call is `1.25 * frames + 7200`, and
    /// it is a worst case rather than an estimate: the encoder buffers across
    /// calls and can return far more than one frame at once. A buffer sized to
    /// the input works on ordinary audio and corrupts the output on the unusual
    /// frame.
    @Test("the output buffer follows LAME's worst case, not the input size")
    func outputCapacityIsTheDocumentedWorstCase() {
        #expect(LAMEFlags.outputCapacity(frames: 0) == 7_200)
        #expect(LAMEFlags.outputCapacity(frames: 1_152) == Int(1_152 * 1.25) + 7_200)
        // Always larger than the input it is encoding, at every size.
        for frames in [1, 100, 1_152, 8_192, 65_536] {
            #expect(LAMEFlags.outputCapacity(frames: frames) > frames)
        }
    }

    // MARK: - Refusals

    @Test("an encode cannot overwrite the file it is reading")
    func inPlaceIsRefused() async throws {
        guard let source = await fixture("mp3-inplace.wav", {
            try await FixtureLibrary.shared.wav(
                named: "mp3-inplace.wav", seconds: 1,
                audio: .noise(amplitude: 0.4), sampleRate: 44_100, channels: 2
            )
        }) else { return }

        await #expect(throws: LatheError.self) {
            try await encoder.encode(source: source, to: source)
        }
    }

    @Test("a file with no audio track is refused by name")
    func noAudioTrackIsRefused() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp3-noaudio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let text = directory.appendingPathComponent("notes.txt")
        try Data("not audio".utf8).write(to: text)

        await #expect(throws: LatheError.self) {
            try await encoder.encode(source: text, to: directory.appendingPathComponent("o.mp3"))
        }
    }

    /// A failure must leave whatever was at the destination alone.
    @Test("a failed encode leaves an existing destination untouched")
    func failureLeavesTheDestination() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp3-atomic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let bogus = directory.appendingPathComponent("in.txt")
        try Data("not audio".utf8).write(to: bogus)
        let destination = directory.appendingPathComponent("out.mp3")
        let existing = Data("a previous file that must survive".utf8)
        try existing.write(to: destination)

        await #expect(throws: LatheError.self) {
            try await encoder.encode(source: bogus, to: destination)
        }
        #expect(try Data(contentsOf: destination) == existing)
    }

    // MARK: - Helpers

    private func scratch(_ name: String) async -> URL {
        let url = await FixtureLibrary.shared.scratchURL(named: name)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    private func fixture(_ name: String, _ make: () async throws -> URL) async -> URL? {
        do {
            return try await make()
        } catch {
            withKnownIssue("could not generate the fixture \"\(name)\": \(error)") {
                Issue.record("fixture generation failed")
            }
            return nil
        }
    }
}
