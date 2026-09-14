import Foundation

// MARK: - A release

/// One version of a project, as an index describes it.
public struct PythonRelease: Sendable, Equatable {

    /// The project name as the index spells it.
    public let project: String

    /// The PEP 503 canonical name.
    public let canonicalName: String

    public let version: PythonPackageVersion

    /// The pure-Python wheel to install, or `nil` when this release publishes
    /// none.
    ///
    /// Optional rather than throwing at this level on purpose: "this version
    /// has no pure wheel" is a fact about a candidate, and the resolver's job is
    /// to try the next candidate before giving up. Only when *no* satisfying
    /// version has one does it become an error — and then the error can say
    /// which package in the graph it was.
    public let wheel: ResolvedWheel?

    /// Every filename this release publishes, for the diagnostic when there is
    /// no usable one among them.
    public let publishedFiles: [String]

    /// `Requires-Python`, when the index states it for this release.
    public let requiresPython: PythonVersionSpecifierSet?

    public init(
        project: String,
        version: PythonPackageVersion,
        wheel: ResolvedWheel?,
        publishedFiles: [String] = [],
        requiresPython: PythonVersionSpecifierSet? = nil
    ) {
        self.project = project
        self.canonicalName = PythonPackageInstaller.canonicalName(project)
        self.version = version
        self.wheel = wheel
        self.publishedFiles = publishedFiles
        self.requiresPython = requiresPython
    }
}

// MARK: - Where releases come from

/// Where the resolver gets its facts.
///
/// Two methods, split by cost. ``releases(of:)`` is one request that answers
/// "what versions exist, and does each publish something installable";
/// ``metadata(for:)`` is a second, per *chosen* release, that answers "what does
/// it need". Fusing them would mean fetching the requirements of every version
/// of every package in the graph to install one of them.
///
/// The split is also what makes the resolver testable without a network: a
/// fixture source answers both from a dictionary, and every resolution test in
/// this package's suite is then a pure function of that dictionary.
public protocol PythonPackageSource: Sendable {

    /// Every version of `project` the source knows about.
    ///
    /// - Throws: ``PythonPackageError/notFoundInIndex(package:version:)`` when
    ///   there is no such project.
    func releases(of project: String) async throws -> [PythonRelease]

    /// What `release` declares it needs.
    func metadata(for release: PythonRelease) async throws -> PythonPackageMetadata
}

// MARK: - PyPI

/// A ``PythonPackageSource`` backed by a PyPI-JSON index.
///
/// An `actor` because it caches, and caching is the difference between one
/// request per package and one per edge in the graph: a diamond like
/// `gallery-dl → requests → urllib3` and `gallery-dl → urllib3` asks for
/// `urllib3` twice, and the second ask should cost nothing.
///
/// ## Where the requirements are read from
///
/// **The wheel's own `METADATA`, wherever it can be had without the wheel.** In
/// order:
///
/// 1. `info.requires_dist` from the project response, when the chosen version is
///    the one that response describes. Already in hand; free.
/// 2. `<wheel-url>.metadata` — PEP 658. One small request, and it is literally
///    the `METADATA` member of the wheel, served separately so a resolver need
///    not download twenty megabytes to read two kilobytes.
/// 3. The per-version JSON, for older files published before indexes served
///    metadata separately.
public actor PyPIPackageSource: PythonPackageSource {

    private let index: PackageIndex
    private let session: URLSession

    private var projects: [String: ProjectResponse] = [:]
    private var metadataCache: [String: PythonPackageMetadata] = [:]

    public init(index: PackageIndex = .pypi, session: URLSession = .shared) {
        self.index = index
        self.session = session
    }

    // MARK: The JSON

    private struct ProjectResponse: Decodable, Sendable {
        struct Info: Decodable, Sendable {
            let name: String
            let version: String
            let requires_dist: [String]?
            let requires_python: String?
            let provides_extra: [String]?
        }
        struct File: Decodable, Sendable {
            let filename: String
            let url: String
            let packagetype: String
            let digests: [String: String]
            let yanked: Bool?
            let size: Int?
            let requires_python: String?
        }
        let info: Info
        let releases: [String: [File]]?
        let urls: [File]?
    }

    private func project(_ name: String) async throws -> ProjectResponse {
        let key = PythonPackageInstaller.canonicalName(name)
        if let cached = projects[key] { return cached }
        let response = try await fetchProject(name, version: nil)
        projects[key] = response
        return response
    }

    private func fetchProject(_ name: String, version: String?) async throws -> ProjectResponse {
        let url = index.metadataURL(for: name, version: version)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw PythonPackageError.transportFailed(reason: (error as NSError).localizedDescription)
        }
        if let http = response as? HTTPURLResponse {
            guard http.statusCode != 404 else {
                throw PythonPackageError.notFoundInIndex(package: name, version: version)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw PythonPackageError.indexUnreadable(package: name, reason: "HTTP \(http.statusCode)")
            }
        }
        do {
            return try JSONDecoder().decode(ProjectResponse.self, from: data)
        } catch {
            throw PythonPackageError.indexUnreadable(package: name, reason: "\(error)")
        }
    }

    // MARK: PythonPackageSource

    public func releases(of project: String) async throws -> [PythonRelease] {
        let response = try await self.project(project)

        // `releases` carries every version's files in the one response, which is
        // what makes "which versions have a pure wheel" answerable without a
        // request per version. An index that omits it still answers for the
        // current version, which is the common case.
        let byVersion = response.releases ?? [response.info.version: response.urls ?? []]

        return byVersion.compactMap { text, files -> PythonRelease? in
            guard let version = PythonPackageVersion(parsing: text) else { return nil }
            let usable = files.filter { $0.yanked != true }
            guard !usable.isEmpty else { return nil }
            return PythonRelease(
                project: response.info.name,
                version: version,
                wheel: Self.pureWheel(among: usable),
                publishedFiles: usable.map(\.filename),
                requiresPython: usable.compactMap(\.requires_python).first.flatMap {
                    try? PythonVersionSpecifierSet(parsing: $0)
                }
            )
        }
    }

    /// The pure-Python wheel among a release's files, by the same ranking
    /// ``PackageIndex/resolve(_:version:using:)`` uses: pure only, `py3`
    /// preferred over `py2.py3`, and a published SHA-256 required.
    private static func pureWheel(among files: [ProjectResponse.File]) -> ResolvedWheel? {
        let ranked =
            files
            .filter { $0.packagetype == "bdist_wheel" }
            .compactMap { file -> (ProjectResponse.File, WheelName)? in
                guard let name = try? WheelName(parsing: file.filename), name.claimsPurePython else { return nil }
                return (file, name)
            }
            .sorted { left, right in
                let leftIsPy3Only = left.1.pythonTags == ["py3"]
                let rightIsPy3Only = right.1.pythonTags == ["py3"]
                if leftIsPy3Only != rightIsPy3Only { return leftIsPy3Only }
                return left.0.filename < right.0.filename
            }

        for (file, name) in ranked {
            guard let digest = file.digests["sha256"], !digest.isEmpty else { continue }
            guard let url = URL(string: file.url) else { continue }
            return ResolvedWheel(
                package: name.distribution,
                version: name.version,
                filename: file.filename,
                url: url,
                sha256: digest.lowercased(),
                size: file.size,
                requiresPython: file.requires_python
            )
        }
        return nil
    }

    public func metadata(for release: PythonRelease) async throws -> PythonPackageMetadata {
        let key = "\(release.canonicalName)/\(release.version.normalized)"
        if let cached = metadataCache[key] { return cached }

        let parsed = try await readMetadata(for: release)
        metadataCache[key] = parsed
        return parsed
    }

    private func readMetadata(for release: PythonRelease) async throws -> PythonPackageMetadata {
        // 1. Already in hand, when this is the version the project response
        //    described.
        if let response = projects[release.canonicalName],
            PythonPackageVersion(parsing: response.info.version) == release.version,
            let lines = response.info.requires_dist
        {
            return try metadata(from: response.info, requiresDist: lines)
        }

        // 2. PEP 658: the wheel's METADATA, served beside the wheel.
        if let wheel = release.wheel {
            let separate = URL(string: wheel.url.absoluteString + ".metadata")
            if let separate, let text = try? await fetchText(separate) {
                return try PythonPackageMetadata.parse(text, describedAs: release.project)
            }
        }

        // 3. The per-version JSON, for files published before indexes served
        //    metadata separately.
        let response = try await fetchProject(release.project, version: release.version.original)
        return try metadata(from: response.info, requiresDist: response.info.requires_dist ?? [])
    }

    private func metadata(
        from info: ProjectResponse.Info, requiresDist: [String]
    ) throws -> PythonPackageMetadata {
        var requirements: [PythonRequirement] = []
        for line in requiresDist {
            do {
                requirements.append(try PythonRequirement(parsing: line))
            } catch let error as PythonPackageError {
                throw PythonPackageError.metadataUnreadable(
                    package: info.name, reason: "Requires-Dist: \(line) — \(error.localizedDescription)")
            }
        }
        return PythonPackageMetadata(
            name: info.name,
            version: info.version,
            requiresPython: info.requires_python.flatMap { try? PythonVersionSpecifierSet(parsing: $0) },
            requirements: requirements,
            providedExtras: Set((info.provides_extra ?? []).map(PythonRequirement.canonicalExtra))
        )
    }

    private func fetchText(_ url: URL) async throws -> String {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PythonPackageError.transportFailed(reason: "HTTP \(http.statusCode)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw PythonPackageError.transportFailed(reason: "the metadata was not UTF-8")
        }
        return text
    }
}
