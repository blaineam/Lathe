import Foundation

// MARK: - The plan

/// What resolving a requirement decided: what to install, in what order, and
/// what it deliberately left out.
///
/// A plan is produced **before anything is downloaded or written**, which is the
/// property that makes the whole thing usable. Half an install is worse than no
/// install: a `site-packages` holding four of the six packages something needs
/// imports until it reaches the fifth, and then fails somewhere that has nothing
/// to do with the missing package.
public struct PythonDependencyPlan: Sendable, Equatable {

    /// One package to install.
    public struct Step: Sendable, Equatable {
        public let release: PythonRelease

        /// The extras that were in play when this package's own requirements
        /// were expanded.
        public let extras: Set<String>

        /// How the graph arrived here — `["gallery-dl", "requests"]` means
        /// gallery-dl needs requests needs this. Empty for something the caller
        /// asked for by name.
        public let requiredBy: [String]

        public var isRoot: Bool { requiredBy.isEmpty }

        /// `gallery-dl → requests → urllib3`, for a message a person reads.
        public var chainDescription: String {
            (requiredBy + [release.canonicalName]).joined(separator: " → ")
        }
    }

    /// A package the graph needs that is already installed at a satisfying
    /// version.
    public struct Satisfied: Sendable, Equatable {
        public let name: String
        public let version: PythonPackageVersion
        public let constraints: String
    }

    /// A requirement that exists in the metadata and is **not** in the plan.
    ///
    /// Kept rather than discarded because "why did it not install PySocks" is a
    /// real question with a real answer, and the answer is a marker. Without
    /// this the only way to find out is to read someone else's `METADATA` by
    /// hand.
    public struct Exclusion: Sendable, Equatable {
        public let requirement: String
        public let declaredBy: String
        public let reason: String
    }

    /// Dependencies first, then the things that need them. A caller that
    /// installs in this order never has a moment where an importable package is
    /// missing something it imports.
    public let steps: [Step]

    public let alreadySatisfied: [Satisfied]

    public let excluded: [Exclusion]

    /// A block for a log line or a confirmation sheet — what is about to be
    /// installed, and what was left out.
    public var summary: String {
        var lines: [String] = []
        if steps.isEmpty {
            lines.append("Nothing to install.")
        } else {
            lines.append("Install \(steps.count) package\(steps.count == 1 ? "" : "s"):")
            for step in steps {
                lines.append(
                    "  · \(step.release.canonicalName) \(step.release.version) "
                        + (step.isRoot ? "(requested)" : "(via \(step.chainDescription))"))
            }
        }
        for satisfied in alreadySatisfied {
            lines.append("  · \(satisfied.name) \(satisfied.version) is already installed and satisfies \(satisfied.constraints.isEmpty ? "the requirement" : satisfied.constraints)")
        }
        for exclusion in excluded {
            lines.append("  · not installing \(exclusion.requirement) (\(exclusion.declaredBy)): \(exclusion.reason)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - The resolver

/// Walks a dependency graph and decides what to install.
///
/// ## What this is, and what it is not
///
/// It is **not** a PEP 440 backtracking solver. It picks the highest version of
/// each package that satisfies every constraint collected for it, re-picking
/// when a later requirement narrows the range, and it **fails loudly and by
/// name** when no version satisfies the accumulated constraints. It does not
/// search for a globally consistent assignment by trying older versions of a
/// package to unblock a different one.
///
/// That is a deliberate stopping point rather than an unfinished one. Full
/// backtracking is worth its complexity when a resolver has to satisfy an
/// arbitrary lock file across a large ecosystem; here the graphs are a handful
/// of packages deep, the alternative to a clear failure is a silent wrong
/// install, and a conflict this cannot solve is one a person should see:
///
/// ```text
/// nothing satisfies urllib3>=2,<2.1 (via gallery-dl → requests → urllib3)
/// ```
///
/// is actionable. Quietly installing `urllib3 1.26` because it unblocked
/// something else is not.
///
/// ## Three rules that are easy to get wrong
///
/// * **Markers are honoured, including `extra`.** A dependency guarded by
///   `; extra == "socks"` is in the graph only when the caller asked for
///   `package[socks]`. Ignoring that is the common bug, and on a device it is
///   not merely wasteful — the extras of popular packages are full of compiled
///   wheels that cannot be installed at all.
/// * **Cycles terminate.** Real metadata contains them, usually through an
///   extra that depends on the package that declares it. Expansion is keyed on
///   package *and version and extras*, so arriving back at the same node is a
///   no-op rather than a loop.
/// * **What is installed is not re-downloaded.** An installed package at a
///   satisfying version is a node the walk passes *through* — its own
///   requirements are read from its `dist-info` on disk and still expanded —
///   rather than a subtree that is skipped.
public struct PythonDependencyResolver: Sendable {

    /// A package that is already installed, and what it declares.
    public struct InstalledState: Sendable, Equatable {
        public let version: PythonPackageVersion

        /// Read from the installed `dist-info/METADATA`. When it is `nil` the
        /// package is treated as a leaf — its own dependencies cannot be walked,
        /// which is worth knowing rather than pretending otherwise.
        public let metadata: PythonPackageMetadata?

        public init(version: PythonPackageVersion, metadata: PythonPackageMetadata? = nil) {
            self.version = version
            self.metadata = metadata
        }
    }

    /// The environment markers are evaluated against.
    public var environment: PythonMarkerEnvironment

    /// What is already installed, by canonical name.
    public var installed: [String: InstalledState]

    /// Whether a release with no pure-Python wheel disqualifies a candidate.
    ///
    /// `true` everywhere it matters. `false` exists for a host that has a way to
    /// install compiled code that this package does not — it does not make one
    /// appear.
    public var requiresPurePython: Bool

    /// How many satisfying versions of one package to examine before concluding
    /// that none publishes a pure wheel.
    ///
    /// Bounded because each examination is an index request. Twelve is deep
    /// enough to step over a project's recent compiled-only releases and
    /// shallow enough that a hopeless case fails in seconds.
    public var candidateDepth: Int

    /// A hard stop on graph walking, so a pathological metadata set fails
    /// rather than runs forever.
    public var stepLimit: Int

    public init(
        environment: PythonMarkerEnvironment,
        installed: [String: InstalledState] = [:],
        requiresPurePython: Bool = true,
        candidateDepth: Int = 12,
        stepLimit: Int = 2048
    ) {
        self.environment = environment
        self.installed = installed
        self.requiresPurePython = requiresPurePython
        self.candidateDepth = candidateDepth
        self.stepLimit = stepLimit
    }

    // MARK: Resolution

    private struct Work {
        let requirement: PythonRequirement
        let chain: [String]
    }

    /// Resolves `roots` and everything they need.
    ///
    /// - Throws: ``PythonPackageError/noSatisfyingVersion(package:constraints:requiredBy:available:)``
    ///   when constraints cannot be met;
    ///   ``PythonPackageError/dependencyNotPurePython(package:version:requiredBy:candidates:)``
    ///   when a package in the graph publishes only compiled wheels — naming
    ///   *that* package and the path to it, because "a wheel was compiled" is
    ///   not something anyone can act on;
    ///   ``PythonPackageError/resolutionDidNotConverge(package:)`` when the walk
    ///   hits its step limit.
    public func resolve(
        _ roots: [PythonRequirement],
        using source: any PythonPackageSource
    ) async throws -> PythonDependencyPlan {

        var constraints: [String: PythonVersionSpecifierSet] = [:]
        var extrasFor: [String: Set<String>] = [:]
        var chosen: [String: PythonRelease] = [:]
        var chainFor: [String: [String]] = [:]
        var expanded: Set<String> = []
        var edges: [String: [String]] = [:]
        var satisfied: [String: PythonDependencyPlan.Satisfied] = [:]
        var excluded: [PythonDependencyPlan.Exclusion] = []
        var releaseCache: [String: [PythonRelease]] = [:]

        var queue: [Work] = []
        var rootOrder: [String] = []

        // Root requirements carry no extras context of their own: a marker on
        // something the caller typed is evaluated with no extras active.
        let rootEnvironment = environment.withExtras([])
        for root in roots {
            guard root.applies(in: rootEnvironment) else {
                excluded.append(
                    .init(
                        requirement: root.description,
                        declaredBy: "(requested)",
                        reason: Self.exclusionReason(for: root, in: rootEnvironment)))
                continue
            }
            rootOrder.append(root.canonicalName)
            queue.append(Work(requirement: root, chain: []))
        }

        var steps = 0
        while !queue.isEmpty {
            steps += 1
            guard steps <= stepLimit else {
                throw PythonPackageError.resolutionDidNotConverge(package: queue[0].requirement.canonicalName)
            }

            let work = queue.removeFirst()
            let requirement = work.requirement
            let name = requirement.canonicalName

            if chainFor[name] == nil { chainFor[name] = work.chain }

            let merged = (constraints[name] ?? PythonVersionSpecifierSet()).merged(with: requirement.specifier)
            constraints[name] = merged
            let extras = (extrasFor[name] ?? []).union(requirement.extras)
            extrasFor[name] = extras

            // Already installed at a version that satisfies everything asked of
            // it so far. Not skipped — walked through, using the metadata the
            // unpack left on disk.
            if chosen[name] == nil, let state = installed[name], merged.isSatisfied(by: state.version) {
                satisfied[name] = .init(name: name, version: state.version, constraints: merged.description)
                if let metadata = state.metadata,
                    !expanded.contains(Self.expansionKey(name, state.version.normalized, extras))
                {
                    expand(
                        metadata: metadata,
                        of: name,
                        version: state.version.normalized,
                        extras: extras,
                        chain: work.chain,
                        into: &queue, &edges, &expanded, &excluded)
                }
                continue
            }

            // Already chosen, and the pick still satisfies the narrowed
            // constraint: nothing to redo unless a new extra appeared.
            if let current = chosen[name], merged.isSatisfied(by: current.version) {
                // Nothing new to learn unless a later requirement added an
                // extra; without this check a diamond costs one metadata
                // request per edge instead of one per node.
                guard !expanded.contains(Self.expansionKey(name, current.version.normalized, extras)) else { continue }
                let metadata = try await source.metadata(for: current)
                expand(
                    metadata: metadata,
                    of: name,
                    version: current.version.normalized,
                    extras: extras,
                    chain: chainFor[name] ?? work.chain,
                    into: &queue, &edges, &expanded, &excluded)
                continue
            }

            let available: [PythonRelease]
            if let cached = releaseCache[name] {
                available = cached
            } else {
                available = try await source.releases(of: requirement.name)
                releaseCache[name] = available
            }

            let release = try pick(
                from: available,
                satisfying: merged,
                package: requirement.name,
                requiredBy: work.chain)

            satisfied[name] = nil
            chosen[name] = release
            let metadata = try await source.metadata(for: release)
            expand(
                metadata: metadata,
                of: name,
                version: release.version.normalized,
                extras: extras,
                chain: work.chain,
                into: &queue, &edges, &expanded, &excluded)
        }

        // Dependencies before the things that need them.
        var ordered: [PythonDependencyPlan.Step] = []
        var emitted: Set<String> = []
        var visiting: Set<String> = []

        func emit(_ name: String) {
            guard !emitted.contains(name), !visiting.contains(name) else { return }
            visiting.insert(name)
            for dependency in edges[name] ?? [] { emit(dependency) }
            visiting.remove(name)
            guard let release = chosen[name] else { return }  // installed already, or not a node
            emitted.insert(name)
            ordered.append(
                .init(
                    release: release,
                    extras: extrasFor[name] ?? [],
                    requiredBy: chainFor[name] ?? []))
        }

        for root in rootOrder { emit(root) }
        // Anything reachable only through a package that was already installed.
        for name in chosen.keys.sorted() { emit(name) }

        return PythonDependencyPlan(
            steps: ordered,
            alreadySatisfied: satisfied.values.sorted { $0.name < $1.name },
            excluded: excluded
        )
    }

    // MARK: Picking a version

    private func pick(
        from available: [PythonRelease],
        satisfying constraints: PythonVersionSpecifierSet,
        package: String,
        requiredBy: [String]
    ) throws -> PythonRelease {

        let interpreter = PythonPackageVersion(parsing: environment.pythonFullVersion)

        // A release whose `Requires-Python` excludes this interpreter is not a
        // candidate, however new it is. Installing it produces a package that
        // imports and then fails on a syntax it was never meant to run on.
        let runnable = available.filter { release in
            guard let requires = release.requiresPython, let interpreter else { return true }
            return requires.isSatisfied(by: interpreter)
        }

        let matching = runnable.filter { constraints.isSatisfied(by: $0.version) }
        let allowPreReleases = constraints.mentionsPreRelease
        var candidates = matching.filter { allowPreReleases || !$0.version.isPreRelease }
        if candidates.isEmpty { candidates = matching }
        candidates.sort { $0.version > $1.version }

        guard !candidates.isEmpty else {
            throw PythonPackageError.noSatisfyingVersion(
                package: PythonPackageInstaller.canonicalName(package),
                constraints: constraints.isEmpty ? "(any version)" : constraints.description,
                requiredBy: requiredBy,
                available: available.map(\.version).sorted(by: >).prefix(10).map(\.description)
            )
        }

        guard requiresPurePython else { return candidates[0] }

        for candidate in candidates.prefix(candidateDepth) where candidate.wheel != nil {
            return candidate
        }

        // Every satisfying version publishes only compiled wheels or sdists.
        // The message names *this* package and the path to it, because the
        // caller asked for something three levels up and has no idea this is
        // even in the graph.
        throw PythonPackageError.dependencyNotPurePython(
            package: PythonPackageInstaller.canonicalName(package),
            version: candidates[0].version.description,
            requiredBy: requiredBy,
            candidates: candidates[0].publishedFiles
        )
    }

    // MARK: Expansion

    private func expand(
        metadata: PythonPackageMetadata,
        of name: String,
        version: String,
        extras: Set<String>,
        chain: [String],
        into queue: inout [Work],
        _ edges: inout [String: [String]],
        _ expanded: inout Set<String>,
        _ excluded: inout [PythonDependencyPlan.Exclusion]
    ) {
        // Keyed on version and extras as well as name, which is what makes a
        // cycle terminate and what makes a widened extras set re-expand.
        guard expanded.insert(Self.expansionKey(name, version, extras)).inserted else { return }

        let active = environment.withExtras(extras)
        for requirement in metadata.requirements {
            guard requirement.applies(in: active) else {
                excluded.append(
                    .init(
                        requirement: requirement.description,
                        declaredBy: name,
                        reason: Self.exclusionReason(for: requirement, in: active)))
                continue
            }
            edges[name, default: []].append(requirement.canonicalName)
            queue.append(Work(requirement: requirement, chain: chain + [name]))
        }
    }

    /// One node of the walk is a package *at a version with a set of extras* —
    /// not merely a package. Keying anything less is how a resolver either
    /// loops on a cycle or misses the dependencies an extra brings in.
    private static func expansionKey(_ name: String, _ version: String, _ extras: Set<String>) -> String {
        "\(name)|\(version)|\(extras.sorted().joined(separator: ","))"
    }

    /// Why a requirement was left out, in words rather than in a boolean.
    private static func exclusionReason(
        for requirement: PythonRequirement, in environment: PythonMarkerEnvironment
    ) -> String {
        guard let marker = requirement.marker else { return "its marker is false" }
        if marker.mentionsExtra {
            return environment.activeExtras.isEmpty
                ? "it belongs to an extra, and no extra was requested"
                : "it belongs to an extra other than \(environment.activeExtras.sorted().joined(separator: ", "))"
        }
        return "its environment marker is false for Python \(environment.pythonVersion) on \(environment.sysPlatform)"
    }
}
