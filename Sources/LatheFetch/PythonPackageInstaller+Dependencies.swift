import Foundation

extension PythonPackageInstaller {

    /// What installing a requirement and its graph actually did.
    public struct Installation: Sendable, Equatable {

        /// The packages the caller named.
        public let requested: [InstalledPackage]

        /// Everything else the graph needed, in the order it was installed —
        /// dependencies before the things that import them.
        public let dependencies: [InstalledPackage]

        /// Packages the graph needed that were already present at a satisfying
        /// version, and were therefore not downloaded again.
        public let alreadySatisfied: [InstalledPackage]

        /// The plan this install carried out, including what it deliberately
        /// left out and why.
        public let plan: PythonDependencyPlan

        /// Everything now on disk because of this call, in install order.
        public var all: [InstalledPackage] { dependencies + requested }
    }

    // MARK: - Resolution

    /// The marker environment for this process's interpreter.
    ///
    /// Read once, from the live interpreter, and cached: `python_version` and
    /// `sys_platform` cannot change under a running CPython, and they are asked
    /// for at every edge of the graph.
    public func markerEnvironment() throws -> PythonMarkerEnvironment {
        if let cached = cachedMarkerEnvironment { return cached }
        let environment = try PythonMarkerEnvironment.read(from: runtime)
        cachedMarkerEnvironment = environment
        return environment
    }

    /// What is installed, with each package's own declared requirements.
    ///
    /// The requirements come from the `dist-info/METADATA` the unpack wrote, so
    /// an installed package's subtree can be **walked** rather than merely
    /// skipped: "urllib3 is already here" is only a safe answer if what urllib3
    /// itself needs is also accounted for.
    public func installedState() throws -> [String: PythonDependencyResolver.InstalledState] {
        var state: [String: PythonDependencyResolver.InstalledState] = [:]
        for record in try installed() {
            guard let version = PythonPackageVersion(parsing: record.version) else { continue }
            let metadataURL =
                root
                .appendingPathComponent("\(record.distribution)-\(record.version).dist-info", isDirectory: true)
                .appendingPathComponent("METADATA")
            let metadata = (try? String(contentsOf: metadataURL, encoding: .utf8))
                .flatMap { try? PythonPackageMetadata.parse($0, describedAs: record.name) }
            state[record.name] = .init(version: version, metadata: metadata)
        }
        return state
    }

    /// Works out what installing `requirement` would involve, without
    /// installing anything.
    ///
    /// Worth calling on its own: the plan is what a confirmation sheet should
    /// show. "Install gallery-dl" is six packages and a few megabytes, and the
    /// person tapping the button is entitled to know that before it happens
    /// rather than after.
    ///
    /// - Parameter requirement: a PEP 508 requirement — `"gallery-dl"`,
    ///   `"requests[socks]>=2.28,<3"`.
    public func plan(
        for requirement: String,
        using source: any PythonPackageSource = PyPIPackageSource()
    ) async throws -> PythonDependencyPlan {
        try await plan(for: [requirement], using: source)
    }

    /// The same, for several requirements resolved together — which is not the
    /// same as resolving them one after another, because a constraint from one
    /// can narrow the version chosen for a dependency of another.
    ///
    /// - Parameter upgrading: replace installed packages the index has moved
    ///   past, rather than keeping whatever already satisfies the requirement.
    public func plan(
        for requirements: [String],
        upgrading: Bool = false,
        using source: any PythonPackageSource = PyPIPackageSource()
    ) async throws -> PythonDependencyPlan {
        let parsed = try requirements.map { try PythonRequirement(parsing: $0) }
        let resolver = PythonDependencyResolver(
            environment: try markerEnvironment(),
            installed: try installedState(),
            upgradesInstalled: upgrading
        )
        return try await resolver.resolve(parsed, using: source)
    }

    // MARK: - Installing a graph

    /// Resolves `requirement` transitively and installs everything it needs.
    ///
    /// This is the method that makes `gallery-dl` possible. The single-package
    /// ``install(_:version:index:session:)`` cannot install it, and never could:
    /// `gallery-dl` needs `requests`, which needs `urllib3`, `certifi`, `idna`
    /// and `charset-normalizer`, and a package whose imports are missing fails
    /// at the first `import` rather than at install time.
    ///
    /// **Everything is resolved before anything is written.** A graph that
    /// cannot be satisfied — a conflict, or a dependency that publishes only
    /// compiled wheels — fails with nothing installed, rather than leaving a
    /// partial set that imports until it does not.
    ///
    /// - Parameter requirement: a PEP 508 requirement. Extras are honoured:
    ///   `"gallery-dl"` installs what gallery-dl needs, and nothing that only
    ///   its extras need.
    @discardableResult
    public func install(
        requirement: String,
        using source: any PythonPackageSource = PyPIPackageSource(),
        session: URLSession = .shared
    ) async throws -> Installation {
        try await install(requirements: [requirement], using: source, session: session)
    }

    /// Several requirements, resolved together and installed as one set.
    @discardableResult
    public func install(
        requirements: [String],
        upgrading: Bool = false,
        using source: any PythonPackageSource = PyPIPackageSource(),
        session: URLSession = .shared
    ) async throws -> Installation {
        let plan = try await plan(for: requirements, upgrading: upgrading, using: source)
        return try await carryOut(plan, session: session)
    }

    /// Installs a plan that was produced earlier — by ``plan(for:using:)``,
    /// and shown to somebody who said yes.
    @discardableResult
    public func carryOut(_ plan: PythonDependencyPlan, session: URLSession = .shared) async throws -> Installation {
        LatheFetchLog.packages.notice(
            "Installing \(plan.steps.count, privacy: .public) package(s); \(plan.alreadySatisfied.count, privacy: .public) already satisfied"
        )

        var requested: [InstalledPackage] = []
        var dependencies: [InstalledPackage] = []

        // In a defer because a failure on the third of five packages has still
        // replaced the first two underneath anything already imported.
        var replacedSomething = false
        defer {
            if replacedSomething { try? forgetImportedPackages() }
        }

        for step in plan.steps {
            guard let wheel = step.release.wheel else {
                // The resolver does not produce a step without a wheel; this is
                // the guard that keeps that a fact rather than an assumption.
                throw PythonPackageError.dependencyNotPurePython(
                    package: step.release.canonicalName,
                    version: step.release.version.description,
                    requiredBy: step.requiredBy,
                    candidates: step.release.publishedFiles)
            }
            let data = try await PackageIndex.download(wheel, using: session)
            let isReplacement = (try? installedPackage(step.release.canonicalName)) != nil
            let record = try install(wheel: data, named: wheel.filename, verifying: wheel.sha256)
            if isReplacement { replacedSomething = true }
            if step.isRoot {
                requested.append(record)
            } else {
                dependencies.append(record)
            }
        }

        let satisfied = plan.alreadySatisfied.compactMap { try? installedPackage($0.name) }.compactMap { $0 }

        return Installation(
            requested: requested,
            dependencies: dependencies,
            alreadySatisfied: satisfied,
            plan: plan
        )
    }

    /// Makes the next `import` of anything under ``root`` read it from disk.
    ///
    /// Replacing a package changes its files and nothing else: the interpreter
    /// never restarts, so `import yt_dlp` would go on returning the old modules,
    /// reporting the old version, and failing when a lazy import reached for a
    /// file the update deleted.
    ///
    /// Every package under the root goes rather than only the replaced ones,
    /// because a new `urllib3` beside an old, still-imported `requests` is a mix
    /// neither was written for. It is safe only with nothing running: something
    /// mid-extraction keeps its old modules and imports the new ones, so don't
    /// call this underneath a download.
    ///
    /// The drivers' "already registered" flags are reset for the same reason.
    /// Their network handler and challenge provider were registered on the
    /// modules being dropped, so a flag left set would keep the fresh `yt_dlp`
    /// from ever getting them. A fetcher only re-registers when it is new, so
    /// discard any held across this call.
    public func forgetImportedPackages() throws {
        try runtime.execute(
            """
            import importlib, os, sys
            _lathe_prefix = os.path.realpath(lathe_arguments["root"]) + os.sep
            for _lathe_name, _lathe_module in list(sys.modules.items()):
                _lathe_origin = getattr(_lathe_module, "__file__", None)
                if not _lathe_origin:
                    _lathe_origin = next(iter(getattr(_lathe_module, "__path__", None) or ()), None)
                if isinstance(_lathe_origin, str) and os.path.realpath(_lathe_origin).startswith(_lathe_prefix):
                    del sys.modules[_lathe_name]
            if "_LATHE_NET" in globals():
                _LATHE_NET["ytdlp_registered"] = False
                _LATHE_NET["gallerydl_registered"] = False
            if "_LATHE_YTDLP" in globals():
                _LATHE_YTDLP["provider_registered"] = False
            importlib.invalidate_caches()
            """,
            arguments: ["root": root.path]
        )
    }
}
