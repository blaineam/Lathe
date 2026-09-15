import AppKit
import Foundation
import LatheCore
import LatheFetch

/// The download queue.
@MainActor
@Observable
final class Queue {
    var downloads: [Download] = []
    var tools = ToolStatus()
    var isRunning = false
    var summary: String?

    /// What new URLs get, until the user changes it.
    var defaultScope: Scope = .single
    var defaultTool: Tool = .automatic

    /// Where finished files land. Picked by the user, and remembered as a
    /// security-scoped bookmark so it survives a relaunch — and so the same
    /// grant can later be handed to Sami, which is the thing that makes the
    /// hand-off possible at all.
    var destination: URL? {
        didSet { saveDestinationBookmark() }
    }

    /// Route traffic through a local SOCKS proxy — Tor, usually.
    var useTor = false
    var proxy = SOCKSProxy()

    /// Hand finished media to Sami, if it is installed.
    var handOffToSami = false
    var samiInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.samiBundleID) != nil
    }
    private static let samiBundleID = "com.wemiller.sami"

    private let pool = ResourcePool.automatic

    // MARK: - Cookies

    /// Cookie files the browser has exported, by host.
    ///
    /// Keyed by host and never merged, because the whole safety property of
    /// the browser hand-off is that a site gets its own session and nothing
    /// else's. One jar for everything would hand every download every login
    /// the user has.
    private var cookieFiles: [String: URL] = [:]

    var cookieHosts: [String] { cookieFiles.keys.sorted() }

    /// Where a site's exported cookies live.
    ///
    /// Inside the app's own Application Support, with owner-only permissions:
    /// these are live session tokens, and a file in a shared temporary
    /// directory would be readable by anything else running as this user.
    private func cookieDirectory() throws -> URL {
        let directory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lathe/cookies", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return directory
    }

    /// Takes the browser's session for one site and remembers it for downloads
    /// from that site.
    @discardableResult
    func adoptCookies(from browser: BrowserModel) async -> String? {
        guard let host = browser.currentURL?.host() else { return nil }
        do {
            let file = try cookieDirectory()
                .appendingPathComponent("\(host).txt")
            try await browser.exportCookies(to: file)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path)
            cookieFiles[host] = file
            // Apply to anything already queued for that site, so pressing
            // "Use this session" after queueing does what it looks like it does.
            for download in downloads where download.host == host && !download.state.isTerminal {
                download.cookieFile = file
            }
            return host
        } catch {
            summary = "Could not read this site's cookies: \(Self.describe(error))"
            return nil
        }
    }

    /// Forgets an exported session and deletes the file.
    func forgetCookies(for host: String) {
        if let file = cookieFiles.removeValue(forKey: host) {
            try? FileManager.default.removeItem(at: file)
        }
        for download in downloads where download.host == host {
            download.cookieFile = nil
        }
    }

    // MARK: - Fetchers

    /// One fetcher per distinct set of credentials.
    ///
    /// `MediaFetcher.configuration` belongs to the actor, not to the call, so
    /// two concurrent downloads cannot each set their own cookie file on a
    /// shared one without racing — and losing that race means sending one
    /// site's session to another site. Keying a small cache by the
    /// configuration that varies gives every download a fetcher whose settings
    /// nothing else is changing underneath it.
    private struct FetcherKey: Hashable {
        let cookieFile: String?
        let proxy: String?
        /// Whether this fetcher treats a link naming both an item and a
        /// collection as the collection. Part of the key because it is a
        /// property of the fetcher's configuration, and two rows in the same
        /// queue can legitimately want opposite answers.
        var wantsCollections = false
    }
    private var mediaFetchers: [FetcherKey: MediaFetcher] = [:]
    private var galleryFetchers: [FetcherKey: GalleryFetcher] = [:]

    private func pythonRoot() throws -> URL {
        let root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lathe/python", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Built lazily, because there may be no interpreter to build it on.
    ///
    /// `PythonLayout.discover` throws when it cannot find one, and that is a
    /// state the app has to present rather than crash on — it is exactly the
    /// case onboarding exists for. Plain URLs keep working without it.
    private func runtime() throws -> PythonRuntime {
        // bootstrap, not a plain init: loading CPython is a process-wide,
        // once-only act, and `current` is how a second caller gets the one that
        // is already up rather than a second interpreter in the same process.
        try PythonRuntime.current
            ?? PythonRuntime.bootstrap(PythonRuntime.Configuration(layout: PythonLayout.discover()))
    }

    private func mediaFetcher(cookieFile: URL?, scope: Scope = .single) async throws -> MediaFetcher {
        let key = FetcherKey(
            cookieFile: cookieFile?.path, proxy: proxyURL, wantsCollections: scope == .all)
        if let existing = mediaFetchers[key] { return existing }
        let runtime = try runtime()
        var configuration = MediaFetcher.Configuration()
        configuration.cookieFile = cookieFile
        configuration.proxy = proxyURL
        configuration.ignoresPlaylists = scope == .single
        configuration.cacheDirectory = try? pythonRoot().appendingPathComponent("cache")
        let made = MediaFetcher(
            runtime: runtime,
            installer: PythonPackageInstaller(runtime: runtime, root: try pythonRoot()),
            configuration: configuration)
        mediaFetchers[key] = made
        return made
    }

    private func galleryFetcher(cookieFile: URL?) async throws -> GalleryFetcher {
        let key = FetcherKey(cookieFile: cookieFile?.path, proxy: proxyURL)
        if let existing = galleryFetchers[key] { return existing }
        let runtime = try runtime()
        var configuration = GalleryFetcher.Configuration()
        configuration.cookieFile = cookieFile
        configuration.proxy = proxyURL
        let made = GalleryFetcher(
            runtime: runtime,
            installer: PythonPackageInstaller(runtime: runtime, root: try pythonRoot()),
            configuration: configuration)
        galleryFetchers[key] = made
        return made
    }

    /// Discards every cached fetcher.
    ///
    /// Called when the proxy setting changes: a fetcher built without a proxy
    /// would keep downloading without one, which is the exact failure the
    /// fail-closed rule exists to prevent.
    private func invalidateFetchers() {
        mediaFetchers.removeAll()
        galleryFetchers.removeAll()
    }

    private var proxyURL: String? { useTor ? proxy.extractorProxyURL : nil }

    init() {
        restoreDestinationBookmark()
    }

    // MARK: - Adding

    /// Accepts anything paste-shaped: one URL, many, newline or space separated.
    @discardableResult
    func add(text: String) -> Int {
        let candidates = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
        var added = 0
        for candidate in candidates {
            guard let url = URL(string: candidate), url.scheme != nil,
                  !downloads.contains(where: { $0.url == url })
            else { continue }
            let download = Download(url: url)
            download.scope = defaultScope
            download.tool = defaultTool
            if let host = url.host() { download.cookieFile = cookieFiles[host] }
            downloads.append(download)
            added += 1
        }
        summary = added > 0 ? "\(added) added" : nil
        return added
    }

    func remove(_ download: Download) {
        downloads.removeAll { $0.id == download.id }
    }

    func clearFinished() {
        downloads.removeAll { $0.state.isTerminal }
    }

    // MARK: - Tools

    func refreshTools() async {
        tools.isChecking = true
        defer { tools.isChecking = false }

        do {
            let readiness = try await mediaFetcher(cookieFile: nil).readiness()
            tools.ytdlpInstalled = readiness.isInstalled
            tools.ytdlpVersion = readiness.version
            tools.installMessage = readiness.isFullyOperational
                ? nil
                : readiness.javaScriptUnavailableReason ?? readiness.solverScriptsReason
        } catch {
            tools.ytdlpInstalled = false
            tools.ytdlpVersion = nil
            // The reason, not just the absence — "no Python interpreter was
            // found" and "yt-dlp is not installed yet" need different buttons.
            tools.installMessage = Self.describe(error)
        }

        do {
            let readiness = try await galleryFetcher(cookieFile: nil).readiness()
            tools.galleryDLInstalled = readiness.isInstalled
            tools.galleryDLVersion = readiness.version
        } catch {
            tools.galleryDLInstalled = false
            tools.galleryDLVersion = nil
        }
    }

    func installYouTubeDL() async {
        tools.ytdlpInstalling = true
        tools.lastError = nil
        defer { tools.ytdlpInstalling = false }
        do {
            _ = try await mediaFetcher(cookieFile: nil).install()
            await refreshTools()
        } catch {
            tools.lastError = Self.describe(error)
        }
    }

    func installGalleryDL() async {
        tools.galleryDLInstalling = true
        tools.lastError = nil
        defer { tools.galleryDLInstalling = false }
        do {
            _ = try await galleryFetcher(cookieFile: nil).install()
            await refreshTools()
        } catch {
            tools.lastError = Self.describe(error)
        }
    }

    // MARK: - Running

    func start() async {
        guard !isRunning, !downloads.isEmpty else { return }

        // Fail closed. If the proxy is not there, nothing is downloaded — a
        // downloader that quietly abandons the proxy it was told to use is
        // worse than one that has no proxy option at all.
        if useTor {
            do {
                try await proxy.verify()
            } catch {
                summary = Self.describe(error)
                return
            }
        }

        guard let folder = destination ?? defaultDestination() else {
            summary = "Choose where downloads should go first."
            return
        }

        isRunning = true
        defer { isRunning = false }
        let started = Date()

        let pending = downloads.filter { !$0.state.isTerminal }
        let items = pending.map { BulkRun.Item($0, workload: .network) }
        let session = useTor ? proxy.urlSession() : URLSession.shared

        _ = await BulkRun(pool: pool).run(items) { download in
            await self.run(download, into: folder, session: session)
        }

        let done = downloads.filter { if case .finished = $0.state { return true } else { return false } }
        let files = done.reduce(0) { $0 + $1.fileCount }
        summary = "\(done.count) of \(pending.count)"
            + (files > done.count ? " — \(files) files" : "")
            + " in \(String(format: "%.0f", Date().timeIntervalSince(started)))s"

        if handOffToSami, samiInstalled {
            let finished = done.compactMap { download -> URL? in
                if case .finished(let url) = download.state { return url }
                return nil
            }
            if !finished.isEmpty { openInSami(finished) }
        }
    }

    /// One download, routed to whichever tool should handle it.
    private func run(_ download: Download, into folder: URL, session: URLSession) async {
        download.state = .inspecting
        do {
            let tool = try await route(download)
            download.resolvedTool = tool
            switch tool {
            case .direct, .automatic:
                let output = try await downloadDirectly(download, into: folder, session: session)
                download.state = .finished(output)
                download.byteCount =
                    (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
            case .media:
                try await downloadWithMediaExtractor(download, into: folder)
            case .gallery:
                try await downloadWithGalleryExtractor(download, into: folder)
            }
        } catch {
            download.state = .failed(Self.describe(error, for: download))
        }
    }

    /// Which tool should handle this URL.
    ///
    /// The order matters and is not arbitrary:
    ///
    /// 1. A link that is already a media file is streamed directly. It needs
    ///    nothing installed, so the app works before onboarding rather than
    ///    after it.
    /// 2. A named yt-dlp extractor wins. Named means yt-dlp knows the site
    ///    rather than guessing from whatever the page contains — its generic
    ///    extractor claims every URL ever written, so "does yt-dlp support
    ///    this" is only a useful question with the generic one excluded.
    /// 3. Otherwise gallery-dl, if it claims the site. It has no generic
    ///    fallback, so a claim from it is a real one.
    /// 4. Otherwise yt-dlp's generic extractor, which is the right last
    ///    resort: it fetches the page and looks for something media-shaped.
    private func route(_ download: Download) async throws -> Tool {
        if download.tool != .automatic { return download.tool }
        if Self.looksLikeMediaFile(download.url) { return .direct }

        if tools.ytdlpInstalled,
           let fetcher = try? await mediaFetcher(cookieFile: download.cookieFile),
           let named = try? await fetcher.extractorName(for: download.url),
           !named.isEmpty {
            return .media
        }

        if tools.galleryDLInstalled,
           let fetcher = try? await galleryFetcher(cookieFile: download.cookieFile),
           let support = try? await fetcher.support(for: download.url), support.isSupported {
            return .gallery
        }

        return tools.ytdlpInstalled ? .media : .direct
    }

    // MARK: - The three paths

    private func downloadDirectly(
        _ download: Download, into folder: URL, session: URLSession
    ) async throws -> URL {
        guard let source = try? MediaSource(download.url), source.isRemote,
              Self.looksLikeMediaFile(download.url)
        else {
            throw LatheError.notImplemented(
                feature: "\(download.url.host() ?? "that site") needs an extractor. Install one "
                    + "from the banner above, or paste a direct link to a media file"
            )
        }
        let output = Self.unique(folder.appendingPathComponent(download.url.lastPathComponent))
        download.state = .running(fraction: 0)
        try await URLSessionMediaTransport(session: session).download(
            download.url, to: output, limits: .standard, progress: nil)
        return output
    }

    private func downloadWithMediaExtractor(_ download: Download, into folder: URL) async throws {
        let fetcher = try await mediaFetcher(cookieFile: download.cookieFile, scope: download.scope)
        download.state = .running(fraction: 0)

        // A playlist is not a failure when the user asked for everything. It
        // is the reason `entries(of:)` exists: expand it here rather than
        // making them paste two hundred URLs.
        if download.scope == .all {
            if let playlist = try? await fetcher.entries(of: download.url), !playlist.entries.isEmpty {
                try await downloadPlaylist(playlist, of: download, using: fetcher, into: folder)
                return
            }
        }

        let listing = try await fetcher.listing(for: download.url)
        download.title = listing.title
        let output = try await fetch(listing, of: download, using: fetcher, into: folder)
        download.state = .finished(output)
        download.byteCount =
            (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
    }

    private func fetch(
        _ listing: MediaListing, of download: Download,
        using fetcher: MediaFetcher, into folder: URL
    ) async throws -> URL {
        let name = (listing.title ?? download.url.lastPathComponent)
            .replacingOccurrences(of: "/", with: "-")
        let output = Self.unique(
            folder.appendingPathComponent(name).appendingPathExtension("mp4"))
        let media = try await fetcher.download(
            download.url, to: output)
        return media.url
    }

    private func downloadPlaylist(
        _ playlist: Playlist, of download: Download,
        using fetcher: MediaFetcher, into folder: URL
    ) async throws {
        let directory = Self.unique(
            folder.appendingPathComponent(
                (playlist.title ?? download.displayTitle).replacingOccurrences(of: "/", with: "-"),
                isDirectory: true))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        download.title = playlist.title

        var written = 0
        var lastFailure: String?
        for (index, entry) in playlist.entries.enumerated() {
            if Task.isCancelled { break }
            download.state = .running(fraction: Double(index) / Double(playlist.entries.count))
            guard let entryURL = URL(string: entry.url) else { continue }
            do {
                // Each entry is a single item, whatever the parent was — a
                // fetcher still configured to prefer collections would walk
                // into the next one's autoplay mix.
                let itemFetcher = try await mediaFetcher(
                    cookieFile: download.cookieFile, scope: .single)
                let listing = try await itemFetcher.listing(for: entryURL)
                let name = (listing.title ?? entry.title ?? "item-\(index + 1)")
                    .replacingOccurrences(of: "/", with: "-")
                let output = Self.unique(
                    directory.appendingPathComponent(name).appendingPathExtension("mp4"))
                _ = try await itemFetcher.download(entryURL, to: output)
                written += 1
            } catch {
                // One dead entry in a playlist of two hundred is not a reason
                // to throw away the other hundred and ninety-nine.
                lastFailure = Self.describe(error)
            }
        }

        download.fileCount = written
        if written == 0 {
            throw LatheError.notImplemented(
                feature: "none of the \(playlist.entries.count) items could be downloaded"
                    + (lastFailure.map { " — \($0)" } ?? ""))
        }
        download.detail = "\(written) of \(playlist.entries.count)"
        download.state = .finished(directory)
    }

    private func downloadWithGalleryExtractor(_ download: Download, into folder: URL) async throws {
        let fetcher = try await galleryFetcher(cookieFile: download.cookieFile)
        let name = (download.title ?? download.displayTitle)
            .replacingOccurrences(of: "/", with: "-")
        let directory = Self.unique(folder.appendingPathComponent(name, isDirectory: true))
        download.state = .running(fraction: 0)

        // "Just this" on a gallery means one file, not the whole album.
        let haul = try await fetcher.download(
            download.url, into: directory, limit: download.scope == .single ? 1 : nil)

        guard !haul.files.isEmpty else {
            try? FileManager.default.removeItem(at: directory)
            throw LatheError.notImplemented(
                feature: "gallery-dl recognised \(download.host) but found no files on that page")
        }
        download.fileCount = haul.files.count
        download.detail = haul.files.count == 1 ? nil : "\(haul.files.count) files"
        // One file goes to the file, so "Show in Finder" selects the thing
        // that was downloaded rather than a folder containing one item.
        download.state = .finished(haul.files.count == 1 ? haul.files[0] : directory)
    }

    // MARK: - Errors

    /// A message somebody can act on.
    ///
    /// Everything this package throws is a `LocalizedError` with a written
    /// explanation, and the app used to print the raw enum case for all of
    /// them because it only asked `LatheError` for its description — so a
    /// perfectly good sentence arrived as
    /// `noUsableFormat(reason: "the extractor returned no formats at all")`.
    static func describe(_ error: any Error) -> String {
        (error as? any LocalizedError)?.errorDescription ?? "\(error)"
    }

    /// The same, with the two cases where the library's honest answer is still
    /// not the useful one — because the real problem is the URL, and only the
    /// app knows where that came from.
    static func describe(_ error: any Error, for download: Download) -> String {
        if let fetchError = error as? MediaFetchError {
            switch fetchError {
            case .noUsableFormat(let reason) where reason.contains("no formats at all"):
                return "There is nothing to download on this page. "
                    + "\(download.host) recognised it, but it holds no media — "
                    + "open the item you want and queue that instead."
            case .isPlaylist(let title, let count):
                let what = title.map { "“\($0)”" } ?? "That URL"
                let many = count > 0 ? " of \(count) items" : ""
                return "\(what) is a collection\(many), not a single item. "
                    + "Set this row to “Everything” to download all of it."
            default:
                break
            }
        }
        return describe(error)
    }

    private nonisolated static func looksLikeMediaFile(_ url: URL) -> Bool {
        ["mp4", "m4v", "mov", "webm", "mkv", "mp3", "m4a", "opus", "flac", "wav",
         "jpg", "jpeg", "png", "gif", "webp", "avif", "heic", "pdf", "cbz", "zip"]
            .contains(url.pathExtension.lowercased())
    }

    /// Never overwrite. A second download of the same thing makes a second file.
    private nonisolated static func unique(_ url: URL) -> URL {
        var candidate = url
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let base = url.deletingPathExtension().lastPathComponent
            let extensionPart = url.pathExtension
            var next = url.deletingLastPathComponent()
                .appendingPathComponent("\(base)-\(counter)")
            if !extensionPart.isEmpty { next = next.appendingPathExtension(extensionPart) }
            candidate = next
            counter += 1
        }
        return candidate
    }

    // MARK: - Sami

    private func openInSami(_ urls: [URL]) {
        guard let sami = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.samiBundleID)
        else { return }
        // `open -a`, which is the arrangement that works without either app
        // knowing anything about the other's internals. An App Intent would be
        // better and is what the hand-off should become.
        NSWorkspace.shared.open(urls, withApplicationAt: sami,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: - Destination

    func defaultDestination() -> URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "Where should downloads go?"
        if panel.runModal() == .OK { destination = panel.url }
    }

    func setTorRouting(_ enabled: Bool) {
        useTor = enabled
        invalidateFetchers()
    }

    private func saveDestinationBookmark() {
        guard let destination else { return }
        // Security-scoped, because this grant is what a future hand-off to Sami
        // has to be built on: a sandboxed app cannot read a folder nobody
        // granted it, and this is the grant.
        if let data = try? destination.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        ) {
            UserDefaults.standard.set(data, forKey: "destinationBookmark")
        }
    }

    private func restoreDestinationBookmark() {
        guard let data = UserDefaults.standard.data(forKey: "destinationBookmark") else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                              relativeTo: nil, bookmarkDataIsStale: &stale), !stale {
            _ = url.startAccessingSecurityScopedResource()
            destination = url
        }
    }
}
