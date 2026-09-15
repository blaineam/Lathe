import Foundation
import LatheCore
import LatheFetch

/// One URL the user asked for.
@MainActor
@Observable
final class Download: Identifiable {
    enum State: Equatable {
        case queued
        case inspecting
        case running(fraction: Double)
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
    var galleryDLInstalled = false
    var installMessage: String?
    var isInstalling = false
    var lastError: String?

    /// Plain URLs work with nothing installed at all, which is worth saying in
    /// the interface: a direct link to an .mp4 needs no extractor.
    var canDownloadPlainURLs: Bool { true }
    var anyExtractor: Bool { ytdlpInstalled || galleryDLInstalled }
}
