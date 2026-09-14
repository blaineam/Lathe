import Foundation
import Testing

@testable import LatheFetch

// MARK: - A package index made of text

/// A ``PythonPackageSource`` whose entire universe is a dictionary.
///
/// The resolver's tests are **pure functions of this text**: no network, no
/// index, no interpreter, and therefore no reason for any of them to be
/// conditional or flaky. That is worth the fixture, because dependency
/// resolution is where a wrong answer is least visible — a graph that resolves
/// to the wrong five packages installs perfectly and fails days later, inside
/// somebody else's code.
///
/// The fixtures are real `METADATA` text rather than a parsed structure, so the
/// header parser is exercised by every resolution test as well as by its own.
struct FixtureSource: PythonPackageSource {

    struct Entry: Sendable {
        var metadata: String
        /// Whether this release publishes a pure-Python wheel.
        var isPure: Bool = true
        var files: [String] = []
        var requiresPython: String?
    }

    /// project → version → entry.
    let catalogue: [String: [String: Entry]]

    /// How many times each project was asked for, so "do not re-download what
    /// is installed" and "a diamond costs one request, not two" are checkable
    /// rather than merely claimed.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var releaseRequests: [String: Int] = [:]
        private(set) var metadataRequests: [String: Int] = [:]
        func release(_ name: String) {
            lock.lock()
            defer { lock.unlock() }
            releaseRequests[name, default: 0] += 1
        }
        func metadata(_ name: String) {
            lock.lock()
            defer { lock.unlock() }
            metadataRequests[name, default: 0] += 1
        }
    }
    let counter = Counter()

    func releases(of project: String) async throws -> [PythonRelease] {
        let canonical = PythonPackageInstaller.canonicalName(project)
        counter.release(canonical)
        guard let versions = entries(for: canonical) else {
            throw PythonPackageError.notFoundInIndex(package: project, version: nil)
        }
        return versions.compactMap { text, entry in
            guard let version = PythonPackageVersion(parsing: text) else { return nil }
            let filename = "\(project.replacingOccurrences(of: "-", with: "_"))-\(text)-py3-none-any.whl"
            return PythonRelease(
                project: project,
                version: version,
                wheel: entry.isPure
                    ? ResolvedWheel(
                        package: project,
                        version: text,
                        filename: filename,
                        url: URL(string: "https://example.invalid/\(filename)")!,
                        sha256: String(repeating: "0", count: 64),
                        size: nil,
                        requiresPython: entry.requiresPython)
                    : nil,
                publishedFiles: entry.files.isEmpty ? [filename] : entry.files,
                requiresPython: entry.requiresPython.flatMap { try? PythonVersionSpecifierSet(parsing: $0) }
            )
        }
    }

    func metadata(for release: PythonRelease) async throws -> PythonPackageMetadata {
        counter.metadata(release.canonicalName)
        guard let versions = entries(for: release.canonicalName) else {
            throw PythonPackageError.notFoundInIndex(package: release.project, version: nil)
        }
        for (text, entry) in versions where PythonPackageVersion(parsing: text) == release.version {
            return try PythonPackageMetadata.parse(entry.metadata, describedAs: release.project)
        }
        throw PythonPackageError.notFoundInIndex(
            package: release.project, version: release.version.description)
    }

    private func entries(for canonical: String) -> [String: Entry]? {
        for (project, versions) in catalogue
        where PythonPackageInstaller.canonicalName(project) == canonical {
            return versions
        }
        return nil
    }

    /// Renders a `METADATA` file. Written out rather than abbreviated because
    /// the field names and the folding are part of what is under test.
    static func metadataText(
        name: String,
        version: String,
        requires: [String] = [],
        extras: [String] = [],
        requiresPython: String? = nil
    ) -> String {
        var lines = [
            "Metadata-Version: 2.1",
            "Name: \(name)",
            "Version: \(version)",
            "Summary: a fixture",
        ]
        if let requiresPython { lines.append("Requires-Python: \(requiresPython)") }
        lines += extras.map { "Provides-Extra: \($0)" }
        lines += requires.map { "Requires-Dist: \($0)" }
        lines.append("")
        lines.append("A long description, which is not metadata and must not be parsed as any.")
        lines.append("Requires-Dist: this-line-is-prose-and-must-be-ignored")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Versions

@Suite("PEP 440 versions")
struct PythonPackageVersionTests {

    @Test(
        "versions order the way packaging orders them, not the way strings do",
        arguments: [
            ("1.9", "1.10"),
            ("1.0", "1.0.1"),
            ("1.0a1", "1.0b1"),
            ("1.0b2", "1.0rc1"),
            ("1.0rc1", "1.0"),
            ("1.0", "1.0.post1"),
            ("1.0.dev1", "1.0a1"),
            ("1.0.dev1", "1.0"),
            ("1.0", "1!0.1"),
            ("1.0", "1.0+local"),
            ("2023.7.22", "2024.2.2"),
        ])
    func ordersCorrectly(lower: String, higher: String) throws {
        let low = try #require(PythonPackageVersion(parsing: lower))
        let high = try #require(PythonPackageVersion(parsing: higher))
        #expect(low < high, "\(lower) should sort below \(higher)")
        #expect(!(high < low))
    }

    @Test("trailing zeros do not make a new version")
    func zeroPadding() throws {
        let short = try #require(PythonPackageVersion(parsing: "1.2"))
        let long = try #require(PythonPackageVersion(parsing: "1.2.0"))
        #expect(short == long)
        #expect(Set([short, long]).count == 1)
    }

    @Test(
        "every spelling of a pre-release normalises to one version",
        arguments: [
            ("1.0alpha1", "1.0a1"),
            ("1.0-beta-2", "1.0b2"),
            ("1.0.c3", "1.0rc3"),
            ("1.0preview4", "1.0rc4"),
            ("v1.0", "1.0"),
            ("1.0-1", "1.0.post1"),
            ("1.0rev2", "1.0.post2"),
        ])
    func normalisesSpellings(written: String, canonical: String) throws {
        let parsed = try #require(PythonPackageVersion(parsing: written))
        #expect(parsed.normalized == canonical)
        #expect(parsed == PythonPackageVersion(parsing: canonical))
    }

    @Test("a version that is not PEP 440 is refused rather than guessed at")
    func refusesNonsense() {
        #expect(PythonPackageVersion(parsing: "not-a-version") == nil)
        #expect(PythonPackageVersion(parsing: "") == nil)
        #expect(PythonPackageVersion(parsing: "1.2.x") == nil)
    }

    @Test("a pre-release knows it is one")
    func identifiesPreReleases() throws {
        #expect(try #require(PythonPackageVersion(parsing: "2.0rc1")).isPreRelease)
        #expect(try #require(PythonPackageVersion(parsing: "2.0.dev3")).isPreRelease)
        #expect(try #require(PythonPackageVersion(parsing: "2.0")).isPreRelease == false)
        #expect(try #require(PythonPackageVersion(parsing: "2.0.post1")).isPreRelease == false)
    }
}

@Suite("Version specifiers")
struct PythonVersionSpecifierTests {

    private func satisfies(_ specifier: String, _ version: String) throws -> Bool {
        let set = try PythonVersionSpecifierSet(parsing: specifier)
        return set.isSatisfied(by: try #require(PythonPackageVersion(parsing: version)))
    }

    @Test(
        "each operator means what PEP 440 says it means",
        arguments: [
            (">=2.0", "2.0", true), (">=2.0", "1.9", false), (">=2.0", "2.0.1", true),
            (">2.0", "2.0", false), (">2.0", "2.0.1", true),
            ("<3", "2.9", true), ("<3", "3.0", false),
            ("<=3", "3.0", true),
            ("==1.4.2", "1.4.2", true), ("==1.4.2", "1.4.3", false),
            ("==1.4.*", "1.4.9", true), ("==1.4.*", "1.5.0", false), ("==1.4.*", "1.4", true),
            ("!=1.4.2", "1.4.3", true), ("!=1.4.2", "1.4.2", false),
            ("~=1.4.2", "1.4.9", true), ("~=1.4.2", "1.5.0", false), ("~=1.4.2", "1.4.1", false),
            ("~=1.4", "1.9", true), ("~=1.4", "2.0", false),
            (">=1.0,<2.0", "1.5", true), (">=1.0,<2.0", "2.0", false),
            (">=1.0,<2.0,!=1.5", "1.5", false),
        ])
    func operators(specifier: String, version: String, expected: Bool) throws {
        #expect(try satisfies(specifier, version) == expected, "\(version) against \(specifier)")
    }

    @Test("a clause that is not an operator plus a version is refused, not ignored")
    func refusesGarbage() {
        // Silently dropping a clause installs a version the caller ruled out,
        // which is the failure this throw exists to prevent.
        #expect(throws: PythonPackageError.self) { try PythonVersionSpecifierSet(parsing: ">=1.0, banana") }
        #expect(throws: PythonPackageError.self) { try PythonVersionSpecifierSet(parsing: "2.0") }
    }

    @Test("an empty specifier accepts anything")
    func emptyAcceptsAnything() throws {
        let set = try PythonVersionSpecifierSet(parsing: "")
        #expect(set.isEmpty)
        #expect(set.isSatisfied(by: try #require(PythonPackageVersion(parsing: "9.9.9"))))
    }

    @Test("the highest satisfying version wins, and a pre-release does not sneak in")
    func picksHighestStable() throws {
        let candidates = ["1.0", "1.5", "2.0rc1", "1.9"].compactMap(PythonPackageVersion.init(parsing:))
        let any = try PythonVersionSpecifierSet(parsing: ">=1.0")
        #expect(any.highestSatisfying(candidates)?.description == "1.9")

        // …unless the constraint itself names one, which is the caller saying
        // they know what they are asking for.
        let explicit = try PythonVersionSpecifierSet(parsing: ">=2.0rc1")
        #expect(explicit.highestSatisfying(candidates)?.description == "2.0rc1")
    }
}

// MARK: - Requirements and markers

@Suite("PEP 508 requirements")
struct PythonRequirementTests {

    @Test("a requirement's four parts come apart")
    func parsesFully() throws {
        let requirement = try PythonRequirement(parsing: #"requests[socks,use_chardet]>=2.28,<3 ; python_version >= "3.8""#)
        #expect(requirement.name == "requests")
        #expect(requirement.canonicalName == "requests")
        #expect(requirement.extras == ["socks", "use-chardet"])  // PEP 685 canonicalisation
        #expect(requirement.specifier.clauses.count == 2)
        #expect(requirement.marker != nil)
    }

    @Test("a bare name is a requirement")
    func parsesBareName() throws {
        let requirement = try PythonRequirement(parsing: "certifi")
        #expect(requirement.canonicalName == "certifi")
        #expect(requirement.specifier.isEmpty)
        #expect(requirement.marker == nil)
        #expect(requirement.extras.isEmpty)
    }

    @Test("parenthesised specifiers, which real metadata does contain")
    func parsesParenthesised() throws {
        let requirement = try PythonRequirement(parsing: "urllib3 (>=1.21.1,<3)")
        #expect(requirement.canonicalName == "urllib3")
        #expect(requirement.specifier.clauses.count == 2)
    }

    @Test("a direct URL reference is refused with its reason")
    func refusesDirectReference() {
        let error = #expect(throws: PythonPackageError.self) {
            try PythonRequirement(parsing: "thing @ https://example.invalid/thing-1.0.whl")
        }
        guard case let .unsupportedRequirement(_, reason)? = error else {
            Issue.record("expected unsupportedRequirement, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("SHA-256"))
    }

    // MARK: Markers

    private var python313: PythonMarkerEnvironment {
        PythonMarkerEnvironment(
            pythonVersion: "3.13",
            pythonFullVersion: "3.13.15",
            sysPlatform: "ios",
            platformMachine: "arm64",
            platformSystem: "iOS")
    }

    private var python310: PythonMarkerEnvironment {
        PythonMarkerEnvironment(
            pythonVersion: "3.10",
            pythonFullVersion: "3.10.13",
            sysPlatform: "darwin",
            platformMachine: "arm64",
            platformSystem: "Darwin")
    }

    @Test("python_version compares as a version, not as a string")
    func versionMarkersUseVersionOrdering() throws {
        // The string comparison says "3.10" < "3.9" and installs the wrong
        // thing. This is the test that catches that.
        let marker = try PythonMarker.parse(#"python_version >= "3.9""#)
        #expect(marker.evaluate(in: python310))
        #expect(marker.evaluate(in: python313))

        let excluded = try PythonMarker.parse(#"python_version < "3.11""#)
        #expect(excluded.evaluate(in: python310))
        #expect(excluded.evaluate(in: python313) == false)
    }

    @Test("boolean structure, including parentheses and precedence")
    func evaluatesBooleans() throws {
        #expect(try PythonMarker.parse(#"sys_platform == "ios" and platform_machine == "arm64""#).evaluate(in: python313))
        #expect(try PythonMarker.parse(#"sys_platform == "win32" or platform_machine == "arm64""#).evaluate(in: python313))
        #expect(
            try PythonMarker.parse(#"(sys_platform == "win32" or sys_platform == "ios") and python_version > "3.9""#)
                .evaluate(in: python313))
        #expect(
            try PythonMarker.parse(#"sys_platform == "win32" and python_version > "3.9""#)
                .evaluate(in: python313) == false)
    }

    @Test("`in` and `not in`")
    func evaluatesMembership() throws {
        #expect(try PythonMarker.parse(#""arm" in platform_machine"#).evaluate(in: python313))
        #expect(try PythonMarker.parse(#""x86" not in platform_machine"#).evaluate(in: python313))
    }

    @Test("an extra marker is false when no extra was requested")
    func extraIsFalseByDefault() throws {
        let marker = try PythonMarker.parse(#"extra == "socks""#)
        #expect(marker.evaluate(in: python313) == false)
        #expect(marker.evaluate(in: python313.withExtras(["socks"])))
        #expect(marker.evaluate(in: python313.withExtras(["security"])) == false)
        #expect(marker.mentionsExtra)
    }

    @Test("an unreadable marker is an error, never an unconditional install")
    func refusesUnparseableMarker() {
        #expect(throws: PythonPackageError.self) { try PythonMarker.parse(#"python_version ??? "3.9""#) }
        #expect(throws: PythonPackageError.self) { try PythonMarker.parse(#"(python_version > "3.9""#) }
    }

    @Test("a marker about a variable this code does not know excludes rather than includes")
    func unknownVariableExcludes() throws {
        // The safe direction: a missing optional dependency raises a legible
        // ImportError, and a compiled wheel installed by mistake cannot even be
        // refused sensibly on a device.
        let marker = try PythonMarker.parse(#"some_future_variable == "yes""#)
        #expect(marker.evaluate(in: python313) == false)
    }
}

// MARK: - METADATA

@Suite("Wheel METADATA")
struct PythonPackageMetadataTests {

    @Test("the headers are read and the description is not")
    func parsesHeaders() throws {
        let metadata = try PythonPackageMetadata.parse(
            FixtureSource.metadataText(
                name: "Example-Pkg",
                version: "1.2.3",
                requires: ["requests>=2.0", #"tomli ; python_version < "3.11""#],
                extras: ["socks"],
                requiresPython: ">=3.8"))
        #expect(metadata.name == "Example-Pkg")
        #expect(metadata.canonicalName == "example-pkg")
        #expect(metadata.version == "1.2.3")
        #expect(metadata.requiresPython?.description == ">=3.8")
        #expect(metadata.providedExtras == ["socks"])
        // Two, not three: the `Requires-Dist:` line inside the long description
        // is prose and stops being metadata at the blank line.
        #expect(metadata.requirements.count == 2)
    }

    @Test("a folded continuation line belongs to the field above it")
    func handlesFoldedLines() throws {
        let metadata = try PythonPackageMetadata.parse(
            """
            Metadata-Version: 2.1
            Name: folded
            Version: 1.0
            Requires-Dist: requests>=2.0
                ; python_version >= "3.8"

            description
            """)
        #expect(metadata.requirements.count == 1)
        #expect(metadata.requirements[0].marker != nil)
    }

    @Test("an unparseable Requires-Dist stops the read rather than vanishing")
    func refusesBadRequirement() {
        let error = #expect(throws: PythonPackageError.self) {
            try PythonPackageMetadata.parse(
                """
                Metadata-Version: 2.1
                Name: broken
                Version: 1.0
                Requires-Dist: requests >>> 2.0
                """)
        }
        guard case let .metadataUnreadable(package, _)? = error else {
            Issue.record("expected metadataUnreadable, got \(String(describing: error))")
            return
        }
        #expect(package == "broken")
    }
}

// MARK: - Resolution

@Suite("Dependency resolution")
struct DependencyResolutionTests {

    private var environment: PythonMarkerEnvironment {
        PythonMarkerEnvironment(
            pythonVersion: "3.13",
            pythonFullVersion: "3.13.15",
            sysPlatform: "ios",
            platformMachine: "arm64",
            platformSystem: "iOS")
    }

    private func resolver(
        installed: [String: PythonDependencyResolver.InstalledState] = [:],
        environment: PythonMarkerEnvironment? = nil
    ) -> PythonDependencyResolver {
        PythonDependencyResolver(environment: environment ?? self.environment, installed: installed)
    }

    private func requirement(_ text: String) throws -> [PythonRequirement] {
        [try PythonRequirement(parsing: text)]
    }

    // MARK: A diamond

    /// `app` needs `left` and `right`; both need `shared`, at overlapping but
    /// different ranges. The only correct answer is one `shared`, at a version
    /// inside both ranges.
    private var diamond: FixtureSource {
        FixtureSource(catalogue: [
            "app": ["1.0": .init(metadata: FixtureSource.metadataText(
                name: "app", version: "1.0", requires: ["left", "right"]))],
            "left": ["1.0": .init(metadata: FixtureSource.metadataText(
                name: "left", version: "1.0", requires: ["shared>=1.2"]))],
            "right": ["1.0": .init(metadata: FixtureSource.metadataText(
                name: "right", version: "1.0", requires: ["shared<1.9"]))],
            "shared": [
                "1.0": .init(metadata: FixtureSource.metadataText(name: "shared", version: "1.0")),
                "1.5": .init(metadata: FixtureSource.metadataText(name: "shared", version: "1.5")),
                "2.0": .init(metadata: FixtureSource.metadataText(name: "shared", version: "2.0")),
            ],
        ])
    }

    @Test("a diamond resolves to one copy of the shared package, satisfying both sides")
    func resolvesDiamond() async throws {
        let source = diamond
        let plan = try await resolver().resolve(try requirement("app"), using: source)

        let names = plan.steps.map(\.release.canonicalName)
        #expect(names.sorted() == ["app", "left", "right", "shared"])
        #expect(names.filter { $0 == "shared" }.count == 1, "shared must appear once, not once per path to it")

        let shared = try #require(plan.steps.first { $0.release.canonicalName == "shared" })
        #expect(shared.release.version.description == "1.5", "1.5 is the only version inside both ranges")

        // Dependencies before the things that import them.
        #expect(names.firstIndex(of: "shared")! < names.firstIndex(of: "left")!)
        #expect(names.firstIndex(of: "left")! < names.firstIndex(of: "app")!)
        #expect(names.last == "app")
    }

    @Test("a diamond asks the index for the shared package once")
    func diamondDoesNotRefetch() async throws {
        let source = diamond
        _ = try await resolver().resolve(try requirement("app"), using: source)
        #expect(source.counter.releaseRequests["shared"] == 1)
    }

    // MARK: Extras

    /// The shape `requests` really has: four unconditional dependencies and two
    /// that belong to extras.
    private var withExtras: FixtureSource {
        FixtureSource(catalogue: [
            "requests": ["2.31.0": .init(metadata: FixtureSource.metadataText(
                name: "requests",
                version: "2.31.0",
                requires: [
                    "urllib3>=1.21.1,<3",
                    "certifi>=2017.4.17",
                    #"PySocks>=1.5.6,!=1.5.7 ; extra == "socks""#,
                    #"chardet>=3.0.2,<6 ; extra == "use_chardet_on_py3""#,
                ],
                extras: ["socks", "use_chardet_on_py3"]))],
            "urllib3": ["2.2.1": .init(metadata: FixtureSource.metadataText(name: "urllib3", version: "2.2.1"))],
            "certifi": ["2024.2.2": .init(metadata: FixtureSource.metadataText(name: "certifi", version: "2024.2.2"))],
            "PySocks": ["1.7.1": .init(metadata: FixtureSource.metadataText(name: "PySocks", version: "1.7.1"))],
            "chardet": ["5.2.0": .init(metadata: FixtureSource.metadataText(name: "chardet", version: "5.2.0"))],
        ])
    }

    @Test("an extra nobody asked for is not installed")
    func doesNotInstallUnrequestedExtras() async throws {
        let plan = try await resolver().resolve(try requirement("requests"), using: withExtras)

        #expect(plan.steps.map(\.release.canonicalName).sorted() == ["certifi", "requests", "urllib3"])
        #expect(!plan.steps.contains { $0.release.canonicalName == "pysocks" })
        #expect(!plan.steps.contains { $0.release.canonicalName == "chardet" })

        // …and it says so, rather than leaving the omission to be noticed.
        let excluded = plan.excluded.map(\.requirement)
        #expect(excluded.contains { $0.hasPrefix("PySocks") })
        #expect(plan.excluded.allSatisfy { $0.reason.contains("extra") })
    }

    @Test("an extra that was asked for is installed, and only that one")
    func installsRequestedExtra() async throws {
        let plan = try await resolver().resolve(try requirement("requests[socks]"), using: withExtras)
        let names = plan.steps.map(\.release.canonicalName).sorted()
        #expect(names == ["certifi", "pysocks", "requests", "urllib3"])
        #expect(!names.contains("chardet"), "the other extra must stay out")
    }

    @Test("the index is never even asked about a package only an unrequested extra needs")
    func doesNotResolveUnrequestedExtras() async throws {
        let source = withExtras
        _ = try await resolver().resolve(try requirement("requests"), using: source)
        #expect(source.counter.releaseRequests["pysocks"] == nil)
    }

    // MARK: Markers

    private var markerGated: FixtureSource {
        FixtureSource(catalogue: [
            "modern": ["1.0": .init(metadata: FixtureSource.metadataText(
                name: "modern",
                version: "1.0",
                requires: [
                    "always-needed",
                    #"tomli>=1.1.0 ; python_version < "3.11""#,
                    #"pywin32 ; sys_platform == "win32""#,
                ]))],
            "always-needed": ["1.0": .init(metadata: FixtureSource.metadataText(name: "always-needed", version: "1.0"))],
            "tomli": ["2.0.1": .init(metadata: FixtureSource.metadataText(name: "tomli", version: "2.0.1"))],
            "pywin32": ["306": .init(metadata: FixtureSource.metadataText(name: "pywin32", version: "306"))],
        ])
    }

    @Test("a dependency excluded by this interpreter's Python version stays out")
    func honoursPythonVersionMarker() async throws {
        let plan = try await resolver().resolve(try requirement("modern"), using: markerGated)
        #expect(plan.steps.map(\.release.canonicalName).sorted() == ["always-needed", "modern"])
        #expect(plan.excluded.contains { $0.requirement.hasPrefix("tomli") })
    }

    @Test("the same graph on an older interpreter does include it")
    func includesItOnAnOlderPython() async throws {
        let older = PythonMarkerEnvironment(
            pythonVersion: "3.10", pythonFullVersion: "3.10.13", sysPlatform: "darwin")
        let plan = try await resolver(environment: older).resolve(try requirement("modern"), using: markerGated)
        #expect(plan.steps.map(\.release.canonicalName).sorted() == ["always-needed", "modern", "tomli"])
        // The platform marker is still false, on either interpreter.
        #expect(!plan.steps.contains { $0.release.canonicalName == "pywin32" })
    }

    // MARK: Conflict

    @Test("an unsatisfiable constraint fails by name, and installs nothing")
    func failsLoudlyOnConflict() async throws {
        let source = FixtureSource(catalogue: [
            "app": ["1.0": .init(metadata: FixtureSource.metadataText(
                name: "app", version: "1.0", requires: ["left", "right"]))],
            "left": ["1.0": .init(metadata: FixtureSource.metadataText(
                name: "left", version: "1.0", requires: ["shared>=2.0"]))],
            "right": ["1.0": .init(metadata: FixtureSource.metadataText(
                name: "right", version: "1.0", requires: ["shared<2.0"]))],
            "shared": [
                "1.0": .init(metadata: FixtureSource.metadataText(name: "shared", version: "1.0")),
                "2.0": .init(metadata: FixtureSource.metadataText(name: "shared", version: "2.0")),
            ],
        ])

        let error = await #expect(throws: PythonPackageError.self) {
            try await resolver().resolve(try requirement("app"), using: source)
        }
        guard case let .noSatisfyingVersion(package, constraints, requiredBy, available)? = error else {
            Issue.record("expected noSatisfyingVersion, got \(String(describing: error))")
            return
        }
        #expect(package == "shared")
        #expect(constraints.contains(">=2.0") && constraints.contains("<2.0"))
        #expect(requiredBy.contains("app"))
        #expect(available.contains("2.0"))
        // The message a person reads has to name the package, not just fail.
        #expect(error?.localizedDescription.contains("shared") == true)
    }

    // MARK: A compiled dependency, three levels down

    @Test("a compiled dependency is named, along with the path that reached it")
    func namesTheCompiledDependency() async throws {
        let source = FixtureSource(catalogue: [
            "gallery-dl": ["1.26.0": .init(metadata: FixtureSource.metadataText(
                name: "gallery-dl", version: "1.26.0", requires: ["requests>=2.11.0"]))],
            "requests": ["2.31.0": .init(metadata: FixtureSource.metadataText(
                name: "requests", version: "2.31.0", requires: ["speedy-parser>=1.0"]))],
            "speedy-parser": ["1.0": .init(
                metadata: FixtureSource.metadataText(name: "speedy-parser", version: "1.0"),
                isPure: false,
                files: ["speedy_parser-1.0-cp313-cp313-macosx_11_0_arm64.whl", "speedy_parser-1.0.tar.gz"])],
        ])

        let error = await #expect(throws: PythonPackageError.self) {
            try await resolver().resolve(try requirement("gallery-dl"), using: source)
        }
        guard case let .dependencyNotPurePython(package, _, requiredBy, candidates)? = error else {
            Issue.record("expected dependencyNotPurePython, got \(String(describing: error))")
            return
        }

        // "a wheel was compiled" is not actionable. This is.
        #expect(package == "speedy-parser")
        #expect(requiredBy == ["gallery-dl", "requests"])
        #expect(candidates.contains { $0.contains("cp313") })

        let message = try #require(error?.localizedDescription)
        #expect(message.contains("speedy-parser"))
        #expect(message.contains("gallery-dl → requests"))
    }

    @Test("a package with an older pure release falls back to it rather than failing")
    func walksBackToAPureRelease() async throws {
        let source = FixtureSource(catalogue: [
            "app": ["1.0": .init(metadata: FixtureSource.metadataText(
                name: "app", version: "1.0", requires: ["mixed"]))],
            "mixed": [
                "1.0": .init(metadata: FixtureSource.metadataText(name: "mixed", version: "1.0")),
                "2.0": .init(metadata: FixtureSource.metadataText(name: "mixed", version: "2.0"), isPure: false),
            ],
        ])
        let plan = try await resolver().resolve(try requirement("app"), using: source)
        let mixed = try #require(plan.steps.first { $0.release.canonicalName == "mixed" })
        #expect(mixed.release.version.description == "1.0")
    }

    // MARK: Cycles

    @Test("a cycle in the metadata terminates, and installs each package once")
    func terminatesOnCycle() async throws {
        // Real metadata contains these, usually through an extra that depends
        // on the package declaring it.
        let source = FixtureSource(catalogue: [
            "ouroboros": ["1.0": .init(metadata: FixtureSource.metadataText(
                name: "ouroboros", version: "1.0", requires: ["tail>=1.0"]))],
            "tail": ["1.0": .init(metadata: FixtureSource.metadataText(
                name: "tail", version: "1.0", requires: ["ouroboros>=1.0"]))],
        ])

        let plan = try await resolver().resolve(try requirement("ouroboros"), using: source)
        #expect(plan.steps.map(\.release.canonicalName).sorted() == ["ouroboros", "tail"])
        #expect(plan.steps.count == 2)
    }

    @Test("a package that depends on itself terminates too")
    func terminatesOnSelfReference() async throws {
        let source = FixtureSource(catalogue: [
            "self-referential": ["1.0": .init(metadata: FixtureSource.metadataText(
                name: "self-referential", version: "1.0",
                requires: ["self-referential>=1.0", "leaf"]))],
            "leaf": ["1.0": .init(metadata: FixtureSource.metadataText(name: "leaf", version: "1.0"))],
        ])
        let plan = try await resolver().resolve(try requirement("self-referential"), using: source)
        #expect(plan.steps.map(\.release.canonicalName).sorted() == ["leaf", "self-referential"])
    }

    // MARK: What is already installed

    @Test("an installed package at a satisfying version is not downloaded again")
    func skipsSatisfiedPackages() async throws {
        let source = withExtras
        let installed: [String: PythonDependencyResolver.InstalledState] = [
            "urllib3": .init(
                version: try #require(PythonPackageVersion(parsing: "2.2.1")),
                metadata: try PythonPackageMetadata.parse(
                    FixtureSource.metadataText(name: "urllib3", version: "2.2.1")))
        ]

        let plan = try await resolver(installed: installed).resolve(try requirement("requests"), using: source)
        #expect(plan.steps.map(\.release.canonicalName).sorted() == ["certifi", "requests"])
        #expect(plan.alreadySatisfied.map(\.name) == ["urllib3"])
        #expect(source.counter.releaseRequests["urllib3"] == nil, "it should not even be resolved")
    }

    @Test("an installed package at a version that does not satisfy the graph is replaced")
    func upgradesUnsatisfyingInstall() async throws {
        let source = FixtureSource(catalogue: [
            "app": ["1.0": .init(metadata: FixtureSource.metadataText(
                name: "app", version: "1.0", requires: ["shared>=1.5"]))],
            "shared": [
                "1.0": .init(metadata: FixtureSource.metadataText(name: "shared", version: "1.0")),
                "1.5": .init(metadata: FixtureSource.metadataText(name: "shared", version: "1.5")),
            ],
        ])
        let installed: [String: PythonDependencyResolver.InstalledState] = [
            "shared": .init(version: try #require(PythonPackageVersion(parsing: "1.0")))
        ]
        let plan = try await resolver(installed: installed).resolve(try requirement("app"), using: source)
        let shared = try #require(plan.steps.first { $0.release.canonicalName == "shared" })
        #expect(shared.release.version.description == "1.5")
        #expect(plan.alreadySatisfied.isEmpty)
    }

    @Test("the dependencies of an already-installed package are still walked")
    func walksThroughSatisfiedPackages() async throws {
        // "urllib3 is already here" is only a safe answer if what urllib3 needs
        // is accounted for as well.
        let source = FixtureSource(catalogue: [
            "app": ["1.0": .init(metadata: FixtureSource.metadataText(
                name: "app", version: "1.0", requires: ["middle"]))],
            "middle": ["1.0": .init(metadata: FixtureSource.metadataText(
                name: "middle", version: "1.0", requires: ["deep"]))],
            "deep": ["1.0": .init(metadata: FixtureSource.metadataText(name: "deep", version: "1.0"))],
        ])
        let installed: [String: PythonDependencyResolver.InstalledState] = [
            "middle": .init(
                version: try #require(PythonPackageVersion(parsing: "1.0")),
                metadata: try PythonPackageMetadata.parse(
                    FixtureSource.metadataText(name: "middle", version: "1.0", requires: ["deep"])))
        ]
        let plan = try await resolver(installed: installed).resolve(try requirement("app"), using: source)
        #expect(plan.steps.map(\.release.canonicalName).sorted() == ["app", "deep"])
        #expect(plan.alreadySatisfied.map(\.name) == ["middle"])
    }

    // MARK: Requires-Python

    @Test("a release this interpreter is too new for is not a candidate")
    func honoursRequiresPython() async throws {
        let source = FixtureSource(catalogue: [
            "legacy": [
                "1.0": .init(metadata: FixtureSource.metadataText(name: "legacy", version: "1.0")),
                "2.0": .init(
                    metadata: FixtureSource.metadataText(name: "legacy", version: "2.0", requiresPython: "<3.11"),
                    requiresPython: "<3.11"),
            ]
        ])
        let plan = try await resolver().resolve(try requirement("legacy"), using: source)
        #expect(plan.steps.first?.release.version.description == "1.0")
    }

    // MARK: Names

    @Test("one package spelled four ways is one node in the graph")
    func canonicalisesNamesAcrossTheGraph() async throws {
        let source = FixtureSource(catalogue: [
            "app": ["1.0": .init(metadata: FixtureSource.metadataText(
                name: "app", version: "1.0", requires: ["Charset_Normalizer>=2", "charset-normalizer<4"]))],
            "charset-normalizer": [
                "3.3.2": .init(metadata: FixtureSource.metadataText(name: "charset-normalizer", version: "3.3.2"))
            ],
        ])
        let plan = try await resolver().resolve(try requirement("app"), using: source)
        #expect(plan.steps.filter { $0.release.canonicalName == "charset-normalizer" }.count == 1)
    }

    // MARK: The summary

    @Test("the plan explains itself in words")
    func summarises() async throws {
        let plan = try await resolver().resolve(try requirement("requests"), using: withExtras)
        let summary = plan.summary
        #expect(summary.contains("Install 3 packages"))
        #expect(summary.contains("requests"))
        #expect(summary.contains("(requested)"))
        #expect(summary.contains("via requests → urllib3"))
        #expect(summary.contains("PySocks"))
    }
}
