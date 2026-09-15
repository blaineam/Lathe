import Foundation
import LatheCore
import LatheFetch

/// A cancellation flag that any thread can read.
///
/// Returning `false` from a progress report is how a `ProgressHandle` asks a
/// downloader to stop, and that answer has to be given on the downloader's own
/// thread. So the flag lives here, behind a lock, rather than on the
/// main-actor model that owns everything else about a download.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    func cancel() {
        lock.lock()
        flag = true
        lock.unlock()
    }
}

/// Which tool should handle a URL.
enum Tool: String, CaseIterable, Identifiable, Sendable {
    /// Decide per URL. The default, and what almost everyone should leave it on.
    case automatic
    /// Stream the URL itself. Needs nothing installed.
    case direct
    /// yt-dlp.
    case media
    /// gallery-dl.
    case gallery

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .direct: return "Direct link"
        case .media: return "yt-dlp"
        case .gallery: return "gallery-dl"
        }
    }
}

/// How much of a page to take.
enum Scope: String, CaseIterable, Identifiable, Sendable {
    /// Just this item. A playlist URL fails rather than quietly starting two
    /// hundred downloads.
    case single
    /// Everything the page holds.
    case all

    var id: String { rawValue }
    var label: String { self == .single ? "Just this" : "Everything" }
}

/// One URL the user asked for.
@MainActor
@Observable
final class Download: Identifiable {
    enum State: Equatable {
        case queued
        case inspecting
        case running(fraction: Double)
        /// A file, or — for a gallery — the directory the files went into.
        case finished(URL)
        case failed(String)

        var isTerminal: Bool {
            if case .finished = self { return true }
            if case .failed = self { return true }
            return false
        }
    }

    let id = UUID()
    let url: URL
    var state: State = .queued
    var title: String?
    var detail: String?
    var byteCount: Int = 0

    /// How many files this produced. One for ordinary media; a gallery makes many.
    var fileCount: Int = 1

    var scope: Scope = .single
    var tool: Tool = .automatic

    /// The session to download with, exported from the browser for this URL's
    /// site. Carried per download rather than set globally because two
    /// downloads from two sites can be in flight at once, and one site's
    /// cookies must never be sent to the other.
    var cookieFile: URL?

    /// What the downloader is doing right now — "downloading", "mux", or
    /// "item 3 of 40" for a playlist. Shown under the title, because a long
    /// download with a moving bar and no words is still a mystery.
    var stage: String?

    /// Set by the cancel button, read by the progress sink.
    ///
    /// A separate object rather than a property, because the sink runs on
    /// whatever thread the downloader is on and has to answer "keep going?"
    /// *synchronously* — it cannot await the main actor to find out. A
    /// main-actor property is unreadable from there, and marking one
    /// `nonisolated(unsafe)` would be a data race with a comment on it.
    let cancellation = CancelToken()

    var isCancelled: Bool { cancellation.isCancelled }

    /// What the router decided, once it has decided. Shown in the row, because
    /// "which tool is this using" is the first question when something fails.
    var resolvedTool: Tool?

    init(url: URL) { self.url = url }

    /// Something to show before the extractor has said what this is.
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        let last = url.lastPathComponent
        if !last.isEmpty, last != "/" { return last }
        return url.host() ?? url.absoluteString
    }
    var host: String { url.host() ?? "" }
}

/// Whether the tools that do the extracting are present.
///
/// Lathe ships **no extractor**. yt-dlp and gallery-dl are installed by the
/// user, at run time, into the app's own Python environment — which is what
/// keeps this a downloader the user assembled rather than one that arrives with
/// a thousand sites baked in. The onboarding exists to make that a button
/// rather than a README.
@MainActor
@Observable
final class ToolStatus {
    var isChecking = false

    var ytdlpInstalled = false
    var ytdlpVersion: String?
    var ytdlpInstalling = false

    var galleryDLInstalled = false
    var galleryDLVersion: String?
    var galleryDLInstalling = false

    /// A capability note rather than an error — "installed, but the JavaScript
    /// challenge solver is missing" is worth saying and is not a failure.
    var installMessage: String?
    var lastError: String?

    var isInstalling: Bool { ytdlpInstalling || galleryDLInstalling }

    /// Plain URLs work with nothing installed at all, which is worth saying in
    /// the interface: a direct link to an .mp4 needs no extractor.
    var canDownloadPlainURLs: Bool { true }
    var anyExtractor: Bool { ytdlpInstalled || galleryDLInstalled }
}
