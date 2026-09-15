import Foundation
import LatheCore

/// What can go wrong between a URL and a downloaded file.
///
/// A closed enum for the same reason ``LatheError`` and ``PythonPackageError``
/// are: the caller has to *route*. "This site is not supported" wants a
/// different response from "this video is private", which wants a different
/// response again from "the extractor crashed" — and only the last of those is
/// worth a bug report.
///
/// ## Where these come from
///
/// Almost all of them are a `yt-dlp` exception, whose type and message arrive
/// here as a ``PythonException``. Mapping that to a case is the job of
/// ``mapping(_:)``, which is a **pure function of the exception's type name and
/// message text** — and is therefore testable from fixtures, without a network
/// and without an interpreter. That matters more than it looks: error mapping
/// is the part of a downloader that is exercised least in development and most
/// in the field.
public enum MediaFetchError: Error, Sendable, Equatable {

    // MARK: Availability

    /// `yt-dlp` is not installed, or was installed and cannot be imported.
    ///
    /// The ordinary state before ``MediaFetcher/install(using:session:)`` has
    /// been called once. A reason to offer the install, not to report a fault.
    case notInstalled(reason: String)

    /// No extractor claimed the URL.
    case unsupportedSite(url: String)

    // MARK: The item

    /// The item exists but this viewer may not have it — private, members-only,
    /// age-gated, or removed.
    case unavailable(reason: String)

    /// The item is blocked in this region.
    case geoRestricted(reason: String)

    /// The site wants credentials.
    case authenticationRequired(reason: String)

    /// The site decided this client is a robot.
    ///
    /// Distinguished from ``unavailable(reason:)`` because the response is
    /// completely different: nothing about the request was wrong, and retrying
    /// later, or from elsewhere, may well work.
    case botCheckFailed(reason: String)

    /// Every rendition is DRM-protected, so a download would produce a file
    /// nothing can play.
    case drmProtected(reason: String)

    /// The item is a live stream with no end, and this API downloads files.
    case liveStream(reason: String)

    /// The URL is a playlist, a channel or a search, not one media item.
    ///
    /// Its own case rather than a generic failure because it is the one error
    /// here with an obvious next action: the caller has a container and wants
    /// to offer its contents, which is a different screen rather than an
    /// apology. The count is `-1` when the extractor produced a lazy generator
    /// and did not say how long it is.
    case isPlaylist(title: String?, count: Int)

    // MARK: Selection

    /// The policy ruled out everything the extractor offered. The reason names
    /// the constraint responsible.
    case noUsableFormat(reason: String)

    /// A format id was asked for that the listing does not contain.
    case unknownFormat(id: String)

    // MARK: Transfer

    /// The network failed, or the server did.
    case transferFailed(reason: String)

    /// The download finished but the file is not what was expected — zero
    /// bytes, or a fraction of the published size.
    case incompleteDownload(path: String, reason: String)

    // MARK: Joining

    /// The two downloaded streams could not be joined.
    ///
    /// Carries the stage because the failure modes are genuinely different: a
    /// track that `AVFoundation` refuses to read is a codec problem, and a
    /// writer that fails half way through is usually a disk problem.
    case muxingFailed(stage: String, reason: String)

    // MARK: Platform

    /// `yt-dlp` tried to spawn a process, which iOS does not permit.
    ///
    /// **This should not happen**, and its presence in the taxonomy is a
    /// tripwire rather than an expectation: this package's whole download path
    /// is built to avoid the two places `yt-dlp` shells out — the `ffmpeg`
    /// merge and the external JavaScript runtime. If this case is ever seen, a
    /// third one has been found.
    case subprocessRequired(reason: String)

    /// The extractor raised something with no better home. The message is
    /// `yt-dlp`'s own.
    case extractionFailed(reason: String)

    /// The interpreter itself failed, rather than the Python running in it.
    case runtimeFailed(reason: String)
}

// MARK: - Mapping

extension MediaFetchError {

    /// Whether this failure means the chosen format stopped existing between
    /// the extraction that offered it and the download that asked for it.
    ///
    /// Recognised by the extractor's own wording, which is unpleasant but is
    /// the only signal there is: `yt-dlp` raises one error type for every
    /// format-selection failure and distinguishes them in the message. The
    /// alternative is treating a stale selection the same as an impossible
    /// one, which means giving up on a download that would succeed on a second
    /// look.
    var indicatesStaleFormatSelection: Bool {
        guard case let .noUsableFormat(reason) = self else { return false }
        return reason.contains("Requested format is not available")
    }
}

extension MediaFetchError {

    /// Maps a raised Python exception to a case.
    ///
    /// ## Why this matches on message text, and why that is acceptable here
    ///
    /// Matching on strings is normally a smell. It is the only option
    /// available: `yt-dlp` funnels nearly everything through two exception
    /// classes, `ExtractorError` and `DownloadError`, and the *distinction*
    /// between "private video" and "geo-blocked" lives only in the message.
    /// The alternative is not a better mapping, it is no mapping — one
    /// `extractionFailed` for everything, with the caller left to do this same
    /// string matching in its UI layer, worse and in more places.
    ///
    /// Two things keep it honest. The matches are **substring, lowercase and
    /// deliberately broad**, so a rephrasing upstream degrades to the general
    /// case rather than to the wrong case; and the general case
    /// ``extractionFailed(reason:)`` carries `yt-dlp`'s message unchanged, so
    /// nothing is lost when a match is missed.
    public static func mapping(_ exception: PythonException) -> MediaFetchError {
        let message = exception.message
        let haystack = message.lowercased()

        func mentions(_ needles: String...) -> Bool {
            needles.contains { haystack.contains($0) }
        }

        // The platform restriction is checked first and on the flag rather than
        // on the text: it is the one failure that means "this design has a
        // hole", and it must never be absorbed into a generic case.
        if exception.isPlatformRestriction {
            return .subprocessRequired(reason: message)
        }

        if exception.type == "ModuleNotFoundError" || exception.type.hasSuffix("ImportError") {
            return .notInstalled(reason: message)
        }

        if mentions("unsupported url", "no suitable extractor") {
            return .unsupportedSite(url: message)
        }
        if mentions("drm", "protected by") {
            return .drmProtected(reason: message)
        }
        if mentions(
            "sign in to confirm you're not a bot", "sign in to confirm your age",
            "confirm you're not a bot", "the page needs to be reloaded", "captcha")
        {
            return .botCheckFailed(reason: message)
        }
        if mentions(
            "login required", "requires authentication", "sign in", "log in",
            "members-only", "subscribers only", "private video", "this video is private")
        {
            // "private video" is authentication-shaped: the item exists and
            // someone can see it, just not this caller.
            return .authenticationRequired(reason: message)
        }
        if mentions(
            "available in your country", "blocked in your country", "blocked it in your country",
            "not available from your location", "geo restrict", "geo-restrict", "geo restriction",
            "geographic")
        {
            // "available in your country" rather than "not available in your
            // country": the extractors phrase the negation half a dozen ways —
            // "has not made this video available in your country" among them —
            // and the positive phrase never appears on its own.
            return .geoRestricted(reason: message)
        }
        if mentions("live event", "is live", "live stream has not", "premieres in") {
            return .liveStream(reason: message)
        }
        if mentions(
            "video unavailable", "this video is unavailable", "has been removed",
            "no longer available", "does not exist", "account associated with this video has been terminated")
        {
            return .unavailable(reason: message)
        }
        if mentions("requested format is not available", "no video formats found", "only images are available") {
            return .noUsableFormat(reason: message)
        }
        if exception.type == "URLError" || exception.type.contains("HTTPError")
            || mentions("unable to download", "connection reset", "timed out", "temporary failure in name resolution")
        {
            return .transferFailed(reason: message)
        }

        return .extractionFailed(reason: message)
    }

    /// Maps whatever came out of the Python layer, keeping non-Python failures
    /// distinguishable from extraction failures.
    public static func mapping(_ error: any Error) -> MediaFetchError {
        switch error {
        case let fetch as MediaFetchError:
            return fetch
        case let PythonError.raised(exception):
            return .mapping(exception)
        case let python as PythonError:
            return .runtimeFailed(reason: python.localizedDescription)
        case let package as PythonPackageError:
            return .notInstalled(reason: package.localizedDescription)
        default:
            return .runtimeFailed(reason: (error as NSError).localizedDescription)
        }
    }

    /// Whether trying the same thing again could plausibly work.
    ///
    /// Not a retry policy — a hint for one. A caller that offers a "try again"
    /// button should not offer it for a removed video.
    public var isWorthRetrying: Bool {
        switch self {
        case .transferFailed, .botCheckFailed, .incompleteDownload: true
        default: false
        }
    }
}

extension MediaFetchError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .notInstalled(reason):
            "yt-dlp is not available in this interpreter: \(reason)"
        case let .unsupportedSite(url):
            "No extractor recognised that URL: \(url)"
        case let .unavailable(reason):
            "The item is not available: \(reason)"
        case let .geoRestricted(reason):
            "The item is blocked in this region: \(reason)"
        case let .authenticationRequired(reason):
            "The site wants credentials for this item: \(reason)"
        case let .botCheckFailed(reason):
            "The site refused this client as automated traffic: \(reason)"
        case let .drmProtected(reason):
            "Every rendition is DRM-protected, so a download would not be playable: \(reason)"
        case let .liveStream(reason):
            "This is a live stream with no end: \(reason)"
        case let .isPlaylist(title, count):
            "That URL is a playlist"
                + (title.map { " (\($0))" } ?? "")
                + (count >= 0 ? " of \(count) items" : "")
                + ", not a single item. Extract one of its entries instead."
        case let .noUsableFormat(reason):
            "No rendition matched: \(reason)"
        case let .unknownFormat(id):
            "This listing has no format with the id \(id)."
        case let .transferFailed(reason):
            "The download failed: \(reason)"
        case let .incompleteDownload(path, reason):
            "The download at \(path) is incomplete: \(reason)"
        case let .muxingFailed(stage, reason):
            "Joining the video and audio streams failed during \(stage): \(reason)"
        case let .subprocessRequired(reason):
            "yt-dlp tried to start a helper process, which this platform does not permit (PEP 730). "
                + "This is a gap in LatheFetch rather than a fault in the request: \(reason)"
        case let .extractionFailed(reason):
            reason
        case let .runtimeFailed(reason):
            "The embedded interpreter failed: \(reason)"
        }
    }
}
