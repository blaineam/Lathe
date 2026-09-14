import AVFoundation
import CoreMedia
import Foundation
import LatheCore
import LatheFixtures
import Testing
import VideoToolbox

@testable import LatheVideo

/// Tests for the video transcoder.
///
/// Every clip is synthesised at run time; no binary media is committed. Two
/// fixture choices are load-bearing rather than incidental:
///
/// - The **noise** clip exists because a flat-colour clip compresses to almost
///   nothing at every quality setting. A "lower quality makes a smaller file"
///   test written against a flat fixture passes with the quality knob
///   disconnected, which makes it worse than no test at all.
/// - The clip is **160x120 or 320x240, not square**, because a square source
///   hides every aspect-ratio and transpose bug there is.
///
/// Serialized because each case runs a real hardware encode; overlapping them
/// makes the timings meaningless and the machine noisy, not the results wrong.
@Suite("Video transcoding", .serialized)
struct VideoTranscoderTests {

    private let transcoder = VideoTranscoder()
    private static let noiseSize = PixelSize(width: 320, height: 240)
    private static let flatSize = PixelSize(width: 160, height: 120)

    // MARK: - Fixtures

    /// Pseudo-random pixels that change every frame: compressible, but only in
    /// proportion to how hard the encoder is asked to try.
    private func noiseMovie() async -> URL? {
        await fixture("transcode-noise.mov") {
            try await FixtureLibrary.shared.movie(
                named: "transcode-noise.mov", size: Self.noiseSize, frameRate: 24, seconds: 2,
                noise: true
            )
        }
    }

    private func toneMovie() async -> URL? {
        await fixture("transcode-tone.mov") {
            try await FixtureLibrary.shared.movie(
                named: "transcode-tone.mov", size: Self.flatSize, frameRate: 24, seconds: 2,
                colour: .black, rightHalf: .white,
                audio: .tone(hertz: 440, amplitude: 0.5)
            )
        }
    }

    private func silentMovie() async -> URL? {
        await fixture("transcode-silent.mov") {
            try await FixtureLibrary.shared.movie(
                named: "transcode-silent.mov", size: Self.flatSize, frameRate: 24, seconds: 2,
                colour: .black, rightHalf: .white
            )
        }
    }

    // MARK: - Quality

    /// The headline claim: the quality knob is connected to something.
    @Test("a lower quality target produces a smaller file")
    func lowerQualityIsSmaller() async throws {
        guard let source = await noiseMovie() else { return }
        let low = await FixtureLibrary.shared.scratchURL(named: "quality-low.mov")
        let high = await FixtureLibrary.shared.scratchURL(named: "quality-high.mov")

        let cheap = try await transcoder.transcode(
            source: source, to: low, codec: .hevc, quality: .quality(0.15)
        )
        let dear = try await transcoder.transcode(
            source: source, to: high, codec: .hevc, quality: .quality(0.9)
        )

        #expect(cheap.outputByteCount > 0)
        #expect(cheap.outputByteCount < dear.outputByteCount, Comment(rawValue:
            "quality 0.15 produced \(cheap.outputByteCount) bytes, "
                + "quality 0.9 produced \(dear.outputByteCount)"))
        // The reported counts are the files', not a guess.
        #expect(Self.byteCount(of: low) == cheap.outputByteCount)
        #expect(Self.byteCount(of: high) == dear.outputByteCount)
    }

    /// Recompressing noise at a low quality should also beat the source, which is
    /// the actual reason anybody runs this.
    @Test("a low-quality transcode is smaller than its source")
    func outputBeatsTheSource() async throws {
        guard let source = await noiseMovie() else { return }
        let output = await FixtureLibrary.shared.scratchURL(named: "smaller-than-source.mov")
        let result = try await transcoder.transcode(
            source: source, to: output, codec: .hevc, quality: .quality(0.2)
        )
        #expect(result.inputByteCount > 0)
        #expect(result.outputByteCount < result.inputByteCount,
                "\(result.inputByteCount) → \(result.outputByteCount) bytes")
    }

    @Test("the result says which rate control actually ran")
    func rateControlIsReported() async throws {
        guard let source = await silentMovie() else { return }

        let constant = try await transcoder.transcode(
            source: source,
            to: await FixtureLibrary.shared.scratchURL(named: "rate-quality.mov"),
            quality: .quality(0.5)
        )
        #expect(constant.rateControl == .constantQuality(0.5))

        let bitrate = try await transcoder.transcode(
            source: source,
            to: await FixtureLibrary.shared.scratchURL(named: "rate-bitrate.mov"),
            quality: .averageBitrate(200_000)
        )
        #expect(bitrate.rateControl == .averageBitrate(200_000))

        // `ConstantQualityFactor` is newer than this package's floor, so either
        // answer is correct — the point is that the *reported* one is the one
        // that ran, rather than the one that was asked for.
        let factor = try await transcoder.transcode(
            source: source,
            to: await FixtureLibrary.shared.scratchURL(named: "rate-factor.mov"),
            quality: .constantQualityFactor(0.4)
        )
        #expect(
            factor.rateControl == .constantQualityFactor(0.4)
                || factor.rateControl == .constantQuality(0.4),
            "unexpected fallback"
        )
    }

    /// `.lossless` means "re-encode nothing", which an encoder cannot honour.
    /// It is refused rather than quietly turned into quality 1.0 — and refused
    /// before anything is created, so no file appears.
    @Test("lossless is refused, not reinterpreted")
    func losslessIsRefused() async throws {
        guard let source = await silentMovie() else { return }
        let output = await FixtureLibrary.shared.scratchURL(named: "lossless.mov")
        try? FileManager.default.removeItem(at: output)

        do {
            _ = try await transcoder.transcode(source: source, to: output, quality: .lossless)
            Issue.record("expected a refusal")
        } catch let error as LatheError {
            guard case let .invalidConfiguration(reason) = error else {
                Issue.record("expected .invalidConfiguration, got \(error)")
                return
            }
            #expect(reason.contains("lossless"))
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: - Fidelity of everything that is not pixels

    @Test("the output's duration matches the input's")
    func durationSurvives() async throws {
        guard let source = await toneMovie() else { return }
        let output = await FixtureLibrary.shared.scratchURL(named: "duration.mov")
        let result = try await transcoder.transcode(source: source, to: output)

        let input = try await MediaProbe().probe(url: source)
        let written = try await MediaProbe().probe(url: output)
        #expect(abs(written.duration - input.duration) < 0.1,
                "\(input.duration)s in, \(written.duration)s out")
        #expect(abs(result.duration - input.duration) < 0.1)
        #expect(result.frameCount == 48)   // 2 s at 24 fps, by construction
    }

    @Test("audio survives, and is passed through rather than re-encoded")
    func audioIsPassedThrough() async throws {
        guard let source = await toneMovie() else { return }
        let output = await FixtureLibrary.shared.scratchURL(named: "audio-passthrough.mov")
        let result = try await transcoder.transcode(source: source, to: output)

        #expect(result.audio == .passedThrough)
        let written = try await MediaProbe().probe(url: output)
        #expect(written.hasAudioTrack)
        #expect(written.audioTracks.first?.codecName == "aac")
        #expect(abs((written.audioTracks.first?.duration ?? 0) - 2) < 0.2)
    }

    @Test("audio can be re-encoded when the caller asks for it")
    func audioCanBeReencoded() async throws {
        guard let source = await toneMovie() else { return }
        let output = await FixtureLibrary.shared.scratchURL(named: "audio-reencoded.mov")
        let result = try await transcoder.transcode(
            source: source, to: output, passthroughAudio: false
        )
        #expect(result.audio == .reencodedAAC)
        let written = try await MediaProbe().probe(url: output)
        #expect(written.hasAudioTrack)
    }

    @Test("a video with no audio reports no audio, rather than inventing a track")
    func silentStaysSilent() async throws {
        guard let source = await silentMovie() else { return }
        let output = await FixtureLibrary.shared.scratchURL(named: "audio-none.mov")
        let result = try await transcoder.transcode(source: source, to: output)
        #expect(result.audio == .none)
        #expect(try await !MediaProbe().probe(url: output).hasAudioTrack)
    }

    /// A portrait phone video is stored landscape with a quarter turn in the
    /// track matrix. Losing that matrix is how a library full of sideways videos
    /// happens, and it looks like a success from every angle except the user's.
    @Test("the track's rotation survives")
    func rotationSurvives() async throws {
        guard let source = await fixture("transcode-rotated.mov", {
            try await FixtureLibrary.shared.movie(
                named: "transcode-rotated.mov", size: Self.flatSize, frameRate: 24, seconds: 1,
                colour: .black, rightHalf: .white, rotationDegrees: 90
            )
        }) else { return }

        let output = await FixtureLibrary.shared.scratchURL(named: "rotated.mov")
        _ = try await transcoder.transcode(source: source, to: output)

        let input = try await MediaProbe().probe(url: source)
        let written = try await MediaProbe().probe(url: output)
        // The stored axes are unchanged and the displayed ones are transposed —
        // which is exactly what the source does.
        #expect(written.primaryVideoTrack?.codedSize == input.primaryVideoTrack?.codedSize)
        #expect(written.primaryVideoTrack?.displaySize == input.primaryVideoTrack?.displaySize)
        #expect(written.primaryVideoTrack?.displaySize
            == PixelSize(width: Self.flatSize.height, height: Self.flatSize.width))
    }

    // MARK: - Metadata

    @Test("metadata policy: preserve keeps the date and the location")
    func metadataPreserved() async throws {
        guard let source = await metadataMovie() else { return }
        let output = await FixtureLibrary.shared.scratchURL(named: "metadata-preserve.mov")
        _ = try await transcoder.transcode(source: source, to: output, metadata: .preserveAll)

        let identifiers = await Self.metadataIdentifiers(of: output)
        #expect(identifiers.contains { $0.contains("creationdate") })
        #expect(identifiers.contains { $0.contains("location") })
    }

    @Test("metadata policy: stripping the location keeps everything else")
    func metadataLocationStripped() async throws {
        guard let source = await metadataMovie() else { return }
        let output = await FixtureLibrary.shared.scratchURL(named: "metadata-strip-gps.mov")
        _ = try await transcoder.transcode(source: source, to: output, metadata: .stripLocation)

        let identifiers = await Self.metadataIdentifiers(of: output)
        #expect(!identifiers.contains { $0.contains("location") })
        #expect(identifiers.contains { $0.contains("creationdate") })
    }

    @Test("metadata policy: stripping everything leaves nothing to strip")
    func metadataStrippedEntirely() async throws {
        guard let source = await metadataMovie() else { return }
        let output = await FixtureLibrary.shared.scratchURL(named: "metadata-strip-all.mov")
        _ = try await transcoder.transcode(source: source, to: output, metadata: .stripAll)

        let identifiers = await Self.metadataIdentifiers(of: output)
        #expect(!identifiers.contains { $0.contains("location") })
        #expect(!identifiers.contains { $0.contains("creationdate") })
    }

    /// The normalisation the policy is applied through, asserted directly: two
    /// keyspaces, one namespace.
    @Test("metadata keys normalise into one namespace")
    func metadataKeysNormalise() {
        let key = MetadataKey("qt.com.apple.quicktime.location.ISO6709")
        #expect(VideoMetadata.metadataClass(of: key) == .gps)
        #expect(VideoMetadata.metadataClass(of: MetadataKey("qt.creationDate")) == .timestamps)
        #expect(VideoMetadata.metadataClass(of: MetadataKey("qt.com.apple.quicktime.make"))
            == .deviceIdentity)
        #expect(VideoMetadata.metadataClass(of: MetadataKey("qt.something.unheard.of")) == nil)
    }

    // MARK: - Resizing

    @Test("a resize target larger than the source does not enlarge it")
    func resizeNeverEnlarges() async throws {
        guard let source = await silentMovie() else { return }
        let output = await FixtureLibrary.shared.scratchURL(named: "resize-huge.mov")
        let result = try await transcoder.transcode(
            source: source, to: output, resize: .longestSide(4000)
        )
        #expect(result.pixelSize == Self.flatSize)
        let written = try await MediaProbe().probe(url: output)
        #expect(written.primaryVideoTrack?.codedSize == Self.flatSize)
    }

    @Test("a smaller resize target is honoured, aspect preserved")
    func resizeDownscales() async throws {
        guard let source = await silentMovie() else { return }
        let output = await FixtureLibrary.shared.scratchURL(named: "resize-small.mov")
        let result = try await transcoder.transcode(
            source: source, to: output, resize: .longestSide(80)
        )
        #expect(result.pixelSize == PixelSize(width: 80, height: 60))
        let written = try await MediaProbe().probe(url: output)
        #expect(written.primaryVideoTrack?.codedSize == PixelSize(width: 80, height: 60))
        // 4:3 in, 4:3 out, as arithmetic rather than by eye.
        #expect(80 * Self.flatSize.height == 60 * Self.flatSize.width)
    }

    /// 4:2:0 chroma cannot represent an odd dimension, so the resolved size is
    /// rounded down to even — and the result reports what was encoded, not what
    /// was asked for.
    @Test("odd resolved sizes are rounded down to even ones")
    func oddSizesAreEvened() {
        #expect(VideoTranscoder.evenDimensions(PixelSize(width: 101, height: 57))
            == PixelSize(width: 100, height: 56))
        #expect(VideoTranscoder.evenDimensions(PixelSize(width: 1, height: 1))
            == PixelSize(width: 2, height: 2))
        #expect(VideoTranscoder.evenDimensions(PixelSize(width: 320, height: 240))
            == PixelSize(width: 320, height: 240))
    }

    // MARK: - Progress and cancellation

    @Test("progress comes from real sample times, not from a ramp")
    func progressIsMeasured() async throws {
        guard let source = await noiseMovie() else { return }
        let output = await FixtureLibrary.shared.scratchURL(named: "progress.mov")
        let recorder = Recorder()

        _ = try await transcoder.transcode(
            VideoTranscodeRequest(source: source, destination: output, quality: .quality(0.4)),
            progress: ProgressHandle(
                sink: ObservingProgressSink { recorder.append($0) }, throttle: .unthrottled
            )
        )

        let samples = recorder.samples
        #expect(samples.count > 5, "only \(samples.count) samples for 48 frames")
        let fractions = samples.compactMap(\.fraction)
        #expect(fractions == fractions.sorted(), "progress went backwards")
        #expect(fractions.first ?? 1 < 0.25)
        #expect(fractions.last == 1)
        // Unit indices are frame indices, and they reach the frame count.
        #expect(samples.contains { $0.stage == "encode" })
        #expect(samples.last?.unitIndex == samples.last?.unitCount)
    }

    /// Cancellation has to actually stop the work *and* leave nothing behind —
    /// no output, and no temporary file beside it either.
    @Test("cancellation stops the encode and leaves no file at the destination")
    func cancellationLeavesNothing() async throws {
        guard let source = await noiseMovie() else { return }
        let output = await FixtureLibrary.shared.scratchURL(named: "cancelled.mov")
        try? FileManager.default.removeItem(at: output)

        let recorder = Recorder()
        let sink = ClosureProgressSink { sample in
            recorder.append(sample)
            return recorder.count < 4    // stop on the fourth frame
        }

        do {
            _ = try await transcoder.transcode(
                VideoTranscodeRequest(source: source, destination: output),
                progress: ProgressHandle(sink: sink, throttle: .unthrottled)
            )
            Issue.record("expected the transcode to be cancelled")
        } catch let error as LatheError {
            #expect(error.isCancellation, "expected cancellation, got \(error)")
            if case let .cancelled(unit) = error {
                #expect((unit ?? 0) < 10, "stopped at frame \(unit as Any), which is not early")
            }
        }

        #expect(!FileManager.default.fileExists(atPath: output.path))
        // And no half-written scratch file beside it. The temporary file is a
        // sibling by design — a move across volumes is a copy — so a leak would
        // land right here.
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: output.deletingLastPathComponent().path
        ))?.filter { $0.hasPrefix(".lathe-") } ?? []
        #expect(leftovers.isEmpty, "left behind \(leftovers)")
    }

    @Test("cancelling the enclosing task cancels the transcode")
    func taskCancellationPropagates() async throws {
        guard let source = await noiseMovie() else { return }
        let output = await FixtureLibrary.shared.scratchURL(named: "task-cancelled.mov")
        try? FileManager.default.removeItem(at: output)

        let started = Recorder()
        let task = Task {
            try await transcoder.transcode(
                VideoTranscodeRequest(source: source, destination: output),
                progress: ProgressHandle(
                    sink: ObservingProgressSink { started.append($0) }, throttle: .unthrottled
                )
            )
        }
        // Give the encode enough of a head start that cancelling it means
        // something, then pull the rug.
        while started.count < 2 { await Task.yield() }
        task.cancel()

        await #expect(throws: LatheError.self) { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: - What the encoder actually did

    /// The hardware flag has to be *read*, not assumed. This reads the same
    /// property independently, through VideoToolbox directly, and requires the
    /// two to agree — so a hard-coded `true` would fail on a machine with no
    /// hardware encoder, and a hard-coded `false` fails here.
    @Test("the hardware-acceleration flag reflects the session, not an assumption")
    func hardwareFlagIsRead() async throws {
        guard let source = await silentMovie() else { return }
        let output = await FixtureLibrary.shared.scratchURL(named: "hardware.mov")
        let result = try await transcoder.transcode(source: source, to: output, codec: .hevc)

        #expect(result.usedHardwareAcceleration == Self.hardwareEncoderExists(for: .hevc, size: Self.flatSize))
    }

    /// B-frames are on by default here, and the flag is read back off the
    /// session rather than echoed from the request.
    @Test("B-frames are allowed by default and can be turned off", arguments: [
        BFramePolicy.allow, BFramePolicy.disallow,
    ])
    func frameReorderingIsReported(_ policy: BFramePolicy) async throws {
        guard let source = await silentMovie() else { return }
        let output = await FixtureLibrary.shared.scratchURL(
            named: "bframes-\(policy == .allow ? "on" : "off").mov"
        )
        let result = try await transcoder.transcode(source: source, to: output, bFrames: policy)
        #expect(result.frameReordering == (policy == .allow))
        #expect(VideoTranscodeRequest(source: source, destination: output).bFrames == .allow)
    }

    // MARK: - Refusals

    @Test("an extension that names no container is refused")
    func unknownContainerIsRefused() async throws {
        guard let source = await silentMovie() else { return }
        let output = await FixtureLibrary.shared.scratchURL(named: "unsupported.mkv")
        await #expect(throws: LatheError.self) {
            _ = try await transcoder.transcode(source: source, to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("containers are named by extension", arguments: [
        ("clip.mov", AVFileType.mov), ("clip.MP4", .mp4), ("clip.m4v", .m4v),
    ])
    func containerMapping(_ name: String, _ expected: AVFileType) throws {
        #expect(try VideoTranscoder.fileType(for: URL(fileURLWithPath: "/tmp/\(name)")) == expected)
    }

    @Test("transcoding onto the source itself is refused")
    func inPlaceIsRefused() async throws {
        guard let source = await silentMovie() else { return }
        await #expect(throws: LatheError.self) {
            _ = try await transcoder.transcode(source: source, to: source)
        }
    }

    @Test("a file that is not media is refused")
    func notMediaIsRefused() async throws {
        guard let source = await fixture("transcode-not-media.mov", {
            try await FixtureLibrary.shared.notMedia(named: "transcode-not-media.mov")
        }) else { return }
        let output = await FixtureLibrary.shared.scratchURL(named: "not-media-out.mov")
        await #expect(throws: LatheError.self) {
            _ = try await transcoder.transcode(source: source, to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    // MARK: - Helpers

    private func metadataMovie() async -> URL? {
        await fixture("transcode-metadata.mov") {
            try await FixtureLibrary.shared.movie(
                named: "transcode-metadata.mov", size: Self.flatSize, frameRate: 24, seconds: 1,
                colour: .black, rightHalf: .white,
                creationDate: Date(timeIntervalSince1970: 1_000_000_000),
                location: "+37.7749-122.4194/"
            )
        }
    }

    private static func metadataIdentifiers(of url: URL) async -> [String] {
        let asset = AVURLAsset(url: url)
        let container = (try? await asset.load(.metadata)) ?? []
        let common = (try? await asset.load(.commonMetadata)) ?? []
        return (container + common).compactMap { $0.identifier?.rawValue.lowercased() }
    }

    /// Asks VideoToolbox directly, the same way the encoder does, so the
    /// assertion above compares two independent reads rather than one value with
    /// itself.
    private static func hardwareEncoderExists(for codec: VideoCodec, size: PixelSize) -> Bool {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(size.width), height: Int32(size.height),
            codecType: codec.codecType,
            encoderSpecification: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            ] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session
        )
        guard status == noErr, let session else { return false }
        defer { VTCompressionSessionInvalidate(session) }

        var value: CFTypeRef?
        let read = withUnsafeMutablePointer(to: &value) { pointer in
            VTSessionCopyProperty(
                session,
                key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                allocator: kCFAllocatorDefault,
                valueOut: pointer
            )
        }
        guard read == noErr, let number = value as? NSNumber else { return false }
        return number.boolValue
    }

    private static func byteCount(of url: URL) -> UInt64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0.map(UInt64.init) }
    }

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

/// Collects progress samples from the encoder's thread.
private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LatheProgress] = []

    func append(_ sample: LatheProgress) {
        lock.lock()
        storage.append(sample)
        lock.unlock()
    }

    var samples: [LatheProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage.count
    }
}
