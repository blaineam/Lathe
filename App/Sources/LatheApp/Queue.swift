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

    /// Where finished files land. Picked by the user, and remembered as a
    /// security-scoped bookmark so it survives a relaunch — and so the same
    /// grant can later be handed to Sami, which is the thing that makes the
    /// hand-off possible at all.
    var destination: URL? {
        didSet { saveDestinationBookmark() }
    }

    /// Route traffic through a local SOCKS proxy.
    ///
    /// **Not implemented yet, and deliberately not pretending to be.** The
    /// toggle exists so the setting has a home; turning it on currently refuses
    /// rather than silently downloading in the clear, because a privacy control
    /// that quietly does nothing is worse than one that is missing.
    var useTor = false

    /// Hand finished media to Sami, if it is installed.
    var handOffToSami = false
    var samiInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.samiBundleID) != nil
    }
    private static let samiBundleID = "com.wemiller.sami"

    private let pool = ResourcePool.automatic

    /// Built lazily, because there may be no interpreter to build it on.
    ///
    /// `PythonLayout.discover` throws when it cannot find one, and that is a
    /// state the app has to present rather than crash on — it is exactly the
    /// case onboarding exists for. Plain URLs keep working without it.
    private var fetcher: MediaFetcher?

    private func makeFetcher() throws -> MediaFetcher {
        if let fetcher { return fetcher }
        // bootstrap, not a plain init: loading CPython is a process-wide,
        // once-only act, and `current` is how a second caller gets the one that
        // is already up rather than a second interpreter in the same process.
        let runtime = try PythonRuntime.current
            ?? PythonRuntime.bootstrap(PythonRuntime.Configuration(layout: PythonLayout.discover()))
        let root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lathe/python", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let made = MediaFetcher(
            runtime: runtime,
            installer: PythonPackageInstaller(runtime: runtime, root: root)
        )
        fetcher = made
        return made
    }

    init() {
        restoreDestinationBookmark()
    }

    // MARK: - Adding

    /// Accepts anything paste-shaped: one URL, many, newline or space separated.
    func add(text: String) {
        let candidates = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
        var added = 0
        for candidate in candidates {
            guard let url = URL(string: candidate), url.scheme != nil,
                  !downloads.contains(where: { $0.url == url })
            else { continue }
            downloads.append(Download(url: url))
            added += 1
        }
        summary = added > 0 ? "\(added) added" : nil
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
            let readiness = try await makeFetcher().readiness()
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
            tools.installMessage = (error as? LatheError)?.errorDescription ?? "\(error)"
        }
    }

    func installYouTubeDL() async {
        tools.isInstalling = true
        tools.lastError = nil
        defer { tools.isInstalling = false }
        do {
            _ = try await makeFetcher().install()
            await refreshTools()
        } catch {
            tools.lastError = (error as? LatheError)?.errorDescription ?? "\(error)"
        }
    }

    // MARK: - Running

    func start() async {
        guard !isRunning, !downloads.isEmpty else { return }
        if useTor {
            summary = "Tor routing is not implemented yet — turn it off to download in the clear."
            return
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

        let fetcher = try? makeFetcher()
        _ = await BulkRun(pool: pool).run(items) { download in
            let url = await download.url
            await MainActor.run { download.state = .inspecting }
            do {
                let output = try await Self.fetch(url, into: folder, using: fetcher, download: download)
                await MainActor.run {
                    download.state = .finished(output)
                    download.byteCount = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                        .flatMap { $0 } ?? 0
                }
            } catch {
                let message = (error as? LatheError)?.errorDescription ?? "\(error)"
                await MainActor.run { download.state = .failed(message) }
            }
        }

        let done = downloads.filter { if case .finished = $0.state { return true } else { return false } }
        summary = "\(done.count) of \(pending.count) in \(String(format: "%.0f", Date().timeIntervalSince(started)))s"

        if handOffToSami, samiInstalled {
            let finished = done.compactMap { download -> URL? in
                if case .finished(let url) = download.state { return url }
                return nil
            }
            if !finished.isEmpty { openInSami(finished) }
        }
    }

    /// A plain URL is fetched directly; anything else needs an extractor.
    private nonisolated static func fetch(
        _ url: URL, into folder: URL, using fetcher: MediaFetcher?, download: Download
    ) async throws -> URL {
        // A direct link to a media file needs nothing installed. Trying this
        // first means the app is useful before onboarding rather than after it.
        if let source = try? MediaSource(url), source.isRemote, Self.looksLikeMediaFile(url) {
            let output = Self.unique(folder.appendingPathComponent(url.lastPathComponent))
            await MainActor.run { download.state = .running(fraction: 0) }
            try await URLSessionMediaTransport().download(
                url, to: output, limits: .standard, progress: nil
            )
            return output
        }

        guard let fetcher else {
            throw LatheError.notImplemented(
                feature: "\(url.host() ?? "that site") needs an extractor. Install yt-dlp from "
                    + "the banner above, or paste a direct link to a media file"
            )
        }
        await MainActor.run { download.state = .running(fraction: 0) }
        let listing = try await fetcher.listing(for: url)
        await MainActor.run { download.title = listing.title }
        let name = (listing.title ?? url.lastPathComponent).replacingOccurrences(of: "/", with: "-")
        let output = Self.unique(folder.appendingPathComponent(name).appendingPathExtension("mp4"))
        let media = try await fetcher.download(url, to: output)
        return media.url
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
            candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(base)-\(counter)")
                .appendingPathExtension(url.pathExtension)
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
