import Foundation

/// Installs pure-Python packages into an application-writable directory and puts
/// that directory on `sys.path`.
///
/// ## What this does and does not distribute
///
/// **Nothing installed through this type is distributed by Lathe.** Lathe ships
/// no Python package, no wheel, no vendored copy and no mirror of anyone's code.
/// This is a client for a package index: the *user of the application*, at run
/// time, on their own device, asks for a named project, and it is fetched from
/// the index they chose and unpacked into their own container.
///
/// That distinction is the entire reason this type exists rather than a
/// `Resources/` directory with some wheels in it, and it has consequences worth
/// being deliberate about:
///
/// * **Licence obligations do not travel with Lathe.** A package's licence binds
///   whoever distributes it. Lathe does not, so a GPL package a user chooses to
///   install is between that package and that user — which is exactly the
///   property that lets this coexist with the package's Apache-2.0 licence and
///   the no-GPL-dependencies rule in the README's licence policy.
/// * **The installed set is the user's, not the vendor's.** It is in their
///   container, listed by ``installed()``, and removable by ``remove(_:)``.
/// * **Nothing is installed implicitly.** There is no bundled default set and no
///   install-on-first-use; every install is a call someone made.
///
/// ## Pure Python only, permanently
///
/// A wheel containing a compiled extension module is refused, with the offending
/// members named — see
/// ``PythonPackageError/notPurePython(package:filename:members:)``. iOS cannot
/// load a dynamic library that was not inside the signed application bundle, so
/// a `.so` downloaded at run time can never be imported. Refusing at install
/// time is the whole value: the alternative is an `ImportError` deep inside
/// somebody else's package, hours later, that reads like a bug in the
/// application.
///
/// ## Layout
///
/// ``root`` is treated as a `purelib` directory — the same shape `pip install
/// --target` produces, which is what makes the result inspectable by anyone who
/// knows Python packaging and nothing about Lathe:
///
/// ```text
/// <root>/gallery_dl/…                      the package
/// <root>/gallery_dl-1.2.3.dist-info/…      its metadata, from the wheel
/// <root>/.lathe-receipts/gallery-dl.json   what this installer put there
/// ```
///
/// The receipts directory is dot-prefixed so it can never be imported as a
/// package, and it exists because removal has to know exactly which files an
/// install wrote — reconstructing that from a `RECORD` that may or may not be
/// present is guesswork at precisely the moment guessing is worst.
public actor PythonPackageInstaller {

    /// One installed package, as recorded at install time.
    public struct InstalledPackage: Sendable, Equatable, Codable {
        /// The PEP 503 canonical name — lowercase, hyphenated.
        public let name: String

        /// The name as the wheel spelled it.
        public let distribution: String
        public let version: String
        public let filename: String

        /// The SHA-256 of the wheel these files came out of, so "is this the
        /// same build?" is answerable later without re-downloading.
        public let sha256: String

        public let installedAt: Date

        /// Every path written, relative to ``root``.
        public let members: [String]
    }

    /// The result of ``update(_:index:session:)``.
    public enum UpdateOutcome: Sendable, Equatable {
        /// The installed version is already the index's current one.
        case alreadyCurrent(InstalledPackage)
        /// Replaced. Both versions are named, because "it updated" is not
        /// useful and "1.2.3 → 1.3.0" is.
        case updated(from: String, to: InstalledPackage)
    }

    /// Where packages are installed. Must be writable — an application's
    /// Application Support directory, not its bundle.
    public let root: URL

    let runtime: PythonRuntime
    private let fileManager = FileManager.default

    /// The interpreter's marker environment, read once on first use.
    /// See ``markerEnvironment()``.
    var cachedMarkerEnvironment: PythonMarkerEnvironment?

    private var receiptsDirectory: URL {
        root.appendingPathComponent(".lathe-receipts", isDirectory: true)
    }

    /// - Parameters:
    ///   - runtime: the process's interpreter. Held because unpacking uses
    ///     Python's own `zipfile` rather than a second ZIP implementation, and
    ///     because registering ``root`` on `sys.path` is a Python operation.
    ///   - root: an application-writable directory. Created on first write.
    public init(runtime: PythonRuntime, root: URL) {
        self.runtime = runtime
        self.root = root
    }

    // MARK: - sys.path

    /// Puts ``root`` at the front of `sys.path`, creating it if needed.
    ///
    /// Idempotent, and front rather than back: an installed package should win
    /// over a same-named module that happens to be in the bundled standard
    /// library, because the user asked for it by name.
    public func activate() throws {
        try createRootIfNeeded()
        try runtime.execute(
            """
            import sys
            _lathe_root = lathe_arguments["root"]
            if _lathe_root in sys.path:
                sys.path.remove(_lathe_root)
            sys.path.insert(0, _lathe_root)
            """,
            arguments: ["root": root.path]
        )
    }

    // MARK: - Listing

    /// What is installed, by canonical name.
    public func installed() throws -> [InstalledPackage] {
        guard let receipts = try? fileManager.contentsOfDirectory(
            at: receiptsDirectory, includingPropertiesForKeys: nil)
        else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return
            receipts
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(InstalledPackage.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name < $1.name }
    }

    /// One installed package, or `nil`.
    public func installedPackage(_ name: String) throws -> InstalledPackage? {
        let url = receiptURL(for: Self.canonicalName(name))
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(InstalledPackage.self, from: data)
    }

    // MARK: - Installing

    /// Resolves a project against the index, downloads its wheel, verifies the
    /// published hash, and unpacks it.
    ///
    /// - Parameter version: `nil` takes the index's current release.
    public func install(
        _ name: String,
        version: String? = nil,
        index: PackageIndex = .pypi,
        session: URLSession = .shared
    ) async throws -> InstalledPackage {
        let resolved = try await index.resolve(name, version: version, using: session)
        let data = try await index.download(resolved, using: session)
        LatheFetchLog.packages.notice(
            "Installing \(resolved.package, privacy: .public) \(resolved.version, privacy: .public)")
        return try install(wheel: data, named: resolved.filename, verifying: resolved.sha256)
    }

    /// Installs a wheel that is already in memory.
    ///
    /// The offline half of ``install(_:version:index:session:)``, and the one
    /// the test suite exercises: everything that can refuse an install —
    /// hash verification, the pure-Python check, the unsafe-member check —
    /// happens here, **before** anything is written and before the interpreter
    /// is asked to do anything. A refused wheel therefore needs no network and
    /// no Python to be refused.
    ///
    /// - Parameter sha256: the expected digest, lowercase or upper. Passing
    ///   `nil` skips verification and is only correct for bytes that came from
    ///   somewhere already trusted — a file the user picked, a test fixture.
    @discardableResult
    public func install(wheel data: Data, named filename: String, verifying sha256: String?) throws -> InstalledPackage
    {
        let inspection = try WheelInspection.inspect(data, filename: filename)
        if let sha256 { try inspection.verify(sha256: sha256) }
        try inspection.validate()

        let canonical = Self.canonicalName(inspection.name.distribution)
        try createRootIfNeeded()

        // Replacing rather than merging: a wheel's members are not guaranteed to
        // be a superset of the previous version's, and an orphaned module left
        // behind by an upgrade imports perfectly well and is wrong.
        if (try? installedPackage(canonical)) != nil {
            try remove(canonical)
        }

        let staging = fileManager.temporaryDirectory
            .appendingPathComponent("lathe-wheel-\(UUID().uuidString).whl")
        try data.write(to: staging)
        defer { try? fileManager.removeItem(at: staging) }

        do {
            try runtime.execute(
                """
                import zipfile
                with zipfile.ZipFile(lathe_arguments["archive"]) as _lathe_archive:
                    _lathe_archive.extractall(lathe_arguments["root"])
                import importlib
                importlib.invalidate_caches()
                """,
                arguments: ["archive": staging.path, "root": root.path]
            )
        } catch let error as PythonError {
            throw PythonPackageError.malformedArchive(reason: error.localizedDescription)
        }

        let record = InstalledPackage(
            name: canonical,
            distribution: inspection.name.distribution,
            version: inspection.name.version,
            filename: filename,
            sha256: inspection.sha256,
            installedAt: Date(),
            members: inspection.members
        )
        try write(record)
        return record
    }

    // MARK: - Updating and removing

    /// Re-resolves the project and replaces it if the index has moved on.
    public func update(
        _ name: String,
        index: PackageIndex = .pypi,
        session: URLSession = .shared
    ) async throws -> UpdateOutcome {
        let canonical = Self.canonicalName(name)
        guard let existing = try installedPackage(canonical) else {
            throw PythonPackageError.notInstalled(package: canonical)
        }
        let resolved = try await index.resolve(existing.distribution, using: session)
        guard resolved.version != existing.version else {
            return .alreadyCurrent(existing)
        }
        let data = try await index.download(resolved, using: session)
        let installed = try install(wheel: data, named: resolved.filename, verifying: resolved.sha256)
        return .updated(from: existing.version, to: installed)
    }

    /// Deletes every file an install wrote, then prunes the directories it
    /// emptied.
    ///
    /// **Does not unload anything.** A module already imported into the running
    /// interpreter stays imported, because CPython cannot reliably unload one —
    /// and since this package never restarts the interpreter either, the removal
    /// takes full effect at the next launch. Said here rather than discovered
    /// later.
    public func remove(_ name: String) throws {
        let canonical = Self.canonicalName(name)
        guard let record = try installedPackage(canonical) else {
            throw PythonPackageError.notInstalled(package: canonical)
        }

        // Files first, then directories longest-path-first so children go before
        // their parents. Only directories this install created and left empty
        // are removed: a shared namespace directory that still has something in
        // it survives.
        var directories: Set<String> = []
        for member in record.members {
            guard !WheelInspection.isUnsafe(member) else { continue }
            let url = root.appendingPathComponent(member)
            if member.hasSuffix("/") {
                directories.insert(member)
            } else {
                try? fileManager.removeItem(at: url)
                var parent = (member as NSString).deletingLastPathComponent
                while !parent.isEmpty {
                    directories.insert(parent)
                    parent = (parent as NSString).deletingLastPathComponent
                }
            }
        }
        for directory in directories.sorted(by: { $0.count > $1.count }) {
            let url = root.appendingPathComponent(directory)
            if let contents = try? fileManager.contentsOfDirectory(atPath: url.path), contents.isEmpty {
                try? fileManager.removeItem(at: url)
            }
        }

        try? fileManager.removeItem(at: receiptURL(for: canonical))
        _ = try? runtime.execute("import importlib; importlib.invalidate_caches()")
        LatheFetchLog.packages.notice("Removed \(canonical, privacy: .public)")
    }

    // MARK: - Plumbing

    /// PEP 503 name normalisation: lowercase, and any run of `-`, `_` or `.`
    /// collapsed to a single `-`. `gallery_dl`, `Gallery-DL` and `gallery.dl`
    /// are one package, and a receipt filename has to agree.
    public static func canonicalName(_ name: String) -> String {
        var result = ""
        var lastWasSeparator = false
        for character in name.lowercased() {
            if character == "-" || character == "_" || character == "." {
                if !lastWasSeparator { result.append("-") }
                lastWasSeparator = true
            } else {
                result.append(character)
                lastWasSeparator = false
            }
        }
        return result
    }

    private func receiptURL(for canonical: String) -> URL {
        receiptsDirectory.appendingPathComponent("\(canonical).json")
    }

    private func createRootIfNeeded() throws {
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: receiptsDirectory, withIntermediateDirectories: true)
        } catch {
            throw PythonPackageError.storeUnwritable(
                path: root.path, reason: (error as NSError).localizedDescription)
        }
    }

    private func write(_ record: InstalledPackage) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(record).write(to: receiptURL(for: record.name), options: .atomic)
        } catch {
            throw PythonPackageError.storeUnwritable(
                path: receiptsDirectory.path, reason: (error as NSError).localizedDescription)
        }
    }
}
