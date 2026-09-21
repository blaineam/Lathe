import Foundation
import LatheCore

/// Downloads media from the sites `yt-dlp` knows how to extract from.
///
/// ## The shape of the thing
///
/// Four steps, each of which a caller can stop after:
///
/// ```swift
/// let fetcher = MediaFetcher(runtime: runtime, installer: installer)
///
/// // 1. Acquire yt-dlp. Once, and again whenever the user wants it updated.
/// let plan = try await fetcher.plan()          // show this to somebody
/// try await fetcher.install()
///
/// // 2. Wire it up and find out what works on this device.
/// let readiness = try await fetcher.prepare()
/// print(readiness.report)
///
/// // 3. Ask what is available.
/// let listing = try await fetcher.listing(for: url)
/// let selection = try FormatSelector.select(from: listing, policy: .upTo(height: 1080))
///
/// // 4. Fetch it.
/// let result = try await fetcher.download(selection, from: listing, to: destination,
///                                         progress: handle)
/// ```
///
/// ## Why `yt-dlp` is installed and not bundled
///
/// `yt-dlp` is public domain — the Unlicense — so bundling it would be legally
/// unencumbered, which makes this a design decision rather than a licence one.
///
/// It is installed because **`yt-dlp` breaks weekly**. Sites change their
/// players, their client tokens and their signature schemes, and `yt-dlp`
/// ships a release most weeks to keep up. A copy bundled into an application is
/// stale the day that application ships and staler every day after, and fixing
/// it means an App Store review cycle for a change that was not the
/// application's. Installing it from an index means a user who cannot download
/// a video today can have the fix in thirty seconds, from the same code path
/// that installed it in the first place.
///
/// Bundling remains a legitimate choice for an offline-first consumer, and the
/// installer supports it: ``PythonPackageInstaller/install(wheel:named:verifying:)``
/// takes a wheel that is already in memory, so an application that ships one in
/// its bundle can install it with no network at all. What it buys is a first
/// launch that works on a plane; what it costs is that the copy goes stale, and
/// on these sites stale means broken. **The difference from how this package
/// treats `gallery-dl` is maintenance, not licence.**
///
/// ## What does not work here, and why
///
/// * **`ffmpeg` is never invoked.** `yt-dlp` merges separately-downloaded video
///   and audio by shelling out to it, and PEP 730 removes process spawning on
///   iOS. This package therefore never asks `yt-dlp` for a compound format, and
///   joins the two streams itself with ``StreamMuxer``.
/// * **The external JavaScript runtimes are never used.** `deno`, `node`, `bun`
///   and `quickjs` are all subprocesses. ``JavaScriptEngine`` stands in for them
///   with `JavaScriptCore`, which is a system framework.
/// * **`pycryptodomex` is never installed.** It is a C extension, and iOS
///   cannot load one that was not inside the signed bundle. `yt-dlp` falls back
///   to its own pure-Python AES, which ``Readiness/cryptographyBackend``
///   reports so the slower path is a known fact rather than a surprise.
public actor MediaFetcher {

    // MARK: - Configuration

    /// Everything that applies to every call.
    public struct Configuration: Sendable, Equatable {

        /// Where `yt-dlp` keeps its cache — the solver script, player signature
        /// timestamps, and cookies it was told to persist.
        ///
        /// `nil` switches the cache off. That works, and costs a re-fetch of
        /// the solver script on every extraction, so an application should
        /// supply a directory in its own container. `yt-dlp`'s own default is
        /// `~/.cache/yt-dlp`, which inside a sandbox is neither present nor
        /// writable.
        public var cacheDirectory: URL?

        /// Sent as `User-Agent`. `nil` leaves `yt-dlp`'s own, which is what its
        /// extractors are tested against and is usually the right answer.
        public var userAgent: String?

        /// Socket timeout, seconds.
        public var timeout: TimeInterval = 30

        /// How many times `yt-dlp` retries a failed request.
        public var retryCount: Int = 3

        /// A Netscape-format cookie file, for sites that need a signed-in
        /// session. The file is read by `yt-dlp` and never copied anywhere.
        public var cookieFile: URL?

        /// An HTTP proxy URL.
        public var proxy: String?

        /// Whether a URL that names both an item and a collection means the
        /// item.
        ///
        /// `true`, the default, is `yt-dlp`'s `--no-playlist`. It matters more
        /// than it sounds: YouTube appends an autoplay mix to nearly every
        /// link it produces, so `watch?v=…&list=RD…` is what copying a link
        /// out of the address bar actually gives you. Treating that as a
        /// collection means the ordinary paste resolves to fifty related
        /// videos and downloads none of them.
        ///
        /// Set it to `false` to take the collection instead — see also
        /// ``MediaFetcher/entries(of:limit:)``, which enumerates one without
        /// downloading anything.
        /// Whether HTTP goes through URLSession (Apple's TLS stack) rather
        /// than the embedded interpreter's own OpenSSL.
        ///
        /// On by default on iOS, where the bundled OpenSSL 3.0 has a TLS
        /// fingerprint some sites refuse outright (the first request comes back
        /// `410 Gone`). Off by default on macOS, whose host Python is not
        /// affected. See ``SystemNetworkBridge``. Registration is process-wide,
        /// so this is read the first time a fetcher prepares its driver.
        public var usesSystemNetworking: Bool = SystemNetworkDriver.defaultEnabled

        public var ignoresPlaylists = true

        /// `yt-dlp`'s `--extractor-args`, as `extractor → key → values`.
        ///
        /// The escape hatch for behaviour this API does not model. The one most
        /// callers will want is `["youtube": ["player_client": ["default"]]]`;
        /// see ``MediaFetcher/preMuxedCapableYouTubeClients`` for the other
        /// useful value and what it is for.
        public var extractorArguments: [String: [String: [String]]] = [:]

        public init() {}
    }

    /// YouTube clients that still publish a pre-muxed rendition.
    ///
    /// Only relevant with ``FormatPolicy/preMuxedOnly``, and only on YouTube.
    /// The default client set returns adaptive streams exclusively — 53 of them
    /// on a test 4K video, **not one carrying both tracks** — so a pre-muxed
    /// policy against the default clients finds nothing at all. These clients
    /// still return format `18`, which is 360p H.264/AAC and the entire
    /// pre-muxed catalogue.
    ///
    /// ```swift
    /// configuration.extractorArguments = [
    ///     "youtube": ["player_client": MediaFetcher.preMuxedCapableYouTubeClients]
    /// ]
    /// ```
    public static let preMuxedCapableYouTubeClients = ["tv_simply", "web_embedded", "mweb"]

    // MARK: - Readiness

    /// What works on this device, read out of the live interpreter.
    ///
    /// The same rule ``PythonPlatform`` follows and for the same reason: which
    /// parts of this work is not derivable from an OS version, and an
    /// `#available` check would be a guess dressed up as a fact.
    public struct Readiness: Sendable, Equatable {

        /// Whether `yt-dlp` imported.
        public let isInstalled: Bool

        /// Its version, as it reports it.
        public let version: String?

        /// Whether the JavaScript challenge provider registered.
        ///
        /// `false` is a **partial** failure, not a total one: every extractor
        /// that does not need a JavaScript runtime keeps working, which is all
        /// of them except signature-protected YouTube.
        public let javaScriptSolverAvailable: Bool

        /// Why it did not, when it did not.
        public let javaScriptUnavailableReason: String?

        /// Whether the solver's own JavaScript is on disk.
        ///
        /// Separate from ``javaScriptSolverAvailable`` because they fail
        /// independently: a registered provider with no script to run is
        /// exactly as useless as no provider, and the fixes are different.
        public let solverScriptsAvailable: Bool

        /// Why they are not, when they are not.
        public let solverScriptsReason: String?

        /// `"pure-python"` or `"pycryptodomex"`.
        ///
        /// On iOS it is permanently the former: `pycryptodomex` is a C
        /// extension and cannot be installed at run time. `yt-dlp`'s own AES
        /// implementation takes over automatically — nothing hard-requires the
        /// C module — at the cost of speed on AES-128 HLS streams, and of the
        /// handful of extractors that want RSA or CMAC rather than AES.
        public let cryptographyBackend: String

        /// The `yt-dlp` release this package's JavaScript provider was written
        /// against. A mismatch is not a failure; it is the first thing to look
        /// at when the provider stops registering.
        public let developedAgainstVersion: String

        /// Whether everything including YouTube signature solving works.
        public var isFullyOperational: Bool {
            isInstalled && javaScriptSolverAvailable && solverScriptsAvailable
        }

        /// A block for a log line or a bug report.
        public var report: String {
            var lines = [
                "yt-dlp: " + (isInstalled ? (version ?? "installed") : "NOT INSTALLED"),
                "  written against:     \(developedAgainstVersion)",
                "  JS challenge solver: "
                    + (javaScriptSolverAvailable
                        ? "JavaScriptCore" : "unavailable — \(javaScriptUnavailableReason ?? "no reason given")"),
                "  solver scripts:      "
                    + (solverScriptsAvailable
                        ? "present" : "missing — \(solverScriptsReason ?? "no reason given")"),
                "  AES:                 \(cryptographyBackend)",
            ]
            if !isFullyOperational && isInstalled {
                lines.append(
                    "  → Sites needing a JavaScript runtime (in practice: signature-protected "
                        + "YouTube) will not work. Everything else is unaffected.")
            }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Results

    /// A completed download.
    public struct FetchedMedia: Sendable, Equatable {
        /// Where the file is. Always the destination that was asked for.
        public let url: URL
        public let byteCount: Int64
        /// Seconds, when it could be read back off the file.
        public let duration: TimeInterval?
        /// What was downloaded.
        public let selection: FormatSelection
        /// Whether ``StreamMuxer`` was involved.
        public var wasMuxed: Bool { selection.needsMuxing }
    }

    // MARK: - State

    public let runtime: PythonRuntime
    public let installer: PythonPackageInstaller
    public var configuration: Configuration

    /// The projects this feature needs, in the order they are useful.
    ///
    /// `yt-dlp` on its own extracts from every site that does not set a
    /// JavaScript challenge. `yt-dlp-ejs` carries the solver's own JavaScript,
    /// which is the other half of making YouTube work; it is a pure-Python
    /// wheel with no dependencies of its own, so the second one is nearly free.
    ///
    /// Everything else in `yt-dlp`'s `default` extra is deliberately left out.
    /// `pycryptodomex` and `brotli` are C extensions that iOS cannot load —
    /// `yt-dlp`'s own packaging already excludes `brotli` on `sys_platform ==
    /// "ios"`, which is a pleasant sign that upstream has thought about this —
    /// and `requests`, `urllib3`, `websockets` and `mutagen` buy nothing this
    /// package uses. `certifi` arrives anyway, as ``PythonTrustStore``.
    public static let requirements = ["yt-dlp", "yt-dlp-ejs"]

    private var driverIsInstalled = false

    public init(
        runtime: PythonRuntime,
        installer: PythonPackageInstaller,
        configuration: Configuration = Configuration()
    ) {
        self.runtime = runtime
        self.installer = installer
        self.configuration = configuration
    }

    public func setConfiguration(_ configuration: Configuration) {
        self.configuration = configuration
    }

    // MARK: - Acquisition

    /// What installing `yt-dlp` would involve, without installing anything.
    ///
    /// Worth showing to somebody before it happens: it is two wheels and a few
    /// megabytes, and that is a fact the person tapping the button is entitled
    /// to before rather than after.
    public func plan(using source: any PythonPackageSource = PyPIPackageSource()) async throws
        -> PythonDependencyPlan
    {
        try await installer.plan(for: Self.requirements, using: source)
    }

    /// Fetches `yt-dlp` and its solver scripts, and puts them on `sys.path`.
    ///
    /// Also the update path: calling it again re-resolves against the index and
    /// replaces what has moved on. That is the whole reason this is an install
    /// rather than a bundle — see the type documentation.
    @discardableResult
    public func install(
        using source: any PythonPackageSource = PyPIPackageSource(),
        session: URLSession = .shared
    ) async throws -> PythonPackageInstaller.Installation {
        let installation = try await installer.install(
            requirements: Self.requirements, using: source, session: session)
        try await installer.activate()
        return installation
    }

    // MARK: - Preparation

    /// Installs the Python glue, binds the JavaScript engine, registers the
    /// challenge provider, and reports what works.
    ///
    /// Idempotent and cheap to call again. Safe to call when `yt-dlp` is not
    /// installed: the result says so rather than throwing, because "not
    /// installed yet" is the ordinary state on a first launch.
    @discardableResult
    public func prepare() async throws -> Readiness {
        try await installDriverIfNeeded()

        // Bind first: the provider registration needs the engine's address,
        // and a provider registered against an unbound engine would report
        // itself available and then fail on the first challenge.
        _ = try await runtime.evaluateDetached(
            "\(MediaFetcherDriver.bindFunction)()",
            arguments: [
                "evaluate": JavaScriptBridge.evaluateAddress,
                "free": JavaScriptBridge.freeAddress,
                "progress": ProgressBridge.callbackAddress,
            ]
        )

        // Registration is allowed to fail. A yt-dlp with no challenge solver is
        // still a yt-dlp for every site that does not set a challenge, and
        // turning a partial capability into a thrown error would trade most of
        // the feature for the loudest possible complaint about part of it.
        _ = try? await runtime.evaluateDetached("\(MediaFetcherDriver.registerProviderFunction)()")

        return try await readiness()
    }

    /// What works, without changing anything.
    public func readiness() async throws -> Readiness {
        try await installDriverIfNeeded()

        struct Raw: Decodable {
            let installed: Bool
            let version: String?
            let javascript: Bool
            let javascript_error: String?
            let solver_scripts: Bool
            let solver_error: String?
            let cryptography: String
        }

        let evaluation = try await runtime.evaluateDetached("\(MediaFetcherDriver.readinessFunction)()")
        guard let json = evaluation.value.string,
            let data = json.data(using: .utf8),
            let raw = try? JSONDecoder().decode(Raw.self, from: data)
        else {
            throw MediaFetchError.runtimeFailed(reason: "the readiness report was not decodable")
        }

        return Readiness(
            isInstalled: raw.installed,
            version: raw.version,
            javaScriptSolverAvailable: raw.javascript,
            javaScriptUnavailableReason: raw.javascript_error,
            solverScriptsAvailable: raw.solver_scripts,
            solverScriptsReason: raw.solver_error,
            cryptographyBackend: raw.cryptography,
            developedAgainstVersion: MediaFetcherDriver.developedAgainstVersion
        )
    }

    private func installDriverIfNeeded() async throws {
        guard !driverIsInstalled else { return }

        // Put the install root on `sys.path` before anything tries to import
        // from it.
        //
        // This is not only an install-time concern, which is the bug it used
        // to be: `activate()` was called from `install()` alone, so a process
        // that found `yt-dlp` already installed from an earlier run never put
        // its directory on the path and every import failed with "No module
        // named 'yt_dlp'". The extractor worked exactly once — in the session
        // that installed it — and appeared to uninstall itself on relaunch.
        //
        // It belongs here because this is the one place every entry point
        // passes through, and `activate()` is idempotent.
        try await installer.activate()

        // The interpreter outlives any one `MediaFetcher`, so "did I install
        // it" is asked of the interpreter rather than remembered here — a
        // second fetcher in the same process must not reinstall the module and
        // re-enter the provider registration.
        if (try? await runtime.evaluateDetached(MediaFetcherDriver.installExpression)) == nil {
            try await runtime.executeDetached(MediaFetcherDriver.source)
        }
        // Before any YoutubeDL is built, since each one snapshots the handler
        // registry. Declined quietly when yt-dlp is not installed yet; the
        // next call tries again.
        if configuration.usesSystemNetworking {
            guard await SystemNetworkDriver.register(
                SystemNetworkDriver.registerYouTubeDLFunction, in: runtime)
            else { return }
        }
        driverIsInstalled = true
    }

    // MARK: - Extraction

    /// Asks the extractors what is available at `url`.
    ///
    /// No bytes of media are fetched. The URLs in the result are usually signed
    /// and short-lived — minutes — so a listing is a thing to act on, not a
    /// thing to store.
    ///
    /// - Throws: a ``MediaFetchError``. Everything `yt-dlp` can raise is mapped;
    ///   see ``MediaFetchError/mapping(_:)``.
    public func listing(for url: URL) async throws -> MediaListing {
        try await installDriverIfNeeded()

        struct Envelope: Decodable {
            let kind: String
            let count: Int?
            let title: String?
            let info: MediaListing?
        }

        let request = try requestPayload(["url": url.absoluteString])
        let evaluation: PythonEvaluation
        do {
            evaluation = try await runtime.evaluateDetached(
                "\(MediaFetcherDriver.extractFunction)()", arguments: ["request": request])
        } catch {
            throw MediaFetchError.mapping(error)
        }

        guard let json = evaluation.value.string, let data = json.data(using: .utf8) else {
            throw MediaFetchError.runtimeFailed(reason: "the extractor returned no JSON")
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw MediaFetchError.runtimeFailed(
                reason: "the extractor's JSON did not decode: \(error)")
        }

        if envelope.kind == "playlist" {
            throw MediaFetchError.isPlaylist(title: envelope.title, count: envelope.count ?? -1)
        }
        guard let listing = envelope.info else {
            throw MediaFetchError.extractionFailed(reason: "the extractor returned no media")
        }
        LatheFetchLog.packages.notice(
            "Extracted \(listing.formats.count, privacy: .public) format(s) from \(listing.extractor ?? "?", privacy: .public)")
        return listing
    }

    /// The name of the extractor that claims this URL, if a named one does.
    ///
    /// `nil` means only the generic extractor matched — yt-dlp will still try,
    /// by fetching the page and looking for something media-shaped in it, but
    /// it does not know the site. That is the distinction worth routing on: a
    /// named extractor is a reason to prefer this tool, and its absence is a
    /// reason to ask whether another tool knows the site better.
    ///
    /// Cheap enough to call before every download — it matches patterns
    /// against a list already in memory and fetches nothing.
    public func extractorName(for url: URL) async throws -> String? {
        try await installDriverIfNeeded()
        struct Raw: Decodable { let extractor: String? }
        let evaluation = try await runtime.evaluateDetached(
            "\(MediaFetcherDriver.extractorFunction)()", arguments: ["url": url.absoluteString])
        guard let json = evaluation.value.string, let data = json.data(using: .utf8),
            let raw = try? JSONDecoder().decode(Raw.self, from: data)
        else { return nil }
        return raw.extractor
    }

    /// What is inside a playlist, channel or gallery page.
    ///
    /// ``listing(for:)`` refuses a playlist, because there is no single set of
    /// formats to report for one. This is the other half of that: it says what
    /// the playlist holds, cheaply, so a caller can offer "just this one" and
    /// "all of them" as a choice rather than guessing.
    ///
    /// Each entry is something to pass back to ``listing(for:)`` or
    /// ``download(_:policy:to:progress:)`` — usually a URL, and for extractors
    /// that publish only an id, the `extractor:id` form yt-dlp resolves itself.
    ///
    /// - Parameter limit: how many entries to walk at most. A channel can hold
    ///   tens of thousands, and the underlying sequence is lazy, so this is a
    ///   real bound on work rather than a slice of a list already in memory.
    ///   ``Playlist/isTruncated`` says whether it bit.
    public func entries(of url: URL, limit: Int = 500) async throws -> Playlist {
        try await installDriverIfNeeded()

        let request = try requestPayload(["url": url.absoluteString, "limit": limit])
        let evaluation: PythonEvaluation
        do {
            evaluation = try await runtime.evaluateDetached(
                "\(MediaFetcherDriver.entriesFunction)()", arguments: ["request": request])
        } catch {
            throw MediaFetchError.mapping(error)
        }

        guard let json = evaluation.value.string, let data = json.data(using: .utf8) else {
            throw MediaFetchError.runtimeFailed(reason: "the extractor returned no JSON")
        }
        do {
            return try JSONDecoder().decode(Playlist.self, from: data)
        } catch {
            throw MediaFetchError.runtimeFailed(
                reason: "the playlist JSON did not decode: \(error)")
        }
    }

    // MARK: - Downloading

    /// Extracts, chooses and downloads in one call.
    public func download(
        _ url: URL,
        policy: FormatPolicy = .best,
        to destination: URL,
        progress: ProgressHandle = .ignoring()
    ) async throws -> FetchedMedia {
        do {
            return try await extractSelectAndDownload(
                url, policy: policy, to: destination, progress: progress)
        } catch let error as MediaFetchError where error.indicatesStaleFormatSelection {
            // The format that was chosen a moment ago is not on offer now.
            //
            // This happens intermittently on YouTube and is not a bug in the
            // selection: extraction and downloading are two separate
            // extractions, YouTube answers them with different player clients,
            // and the clients do not all publish the same format ids. The
            // selection was correct against the listing it was made from; that
            // listing simply stopped being true.
            //
            // Extracting again and re-selecting is the whole fix, and it is
            // done once rather than in a loop: if a second fresh listing
            // cannot produce a format that survives to the download, the
            // problem is not staleness and retrying will not find out what it
            // is.
            LatheFetchLog.packages.notice(
                "Format selection went stale between extraction and download; re-extracting once")
            return try await extractSelectAndDownload(
                url, policy: policy, to: destination, progress: progress)
        }
    }

    private func extractSelectAndDownload(
        _ url: URL,
        policy: FormatPolicy,
        to destination: URL,
        progress: ProgressHandle
    ) async throws -> FetchedMedia {
        let listing = try await listing(for: url)
        let selection = try FormatSelector.select(from: listing, policy: policy)
        return try await download(selection, from: listing, to: destination, progress: progress)
    }

    /// Downloads a selection that was made earlier.
    ///
    /// ## What "never leave a partial file" means here
    ///
    /// Every byte goes into a working directory beside the destination, and the
    /// destination is written exactly once, at the end, by a move or by the
    /// muxer. A cancellation, a network failure or a crashed extractor
    /// therefore leaves `destination` exactly as it found it — which for the
    /// ordinary case means absent, and for a retry over an existing file means
    /// the old file intact rather than truncated.
    ///
    /// The working directory is a sibling of the destination rather than in the
    /// system temporary directory, so the final move is a rename within one
    /// volume rather than a copy of several gigabytes across two.
    public func download(
        _ selection: FormatSelection,
        from listing: MediaListing,
        to destination: URL,
        progress: ProgressHandle = .ignoring()
    ) async throws -> FetchedMedia {
        try await installDriverIfNeeded()

        guard let sourceURL = listing.webpageURL else {
            throw MediaFetchError.extractionFailed(
                reason: "this listing has no webpage URL to download from")
        }
        if listing.isLive {
            throw MediaFetchError.liveStream(
                reason: "this is a live stream, which has no end to download to")
        }
        if case let .pair(video, audio) = selection {
            guard StreamMuxer.canMuxVideo(video) else {
                throw MediaFetchError.muxingFailed(
                    stage: "select",
                    reason: "an MPEG-4 file cannot hold \(video.videoCodec ?? "this video codec")")
            }
            guard StreamMuxer.canMuxAudio(audio) else {
                throw MediaFetchError.muxingFailed(
                    stage: "select",
                    reason: "an MPEG-4 file cannot hold \(audio.audioCodec ?? "this audio codec")")
            }
        }

        let fileManager = FileManager.default
        let workingDirectory = destination.deletingLastPathComponent()
            .appendingPathComponent(".lathe-fetch-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        } catch {
            throw MediaFetchError.runtimeFailed(
                reason: "could not create a working directory beside the destination: "
                    + (error as NSError).localizedDescription)
        }
        defer { try? fileManager.removeItem(at: workingDirectory) }

        // The download phase owns the first 85% when a mux follows, and all of
        // it when one does not. A tail reserved for muxing that never happens
        // is a bar that stops at 85% and then jumps, which reads as a hang.
        let downloadShare = selection.needsMuxing ? 0.85 : 1.0
        let token = ProgressBridge.register(
            handle: progress,
            selection: selection,
            scale: downloadShare
        )
        defer { ProgressBridge.unregister(token) }

        var parts: [URL] = []
        for (index, format) in selection.formats.enumerated() {
            try Task.checkCancellation()
            let part = workingDirectory
                .appendingPathComponent("part\(index).\(format.ext ?? "bin")")
            try await downloadOne(
                format: format,
                from: sourceURL,
                to: part,
                token: token,
                part: index,
                partCount: selection.formats.count
            )
            guard let size = try? fileManager.attributesOfItem(atPath: part.path)[.size] as? Int64,
                size > 0
            else {
                throw MediaFetchError.incompleteDownload(
                    path: part.path, reason: "the downloader produced no bytes for format \(format.formatID)")
            }
            parts.append(part)
        }

        switch selection {
        case .single:
            guard let part = parts.first else {
                throw MediaFetchError.incompleteDownload(path: destination.path, reason: "nothing was downloaded")
            }
            try publish(part, to: destination)

        case .pair:
            let muxProgress = ProgressHandle(
                sink: ScaledProgressSink(target: progress, from: downloadShare, to: 1.0),
                throttle: .standard
            )
            _ = try await StreamMuxer.mux(
                video: parts[0], audio: parts[1], to: destination, progress: muxProgress)
        }

        let byteCount =
            (try? fileManager.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? nil
        _ = progress.report(LatheProgress(fraction: 1, stage: "done", unitIndex: 1, unitCount: 1))

        return FetchedMedia(
            url: destination,
            byteCount: byteCount ?? 0,
            duration: listing.duration,
            selection: selection
        )
    }

    private func downloadOne(
        format: MediaFormat,
        from sourceURL: URL,
        to destination: URL,
        token: Int,
        part: Int,
        partCount: Int
    ) async throws {
        let request = try requestPayload([
            "url": sourceURL.absoluteString,
            "format_id": format.formatID,
            "destination": destination.path,
            "token": token,
            "part": part,
            "part_count": partCount,
        ])
        LatheFetchLog.packages.debug(
            "Download request: \(request, privacy: .private)")
        do {
            _ = try await runtime.evaluateDetached(
                "\(MediaFetcherDriver.downloadFunction)()", arguments: ["request": request])
        } catch is CancellationError {
            throw LatheError.cancelled(atUnit: UInt64(part))
        } catch let PythonError.raised(exception) where exception.type == "DownloadCancelled" {
            // The progress bridge answered "stop", which is this package's own
            // cancellation arriving through yt-dlp's exception rather than an
            // error.
            throw LatheError.cancelled(atUnit: UInt64(part))
        } catch {
            throw MediaFetchError.mapping(error)
        }
    }

    /// Moves a finished part onto the destination, replacing what is there.
    private func publish(_ part: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: part)
            } else {
                try fileManager.moveItem(at: part, to: destination)
            }
        } catch {
            throw LatheError.writeFailed(
                path: destination.path, reason: (error as NSError).localizedDescription)
        }
    }

    /// The JSON request body every driver function reads.
    private func requestPayload(_ extra: [String: Any]) throws -> String {
        var payload: [String: Any] = extra
        payload["timeout"] = configuration.timeout
        payload["retries"] = configuration.retryCount
        if let cache = configuration.cacheDirectory { payload["cache_directory"] = cache.path }
        if let agent = configuration.userAgent { payload["user_agent"] = agent }
        if let cookies = configuration.cookieFile { payload["cookie_file"] = cookies.path }
        if let proxy = configuration.proxy { payload["proxy"] = proxy }
        payload["no_playlist"] = configuration.ignoresPlaylists
        if !configuration.extractorArguments.isEmpty {
            payload["extractor_args"] = configuration.extractorArguments
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
            let json = String(data: data, encoding: .utf8)
        else {
            throw MediaFetchError.runtimeFailed(reason: "the request could not be encoded as JSON")
        }
        return json
    }
}

// MARK: - Progress scaling

/// Forwards progress into a slice of another handle's range.
///
/// So that a muxing pass reporting `0…1` of its own work lands as `0.85…1` of
/// the whole job, instead of sending the bar backwards the moment the download
/// finishes.
struct ScaledProgressSink: ProgressSink {
    let target: ProgressHandle
    let from: Double
    let to: Double

    func report(_ progress: LatheProgress) -> Bool {
        let scaled = progress.fraction.map { from + ($0 * (to - from)) }
        return target.report(
            LatheProgress(
                fraction: scaled,
                stage: progress.stage,
                unitIndex: progress.unitIndex,
                unitCount: progress.unitCount))
    }
}
