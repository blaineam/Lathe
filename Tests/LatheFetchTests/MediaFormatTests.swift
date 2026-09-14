import Foundation
import Testing

@testable import LatheFetch

/// Decoding `yt-dlp`'s info dictionary.
///
/// Every test here is offline and interpreter-free: the `--dump-json` shape is
/// stable enough to fixture, which is what makes the whole of this package's
/// format reasoning testable on an aeroplane.
@Suite("yt-dlp info dictionaries decode")
struct MediaFormatTests {

    // MARK: - The distinction that matters

    @Test("acodec \"none\" means silent; an absent acodec does not")
    func distinguishesAbsentFromUnknown() throws {
        let listing = try MediaFixtures.listing(MediaFixtures.awkwardTypes)

        let silent = try #require(listing.formats.first { $0.formatID == "silent" })
        #expect(silent.audioIsAbsent)
        #expect(!silent.hasAudio)
        #expect(silent.audioCodec == nil)
        #expect(silent.isVideoOnly)

        // No `vcodec` and no `acodec` at all. yt-dlp's own convention is that
        // this means "unknown, assume present" — `f.get('vcodec') != 'none'` —
        // and reading it as silence would throw away the best rendition on a
        // great many sites.
        let unknown = try #require(listing.formats.first { $0.formatID == "unknown-codecs" })
        #expect(!unknown.audioIsAbsent)
        #expect(!unknown.videoIsAbsent)
        #expect(unknown.hasAudio)
        #expect(unknown.hasVideo)
        #expect(unknown.isPreMuxed)
        #expect(unknown.audioCodec == nil, "present-but-unknown is still not a codec name")
    }

    // MARK: - Lenient scalars

    @Test("numeric strings, floats and integer ids all decode")
    func decodesAwkwardTypes() throws {
        let listing = try MediaFixtures.listing(MediaFixtures.awkwardTypes)
        let awkward = try #require(listing.formats.first { $0.formatID == "42" })
        #expect(awkward.height == 720, "a height that arrived as \"720\"")
        #expect(awkward.width == 1280, "a width that arrived as 1280.0")
        #expect(awkward.frameRate == 29.97)
        #expect(awkward.byteCount == 1_048_576)
    }

    @Test("a format with no format_id is dropped; the ones beside it survive")
    func dropsUnusableFormatsIndividually() throws {
        // format_id is the handle every later request is expressed in, so a
        // rendition without one cannot be asked for again and is useless. It is
        // dropped — but *only* it. One extractor emitting one bad entry must
        // not take the other forty with it, which is what decoding the array as
        // a whole would do.
        let json = """
            {"id":"x","formats":[
              {"ext":"mp4","url":"https://example.invalid/a"},
              {"format_id":"good","ext":"mp4","url":"https://example.invalid/b","height":720}
            ]}
            """
        let listing = try MediaFixtures.listing(json)
        #expect(listing.formats.map(\.formatID) == ["good"])
    }

    // MARK: - The real shape

    @Test("the captured YouTube listing decodes")
    func decodesYouTube() throws {
        let listing = try MediaFixtures.listing(MediaFixtures.youTubeAdaptive)
        #expect(listing.extractor == "youtube")
        #expect(listing.formats.count == 41)
        #expect(listing.duration == 635)
    }

    @Test("YouTube publishes no pre-muxed rendition to the default clients")
    func youTubeHasNothingPreMuxed() throws {
        // The fact the selector's default is built around, asserted so that it
        // is a checked claim rather than a remembered one. If YouTube starts
        // publishing progressive files again this test fails, and the comment
        // in FormatSelector needs rewriting — which is exactly when someone
        // should be made to look at it.
        let listing = try MediaFixtures.listing(MediaFixtures.youTubeAdaptive)
        #expect(listing.preMuxedFormats.isEmpty)
        #expect(!listing.videoOnlyFormats.isEmpty)
        #expect(!listing.audioOnlyFormats.isEmpty)
        #expect(listing.maximumPreMuxedHeight == nil)
        #expect(listing.maximumHeight == 2160)
    }

    @Test("the single-request test separates progressive from manifest formats")
    func classifiesProtocols() throws {
        let listing = try MediaFixtures.listing(MediaFixtures.youTubeAdaptive)
        let progressive = listing.formats.filter(\.isSingleRequestHTTP)
        let manifests = listing.formats.filter { !$0.isSingleRequestHTTP }
        #expect(!progressive.isEmpty, "https renditions")
        #expect(!manifests.isEmpty, "m3u8/dash renditions")
        #expect(manifests.allSatisfy { $0.transferProtocol != "https" })
    }

    @Test("size falls back from exact to approximate and never invents one")
    func reportsSizes() {
        #expect(MediaFormat(formatID: "a", byteCount: 100, approximateByteCount: 200)
            .estimatedByteCount == 100)
        #expect(MediaFormat(formatID: "a", approximateByteCount: 200).estimatedByteCount == 200)
        #expect(MediaFormat(formatID: "a").estimatedByteCount == nil)
    }

    @Test("a listing round-trips through its own encoder")
    func roundTrips() throws {
        let original = try MediaFixtures.listing(MediaFixtures.preMuxedAndAdaptive)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MediaListing.self, from: data)
        // The codec sentinel is the interesting part of the round trip: it has
        // to come back out as "none" for the absence to survive.
        #expect(decoded.formats.map(\.formatID) == original.formats.map(\.formatID))
        #expect(decoded.formats.map(\.audioIsAbsent) == original.formats.map(\.audioIsAbsent))
        #expect(decoded.formats.map(\.videoIsAbsent) == original.formats.map(\.videoIsAbsent))
        #expect(decoded.preMuxedFormats.count == original.preMuxedFormats.count)
    }
}
