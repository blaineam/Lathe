import Foundation
import Testing

@testable import LatheFetch

/// The muxing decision, and the policy that produces it.
///
/// This is the suite that matters most for the iOS story, because the decision
/// it tests is the one PEP 730 forces: `yt-dlp` cannot merge two streams here,
/// so the choice between "one file" and "two files and an `AVAssetWriter`" has
/// to be made in Swift, from data, before anything is downloaded.
@Suite("Format selection decides what to download, and whether to mux")
struct FormatSelectionTests {

    // MARK: - The muxing decision

    @Test("YouTube's adaptive-only listing selects a pair, because it must")
    func youTubeNeedsMuxing() throws {
        let listing = try MediaFixtures.listing(MediaFixtures.youTubeAdaptive)
        let selection = try FormatSelector.select(from: listing, policy: .best)

        guard case let .pair(video, audio) = selection else {
            Issue.record("expected a pair, got \(selection.summary)")
            return
        }
        #expect(selection.needsMuxing)
        #expect(video.isVideoOnly)
        #expect(audio.isAudioOnly)
        #expect(video.height == 2160, "the ceiling with muxing on")
        #expect(selection.formatIDs.count == 2)
        #expect(selection.formatIDs[0] == video.formatID, "video is fetched first")
    }

    @Test("with muxing forbidden, the same listing has nothing at all to offer")
    func youTubeWithoutMuxingFindsNothing() throws {
        // The measurement behind the default, as a test. "Constrain to
        // pre-muxed" is usually described as a quality cap; against YouTube's
        // current default client set it is not a cap, it is a complete
        // failure, and that is worth being unable to forget.
        let listing = try MediaFixtures.listing(MediaFixtures.youTubeAdaptive)
        let error = #expect(throws: MediaFetchError.self) {
            try FormatSelector.select(from: listing, policy: .preMuxedOnly)
        }
        guard case let .noUsableFormat(reason) = error else {
            Issue.record("expected noUsableFormat, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("muxing"), "the reason names the constraint responsible: \(reason)")
    }

    @Test("a pre-muxed rendition that is already the best needs no second request")
    func prefersPreMuxedWhenItWins() throws {
        // 1080p pre-muxed against 2160p video-only: the pair genuinely wins, so
        // it is taken.
        let listing = try MediaFixtures.listing(MediaFixtures.preMuxedAndAdaptive)
        let unconstrained = try FormatSelector.select(from: listing, policy: .best)
        #expect(unconstrained.needsMuxing)
        #expect(unconstrained.height == 2160)

        // Cap at 1080 and the 4K video-only rendition is out, which leaves the
        // 1080p pre-muxed file beating a pair that could only reach 360p. One
        // request, no muxer.
        let capped = try FormatSelector.select(from: listing, policy: .upTo(height: 1080))
        guard case let .single(format) = capped else {
            Issue.record("expected a single format, got \(capped.summary)")
            return
        }
        #expect(!capped.needsMuxing)
        #expect(format.formatID == "hd")
        #expect(format.isPreMuxed)
    }

    @Test("muxing is not attempted for codecs an MPEG-4 file cannot hold")
    func refusesUnmuxableCodecs() throws {
        // VP9 and Opus. Both are perfectly good codecs and neither goes into an
        // .mp4 through AVAssetWriter. Discovering that at the muxer would mean
        // discovering it *after* downloading both streams, which is the worst
        // possible moment.
        let listing = try MediaFixtures.listing(MediaFixtures.webMOnly)
        let error = #expect(throws: MediaFetchError.self) {
            try FormatSelector.select(from: listing, policy: .best)
        }
        guard case let .noUsableFormat(reason) = error else {
            Issue.record("expected noUsableFormat, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("vp9"), "the reason names the codec: \(reason)")
    }

    @Test("the mux-compatibility check is a filter on pairs, not on whole listings")
    func muxCheckOnlyAppliesToPairs() {
        #expect(StreamMuxer.canMuxVideo(MediaFormat(formatID: "a", videoCodec: "avc1.640028")))
        #expect(StreamMuxer.canMuxVideo(MediaFormat(formatID: "a", videoCodec: "av01.0.12M.08")))
        #expect(StreamMuxer.canMuxVideo(MediaFormat(formatID: "a", videoCodec: "hvc1.1.6.L93")))
        #expect(!StreamMuxer.canMuxVideo(MediaFormat(formatID: "a", videoCodec: "vp9")))
        #expect(!StreamMuxer.canMuxVideo(MediaFormat(formatID: "a", videoCodec: "vp09.00.51.08")))

        #expect(StreamMuxer.canMuxAudio(MediaFormat(formatID: "a", audioCodec: "mp4a.40.2")))
        #expect(!StreamMuxer.canMuxAudio(MediaFormat(formatID: "a", audioCodec: "opus")))

        // An unknown codec is muxable until proved otherwise. Refusing on
        // missing metadata would rule out a great many perfectly good
        // renditions from extractors that simply do not publish a codec name.
        #expect(StreamMuxer.canMuxVideo(MediaFormat(formatID: "a")))
        #expect(StreamMuxer.canMuxAudio(MediaFormat(formatID: "a")))
    }

    // MARK: - Intent

    @Test("audio-only never picks up a video track")
    func audioOnly() throws {
        let listing = try MediaFixtures.listing(MediaFixtures.youTubeAdaptive)
        let selection = try FormatSelector.select(from: listing, policy: .audio)
        guard case let .single(format) = selection else {
            Issue.record("audio should never mux")
            return
        }
        #expect(format.isAudioOnly)
        #expect(!selection.needsMuxing)
    }

    @Test("video-only picks the tallest silent rendition")
    func videoOnly() throws {
        let listing = try MediaFixtures.listing(MediaFixtures.youTubeAdaptive)
        var policy = FormatPolicy()
        policy.intent = .videoOnly
        let selection = try FormatSelector.select(from: listing, policy: policy)
        guard case let .single(format) = selection else {
            Issue.record("video-only should never mux")
            return
        }
        #expect(format.isVideoOnly)
        #expect(format.height == 2160)
    }

    // MARK: - Constraints

    @Test("a height ceiling is respected exactly")
    func respectsHeightCeiling() throws {
        let listing = try MediaFixtures.listing(MediaFixtures.youTubeAdaptive)
        for ceiling in [360, 480, 720, 1080, 1440] {
            let selection = try FormatSelector.select(from: listing, policy: .upTo(height: ceiling))
            let height = try #require(selection.height)
            #expect(height <= ceiling, "ceiling \(ceiling) produced \(height)")
        }
    }

    @Test("requiring a single HTTP request rules out the manifests")
    func requiresProgressive() throws {
        let listing = try MediaFixtures.listing(MediaFixtures.youTubeAdaptive)
        var policy = FormatPolicy()
        policy.requiresSingleRequestHTTP = true
        let selection = try FormatSelector.select(from: listing, policy: policy)
        #expect(selection.formats.allSatisfy { $0.isSingleRequestHTTP })
    }

    @Test("a DRM-only listing is refused, and the reason says why")
    func refusesDRM() throws {
        let listing = try MediaFixtures.listing(MediaFixtures.allDRM)
        let error = #expect(throws: MediaFetchError.self) {
            try FormatSelector.select(from: listing, policy: .best)
        }
        guard case let .noUsableFormat(reason) = error else {
            Issue.record("expected noUsableFormat, got \(String(describing: error))")
            return
        }
        #expect(reason.lowercased().contains("drm"))
    }

    @Test("an empty listing is refused before anything else is considered")
    func refusesEmpty() {
        let listing = MediaListing(id: "x", formats: [])
        #expect(throws: MediaFetchError.self) {
            try FormatSelector.select(from: listing, policy: .best)
        }
    }

    @Test("an impossible height ceiling names itself in the reason")
    func explainsImpossibleCeiling() throws {
        let listing = try MediaFixtures.listing(MediaFixtures.youTubeAdaptive)
        let error = #expect(throws: MediaFetchError.self) {
            try FormatSelector.select(from: listing, policy: .upTo(height: 1))
        }
        guard case let .noUsableFormat(reason) = error else {
            Issue.record("expected noUsableFormat, got \(String(describing: error))")
            return
        }
        // The caller set that ceiling and is the only one who can change it, so
        // the reason has to name it rather than say "no formats available"
        // against a listing with forty-one of them.
        #expect(reason.contains("caps height at 1px"), "the reason was: \(reason)")
    }

    // MARK: - Ordering

    @Test("container preference breaks a tie but never decides against quality")
    func containerIsATieBreak() {
        let mp4 = MediaFormat(
            formatID: "mp4-1080", ext: "mp4", url: URL(string: "https://example.invalid/a"),
            width: 1920, height: 1080, videoCodec: "avc1", audioIsAbsent: true)
        let webmTaller = MediaFormat(
            formatID: "webm-2160", ext: "webm", url: URL(string: "https://example.invalid/b"),
            width: 3840, height: 2160, videoCodec: "avc1", audioIsAbsent: true)
        let webmSame = MediaFormat(
            formatID: "webm-1080", ext: "webm", url: URL(string: "https://example.invalid/c"),
            width: 1920, height: 1080, videoCodec: "avc1", audioIsAbsent: true)

        #expect(
            FormatSelector.bestVideo(from: [mp4, webmTaller], policy: .best)?.formatID == "webm-2160",
            "a taller rendition wins even in a less-preferred container")
        #expect(
            FormatSelector.bestVideo(from: [webmSame, mp4], policy: .best)?.formatID == "mp4-1080",
            "with quality equal, the preferred container wins")
    }

    @Test("a preferred audio language outranks a higher bitrate")
    func languagePreference() {
        let japanese = MediaFormat(
            formatID: "ja", ext: "m4a", url: URL(string: "https://example.invalid/a"),
            audioCodec: "mp4a", videoIsAbsent: true, audioBitrate: 256, language: "ja")
        let english = MediaFormat(
            formatID: "en", ext: "m4a", url: URL(string: "https://example.invalid/b"),
            audioCodec: "mp4a", videoIsAbsent: true, audioBitrate: 128, language: "en")

        var policy = FormatPolicy()
        policy.preferredLanguage = "en"
        #expect(FormatSelector.bestAudio(from: [japanese, english], policy: policy)?.formatID == "en")

        // With no preference expressed, bitrate decides and the language fields
        // are ignored rather than guessed at.
        #expect(FormatSelector.bestAudio(from: [japanese, english], policy: .best)?.formatID == "ja")
    }

    @Test("a regional variant still counts as the preferred language")
    func languagePrefixMatch() {
        let regional = MediaFormat(
            formatID: "en-US", ext: "m4a", url: URL(string: "https://example.invalid/a"),
            audioCodec: "mp4a", videoIsAbsent: true, audioBitrate: 128, language: "en-US")
        let other = MediaFormat(
            formatID: "de", ext: "m4a", url: URL(string: "https://example.invalid/b"),
            audioCodec: "mp4a", videoIsAbsent: true, audioBitrate: 256, language: "de")
        var policy = FormatPolicy()
        policy.preferredLanguage = "en"
        #expect(FormatSelector.bestAudio(from: [other, regional], policy: policy)?.formatID == "en-US")
    }

    // MARK: - The selection value

    @Test("a total size is reported only when every part published one")
    func totalSizeIsAllOrNothing() {
        let sized = MediaFormat(formatID: "a", byteCount: 100)
        let unsized = MediaFormat(formatID: "b")
        #expect(FormatSelection.pair(video: sized, audio: sized).estimatedByteCount == 200)
        #expect(
            FormatSelection.pair(video: sized, audio: unsized).estimatedByteCount == nil,
            "a partial total makes a progress bar that runs past 100%")
    }
}
