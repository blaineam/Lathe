import Foundation
import Testing

@testable import LatheFetch

/// Mapping `yt-dlp`'s exceptions onto something a caller can route on.
///
/// Error mapping is the part of a downloader that is exercised least in
/// development and most in the field, which is exactly why it is a pure
/// function here and tested from fixtures rather than discovered against a live
/// site.
@Suite("yt-dlp exceptions map to routable errors")
struct MediaFetchErrorTests {

    private func exception(
        _ type: String, _ message: String, restricted: Bool = false
    ) -> PythonException {
        PythonException(
            type: type, message: message, traceback: "", isPlatformRestriction: restricted)
    }

    @Test("the platform restriction wins over everything, including the text")
    func platformRestrictionIsNeverAbsorbed() {
        // Deliberately given a message that would otherwise match "unavailable".
        let error = MediaFetchError.mapping(
            exception("OSError", "This video is unavailable", restricted: true))
        guard case .subprocessRequired = error else {
            Issue.record("expected subprocessRequired, got \(error)")
            return
        }
        // It is the one failure that means "this design has a hole", and
        // absorbing it into a generic case would hide the hole.
    }

    @Test("a missing module is an installation problem, not an extraction one")
    func missingModule() {
        let error = MediaFetchError.mapping(
            exception("ModuleNotFoundError", "No module named 'yt_dlp'"))
        guard case .notInstalled = error else {
            Issue.record("expected notInstalled, got \(error)")
            return
        }
    }

    @Test("each family of message reaches its own case", arguments: [
        ("Unsupported URL: https://example.invalid/x", "unsupportedSite"),
        ("The requested site is protected by DRM", "drmProtected"),
        ("Sign in to confirm you're not a bot", "botCheckFailed"),
        ("The page needs to be reloaded.", "botCheckFailed"),
        ("Private video. Sign in if you've been granted access", "authenticationRequired"),
        ("Join this channel to get access to members-only content", "authenticationRequired"),
        ("The uploader has not made this video available in your country", "geoRestricted"),
        ("This live event will begin in 3 hours", "liveStream"),
        ("Video unavailable", "unavailable"),
        ("This video has been removed by the uploader", "unavailable"),
        ("Requested format is not available", "noUsableFormat"),
        ("Only images are available for download", "noUsableFormat"),
        ("Unable to download webpage: connection reset", "transferFailed"),
    ])
    func mapsMessageFamilies(message: String, expected: String) {
        let error = MediaFetchError.mapping(exception("ExtractorError", message))
        #expect(caseName(of: error) == expected, "\(message) → \(error)")
    }

    @Test("an unrecognised message keeps yt-dlp's own text rather than losing it")
    func fallsBackWithoutLosingAnything() {
        let message = "Some entirely new failure mode nobody has seen before"
        let error = MediaFetchError.mapping(exception("ExtractorError", message))
        guard case let .extractionFailed(reason) = error else {
            Issue.record("expected extractionFailed, got \(error)")
            return
        }
        #expect(reason == message, "nothing is lost when a match is missed")
    }

    @Test("a non-Python error is a runtime failure, not an extraction failure")
    func separatesRuntimeFromExtraction() {
        let error = MediaFetchError.mapping(
            PythonError.interpreterUnavailable(reason: "no CPython here"))
        guard case .runtimeFailed = error else {
            Issue.record("expected runtimeFailed, got \(error)")
            return
        }
    }

    @Test("a MediaFetchError passes through the mapper unchanged")
    func isIdempotent() {
        let original = MediaFetchError.noUsableFormat(reason: "because")
        #expect(MediaFetchError.mapping(original) == original)
    }

    @Test("retry advice matches what could plausibly change")
    func retryAdvice() {
        #expect(MediaFetchError.transferFailed(reason: "").isWorthRetrying)
        #expect(MediaFetchError.botCheckFailed(reason: "").isWorthRetrying)
        #expect(!MediaFetchError.unavailable(reason: "").isWorthRetrying)
        #expect(!MediaFetchError.drmProtected(reason: "").isWorthRetrying)
        #expect(!MediaFetchError.unsupportedSite(url: "").isWorthRetrying)
    }

    @Test("every case has a description that says something")
    func allCasesDescribeThemselves() {
        let cases: [MediaFetchError] = [
            .notInstalled(reason: "r"), .unsupportedSite(url: "u"), .unavailable(reason: "r"),
            .geoRestricted(reason: "r"), .authenticationRequired(reason: "r"),
            .botCheckFailed(reason: "r"), .drmProtected(reason: "r"), .liveStream(reason: "r"),
            .isPlaylist(title: "t", count: 12), .noUsableFormat(reason: "r"),
            .unknownFormat(id: "137"), .transferFailed(reason: "r"),
            .incompleteDownload(path: "p", reason: "r"), .muxingFailed(stage: "s", reason: "r"),
            .subprocessRequired(reason: "r"), .extractionFailed(reason: "r"),
            .runtimeFailed(reason: "r"),
        ]
        for error in cases {
            let description = error.errorDescription ?? ""
            #expect(!description.isEmpty, "\(error) has no description")
        }
    }

    @Test("a playlist reports its size so the caller can offer the contents")
    func playlistCarriesItsCount() {
        let error = MediaFetchError.isPlaylist(title: "Mixtape", count: 12)
        let description = try! #require(error.errorDescription)
        #expect(description.contains("Mixtape"))
        #expect(description.contains("12"))
    }

    private func caseName(of error: MediaFetchError) -> String {
        switch error {
        case .notInstalled: "notInstalled"
        case .unsupportedSite: "unsupportedSite"
        case .unavailable: "unavailable"
        case .geoRestricted: "geoRestricted"
        case .authenticationRequired: "authenticationRequired"
        case .botCheckFailed: "botCheckFailed"
        case .drmProtected: "drmProtected"
        case .liveStream: "liveStream"
        case .isPlaylist: "isPlaylist"
        case .noUsableFormat: "noUsableFormat"
        case .unknownFormat: "unknownFormat"
        case .transferFailed: "transferFailed"
        case .incompleteDownload: "incompleteDownload"
        case .muxingFailed: "muxingFailed"
        case .subprocessRequired: "subprocessRequired"
        case .extractionFailed: "extractionFailed"
        case .runtimeFailed: "runtimeFailed"
        }
    }
}
