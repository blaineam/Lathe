import Foundation

// MARK: - A version

/// A version number, ordered the way Python packaging orders them.
///
/// ## Why not `String` comparison, and why not `OperatingSystemVersion`
///
/// `"1.10" < "1.9"` lexicographically, and `"2.0rc1"` is not a number at all.
/// Python packaging's ordering (PEP 440) is genuinely its own thing: it has an
/// epoch, an arbitrary-length release tuple, pre-releases that sort *before*
/// the release they lead to, post-releases that sort after, development
/// releases that sort before everything, and a local segment that participates
/// in ordering but not in equality with a bare version.
///
/// Getting that wrong does not produce a compile error or a crash. It produces
/// an install of the wrong version, which is the failure this whole type exists
/// to avoid.
///
/// ## What is implemented, and what is not
///
/// The full ordering, including every spelling PEP 440 normalises away
/// (`1.0-alpha-1`, `1.0.post1`, `1.0-1`, `1!2.0`, `1.0+local.7`). Versions that
/// do not parse are **not** silently coerced: ``init(parsing:)`` returns `nil`,
/// and the caller decides. An index that publishes a version this cannot read
/// is a fact worth surfacing rather than guessing at.
public struct PythonPackageVersion: Sendable, Hashable, Comparable, CustomStringConvertible {

    /// `a`, `b`, `rc` — the three pre-release kinds, in their sort order. Every
    /// other spelling (`alpha`, `beta`, `c`, `pre`, `preview`) normalises to one
    /// of these, which is why this is closed.
    public enum PreReleaseKind: Int, Sendable, Hashable, Comparable {
        case alpha = 0
        case beta = 1
        case releaseCandidate = 2

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        var spelling: String {
            switch self {
            case .alpha: "a"
            case .beta: "b"
            case .releaseCandidate: "rc"
            }
        }
    }

    public struct PreRelease: Sendable, Hashable, Comparable {
        public let kind: PreReleaseKind
        public let number: Int

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.kind == rhs.kind ? lhs.number < rhs.number : lhs.kind < rhs.kind
        }
    }

    /// `1!` in `1!2.0`. Almost always zero; exists because a project that has
    /// changed versioning schemes has no other way to say "this is newer".
    public let epoch: Int

    /// `[1, 2, 3]` for `1.2.3`. Compared with implicit trailing zeros, so
    /// `1.2 == 1.2.0`.
    public let release: [Int]

    public let preRelease: PreRelease?
    public let post: Int?
    public let dev: Int?

    /// `+cuda.1`, lowercased and normalised to `.` separators. Ignored by `==`
    /// against a bare version, per PEP 440, but it does participate in ordering.
    public let local: [String]

    /// The text this was parsed from, so a diagnostic can echo what the index
    /// actually published rather than a re-rendered normalisation of it.
    public let original: String

    /// `true` for `1.0a1`, `1.0rc2`, `1.0.dev3`.
    ///
    /// Load-bearing: pre-releases are excluded from resolution unless the
    /// caller's own constraint mentions one. Installing `2.0rc1` because it
    /// happened to be the highest number in the index is the classic packaging
    /// surprise.
    public var isPreRelease: Bool { preRelease != nil || dev != nil }

    public var description: String { original }

    /// The canonical spelling, which is what two versions are compared *as*.
    public var normalized: String {
        var text = epoch == 0 ? "" : "\(epoch)!"
        text += release.map(String.init).joined(separator: ".")
        if let preRelease { text += "\(preRelease.kind.spelling)\(preRelease.number)" }
        if let post { text += ".post\(post)" }
        if let dev { text += ".dev\(dev)" }
        if !local.isEmpty { text += "+" + local.joined(separator: ".") }
        return text
    }

    // MARK: Parsing

    /// The PEP 440 grammar, as the specification itself writes it.
    ///
    /// Transcribed rather than hand-rolled: the grammar's awkwardness is in the
    /// separators (`1.0-alpha-1`, `1.0_a_1` and `1.0a1` are the same version)
    /// and a hand-written scanner for that is a longer, less checkable way to
    /// say the same thing.
    private static let grammar: NSRegularExpression? = try? NSRegularExpression(
        pattern: """
            ^\\s*v?\
            (?:(?<epoch>[0-9]+)!)?\
            (?<release>[0-9]+(?:\\.[0-9]+)*)\
            (?:[-_\\.]?(?<preLabel>a|b|c|rc|alpha|beta|pre|preview)[-_\\.]?(?<preNumber>[0-9]+)?)?\
            (?:(?:-(?<postImplicit>[0-9]+))\
            |(?:[-_\\.]?(?<postLabel>post|rev|r)[-_\\.]?(?<postNumber>[0-9]+)?))?\
            (?:[-_\\.]?(?<devLabel>dev)[-_\\.]?(?<devNumber>[0-9]+)?)?\
            (?:\\+(?<local>[a-z0-9]+(?:[-_\\.][a-z0-9]+)*))?\
            \\s*$
            """,
        options: [.caseInsensitive])

    /// - Returns: `nil` when `text` is not a PEP 440 version. Deliberately not a
    ///   throwing initialiser: the common caller is filtering a list of a
    ///   hundred version strings from an index, where "skip this one" is the
    ///   right response and an error would have to be discarded anyway.
    public init?(parsing text: String) {
        guard let grammar = Self.grammar else { return nil }
        let subject = text as NSString
        let whole = NSRange(location: 0, length: subject.length)
        guard let match = grammar.firstMatch(in: text, options: [], range: whole) else { return nil }

        func group(_ name: String) -> String? {
            let range = match.range(withName: name)
            guard range.location != NSNotFound else { return nil }
            return subject.substring(with: range).lowercased()
        }

        epoch = group("epoch").flatMap(Int.init) ?? 0

        guard let releaseText = group("release") else { return nil }
        let segments = releaseText.split(separator: ".").compactMap { Int($0) }
        guard segments.count == releaseText.split(separator: ".").count, !segments.isEmpty else { return nil }
        release = segments

        if let label = group("preLabel") {
            let kind: PreReleaseKind
            switch label {
            case "a", "alpha": kind = .alpha
            case "b", "beta": kind = .beta
            default: kind = .releaseCandidate  // c, rc, pre, preview
            }
            preRelease = PreRelease(kind: kind, number: group("preNumber").flatMap(Int.init) ?? 0)
        } else {
            preRelease = nil
        }

        if let implicit = group("postImplicit").flatMap(Int.init) {
            post = implicit
        } else if group("postLabel") != nil {
            post = group("postNumber").flatMap(Int.init) ?? 0
        } else {
            post = nil
        }

        // A `dev` segment with no number is `dev0`, so the *label* decides
        // presence and the number merely defaults. Keying this off the number
        // would read `1.0.dev` as having no dev segment at all.
        dev = group("devLabel") == nil ? nil : (group("devNumber").flatMap(Int.init) ?? 0)

        local =
            group("local")?
            .split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "_" })
            .map(String.init) ?? []

        original = text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Ordering

    /// Release segments compared with implicit trailing zeros — `1.2` and
    /// `1.2.0` are the same version, and a three-segment version is not
    /// automatically greater than a two-segment one.
    private static func compareRelease(_ left: [Int], _ right: [Int]) -> Int {
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }

    /// The pre-release sort bucket. A version that is *only* a dev release
    /// sorts before every pre-release of the same number; a version with no
    /// pre-release at all sorts after all of them.
    private var preReleaseOrder: (Int, Int, Int) {
        if preRelease == nil && post == nil && dev != nil { return (0, 0, 0) }
        if let preRelease { return (1, preRelease.kind.rawValue, preRelease.number) }
        return (2, 0, 0)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { compare(lhs, rhs) < 0 }

    /// -1, 0 or 1. Shared by `<` and by the specifier operators, which need the
    /// three-way answer rather than two boolean ones.
    static func compare(_ lhs: Self, _ rhs: Self) -> Int {
        if lhs.epoch != rhs.epoch { return lhs.epoch < rhs.epoch ? -1 : 1 }

        let releases = compareRelease(lhs.release, rhs.release)
        if releases != 0 { return releases }

        let leftPre = lhs.preReleaseOrder
        let rightPre = rhs.preReleaseOrder
        if leftPre != rightPre { return leftPre < rightPre ? -1 : 1 }

        let leftPost = lhs.post ?? -1
        let rightPost = rhs.post ?? -1
        if leftPost != rightPost { return leftPost < rightPost ? -1 : 1 }

        // No dev segment sorts *after* any dev segment: `1.0.dev9 < 1.0`.
        let leftDev = lhs.dev ?? Int.max
        let rightDev = rhs.dev ?? Int.max
        if leftDev != rightDev { return leftDev < rightDev ? -1 : 1 }

        return compareLocal(lhs.local, rhs.local)
    }

    /// A local segment sorts after no local segment; numeric sub-segments sort
    /// above alphabetic ones and compare as numbers.
    private static func compareLocal(_ left: [String], _ right: [String]) -> Int {
        if left.isEmpty && right.isEmpty { return 0 }
        if left.isEmpty { return -1 }
        if right.isEmpty { return 1 }
        for index in 0..<max(left.count, right.count) {
            guard index < left.count else { return -1 }
            guard index < right.count else { return 1 }
            let l = left[index]
            let r = right[index]
            switch (Int(l), Int(r)) {
            case let (lNumber?, rNumber?):
                if lNumber != rNumber { return lNumber < rNumber ? -1 : 1 }
            case (_?, nil):
                return 1  // numeric outranks alphabetic
            case (nil, _?):
                return -1
            case (nil, nil):
                if l != r { return l < r ? -1 : 1 }
            }
        }
        return 0
    }

    /// Equality is on the *normalised* version, so `1.0` and `1.0.0` are equal
    /// and `1.0-alpha-1` equals `1.0a1`.
    public static func == (lhs: Self, rhs: Self) -> Bool { compare(lhs, rhs) == 0 }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(epoch)
        var trimmed = release
        while trimmed.count > 1, trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
        hasher.combine(preRelease)
        hasher.combine(post)
        hasher.combine(dev)
        hasher.combine(local)
    }
}

// MARK: - A constraint

/// One clause of a version constraint — `>=2.0`, `==1.4.*`, `~=1.4.2`.
public struct PythonVersionSpecifier: Sendable, Hashable, CustomStringConvertible {

    public enum Operator: String, Sendable, Hashable, CaseIterable {
        /// `~=` — "compatible release". `~=1.4.2` means `>=1.4.2, ==1.4.*`.
        case compatible = "~="
        case equal = "=="
        case notEqual = "!="
        case lessThanOrEqual = "<="
        case greaterThanOrEqual = ">="
        case lessThan = "<"
        case greaterThan = ">"
        /// `===` — arbitrary string equality, for versions that are not PEP 440
        /// at all. Rare, and honoured literally.
        case arbitrary = "==="

        /// Longest first, so `>=` is never mistaken for `>` and `===` never for
        /// `==`.
        static let byLengthDescending: [Operator] = [.arbitrary, .compatible, .equal, .notEqual, .lessThanOrEqual, .greaterThanOrEqual, .lessThan, .greaterThan]
    }

    public let `operator`: Operator

    /// The right-hand side exactly as written, `.*` included.
    public let version: String

    public var description: String { "\(`operator`.rawValue)\(version)" }

    public init(operator: Operator, version: String) {
        self.operator = `operator`
        self.version = version
    }

    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        for candidate in Operator.byLengthDescending where trimmed.hasPrefix(candidate.rawValue) {
            let value = String(trimmed.dropFirst(candidate.rawValue.count)).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { return nil }
            // The right-hand side has to be a version, or this is not a
            // specifier. Without this check `requests >>> 2.0` parses as
            // "greater than `>> 2.0`" and then silently matches nothing —
            // a constraint that is wrong rather than absent, which is worse.
            // `===` is exempt: its whole purpose is versions PEP 440 cannot
            // read.
            guard candidate == .arbitrary || Self.isVersionLike(value) else { return nil }
            self.init(operator: candidate, version: value)
            return
        }
        return nil
    }

    /// A version, or a `==1.4.*`-style prefix of one.
    private static func isVersionLike(_ text: String) -> Bool {
        let stem = text.hasSuffix(".*") ? String(text.dropLast(2)) : text
        return PythonPackageVersion(parsing: stem) != nil
    }

    /// `true` when the right-hand side is itself a pre-release, which is what
    /// licenses a pre-release candidate to be considered at all.
    public var mentionsPreRelease: Bool {
        PythonPackageVersion(parsing: version.replacingOccurrences(of: ".*", with: ""))?.isPreRelease ?? false
    }

    /// Whether `candidate` satisfies this clause.
    public func isSatisfied(by candidate: PythonPackageVersion) -> Bool {
        switch `operator` {
        case .arbitrary:
            return candidate.original == version

        case .equal, .notEqual:
            let matches: Bool
            if version.hasSuffix(".*") {
                matches = Self.matchesPrefix(candidate, prefix: String(version.dropLast(2)))
            } else if let wanted = PythonPackageVersion(parsing: version) {
                // A constraint with no local segment compares against the
                // candidate's public version only, per PEP 440: `==1.2` is
                // satisfied by `1.2+local`.
                matches =
                    wanted.local.isEmpty
                    ? PythonPackageVersion.compare(candidate.withoutLocal, wanted) == 0
                    : PythonPackageVersion.compare(candidate, wanted) == 0
            } else {
                matches = candidate.original == version
            }
            return `operator` == .equal ? matches : !matches

        case .compatible:
            // `~=X.Y.Z` is `>=X.Y.Z` and `==X.Y.*`: the last segment may move,
            // nothing above it may.
            guard let floor = PythonPackageVersion(parsing: version), floor.release.count >= 2 else { return false }
            let prefix = floor.release.dropLast().map(String.init).joined(separator: ".")
            return PythonPackageVersion.compare(candidate, floor) >= 0
                && Self.matchesPrefix(candidate, prefix: prefix)

        case .lessThan, .lessThanOrEqual, .greaterThan, .greaterThanOrEqual:
            guard let bound = PythonPackageVersion(parsing: version) else { return false }
            let ordering = PythonPackageVersion.compare(candidate, bound)
            switch `operator` {
            case .lessThan: return ordering < 0
            case .lessThanOrEqual: return ordering <= 0
            case .greaterThan: return ordering > 0
            default: return ordering >= 0
            }
        }
    }

    /// `==1.4.*` — the candidate's release segments must start with the
    /// prefix's.
    private static func matchesPrefix(_ candidate: PythonPackageVersion, prefix: String) -> Bool {
        guard let wanted = PythonPackageVersion(parsing: prefix) else { return false }
        guard candidate.epoch == wanted.epoch else { return false }
        // Zero-padded, so `1.4` satisfies `==1.4.*` as well as `1.4.2` does.
        return PythonPackageVersion.compareReleasePrefix(candidate.release, wanted.release)
    }
}

extension PythonPackageVersion {
    /// The same version with its local segment dropped.
    var withoutLocal: PythonPackageVersion {
        guard !local.isEmpty, let stripped = PythonPackageVersion(parsing: original.split(separator: "+").first.map(String.init) ?? original) else {
            return self
        }
        return stripped
    }

    static func compareReleasePrefix(_ candidate: [Int], _ wanted: [Int]) -> Bool {
        for index in 0..<wanted.count {
            let value = index < candidate.count ? candidate[index] : 0
            if value != wanted[index] { return false }
        }
        return true
    }
}

// MARK: - A set of constraints

/// Every clause a requirement carries — `>=2.0,<3,!=2.4.1`.
///
/// All clauses must hold. That is what a comma means in a requirement, and it
/// is why merging two requirements for the same package is concatenation rather
/// than anything cleverer.
public struct PythonVersionSpecifierSet: Sendable, Hashable, CustomStringConvertible, ExpressibleByArrayLiteral {

    public let clauses: [PythonVersionSpecifier]

    public var isEmpty: Bool { clauses.isEmpty }

    public var description: String { clauses.map(\.description).joined(separator: ",") }

    public init(_ clauses: [PythonVersionSpecifier] = []) {
        self.clauses = clauses
    }

    public init(arrayLiteral elements: PythonVersionSpecifier...) {
        self.init(elements)
    }

    /// - Throws: ``PythonPackageError/malformedRequirement(_:reason:)`` when a
    ///   clause is not a recognisable operator plus version. A specifier this
    ///   cannot read must not be silently dropped: dropping it installs
    ///   something the caller did not ask for.
    public init(parsing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            self.init([])
            return
        }
        var parsed: [PythonVersionSpecifier] = []
        for piece in trimmed.split(separator: ",") {
            guard let clause = PythonVersionSpecifier(parsing: String(piece)) else {
                throw PythonPackageError.malformedRequirement(
                    text, reason: "\(piece.trimmingCharacters(in: .whitespaces)) is not a version specifier")
            }
            parsed.append(clause)
        }
        self.init(parsed)
    }

    public func isSatisfied(by candidate: PythonPackageVersion) -> Bool {
        clauses.allSatisfy { $0.isSatisfied(by: candidate) }
    }

    /// `true` when some clause names a pre-release, which is the only thing
    /// that makes a pre-release candidate eligible.
    public var mentionsPreRelease: Bool { clauses.contains(where: \.mentionsPreRelease) }

    /// The union of two constraint sets: every clause of both.
    public func merged(with other: PythonVersionSpecifierSet) -> PythonVersionSpecifierSet {
        var combined = clauses
        for clause in other.clauses where !combined.contains(clause) {
            combined.append(clause)
        }
        return PythonVersionSpecifierSet(combined)
    }

    /// The best candidate, or `nil` when nothing satisfies the set.
    ///
    /// "Best" is the highest satisfying version, with pre-releases excluded
    /// unless a clause explicitly names one — the rule `pip` follows, and the
    /// reason `pip install requests` does not hand anyone a release candidate.
    public func highestSatisfying(_ candidates: [PythonPackageVersion]) -> PythonPackageVersion? {
        let allowPreReleases = mentionsPreRelease
        let eligible = candidates.filter { candidate in
            (allowPreReleases || !candidate.isPreRelease) && isSatisfied(by: candidate)
        }
        if let best = eligible.max() { return best }
        // Nothing final satisfies it. A pre-release is better than failing, and
        // is what pip falls back to for exactly this case.
        return candidates.filter { isSatisfied(by: $0) }.max()
    }
}
