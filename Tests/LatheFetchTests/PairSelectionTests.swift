import Foundation
import Testing

@testable import LatheFetch

/// Choosing the two halves of a pair that is about to be muxed.
///
/// These are regression tests for a download that failed *after* fetching
/// 712 MB: the selector took YouTube's format 233 as the audio half, which is
/// not an audio stream at all but an HLS manifest carrying no codec
/// information. `canMuxAudio` passed it — correctly, since its rule is not to
/// reject a codec it cannot see — and the muxer then could not open what the
/// manifest downloader produced.
@Suite("Pair selection")
struct PairSelectionTests {

    /// YouTube's real shape, reduced: a 4K AV1 video-only rendition, the HLS
    /// audio manifests with no codec, and an ordinary progressive m4a.
    private static func youTubeLikeListing() -> MediaListing {
        MediaListing(
            id: "t",
            title: "Test",
            formats: [
                MediaFormat(formatID: "401", ext: "mp4", transferProtocol: "https", url: URL(string: "https://example.test/401"),
                            width: 3840, height: 2160, videoCodec: "av01.0.13M.08",
                            audioIsAbsent: true, byteCount: 712_445_280),
                MediaFormat(formatID: "137", ext: "mp4", transferProtocol: "https", url: URL(string: "https://example.test/137"),
                            width: 1920, height: 1080, videoCodec: "avc1.640028",
                            audioIsAbsent: true, byteCount: 200_000_000),
                // The manifests. vcodec is asserted absent; acodec is simply
                // not reported, which is what makes them slip through a filter
                // that only rejects known-bad codecs.
                MediaFormat(formatID: "233", ext: "mp4", transferProtocol: "m3u8_native", url: URL(string: "https://example.test/233"),
                            videoIsAbsent: true),
                MediaFormat(formatID: "234", ext: "mp4", transferProtocol: "m3u8_native", url: URL(string: "https://example.test/234"),
                            videoIsAbsent: true),
                MediaFormat(formatID: "140", ext: "m4a", transferProtocol: "https", url: URL(string: "https://example.test/140"),
                            audioCodec: "mp4a.40.2", videoIsAbsent: true,
                            audioBitrate: 129, byteCount: 10_000_000),
            ])
    }

    @Test("the audio half is a real stream, not a manifest with no codec")
    func audioHalfIsNotAManifest() throws {
        let selection = try FormatSelector.select(from: Self.youTubeLikeListing(), policy: .best)
        guard case let .pair(_, audio) = selection else {
            Issue.record("expected a pair, got \(selection)")
            return
        }
        #expect(audio.formatID == "140")
        #expect(audio.audioCodec != nil, "an audio half with no codec cannot be vetted for the muxer")
    }

    @Test("the video half is fetched in one request rather than as fragments")
    func videoHalfIsSingleRequest() throws {
        let selection = try FormatSelector.select(from: Self.youTubeLikeListing(), policy: .best)
        guard case let .pair(video, _) = selection else {
            Issue.record("expected a pair, got \(selection)")
            return
        }
        #expect(video.isSingleRequestHTTP)
        #expect(video.videoCodec != nil)
    }

    /// The filter must not be so strict that a site publishing only manifests
    /// loses its pre-muxed rendition too — that would trade one failure for a
    /// broader one.
    @Test("a pre-muxed rendition still wins when no vettable pair exists")
    func preMuxedSurvivesWhenNoPairIsVettable() throws {
        let listing = MediaListing(
            id: "t",
            formats: [
                MediaFormat(formatID: "hls-v", ext: "mp4", transferProtocol: "m3u8_native", url: URL(string: "https://example.test/hls-v"),
                            width: 1920, height: 1080, videoCodec: "avc1.4d401f",
                            audioIsAbsent: true),
                MediaFormat(formatID: "hls-a", ext: "mp4", transferProtocol: "m3u8_native", url: URL(string: "https://example.test/hls-a"),
                            audioCodec: "mp4a.40.2", videoIsAbsent: true),
                MediaFormat(formatID: "18", ext: "mp4", transferProtocol: "https", url: URL(string: "https://example.test/18"),
                            width: 640, height: 360, videoCodec: "avc1.42001E",
                            audioCodec: "mp4a.40.2", byteCount: 5_000_000),
            ])
        let selection = try FormatSelector.select(from: listing, policy: .best)
        guard case let .single(format) = selection else {
            Issue.record("expected the pre-muxed rendition, got \(selection)")
            return
        }
        #expect(format.formatID == "18")
    }

    /// And when a site has *only* manifests, the pair path is still allowed to
    /// use them — a fragmented download that might need remuxing beats no
    /// download at all.
    @Test("manifests are used when they are the only thing on offer")
    func manifestsAreALastResort() throws {
        let listing = MediaListing(
            id: "t",
            formats: [
                MediaFormat(formatID: "hls-v", ext: "mp4", transferProtocol: "m3u8_native", url: URL(string: "https://example.test/hls-v"),
                            width: 1920, height: 1080, videoCodec: "avc1.4d401f",
                            audioIsAbsent: true),
                MediaFormat(formatID: "hls-a", ext: "mp4", transferProtocol: "m3u8_native", url: URL(string: "https://example.test/hls-a"),
                            audioCodec: "mp4a.40.2", videoIsAbsent: true),
            ])
        let selection = try FormatSelector.select(from: listing, policy: .best)
        guard case let .pair(video, audio) = selection else {
            Issue.record("expected a pair, got \(selection)")
            return
        }
        #expect(video.formatID == "hls-v")
        #expect(audio.formatID == "hls-a")
    }
}

/// A page that only has audio on it.
@Suite("Audio-only pages")
struct AudioOnlySelectionTests {

    /// The regression: an ordinary web page with an MP3 on it failed with
    /// "every audio rendition here is in a codec an MPEG-4 file cannot hold
    /// (mp3)". The container rule is about joining two streams into an MP4,
    /// and with no video there is nothing to join.
    @Test("an mp3 with no video beside it is downloadable")
    func mp3WithoutVideo() throws {
        let listing = MediaListing(
            id: "t",
            formats: [
                MediaFormat(formatID: "mp3-128", ext: "mp3", transferProtocol: "https",
                            url: URL(string: "https://example.test/a.mp3"),
                            audioCodec: "mp3", videoIsAbsent: true,
                            audioBitrate: 128, byteCount: 3_000_000)
            ])
        let selection = try FormatSelector.select(from: listing, policy: .best)
        guard case let .single(format) = selection else {
            Issue.record("expected a single rendition, got \(selection)")
            return
        }
        #expect(format.formatID == "mp3-128")
    }

    @Test("the best of several audio-only renditions wins")
    func picksTheBestAudio() throws {
        let listing = MediaListing(
            id: "t",
            formats: [
                MediaFormat(formatID: "low", ext: "mp3", transferProtocol: "https",
                            url: URL(string: "https://example.test/low.mp3"),
                            audioCodec: "mp3", videoIsAbsent: true, audioBitrate: 64),
                MediaFormat(formatID: "high", ext: "mp3", transferProtocol: "https",
                            url: URL(string: "https://example.test/high.mp3"),
                            audioCodec: "mp3", videoIsAbsent: true, audioBitrate: 320),
            ])
        let selection = try FormatSelector.select(from: listing, policy: .best)
        guard case let .single(format) = selection else {
            Issue.record("expected a single rendition, got \(selection)")
            return
        }
        #expect(format.formatID == "high")
    }

    /// And the rule still applies where it should: with video present, an
    /// unmuxable audio track is still a real problem.
    @Test("video plus unmuxable audio still prefers a pre-muxed rendition")
    func videoStillConstrained() throws {
        let listing = MediaListing(
            id: "t",
            formats: [
                MediaFormat(formatID: "v", ext: "mp4", transferProtocol: "https",
                            url: URL(string: "https://example.test/v.mp4"),
                            width: 1920, height: 1080, videoCodec: "avc1.640028",
                            audioIsAbsent: true),
                MediaFormat(formatID: "a", ext: "mp3", transferProtocol: "https",
                            url: URL(string: "https://example.test/a.mp3"),
                            audioCodec: "mp3", videoIsAbsent: true),
                MediaFormat(formatID: "both", ext: "mp4", transferProtocol: "https",
                            url: URL(string: "https://example.test/b.mp4"),
                            width: 640, height: 360, videoCodec: "avc1.42001E",
                            audioCodec: "mp4a.40.2"),
            ])
        let selection = try FormatSelector.select(from: listing, policy: .best)
        guard case let .single(format) = selection else {
            Issue.record("expected the pre-muxed rendition, got \(selection)")
            return
        }
        #expect(format.formatID == "both")
    }
}
