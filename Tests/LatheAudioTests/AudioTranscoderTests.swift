import AudioToolbox
import AVFoundation
import Foundation
import LatheCore
import LatheFixtures
import Testing

@testable import LatheAudio

/// Tests for the audio transcoder.
///
/// Serialised because every test encodes media. Every fixture is white noise
/// rather than a tone wherever a size is asserted — see ``FixtureAudio/noise(amplitude:)``
/// for why a sine wave makes a size assertion meaningless.
@Suite("Audio transcoding", .serialized)
struct AudioTranscoderTests {

    private let transcoder = AudioTranscoder()
    private let inspector = AudioInspector()

    // MARK: - The win

    /// The case re-encoding is *for*: a lossless source, where the bits thrown
    /// away have not been thrown away once already.
    @Test("a lossless source shrinks by a lot")
    func losslessSourceShrinks() async throws {
        guard let wav = await fixture("tx-lossless.wav", {
            try await FixtureLibrary.shared.wav(
                named: "tx-lossless.wav", seconds: 4,
                audio: .noise(amplitude: 0.4), sampleRate: 44_100, channels: 2
            )
        }) else { return }
        let destination = await scratch("tx-lossless-out.m4a")

        let result = try await transcoder.transcode(
            source: wav, to: destination, codec: .aac, quality: .quality(0.5)
        )

        #expect(result.outcome == .transcoded)
        #expect(result.output == destination)
        #expect(result.source.codecName == "pcm")
        #expect(result.source.isLossless)
        #expect(result.destination?.codecName == "aac")
        #expect(result.destination?.isLossless == false)

        // 16-bit stereo PCM at 44.1 kHz is 1,411 kbit/s; quality 0.5 asks for
        // 120. A quarter of the original is a deliberately loose floor — the
        // point is that this is a *large* win, not a rounding one.
        let ratio = Double(result.outputByteCount) / Double(result.inputByteCount)
        #expect(ratio < 0.25)
        #expect(result.outputByteCount > 0)
        #expect(FileManager.default.fileExists(atPath: destination.path))
    }

    /// Apple Lossless, where the codec's promise is the whole point.
    @Test("a lossless source can be made smaller without becoming lossy")
    func losslessToLossless() async throws {
        guard let wav = await fixture("tx-alac.wav", {
            try await FixtureLibrary.shared.wav(
                named: "tx-alac.wav", seconds: 3,
                audio: .tone(hertz: 440, amplitude: 0.5), sampleRate: 44_100, channels: 1
            )
        }) else { return }
        let destination = await scratch("tx-alac-out.m4a")

        let result = try await transcoder.transcode(
            source: wav, to: destination, codec: .appleLossless, quality: .lossless
        )

        #expect(result.outcome == .transcoded)
        #expect(result.destination?.codecName == "alac")
        #expect(result.destination?.isLossless == true)
        #expect(result.outputByteCount < result.inputByteCount)
    }

    // MARK: - The trap

    /// The headline rule. A 128 kbit/s source asked to become a 128 kbit/s
    /// output is two generations of loss for no saving, and is refused.
    @Test("an already-lossy source at a similar bitrate is skipped, and nothing is written")
    func lossySourceAtSimilarBitrateIsSkipped() async throws {
        guard let aac = await fixture("tx-lossy-128.m4a", {
            try await FixtureLibrary.shared.aacFile(
                named: "tx-lossy-128.m4a", seconds: 3, bitsPerSecond: 128_000
            )
        }) else { return }
        let destination = await scratch("tx-lossy-128-out.m4a")
        try? FileManager.default.removeItem(at: destination)

        let result = try await transcoder.transcode(
            source: aac, to: destination, codec: .aac, quality: .averageBitrate(128_000)
        )

        guard case let .skipped(reason) = result.outcome else {
            Issue.record("expected a skip, got \(result.outcome)")
            return
        }
        guard case let .lossySourceWithoutMeaningfulSavings(source, target, fraction) = reason else {
            Issue.record("expected the savings rule to fire, got \(reason)")
            return
        }
        #expect(target == 128_000)
        #expect(source > 100_000)
        #expect(fraction == 0.75)

        // The load-bearing half: a refusal leaves *nothing* behind, and says so
        // by not handing back a URL.
        #expect(result.output == nil)
        #expect(result.destination == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        // ...and the source's own facts are still reported, so a caller can
        // decide differently without probing again.
        #expect(result.source.codecName == "aac")
        #expect(result.source.isLossy)
    }

    @Test("a big enough drop in bitrate is allowed through")
    func lossySourceWithRealSavingsProceeds() async throws {
        guard let aac = await fixture("tx-lossy-192.m4a", {
            try await FixtureLibrary.shared.aacFile(
                named: "tx-lossy-192.m4a", seconds: 3, bitsPerSecond: 192_000
            )
        }) else { return }
        let destination = await scratch("tx-lossy-192-out.m4a")

        let result = try await transcoder.transcode(
            source: aac, to: destination, codec: .aac, quality: .averageBitrate(64_000)
        )

        #expect(result.outcome == .transcoded)
        #expect(result.outputByteCount < result.inputByteCount)
    }

    @Test("the rule can be turned off, and turned all the way up")
    func ruleIsOverridable() async throws {
        guard let aac = await fixture("tx-rule.m4a", {
            try await FixtureLibrary.shared.aacFile(
                named: "tx-rule.m4a", seconds: 2, bitsPerSecond: 128_000
            )
        }) else { return }

        // `.never`: no lossy source is ever re-encoded, however large the saving.
        let refused = try await transcoder.transcode(
            source: aac, to: await scratch("tx-rule-never.m4a"),
            quality: .averageBitrate(32_000), lossySources: .never
        )
        #expect(refused.outcome == .skipped(.lossySourceRefusedByRule))

        // `.allow`: the savings rule does not fire at all. (The output may still
        // be discarded for coming out *larger*, which is a different guard.)
        let allowed = try await transcoder.transcode(
            source: aac, to: await scratch("tx-rule-allow.m4a"),
            quality: .averageBitrate(128_000), lossySources: .allow
        )
        if case let .skipped(reason) = allowed.outcome {
            if case .lossySourceWithoutMeaningfulSavings = reason {
                Issue.record(".allow should bypass the savings rule")
            }
        }
    }

    /// Lossy to lossless is the expensive mistake: ALAC cannot restore what the
    /// lossy encoder discarded, so it buys a much larger file that sounds
    /// identical.
    @Test("a lossy source is not re-encoded to a lossless target")
    func lossyToLosslessIsRefused() async throws {
        guard let aac = await fixture("tx-lossy-alac.m4a", {
            try await FixtureLibrary.shared.aacFile(named: "tx-lossy-alac.m4a", seconds: 2)
        }) else { return }
        let destination = await scratch("tx-lossy-alac-out.m4a")
        try? FileManager.default.removeItem(at: destination)

        let result = try await transcoder.transcode(
            source: aac, to: destination, codec: .appleLossless, quality: .lossless
        )

        #expect(result.outcome == .skipped(.losslessTargetForLossySource(sourceCodec: "aac")))
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Never upsample

    /// Two halves of one rule: neither the sample rate nor the channel count may
    /// exceed the source's, whatever was asked for. Both grow the file by
    /// exactly the amount of information they do not add.
    @Test("a 22 kHz mono source does not become 48 kHz stereo")
    func neverUpsamples() async throws {
        guard let wav = await fixture("tx-narrow.wav", {
            try await FixtureLibrary.shared.wav(
                named: "tx-narrow.wav", seconds: 2,
                audio: .noise(amplitude: 0.4), sampleRate: 22_050, channels: 1
            )
        }) else { return }
        let destination = await scratch("tx-narrow-out.m4a")

        let result = try await transcoder.transcode(
            source: wav, to: destination,
            quality: .quality(0.5),
            sampleRate: 48_000,                  // asked for, and refused
            channels: .atMost(6)                 // likewise
        )

        #expect(result.outcome == .transcoded)
        let written = try #require(result.destination)
        #expect(written.sampleRate <= 22_050)
        #expect(written.channelCount == 1)
        #expect(result.channels == .preserved(channels: 1))
    }

    /// Pure arithmetic, so it covers the combinations a fixture would be
    /// expensive for.
    @Test("the channel policy never resolves upward")
    func channelPolicyNeverGrows() {
        #expect(ChannelPolicy.preserve.resolve(sourceChannels: 1) == 1)
        #expect(ChannelPolicy.downmixToStereo.resolve(sourceChannels: 1) == 1)
        #expect(ChannelPolicy.atMost(8).resolve(sourceChannels: 2) == 2)
        #expect(ChannelPolicy.atMost(1).resolve(sourceChannels: 6) == 1)

        // A multi-channel source with no layout cannot be preserved by any
        // encoder, and the case that says so is its own.
        #expect(AudioTranscoder.resolveChannels(.preserve, sourceChannels: 6, hasLayout: true)
            == .preserved(channels: 6))
        #expect(AudioTranscoder.resolveChannels(.preserve, sourceChannels: 6, hasLayout: false)
            == .downmixedForWantOfALayout(from: 6, to: 2))
        // 7.1 to 5.1 is a mixing decision this package does not make; it becomes
        // the one downmix every decoder agrees on.
        #expect(AudioTranscoder.resolveChannels(.atMost(6), sourceChannels: 8, hasLayout: true)
            == .downmixed(from: 8, to: 2))
    }

    // MARK: - Multi-channel

    /// The iOS Simulator's AAC encoder refuses six channels (AVFoundation
    /// -11800), so only the downmix half can run there.
    @Test("5.1 is preserved by default, and downmixed only when asked",
          .disabled(if: audioRunningInSimulator, "the simulator's AAC encoder has no 5.1 layout"))
    func multichannelIsPreservedUnlessAsked() async throws {
        guard let surround = await fixture("tx-surround.caf", {
            try await FixtureLibrary.shared.multichannelPCM(
                named: "tx-surround.caf", seconds: 1,
                audio: .noise(amplitude: 0.3), channels: 6
            )
        }) else { return }

        let preserved = try await transcoder.transcode(
            source: surround, to: await scratch("tx-surround-6.m4a"), quality: .quality(0.4)
        )
        #expect(preserved.outcome == .transcoded)
        #expect(preserved.channels == .preserved(channels: 6))
        #expect(preserved.destination?.channelCount == 6)

        let downmixed = try await transcoder.transcode(
            source: surround, to: await scratch("tx-surround-2.m4a"),
            quality: .quality(0.4), channels: .downmixToStereo
        )
        #expect(downmixed.outcome == .transcoded)
        #expect(downmixed.channels == .downmixed(from: 6, to: 2))
        #expect(downmixed.destination?.channelCount == 2)
        // And the downmix is the smaller file, which is the reason to ask.
        #expect(downmixed.outputByteCount < preserved.outputByteCount)
    }

    // MARK: - Duration

    @Test("the duration survives the transcode")
    func durationSurvives() async throws {
        guard let wav = await fixture("tx-duration.wav", {
            try await FixtureLibrary.shared.wav(
                named: "tx-duration.wav", seconds: 5, audio: .noise(amplitude: 0.3)
            )
        }) else { return }
        let destination = await scratch("tx-duration-out.m4a")

        let result = try await transcoder.transcode(source: wav, to: destination)
        #expect(result.outcome == .transcoded)

        let written = try await inspector.duration(of: destination)
        // The tolerance is for AAC's encoder delay, which pads the front of the
        // track by about 2,048 samples — a twentieth of a second at 44.1 kHz.
        #expect(abs(written - 5) < 0.2)
        #expect(abs((result.destination?.duration ?? 0) - 5) < 0.2)
    }

    // MARK: - Metadata and artwork

    @Test("tags and cover art survive a policy that preserves them")
    func metadataSurvives() async throws {
        guard let tagged = await fixture("tx-tagged.m4a", {
            try await FixtureLibrary.shared.aacFile(
                named: "tx-tagged.m4a", seconds: 2, bitsPerSecond: 192_000,
                title: "A Known Title", artist: "A Known Artist", album: "A Known Album",
                artwork: true
            )
        }) else { return }
        let destination = await scratch("tx-tagged-out.m4a")

        let result = try await transcoder.transcode(
            source: tagged, to: destination,
            quality: .averageBitrate(64_000), metadata: .preserveAll
        )

        #expect(result.outcome == .transcoded)
        #expect(result.carriedArtwork)
        #expect(result.metadataItemsWritten >= 4)

        // Read the written file rather than trust the count: the failure this
        // guards against is items that are *accepted* by the writer and dropped
        // at mux time because the destination's keyspace had nowhere for them.
        let info = try await inspector.inspect(destination)
        #expect(info.hasArtwork)

        let written = AVURLAsset(url: destination)
        let common = try await written.load(.commonMetadata)
        #expect(try await Self.string(from: common, key: .commonKeyTitle) == "A Known Title")
        #expect(try await Self.string(from: common, key: .commonKeyArtist) == "A Known Artist")
        #expect(try await Self.string(from: common, key: .commonKeyAlbumName) == "A Known Album")
    }

    @Test("stripAll removes everything, cover art included")
    func stripAllRemovesEverything() async throws {
        guard let tagged = await fixture("tx-strip.m4a", {
            try await FixtureLibrary.shared.aacFile(
                named: "tx-strip.m4a", seconds: 2, bitsPerSecond: 192_000,
                title: "Gone", artist: "Gone", artwork: true
            )
        }) else { return }
        let destination = await scratch("tx-strip-out.m4a")

        let result = try await transcoder.transcode(
            source: tagged, to: destination,
            quality: .averageBitrate(64_000), metadata: .stripAll
        )

        #expect(result.outcome == .transcoded)
        #expect(!result.carriedArtwork)
        #expect(result.metadataItemsWritten == 0)
        #expect(try await inspector.inspect(destination).hasArtwork == false)
    }

    /// The documented consequence of audio artwork being classified as
    /// ``MetadataClass/thumbnails``: that one strip removes the cover, and
    /// nothing else does.
    @Test("a targeted strip of thumbnails takes the cover art and leaves the title")
    func strippingThumbnailsTakesTheCover() async throws {
        guard let tagged = await fixture("tx-cover.m4a", {
            try await FixtureLibrary.shared.aacFile(
                named: "tx-cover.m4a", seconds: 2, bitsPerSecond: 192_000,
                title: "Still Here", artwork: true
            )
        }) else { return }

        let stripped = await scratch("tx-cover-stripped.m4a")
        let result = try await transcoder.transcode(
            source: tagged, to: stripped,
            quality: .averageBitrate(64_000), metadata: .strip([.thumbnails])
        )
        #expect(result.outcome == .transcoded)
        #expect(!result.carriedArtwork)
        #expect(try await inspector.inspect(stripped).hasArtwork == false)

        let common = try await AVURLAsset(url: stripped).load(.commonMetadata)
        #expect(try await Self.string(from: common, key: .commonKeyTitle) == "Still Here")

        // ...while an unrelated strip leaves it alone.
        let kept = await scratch("tx-cover-kept.m4a")
        let other = try await transcoder.transcode(
            source: tagged, to: kept,
            quality: .averageBitrate(64_000), metadata: .strip([.gps])
        )
        #expect(other.carriedArtwork)
        #expect(try await inspector.inspect(kept).hasArtwork)
    }

    // MARK: - Cancellation

    @Test("a cancelled transcode leaves no file at all")
    func cancellationLeavesNoFile() async throws {
        guard let wav = await fixture("tx-cancel.wav", {
            try await FixtureLibrary.shared.wav(
                named: "tx-cancel.wav", seconds: 30, audio: .noise(amplitude: 0.3)
            )
        }) else { return }
        let destination = await scratch("tx-cancel-out.m4a")
        try? FileManager.default.removeItem(at: destination)

        let ticks = Counter()
        let handle = ProgressHandle(
            sink: ClosureProgressSink { _ in
                ticks.increment()
                // Let a little work happen first, so the cancellation lands in
                // the middle of the encode rather than before it starts.
                return ticks.value < 3
            },
            throttle: .unthrottled
        )
        let request = AudioTranscodeRequest(source: wav, destination: destination)

        await #expect(throws: LatheError.self) {
            _ = try await transcoder.transcode(request, progress: handle)
        }
        #expect(ticks.value >= 3)

        // Neither the destination nor the scratch file it was being written
        // through may be left behind.
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try Self.scratchLeftovers(beside: destination).isEmpty)
    }

    /// A failure must not destroy what was already there. The strongest version
    /// of "never leave a partial file" is "never replace a good file with
    /// nothing".
    @Test("a cancelled transcode leaves a previous file untouched")
    func cancellationLeavesThePreviousFile() async throws {
        guard let wav = await fixture("tx-cancel2.wav", {
            try await FixtureLibrary.shared.wav(
                named: "tx-cancel2.wav", seconds: 30, audio: .noise(amplitude: 0.3)
            )
        }) else { return }
        let destination = await scratch("tx-cancel2-out.m4a")
        let sentinel = Data("not a real m4a, and must survive".utf8)
        try sentinel.write(to: destination)

        let ticks = Counter()
        let handle = ProgressHandle(
            sink: ClosureProgressSink { _ in
                ticks.increment()
                return ticks.value < 3
            },
            throttle: .unthrottled
        )

        await #expect(throws: LatheError.self) {
            _ = try await transcoder.transcode(
                AudioTranscodeRequest(source: wav, destination: destination), progress: handle
            )
        }
        #expect(try Data(contentsOf: destination) == sentinel)
    }

    // MARK: - Refusals

    /// Opus: AVFoundation decodes it and cannot write it. The refusal is by
    /// name, and nothing quietly substitutes AAC.
    @Test("an Opus destination is refused, clearly, and nothing is substituted")
    func opusIsRefused() async throws {
        guard let wav = await fixture("tx-opus.wav", {
            try await FixtureLibrary.shared.wav(
                named: "tx-opus.wav", seconds: 1, audio: .noise(amplitude: 0.3)
            )
        }) else { return }

        for ext in ["opus", "ogg", "webm"] {
            let destination = await scratch("tx-opus-out.\(ext)")
            try? FileManager.default.removeItem(at: destination)
            do {
                _ = try await transcoder.transcode(source: wav, to: destination)
                Issue.record("a .\(ext) destination should have been refused")
            } catch let error as LatheError {
                guard case let .unsupportedOnThisPlatform(feature) = error else {
                    Issue.record("expected unsupportedOnThisPlatform, got \(error)")
                    continue
                }
                // The message has to name the codec and say why, or the caller
                // learns nothing it can act on.
                #expect(feature.contains("Opus"))
                #expect(feature.lowercased().contains("encoder"))
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test("MP3 and FLAC destinations are refused by name too")
    func otherUnwritableContainersAreRefused() async throws {
        guard let wav = await fixture("tx-refuse.wav", {
            try await FixtureLibrary.shared.wav(
                named: "tx-refuse.wav", seconds: 1, audio: .noise(amplitude: 0.3)
            )
        }) else { return }

        for ext in ["mp3", "flac", "wav", "zzz"] {
            let destination = await scratch("tx-refuse-out.\(ext)")
            await #expect(throws: LatheError.self) {
                _ = try await transcoder.transcode(source: wav, to: destination)
            }
        }
    }

    @Test("a quality knob on a lossless codec is a contradiction, and is refused")
    func contradictoryQualityIsRefused() async throws {
        guard let wav = await fixture("tx-config.wav", {
            try await FixtureLibrary.shared.wav(
                named: "tx-config.wav", seconds: 1, audio: .noise(amplitude: 0.3)
            )
        }) else { return }
        let destination = await scratch("tx-config-out.m4a")

        // ALAC has no quality knob.
        await #expect(throws: LatheError.self) {
            _ = try await transcoder.transcode(
                source: wav, to: destination, codec: .appleLossless, quality: .quality(0.8)
            )
        }
        // ...and AAC cannot be lossless, however it is asked.
        await #expect(throws: LatheError.self) {
            _ = try await transcoder.transcode(
                source: wav, to: destination, codec: .aac, quality: .lossless
            )
        }
        // A VideoToolbox rate control is not reinterpreted as something else.
        await #expect(throws: LatheError.self) {
            _ = try await transcoder.transcode(
                source: wav, to: destination, codec: .aac,
                quality: .constantQualityFactor(0.6)
            )
        }
    }

    @Test("a transcode cannot overwrite the file it is reading")
    func sourceAndDestinationMustDiffer() async throws {
        guard let wav = await fixture("tx-same.wav", {
            try await FixtureLibrary.shared.wav(
                named: "tx-same.wav", seconds: 1, audio: .noise(amplitude: 0.3)
            )
        }) else { return }
        await #expect(throws: LatheError.self) {
            _ = try await transcoder.transcode(source: wav, to: wav)
        }
    }

    // MARK: - Planning

    @Test("the plan says what the transcode would do, and writes nothing")
    func planAgreesWithTheTranscode() async throws {
        guard let aac = await fixture("tx-plan.m4a", {
            try await FixtureLibrary.shared.aacFile(
                named: "tx-plan.m4a", seconds: 2, bitsPerSecond: 128_000
            )
        }) else { return }
        let destination = await scratch("tx-plan-out.m4a")
        try? FileManager.default.removeItem(at: destination)

        let request = AudioTranscodeRequest(
            source: aac, destination: destination, quality: .averageBitrate(128_000)
        )
        let plan = try await transcoder.plan(for: request)

        #expect(!plan.wouldTranscode)
        #expect(plan.isSecondGenerationLossy)
        #expect(plan.targetBitsPerSecond == 128_000)
        #expect(plan.source.codecName == "aac")
        #expect(!FileManager.default.fileExists(atPath: destination.path))

        let result = try await transcoder.transcode(request)
        #expect(result.outcome.skipReason == plan.skipReason)
    }

    // MARK: - The bitrate mapping

    /// Pinned, because ``LossySourceRule`` compares against these numbers: a
    /// quality knob that resolved to "whatever the encoder felt like" would make
    /// the generation-loss guard unenforceable.
    @Test("quality maps onto bitrate by arithmetic, per channel")
    func bitrateMapping() {
        #expect(AudioTranscoder.bitrate(for: .quality(0), channels: 2) == 48_000)
        #expect(AudioTranscoder.bitrate(for: .quality(0.5), channels: 2) == 120_000)
        #expect(AudioTranscoder.bitrate(for: .quality(1), channels: 2) == 192_000)
        #expect(AudioTranscoder.bitrate(for: .quality(0.5), channels: 1) == 60_000)
        #expect(AudioTranscoder.bitrate(for: .quality(0.5), channels: 6) == 360_000)
        // Out of range is clamped rather than extrapolated.
        #expect(AudioTranscoder.bitrate(for: .quality(5), channels: 2) == 192_000)
        #expect(AudioTranscoder.bitrate(for: .averageBitrate(96_000), channels: 2) == 96_000)
        #expect(AudioTranscoder.bitrate(for: .lossless, channels: 2) == nil)
    }

    // MARK: - Encoder capability

    /// The guard that stops a 5.1 file from taking the host application down.
    ///
    /// This is not a hypothetical. `AVAssetWriterInput` given a channel layout
    /// its encoder does not accept raises an Objective-C exception, which Swift
    /// cannot catch — and the layout a CAF or WAV carries for six speakers is
    /// one AAC refuses. It was an `NSInvalidArgumentException` and a dead
    /// process before ``AudioEncodeSupport`` translated it.
    @Test("a 5.1 layout the source carries is translated into one the encoder accepts")
    func channelLayoutsAreTranslated() {
        let accepted = AudioEncodeSupport.availableChannelLayoutTags(
            formatID: kAudioFormatMPEG4AAC, channels: 6
        )
        #expect(!accepted.isEmpty)

        // The tag a fixture writes for 5.1 — and the one AAC would not take.
        var source = FixtureLibrary.channelLayout(for: 6)
        let sourceData = Data(bytes: &source, count: MemoryLayout<AudioChannelLayout>.size)

        let translated = try? #require(AudioEncodeSupport.channelLayout(
            forSource: sourceData, formatID: kAudioFormatMPEG4AAC, channels: 6
        ))
        let tag = try? #require(AudioEncodeSupport.tag(of: translated))
        #expect(tag.map { accepted.contains($0) } == true)
        #expect(tag.map { AudioChannelLayoutTag_GetNumberOfChannels($0) } == 6)

        // Mono and stereo need no layout, and handing one over is how a valid
        // request becomes an invalid settings dictionary.
        #expect(AudioEncodeSupport.channelLayout(
            forSource: sourceData, formatID: kAudioFormatMPEG4AAC, channels: 2
        ) == nil)
    }

    @Test("the chosen sample rate is never above the one asked for")
    func sampleRateNeverRises() {
        for requested in [8_000.0, 11_025, 22_050, 44_100, 48_000, 96_000] {
            let chosen = AudioEncodeSupport.sampleRate(
                atOrBelow: requested, formatID: kAudioFormatMPEG4AAC
            )
            #expect(chosen ?? 0 <= requested)
            #expect(chosen ?? 0 > 0)
        }
        // Below anything AAC encodes: refused rather than resampled upward.
        #expect(AudioEncodeSupport.sampleRate(atOrBelow: 300, formatID: kAudioFormatMPEG4AAC) == nil)
    }

    @Test("an absurd bitrate is clamped into what the encoder accepts")
    func bitrateIsClamped() {
        let low = AudioEncodeSupport.bitrate(nearest: 1, formatID: kAudioFormatMPEG4AAC)
        let high = AudioEncodeSupport.bitrate(nearest: 50_000_000, formatID: kAudioFormatMPEG4AAC)
        #expect(low > 1)
        #expect(high < 50_000_000)
        #expect(low < high)
        // An ordinary request passes through untouched.
        #expect(AudioEncodeSupport.bitrate(nearest: 128_000, formatID: kAudioFormatMPEG4AAC)
            == 128_000)
    }

    @Test("the capability report names both codecs")
    func capabilityReportIsLegible() {
        let report = AudioEncodeSupport.diagnosticReport()
        #expect(report.contains("aac"))
        #expect(report.contains("alac"))
    }

    // MARK: - Helpers

    private static func string(
        from items: [AVMetadataItem],
        key: AVMetadataKey
    ) async throws -> String? {
        guard let item = items.first(where: { $0.commonKey == key }) else { return nil }
        return try await item.load(.stringValue)
    }

    /// Any `.lathe-*` scratch file the transcoder failed to clean up.
    private static func scratchLeftovers(beside destination: URL) throws -> [String] {
        let directory = destination.deletingLastPathComponent()
        return try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".lathe-") }
    }

    private func scratch(_ name: String) async -> URL {
        let url = await FixtureLibrary.shared.scratchURL(named: name)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    /// Generates a fixture, or turns a generation failure into a known issue
    /// with a legible reason.
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

/// A counter a progress sink can bump from whatever thread it is called on.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }
}

let audioRunningInSimulator: Bool = {
    #if targetEnvironment(simulator)
    true
    #else
    false
    #endif
}()
