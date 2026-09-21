import Foundation
import LatheCore

/// Downloads galleries — the many-files-on-one-page case.
///
/// The sibling of ``MediaFetcher``, and the division between them is the
/// division between the two tools they drive. `yt-dlp` answers "what
/// renditions of this one thing exist", and this package picks one, fetches
/// it, and joins tracks where it has to. `gallery-dl` answers "what files are
/// on this page" and writes them itself.
///
/// That difference is why the API here is shaped differently: there is no
/// format to select, no single destination file, and the result is a list of
/// paths rather than one.
///
/// ## Licensing
///
/// `gallery-dl` is GPL-2.0. It is **never** vendored, linked, or shipped
/// inside anything this package builds — it is fetched at run time, into a
/// directory the application owns, by a user who asked for it. What this
/// package contains is a few dozen lines of Python that call its public API,
/// and the same arrangement any user running `pip install gallery-dl` arrives
/// at. The same reasoning as ``MediaFetcher``'s, and the same conclusion.
public actor GalleryFetcher {

    /// Everything that applies to every call.
    public struct Configuration: Sendable, Equatable {

        /// A Netscape-format cookie file, for sites that need a signed-in
        /// session. Read by `gallery-dl` and never copied anywhere.
        public var cookieFile: URL?

        /// A proxy URL. `socks5h://` routes name resolution through the proxy
        /// too, which is the form to use when the point is that nothing local
        /// learns the hostname.
        public var proxy: String?

        /// Sent as `User-Agent`. `nil` leaves `gallery-dl`'s own.
        public var userAgent: String?

        /// Socket timeout, seconds.
        public var timeout: TimeInterval = 30

        /// How many times a failed request is retried.
        /// Whether HTTP goes through URLSession (Apple's TLS stack) rather
        /// than the embedded interpreter's own OpenSSL.
        ///
        /// On by default on iOS, where the bundled OpenSSL 3.0 has a TLS
        /// fingerprint some sites refuse outright (the first request comes back
        /// `410 Gone`). Off by default on macOS, whose host Python is not
        /// affected. See ``SystemNetworkBridge``. Registration is process-wide,
        /// so this is read the first time a fetcher prepares its driver.
        public var usesSystemNetworking: Bool = SystemNetworkDriver.defaultEnabled

        public var retryCount: Int = 3

        public init() {}
    }

    /// What works on this device.
    public struct Readiness: Sendable, Equatable {
        public let isInstalled: Bool
        public let version: String?
        /// Why it is not installed, when it is not.
        public let reason: String?
    }

    /// What a site's extractor said about a URL.
    public struct Support: Sendable, Equatable {
        public let isSupported: Bool
        /// The site, in `gallery-dl`'s own vocabulary — `"twitter"`,
        /// `"pixiv"`, `"reddit"`.
        public let category: String?
        /// What kind of page it is — `"user"`, `"gallery"`, `"search"`.
        public let subcategory: String?
    }

    /// One file the extractor found.
    public struct Item: Sendable, Equatable, Codable, Identifiable {
        public let url: String
        public let title: String?
        public let `extension`: String?
        public var id: String { url }
    }

    /// What a page holds.
    public struct Contents: Sendable, Equatable, Codable {
        public let entries: [Item]
        /// Whether the walk stopped at the limit rather than at the end.
        public let isTruncated: Bool

        private enum CodingKeys: String, CodingKey {
            case entries
            case isTruncated = "truncated"
        }
    }

    /// What a completed download wrote.
    public struct Haul: Sendable, Equatable {
        public let files: [URL]
        /// `gallery-dl`'s own exit status. Non-zero means at least one item
        /// failed, which for a gallery of two hundred is a partial success
        /// rather than a failure — the files that did arrive are in ``files``.
        public let status: Int
        /// Whether the caller's limit or cancellation stopped it early.
        public let wasStoppedEarly: Bool

        /// What `gallery-dl` complained about along the way.
        ///
        /// It reports per-item failures through the logging module and carries
        /// on, so a run can finish with a clean status and no files. Without
        /// these, "nothing was downloaded" is the entire diagnosis.
        public let problems: [String]
    }

    public var configuration: Configuration

    private let runtime: PythonRuntime
    private let installer: PythonPackageInstaller
    private var driverIsInstalled = false

    /// What is fetched by ``install(using:session:)``.
    ///
    /// Only the one package by name; its dependencies — `requests` and what
    /// `requests` needs — are resolved from its metadata rather than listed
    /// here, so this does not go stale every time upstream adds one.
    public static let requirements = ["gallery-dl"]

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

    // MARK: - Installing

    /// What installing would fetch, without fetching it.
    public func plan(using source: any PythonPackageSource = PyPIPackageSource()) async throws
        -> PythonDependencyPlan
    {
        try await installer.plan(for: Self.requirements, using: source)
    }

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

    // MARK: - Readiness

    public func readiness() async throws -> Readiness {
        try await installDriverIfNeeded()
        struct Raw: Decodable {
            let installed: Bool
            let version: String?
            let error: String?
        }
        let evaluation = try await runtime.evaluateDetached("\(GalleryFetcherDriver.readinessFunction)()")
        guard let json = evaluation.value.string, let data = json.data(using: .utf8),
            let raw = try? JSONDecoder().decode(Raw.self, from: data)
        else {
            throw MediaFetchError.runtimeFailed(reason: "the readiness report did not decode")
        }
        return Readiness(isInstalled: raw.installed, version: raw.version, reason: raw.error)
    }

    // MARK: - Matching

    /// Whether `gallery-dl` has an extractor for this site.
    ///
    /// Unlike `yt-dlp`, there is no generic fallback, so a `true` here is a
    /// real claim on the site rather than "there might be media on that page".
    /// That is what makes this usable for routing a URL to one tool or the
    /// other.
    public func support(for url: URL) async throws -> Support {
        try await installDriverIfNeeded()
        struct Raw: Decodable {
            let supported: Bool
            let category: String?
            let subcategory: String?
        }
        let evaluation = try await runtime.evaluateDetached(
            "\(GalleryFetcherDriver.supportsFunction)()", arguments: ["url": url.absoluteString])
        guard let json = evaluation.value.string, let data = json.data(using: .utf8),
            let raw = try? JSONDecoder().decode(Raw.self, from: data)
        else {
            return Support(isSupported: false, category: nil, subcategory: nil)
        }
        return Support(isSupported: raw.supported, category: raw.category, subcategory: raw.subcategory)
    }

    // MARK: - Listing

    /// What is on the page, without downloading any of it.
    ///
    /// - Parameter limit: how many items to collect at most. A user's whole
    ///   posting history can be tens of thousands, and asking for all of it to
    ///   show a list is not what anybody wanted.
    public func contents(of url: URL, into directory: URL, limit: Int = 500) async throws -> Contents {
        try await installDriverIfNeeded()
        let request = try requestPayload([
            "url": url.absoluteString,
            "directory": directory.path,
            "limit": limit,
        ])
        let evaluation: PythonEvaluation
        do {
            evaluation = try await runtime.evaluateDetached(
                "\(GalleryFetcherDriver.listFunction)()", arguments: ["request": request])
        } catch {
            throw MediaFetchError.mapping(error)
        }
        guard let json = evaluation.value.string, let data = json.data(using: .utf8) else {
            throw MediaFetchError.runtimeFailed(reason: "the extractor returned no JSON")
        }
        do {
            return try JSONDecoder().decode(Contents.self, from: data)
        } catch {
            throw MediaFetchError.runtimeFailed(reason: "the gallery JSON did not decode: \(error)")
        }
    }

    // MARK: - Downloading

    /// Downloads everything the extractor finds into one directory.
    ///
    /// - Parameters:
    ///   - url: the page.
    ///   - directory: where the files go. Created if it does not exist.
    ///   - limit: stop after this many files. `nil` means everything.
    ///   - progress: reported by file rather than by byte — `gallery-dl`
    ///     downloads many small files and a byte total for the set is not
    ///     known until the end, so counting files is the honest unit.
    public func download(
        _ url: URL,
        into directory: URL,
        limit: Int? = nil,
        progress: ProgressHandle = .ignoring()
    ) async throws -> Haul {
        try await installDriverIfNeeded()

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw LatheError.writeFailed(
                path: directory.path, reason: (error as NSError).localizedDescription)
        }

        let token = ProgressBridge.register(handle: progress, parts: limit ?? 1)
        defer { ProgressBridge.unregister(token) }

        var extra: [String: Any] = [
            "url": url.absoluteString,
            "directory": directory.path,
            "token": token,
        ]
        if let limit { extra["limit"] = limit }
        let request = try requestPayload(extra)

        struct Raw: Decodable {
            let paths: [String]
            let status: Int
            let cancelled: Bool
            let problems: [String]?
        }
        let evaluation: PythonEvaluation
        do {
            evaluation = try await runtime.evaluateDetached(
                "\(GalleryFetcherDriver.downloadFunction)()", arguments: ["request": request])
        } catch is CancellationError {
            throw LatheError.cancelled(atUnit: 0)
        } catch {
            throw MediaFetchError.mapping(error)
        }

        guard let json = evaluation.value.string, let data = json.data(using: .utf8),
            let raw = try? JSONDecoder().decode(Raw.self, from: data)
        else {
            throw MediaFetchError.runtimeFailed(reason: "the download report did not decode")
        }
        return Haul(
            files: raw.paths.map { URL(fileURLWithPath: $0) },
            status: raw.status,
            wasStoppedEarly: raw.cancelled,
            problems: raw.problems ?? [])
    }

    // MARK: - Plumbing

    private func installDriverIfNeeded() async throws {
        guard !driverIsInstalled else { return }
        // Same reasoning as MediaFetcher's: the install root has to be on
        // `sys.path` before anything imports from it, on every run and not
        // only on the run that installed it.
        try await installer.activate()
        if (try? await runtime.evaluateDetached(GalleryFetcherDriver.installExpression)) == nil {
            try await runtime.executeDetached(GalleryFetcherDriver.source)
        }
        if configuration.usesSystemNetworking {
            guard await SystemNetworkDriver.register(
                SystemNetworkDriver.registerGalleryDLFunction, in: runtime)
            else { return }
        }
        driverIsInstalled = true
    }

    private func requestPayload(_ extra: [String: Any]) throws -> String {
        var payload: [String: Any] = extra
        payload["timeout"] = configuration.timeout
        payload["retries"] = configuration.retryCount
        if let cookies = configuration.cookieFile { payload["cookie_file"] = cookies.path }
        if let proxy = configuration.proxy { payload["proxy"] = proxy }
        if let agent = configuration.userAgent { payload["user_agent"] = agent }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
            let json = String(data: data, encoding: .utf8)
        else {
            throw MediaFetchError.runtimeFailed(reason: "the request could not be encoded as JSON")
        }
        return json
    }
}
