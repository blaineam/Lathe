import Foundation

/// A wheel the index has told us about: where it is, and what it should hash to.
public struct ResolvedWheel: Sendable, Equatable {
    public let package: String
    public let version: String
    public let filename: String
    public let url: URL

    /// The index's published SHA-256, lowercase hex.
    ///
    /// Non-optional on purpose. A file published without one is refused during
    /// resolution rather than downloaded and then worried about.
    public let sha256: String

    public let size: Int?
    public let requiresPython: String?
}

/// A PEP 503 / PyPI-JSON package index.
///
/// Parameterised rather than hard-coded so a host can point at a mirror or an
/// internal index, which is often the difference between "can use this" and
/// "cannot use this" inside an organisation. The default is PyPI.
public struct PackageIndex: Sendable, Equatable {

    /// The JSON API root — `https://pypi.org/pypi`.
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    public static let pypi = PackageIndex(baseURL: URL(string: "https://pypi.org/pypi")!)

    /// `…/<project>/json`, or `…/<project>/<version>/json`.
    ///
    /// The unversioned form is how "whatever the current release is" is asked:
    /// the response's `urls` array is the files of the latest non-prerelease
    /// version, and `info.version` names it.
    func metadataURL(for project: String, version: String?) -> URL {
        var url = baseURL.appendingPathComponent(project)
        if let version { url.appendPathComponent(version) }
        return url.appendingPathComponent("json")
    }

    // MARK: - Resolution

    private struct Metadata: Decodable {
        struct Info: Decodable {
            let name: String
            let version: String
        }
        struct File: Decodable {
            let filename: String
            let url: String
            let packagetype: String
            let digests: [String: String]
            let yanked: Bool?
            let size: Int?
            let requires_python: String?
        }
        let info: Info
        let urls: [File]
    }

    /// Asks the index for a project and returns the pure-Python wheel to install.
    ///
    /// - Parameter version: `nil` resolves the project's current version.
    /// - Throws: ``PythonPackageError/noPureWheelAvailable(package:version:candidates:)``
    ///   when the release publishes only compiled wheels or only an sdist. That
    ///   is a permanent answer for that version, not a transient one — building
    ///   an sdist needs a compiler, and there is none on a device.
    public func resolve(
        _ project: String,
        version: String? = nil,
        using session: URLSession = .shared
    ) async throws -> ResolvedWheel {
        let url = metadataURL(for: project, version: version)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw PythonPackageError.transportFailed(reason: (error as NSError).localizedDescription)
        }

        if let http = response as? HTTPURLResponse {
            guard http.statusCode != 404 else {
                throw PythonPackageError.notFoundInIndex(package: project, version: version)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw PythonPackageError.indexUnreadable(
                    package: project, reason: "HTTP \(http.statusCode)")
            }
        }

        let metadata: Metadata
        do {
            metadata = try JSONDecoder().decode(Metadata.self, from: data)
        } catch {
            throw PythonPackageError.indexUnreadable(package: project, reason: "\(error)")
        }

        let wheels = metadata.urls.filter { $0.packagetype == "bdist_wheel" && $0.yanked != true }

        // Rank pure wheels ahead of everything else, and among pure wheels
        // prefer a `py3`-only tag: a `py2.py3` wheel is usually older packaging
        // and occasionally carries compatibility shims that nothing needs here.
        let ranked = wheels.compactMap { file -> (Metadata.File, WheelName)? in
            guard let name = try? WheelName(parsing: file.filename) else { return nil }
            return (file, name)
        }
        .filter { $0.1.claimsPurePython }
        .sorted { left, right in
            let leftIsPy3Only = left.1.pythonTags == ["py3"]
            let rightIsPy3Only = right.1.pythonTags == ["py3"]
            if leftIsPy3Only != rightIsPy3Only { return leftIsPy3Only }
            return left.0.filename < right.0.filename
        }

        guard let (file, _) = ranked.first else {
            throw PythonPackageError.noPureWheelAvailable(
                package: metadata.info.name,
                version: metadata.info.version,
                candidates: metadata.urls.map(\.filename)
            )
        }
        guard let digest = file.digests["sha256"], !digest.isEmpty else {
            throw PythonPackageError.digestMissing(filename: file.filename)
        }
        guard let fileURL = URL(string: file.url) else {
            throw PythonPackageError.indexUnreadable(
                package: project, reason: "\(file.filename) has an unusable URL")
        }

        return ResolvedWheel(
            package: metadata.info.name,
            version: metadata.info.version,
            filename: file.filename,
            url: fileURL,
            sha256: digest.lowercased(),
            size: file.size,
            requiresPython: file.requires_python
        )
    }

    /// Downloads a resolved wheel and checks it against the index's hash.
    ///
    /// The verification is here, at the transport boundary, rather than inside
    /// the installer: unverified bytes should never reach a caller in the first
    /// place, and a function that returns `Data` known only to be "what some
    /// server sent" invites somebody to use it.
    public func download(_ wheel: ResolvedWheel, using session: URLSession = .shared) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: wheel.url)
        } catch {
            throw PythonPackageError.transportFailed(reason: (error as NSError).localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw PythonPackageError.transportFailed(reason: "HTTP \(http.statusCode) fetching \(wheel.filename)")
        }
        let actual = WheelInspection.hexDigest(of: data)
        guard actual == wheel.sha256 else {
            throw PythonPackageError.digestMismatch(expected: wheel.sha256, actual: actual)
        }
        return data
    }
}
