import Foundation
import Testing

@testable import LatheFetch

/// The installer, against wheels built in memory.
///
/// **The default run reaches no network.** Every refusal — a bad hash, a
/// compiled wheel, a member that would escape the directory — is exercised
/// against a fixture, because every one of them is decided before a byte is
/// written. The tests that do talk to a real index are opt-in through
/// `LATHE_FETCH_NETWORK_TESTS=1` and skip cleanly without it; a default suite
/// that depends on someone else's uptime is a suite that eventually gets
/// disbelieved.
/// `.serialized` because these tests share one interpreter and each one
/// installs into a temporary root it deletes afterwards. Run concurrently, one
/// test's cleanup pulls the directory out from under another test's `sys.path`
/// and `sys.modules`, and the failure looks like a packaging bug rather than
/// like the test-isolation problem it is.
@Suite("Pure-Python package installer", .serialized)
struct PackageInstallerTests {

    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lathe-packages-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Name normalisation (no interpreter needed)

    @Test(
        "names are normalised the way PEP 503 says",
        arguments: [
            ("gallery_dl", "gallery-dl"),
            ("Gallery-DL", "gallery-dl"),
            ("gallery.dl", "gallery-dl"),
            ("zope..interface", "zope-interface"),
            ("yt_dlp", "yt-dlp"),
            ("requests", "requests"),
        ])
    func canonicalisesNames(input: String, expected: String) {
        #expect(PythonPackageInstaller.canonicalName(input) == expected)
    }

    // MARK: - Refusals

    @Test("a wheel whose hash does not match is refused, and writes nothing",
          .enabled(if: SharedInterpreter.isAvailable))
    func refusesBadDigest() async throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let installer = PythonPackageInstaller(runtime: runtime, root: root)
        let (filename, data) = WheelFixtures.pureWheel(distribution: "example-pkg", version: "1.0.0")

        let error = await #expect(throws: PythonPackageError.self) {
            try await installer.install(wheel: data, named: filename, verifying: String(repeating: "a", count: 64))
        }
        guard case .digestMismatch = error else {
            Issue.record("expected digestMismatch, got \(String(describing: error))")
            return
        }
        #expect(try await installer.installed().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("example_pkg").path))
    }

    @Test("a wheel with compiled code is refused, and writes nothing",
          .enabled(if: SharedInterpreter.isAvailable))
    func refusesCompiledWheel() async throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let installer = PythonPackageInstaller(runtime: runtime, root: root)
        let data = WheelFixtures.wheel([
            "fastthing/__init__.py",
            "fastthing/_speedups.cpython-313-darwin.so",
        ])

        let error = await #expect(throws: PythonPackageError.self) {
            try await installer.install(wheel: data, named: "fastthing-1.0-py3-none-any.whl", verifying: nil)
        }
        guard case let .notPurePython(_, _, members) = error else {
            Issue.record("expected notPurePython, got \(String(describing: error))")
            return
        }
        #expect(members == ["fastthing/_speedups.cpython-313-darwin.so"])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("fastthing").path))
    }

    @Test("a wheel that would write outside the root is refused",
          .enabled(if: SharedInterpreter.isAvailable))
    func refusesEscapingMember() async throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let installer = PythonPackageInstaller(runtime: runtime, root: root)
        let data = WheelFixtures.wheel(["sneaky/__init__.py", "../escaped.py"])

        let error = await #expect(throws: PythonPackageError.self) {
            try await installer.install(wheel: data, named: "sneaky-1.0-py3-none-any.whl", verifying: nil)
        }
        guard case .unsafeArchiveMember = error else {
            Issue.record("expected unsafeArchiveMember, got \(String(describing: error))")
            return
        }
        #expect(
            !FileManager.default.fileExists(
                atPath: root.deletingLastPathComponent().appendingPathComponent("escaped.py").path))
    }

    // MARK: - The round trip

    @Test("a pure wheel installs, imports, lists and removes",
          .enabled(if: SharedInterpreter.isAvailable))
    func installsListsAndRemoves() async throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let installer = PythonPackageInstaller(runtime: runtime, root: root)
        let (filename, data) = WheelFixtures.pureWheel(distribution: "lathe-demo", version: "1.2.3")

        let record = try await installer.install(
            wheel: data, named: filename, verifying: WheelInspection.hexDigest(of: data))
        #expect(record.name == "lathe-demo")
        #expect(record.version == "1.2.3")
        #expect(record.distribution == "lathe_demo")

        // The on-disk shape is `pip install --target`'s, so it is legible to
        // anyone who knows Python packaging and nothing about Lathe.
        let files = FileManager.default
        #expect(files.fileExists(atPath: root.appendingPathComponent("lathe_demo/__init__.py").path))
        #expect(files.fileExists(atPath: root.appendingPathComponent("lathe_demo-1.2.3.dist-info/METADATA").path))

        let listed = try await installer.installed()
        #expect(listed.map(\.name) == ["lathe-demo"])
        #expect(listed.first?.version == "1.2.3")

        // The real proof: the interpreter can import it.
        try await installer.activate()
        try runtime.importModule("lathe_demo")
        #expect(try runtime.evaluate("lathe_demo.VERSION").value.string == "1.2.3")
        #expect(
            try runtime.evaluate("__import__('lathe_demo.core', fromlist=['core']).greet()").value.string
                == "hello from lathe_demo")

        try await installer.remove("Lathe-Demo")  // a non-canonical spelling must still find it
        #expect(try await installer.installed().isEmpty)
        #expect(!files.fileExists(atPath: root.appendingPathComponent("lathe_demo").path))
        #expect(!files.fileExists(atPath: root.appendingPathComponent("lathe_demo-1.2.3.dist-info").path))
    }

    @Test("reinstalling a different version leaves nothing of the old one behind",
          .enabled(if: SharedInterpreter.isAvailable))
    func replacesRatherThanMerges() async throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let installer = PythonPackageInstaller(runtime: runtime, root: root)
        let first = WheelFixtures.pureWheel(distribution: "lathe-swap", version: "1.0.0")
        try await installer.install(wheel: first.data, named: first.filename, verifying: nil)

        // A version whose wheel drops a module. Left behind, `core.py` would
        // still import perfectly well — and be wrong.
        let second = StoredZIP.archive([
            ("lathe_swap/__init__.py", Data("VERSION = \"2.0.0\"\n".utf8)),
            ("lathe_swap-2.0.0.dist-info/METADATA", Data("Name: lathe-swap\nVersion: 2.0.0\n".utf8)),
        ])
        try await installer.install(wheel: second, named: "lathe_swap-2.0.0-py3-none-any.whl", verifying: nil)

        let files = FileManager.default
        #expect(!files.fileExists(atPath: root.appendingPathComponent("lathe_swap/core.py").path))
        #expect(!files.fileExists(atPath: root.appendingPathComponent("lathe_swap-1.0.0.dist-info").path))
        #expect(files.fileExists(atPath: root.appendingPathComponent("lathe_swap-2.0.0.dist-info").path))
        #expect(try await installer.installed().first?.version == "2.0.0")
    }

    @Test("removing something that is not installed says so",
          .enabled(if: SharedInterpreter.isAvailable))
    func refusesUnknownRemoval() async throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let installer = PythonPackageInstaller(runtime: runtime, root: root)
        let error = await #expect(throws: PythonPackageError.self) { try await installer.remove("nothing-here") }
        guard case .notInstalled = error else {
            Issue.record("expected notInstalled, got \(String(describing: error))")
            return
        }
    }

    @Test("activate puts the root at the front of sys.path, once",
          .enabled(if: SharedInterpreter.isAvailable))
    func activatesIdempotently() async throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let installer = PythonPackageInstaller(runtime: runtime, root: root)
        try await installer.activate()
        try await installer.activate()

        let occurrences = try runtime.evaluate(
            "__import__('sys').path.count(lathe_arguments['root'])", arguments: ["root": root.path])
        #expect(occurrences.value.int == 1)
        #expect(try runtime.evaluate("__import__('sys').path[0]").value.string == root.path)
    }

    // MARK: - The index (network, opt-in)

    @Test(
        "resolving a real project finds a pure wheel with a hash",
        .enabled(if: SharedInterpreter.networkTestsEnabled))
    func resolvesFromPyPI() async throws {
        // gallery-dl is the first intended client of this installer and is
        // published as a pure-Python wheel; that is the property being checked,
        // not any particular version.
        let resolved = try await PackageIndex.pypi.resolve("gallery-dl")
        #expect(resolved.filename.hasSuffix("-py3-none-any.whl"))
        #expect(resolved.sha256.count == 64)
        #expect(!resolved.version.isEmpty)
        #expect(try WheelName(parsing: resolved.filename).claimsPurePython)
        print("  resolved gallery-dl \(resolved.version): \(resolved.filename)")
    }

    @Test(
        "a project with only compiled wheels is refused at resolution",
        .enabled(if: SharedInterpreter.networkTestsEnabled))
    func refusesCompiledProject() async throws {
        // lxml publishes compiled wheels for every platform and no pure one.
        let error = await #expect(throws: PythonPackageError.self) {
            try await PackageIndex.pypi.resolve("lxml")
        }
        guard case .noPureWheelAvailable = error else {
            Issue.record("expected noPureWheelAvailable, got \(String(describing: error))")
            return
        }
    }

    @Test("a project that does not exist is reported as such", .enabled(if: SharedInterpreter.networkTestsEnabled))
    func reportsUnknownProject() async throws {
        let error = await #expect(throws: PythonPackageError.self) {
            try await PackageIndex.pypi.resolve("lathe-no-such-project-exists-here")
        }
        guard case .notFoundInIndex = error else {
            Issue.record("expected notFoundInIndex, got \(String(describing: error))")
            return
        }
    }

    @Test(
        "a real package downloads, verifies and imports",
        .enabled(if: SharedInterpreter.networkTestsEnabled && SharedInterpreter.isAvailable))
    func installsFromPyPI() async throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let installer = PythonPackageInstaller(runtime: runtime, root: root)
        let record = try await installer.install("gallery-dl")
        try await installer.activate()

        print("  installed gallery-dl \(record.version) — \(record.members.count) files")
        try runtime.importModule("gallery_dl.version")
        #expect(try runtime.evaluate("gallery_dl.version.__version__").value.string == record.version)
    }

    // MARK: - The whole thing (network, opt-in)

    @Test(
        "gallery-dl installs with its dependencies and imports properly",
        .enabled(if: SharedInterpreter.networkTestsEnabled && SharedInterpreter.isAvailable))
    func installsGalleryDLWithDependencies() async throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let installer = PythonPackageInstaller(runtime: runtime, root: root)

        // The plan first, because a person should be able to see what "install
        // gallery-dl" actually means before it happens.
        let plan = try await installer.plan(for: "gallery-dl")
        print("")
        print(plan.summary)
        print("")

        let planned = plan.steps.map(\.release.canonicalName)
        #expect(planned.contains("gallery-dl"))
        #expect(planned.contains("requests"), "gallery-dl needs requests, which is the reason this exists")
        #expect(planned.contains("urllib3"), "requests needs urllib3, two levels down")
        #expect(planned.contains("certifi"))
        #expect(planned.contains("idna"))
        // The extras of requests must not be in here. PySocks is the one that
        // arrives uninvited when markers are ignored.
        #expect(!planned.contains("pysocks"))
        // Dependencies before the thing that imports them.
        #expect(planned.last == "gallery-dl")

        let installation = try await installer.install(requirement: "gallery-dl")
        try await installer.activate()

        #expect(installation.requested.map(\.name) == ["gallery-dl"])
        #expect(installation.dependencies.count >= 4)
        print("  installed \(installation.all.count) packages:")
        for package in installation.all {
            print("    · \(package.name) \(package.version) (\(package.members.count) files)")
        }

        // The interpreter is shared by the whole suite and never restarts, so
        // an earlier test may have imported `gallery_dl` from a root that no
        // longer exists. Dropping it from `sys.modules` makes the import below
        // a real import of what was just installed rather than a cache hit.
        try runtime.execute(
            """
            import sys
            for _lathe_stale in [n for n in list(sys.modules) if n.split(".")[0] == "gallery_dl"]:
                del sys.modules[_lathe_stale]
            """)

        // The proof, and the thing the previous suite could not do. Not
        // `gallery_dl.version` — that is one file with no imports in it and
        // passes with none of the dependency work done at all.
        try runtime.importModule("gallery_dl")
        try runtime.importModule("gallery_dl.extractor")
        #expect(try runtime.evaluate("bool(gallery_dl.extractor.extractors())").value.bool == true)

        // requests arrived as a dependency and works, which is what anything
        // built on this is going to need first.
        try runtime.importModule("requests")
        #expect(try runtime.evaluate("requests.__version__").value.string?.isEmpty == false)
    }

    @Test(
        "a second resolution sees the first one's packages rather than refetching them",
        .enabled(if: SharedInterpreter.networkTestsEnabled && SharedInterpreter.isAvailable))
    func reusesInstalledDependencies() async throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let installer = PythonPackageInstaller(runtime: runtime, root: root)
        _ = try await installer.install(requirement: "requests")

        let second = try await installer.plan(for: "requests")
        #expect(second.steps.isEmpty, "everything was already installed:\n\(second.summary)")
        #expect(second.alreadySatisfied.contains { $0.name == "urllib3" })
    }
}
