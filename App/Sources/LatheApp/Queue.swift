#if os(macOS)
import AppKit
#endif
import Foundation
import LatheCore
import LatheFetch
import SwiftUI

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

    /// Where the proxy comes from.
    var torMode: TorMode = TorController.isAvailable ? .embedded : .external

    let tor = TorController()

    var torStatus: String {
        guard useTor else { return "Off" }
        return torMode == .embedded ? tor.state.label : "Using \(proxy.host):\(proxy.port)"
    }

    var torStatusColor: Color {
        guard useTor else { return .secondary }
        if torMode == .external { return .yellow }
        switch tor.state {
        case .running: return .green
        case .failed, .unavailable: return .red
        default: return .yellow
        }
    }

    /// The endpoint in use, which for the embedded client is its own port.
    var activeProxy: SOCKSProxy { torMode == .embedded ? tor.endpoint : proxy }

    /// Hand finished media to Sami, if it is installed.
    var handOffToSami = false
    var samiInstalled: Bool {
        #if os(macOS)
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.samiBundleID) != nil
        #else
        // Sami is a Mac app and the hand-off is a Mac mechanism: one app
        // launching another with a file list. There is no iOS equivalent
        // worth pretending to, so the feature is simply absent there.
        false
        #endif
    }
    private static let samiBundleID = "com.blainemiller.Sami"

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

    /// Takes a tab's session for its site and remembers it for downloads from
    /// that site.
    @discardableResult
    func adoptCookies(from tab: BrowserTab) async -> String? {
        guard let host = tab.host else { return nil }
        do {
            let file = try cookieDirectory()
                .appendingPathComponent("\(host).txt")
            try await tab.exportCookies(to: file)
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

    private var proxyURL: String? { useTor ? activeProxy.extractorProxyURL : nil }

    /// Changes when the routing does, so views can react to it.
    var routingSignature: String { useTor ? activeProxy.extractorProxyURL : "direct" }

    /// Links dropped in by Shortcuts, scripts, or the phone.
    private let inbox = Inbox()
    private(set) var watchesInbox = UserDefaults.standard.object(forKey: "watchesInbox") as? Bool ?? true

    init() {
        restoreDestinationBookmark()
        inbox.onURL = { [weak self] request in
            guard let self else { return }
            let added = add(text: request.url.absoluteString, scope: request.scope)
            DiagnosticLog.note("queue: add returned \(added), queue now holds \(downloads.count)")
            if added == 0 {
                // Already on the list. Sharing it again is somebody asking for
                // it again — usually because the first attempt failed, or
                // because they have now chosen different answers — so the
                // answers are applied to the row that is already there rather
                // than dropped on the floor.
                guard let existing = downloads.first(where: { $0.url == request.url })
                else { return }
                switch existing.state {
                // Leave a download in flight, and a finished one, alone.
                case .running, .finished: return
                default: break
                }
                if let scope = request.scope { existing.scope = scope }
                existing.state = .queued
                existing.stage = nil
                existing.detail = nil
            }
            if let destination = request.destination {
                inboxDestination = destination
            }
            // The share sheet already asked whether to start. Anything that
            // arrives without an answer is queued and left alone: something
            // sent from a phone is not a reason to saturate the connection
            // without being asked, and the row is visible the moment it lands.
            guard !request.queueOnly, request.scope != nil || request.destination != nil else {
                DiagnosticLog.note("queue: not starting — queueOnly=\(request.queueOnly) scope=\(request.scope != nil) destination=\(request.destination != nil)")
                return
            }
            DiagnosticLog.note("queue: starting")
            Task { await self.start() }
        }
        if watchesInbox { inbox.start() }
    }

    func setInboxWatching(_ enabled: Bool) {
        watchesInbox = enabled
        UserDefaults.standard.set(enabled, forKey: "watchesInbox")
        if enabled { inbox.start() } else { inbox.stop() }
    }

    func drainInbox() { inbox.drain() }

    // MARK: - Adding

    /// Accepts anything paste-shaped: one URL, many, newline or space separated.
    @discardableResult
    func add(text: String, scope: Scope? = nil) -> Int {
        let candidates = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
        var added = 0
        for candidate in candidates {
            guard let url = URL(string: candidate), url.scheme != nil,
                  !downloads.contains(where: { $0.url == url })
            else { continue }
            let download = Download(url: url)
            download.scope = scope ?? defaultScope
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

    /// Puts a download that failed back in the queue and runs it again.
    ///
    /// A failure is usually the network, the site, or a tool that needed
    /// updating — none of which mean the link was wrong. Retyping it to try
    /// again was the only way, and it lost the scope and the session that had
    /// been set on it.
    func retry(_ download: Download) {
        guard case .failed = download.state else { return }
        download.state = .queued
        download.stage = nil
        download.detail = nil
        download.byteCount = 0
        summary = nil
        // A run in flight took its list when it started, so this one joins the
        // next run; otherwise it starts now.
        if !isRunning {
            Task { await start() }
        }
    }

    /// Everything that failed, back in the queue at once.
    func retryFailed() {
        let failures = downloads.filter { if case .failed = $0.state { return true } else { return false } }
        guard !failures.isEmpty else { return }
        for download in failures {
            download.state = .queued
            download.stage = nil
            download.detail = nil
            download.byteCount = 0
        }
        summary = nil
        if !isRunning { Task { await start() } }
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

    /// Brings a tool up to the newest release.
    ///
    /// The same call as installing: the resolver re-reads the index and
    /// replaces what has moved on. That is the whole reason these are fetched
    /// rather than bundled — a downloader that cannot be updated without
    /// shipping a new app is a downloader that is broken every time a site
    /// changes, which is weekly.
    func update(_ tool: Tool) async {
        switch tool {
        case .media: await installYouTubeDL()
        case .gallery: await installGalleryDL()
        default: break
        }
    }

    /// Removes a tool and everything installed for it.
    func remove(_ tool: Tool) async {
        let requirements: [String]
        switch tool {
        case .media: requirements = MediaFetcher.requirements
        case .gallery: requirements = GalleryFetcher.requirements
        default: return
        }
        do {
            let installer = PythonPackageInstaller(runtime: try runtime(), root: try pythonRoot())
            for name in requirements {
                try? await installer.remove(name)
            }
            // The fetchers hold an interpreter that still has the module
            // imported, so they have to go too or readiness keeps reporting it
            // as present until the app is relaunched.
            invalidateFetchers()
            await refreshTools()
        } catch {
            tools.lastError = Self.describe(error)
        }
    }

    /// What is installed, for the manager to list.
    func installedPackages() async -> [PythonPackageInstaller.InstalledPackage] {
        guard let root = try? pythonRoot(), let runtime = try? runtime() else { return [] }
        let installer = PythonPackageInstaller(runtime: runtime, root: root)
        return (try? await installer.installed()) ?? []
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
        guard !isRunning, !downloads.isEmpty else {
            DiagnosticLog.note("start: refused — isRunning=\(isRunning) downloads=\(downloads.count)")
            return
        }
        DiagnosticLog.note("start: entered with \(downloads.count) download(s), useTor=\(useTor)")

        // Fail closed. If the proxy is not there, nothing is downloaded — a
        // downloader that quietly abandons the proxy it was told to use is
        // worse than one that has no proxy option at all.
        if useTor {
            do {
                try await readyProxy()
            } catch {
                DiagnosticLog.note("start: proxy not ready — \(Self.describe(error))")
                summary = Self.describe(error)
                return
            }
        }

        // A share that named where its files should go wins for this run;
        // otherwise the folder set in Lathe.
        let chosen = inboxDestination != nil ? defaultDestination() : (destination ?? defaultDestination())
        guard let folder = chosen else {
            DiagnosticLog.note("start: no destination — inboxDestination=\(inboxDestination?.rawValue ?? "nil")")
            summary = "Choose where downloads should go first."
            return
        }
        DiagnosticLog.note("start: running into \(folder.lastPathComponent)")

        isRunning = true
        defer { isRunning = false }
        let started = Date()

        let pending = downloads.filter { !$0.state.isTerminal }
        let items = pending.map { BulkRun.Item($0, workload: .network) }
        let session = useTor ? activeProxy.urlSession() : URLSession.shared

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

    /// Queue something and start it immediately, without touching the rest.
    ///
    /// The whole-queue button waits for you to finish adding things; this is
    /// for the other half of the time, when you are looking at the page and
    /// want that one thing now. Running rows are unaffected — the lane
    /// broker rations them the same way it rations a batch.
    @discardableResult
    func downloadNow(_ url: URL, scope: Scope? = nil) async -> Download? {
        if useTor {
            do { try await readyProxy() } catch {
                summary = Self.describe(error)
                return nil
            }
        }
        guard let folder = destination ?? defaultDestination() else {
            summary = "Choose where downloads should go first."
            return nil
        }

        let download: Download
        if let existing = downloads.first(where: { $0.url == url }), !existing.state.isTerminal {
            download = existing
        } else {
            download = Download(url: url)
            download.scope = scope ?? defaultScope
            download.tool = defaultTool
            if let host = url.host() { download.cookieFile = cookieFiles[host] }
            downloads.append(download)
        }
        if let scope { download.scope = scope }

        let session = useTor ? activeProxy.urlSession() : URLSession.shared
        await run(download, into: folder, session: session)
        return download
    }

    /// How many downloads are in flight, for the menu bar to show.
    var activeCount: Int {
        downloads.filter { !$0.state.isTerminal }.count
    }

    /// Stops everything.
    func cancelAll() {
        for download in downloads where !download.state.isTerminal {
            cancel(download)
        }
    }

    func cancel(_ download: Download) {
        download.cancellation.cancel()
        if !download.state.isTerminal {
            download.state = .failed("Cancelled.")
        }
    }

    /// Makes sure the proxy is actually there before anything is sent through
    /// it, starting the embedded client if that is the one in use.
    private func readyProxy() async throws {
        if torMode == .embedded, !tor.state.isUsable {
            await tor.start()
        }
        try await activeProxy.verify()
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
            DiagnosticLog.note("download failed: \(Self.describe(error, for: download)) [raw: \(error)]")
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

    /// A handle that drives one row's progress bar.
    ///
    /// All three download paths report through `ProgressHandle`, and none of
    /// them were given one — so every row sat at an indeterminate spinner from
    /// start to finish however long it took. The sink hops to the main actor
    /// because it is called from whatever thread the downloader is on.
    ///
    /// Returning `false` is how a handle asks the work to stop, which is what
    /// makes the cancel button on a running row work at all.
    private nonisolated static func handle(for download: Download) -> ProgressHandle {
        let cancellation = download.cancellation
        return ProgressHandle(sink: ClosureProgressSink { progress in
            let fraction = progress.fraction
            let stage = progress.stage
            let index = progress.unitIndex
            let count = progress.unitCount
            Task { @MainActor in
                guard !download.state.isTerminal else { return }
                download.state = .running(fraction: fraction ?? 0)
                download.stage = count > 1
                    ? "\(stage) — \(index + 1) of \(count)"
                    : stage
            }
            return !cancellation.isCancelled
        })
    }

    // MARK: - The three paths

    private func downloadDirectly(
        _ download: Download, into folder: URL, session: URLSession
    ) async throws -> URL {
        guard let source = try? MediaSource(download.url), source.isRemote,
              Self.looksLikeMediaFile(download.url)
        else {
            throw DownloadProblem.noExtractor(host: download.url.host() ?? "That site")
        }
        let output = Self.unique(folder.appendingPathComponent(download.url.lastPathComponent))
        download.state = .running(fraction: 0)
        try await URLSessionMediaTransport(session: session).download(
            download.url, to: output, limits: .standard, progress: Self.handle(for: download))
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

        // The extension has to match what is actually going to be written. It
        // was always ".mp4", which is right for the pair path — two streams
        // joined into an MPEG-4 file — and wrong for everything else: an MP3
        // taken from a page would have landed as `something.mp4` and confused
        // every player that trusts a filename.
        let selection = try FormatSelector.select(from: listing, policy: .best)
        let ext: String
        switch selection {
        case .pair:
            ext = "mp4"
        case .single(let format):
            ext = format.ext ?? "mp4"
        }

        let output = Self.unique(
            folder.appendingPathComponent(name).appendingPathExtension(ext))
        let media = try await fetcher.download(
            download.url, to: output, progress: Self.handle(for: download))
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
                _ = try await itemFetcher.download(
                    entryURL, to: output, progress: Self.handle(for: download))
                written += 1
            } catch {
                // One dead entry in a playlist of two hundred is not a reason
                // to throw away the other hundred and ninety-nine.
                lastFailure = Self.describe(error)
            }
        }

        download.fileCount = written
        if written == 0 {
            throw DownloadProblem.nothingFound(
                host: download.host,
                detail: "None of the \(playlist.entries.count) items could be downloaded."
                    + (lastFailure.map { " \($0)" } ?? ""),
                needsSignIn: download.cookieFile == nil
                    && SignInLikely.matches(download.host))
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
            download.url, into: directory,
            limit: download.scope == .single ? 1 : nil,
            progress: Self.handle(for: download))

        guard !haul.files.isEmpty else {
            try? FileManager.default.removeItem(at: directory)
            // The tool's own complaint, when it made one. "No files" on its own
            // is not a diagnosis — it is the same message for a page with
            // nothing on it, a login that expired, and a site that has started
            // refusing.
            throw DownloadProblem.nothingFound(
                host: download.host,
                detail: haul.problems.first,
                // Only suggest signing in when they are not already, or the
                // advice is both wrong and irritating.
                needsSignIn: download.cookieFile == nil
                    && SignInLikely.matches(download.host))
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

    /// What to ask Sami for. Mirrors Sami's own vocabulary.
    var samiIntent: Handoff.Intent = .compress

    /// The preset name to ask for, when the user has named one.
    var samiPreset: String = ""

    private func openInSami(_ urls: [URL]) {
        #if !os(macOS)
        _ = urls
        return
        #else
        guard let sami = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.samiBundleID)
        else { return }

        let handoff = Handoff(
            files: urls,
            intent: samiIntent,
            preset: samiPreset.isEmpty ? nil : samiPreset,
            destination: destination ?? defaultDestination())

        do {
            // The request travels as a document opened alongside the media.
            //
            // Sami is sandboxed: it cannot read a folder we chose, see our
            // preferences, or share a container with a locally built tool. The
            // one thing it can read is a file the system handed it, and
            // `open(_:withApplicationAt:)` grants access to exactly the files
            // in the call. So the options ride in the same delivery as the
            // media, and arrive or fail together.
            let document = try handoff.write()
            NSWorkspace.shared.open(
                handoff.openList(documentAt: document),
                withApplicationAt: sami,
                configuration: NSWorkspace.OpenConfiguration())

            // Left for Sami to read at its own pace, then swept. Deleting it
            // straight away would race the open.
            Task {
                try? await Task.sleep(for: .seconds(60))
                try? FileManager.default.removeItem(at: document.deletingLastPathComponent())
            }
        } catch {
            summary = "Could not hand off to Sami: \(Self.describe(error))"
            // The media still goes, without the options. A failed preference
            // is not a reason to lose the files.
            NSWorkspace.shared.open(urls, withApplicationAt: sami,
                                    configuration: NSWorkspace.OpenConfiguration())
        }
        #endif
    }

    // MARK: - Destination

    /// The folder Sami has been told to watch, if it named one.
    ///
    /// Sami is sandboxed and can only read a folder the user granted it, which
    /// means the user has to pick it *there*. Once they have, downloading into
    /// it is what lets Sami see the files without each one being opened —
    /// which is the difference between a hand-off and a pipeline.
    var samiFolder: SharedFolder? {
        SharedFolder.published(byBundleIdentifier: Self.samiBundleID)
    }

    /// Whether to prefer it over the download folder.
    var usesSamiFolder: Bool {
        get { UserDefaults.standard.bool(forKey: "usesSamiFolder") }
        set { UserDefaults.standard.set(newValue, forKey: "usesSamiFolder") }
    }

    /// Where the last share asked for its files, when it asked at all.
    ///
    /// Set per share rather than stored: the sender chose it for that link,
    /// not for every download from now on.
    var inboxDestination: Inbox.Request.Destination?

    func defaultDestination() -> URL? {
        switch inboxDestination {
        case .downloads:
            return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case .shared:
            // Beside the inbox, so a phone can reach the results as well as
            // send the link.
            if let folder = try? Inbox.outputLocation() { return folder }
        case nil:
            break
        }
        if usesSamiFolder, let shared = samiFolder { return shared.url }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    /// Opens the download folder in the Finder.
    func revealDestination() {
        #if os(macOS)
        guard let folder = destination ?? defaultDestination() else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        #endif
    }

    #if os(macOS)
    func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "Where should downloads go?"
        if panel.runModal() == .OK { destination = panel.url }
    }
    #endif

    func setTorRouting(_ enabled: Bool) {
        useTor = enabled
        invalidateFetchers()
        Task {
            if enabled, torMode == .embedded {
                await tor.start()
            } else if !enabled {
                tor.stop()
            }
        }
    }

    private func saveDestinationBookmark() {
        #if !os(macOS)
        // Security-scoped bookmarks are a macOS sandbox mechanism, and with no
        // folder picker on iOS there is no granted folder to remember.
        return
        #else
        guard let destination else { return }
        // Security-scoped, because this grant is what a future hand-off to Sami
        // has to be built on: a sandboxed app cannot read a folder nobody
        // granted it, and this is the grant.
        if let data = try? destination.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        ) {
            UserDefaults.standard.set(data, forKey: "destinationBookmark")
        }
        #endif
    }

    private func restoreDestinationBookmark() {
        #if !os(macOS)
        return
        #else
        guard let data = UserDefaults.standard.data(forKey: "destinationBookmark") else { return }
        var stale = false
        if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                              relativeTo: nil, bookmarkDataIsStale: &stale), !stale {
            _ = url.startAccessingSecurityScopedResource()
            destination = url
        }
        #endif
    }
}
