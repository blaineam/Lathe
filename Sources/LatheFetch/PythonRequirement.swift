import Foundation

// MARK: - The environment a marker is evaluated against

/// The eleven variables a PEP 508 environment marker can name, plus `extra`.
///
/// **Read from the live interpreter, never inferred.** `python_version` is
/// `sys.version_info`, `sys_platform` is `sys.platform`, `platform_machine` is
/// `os.uname().machine`. Guessing any of them from the host OS is how a
/// resolution performed on a Mac quietly installs the wrong set of packages for
/// the device it is going to run on — the same reason ``PythonPlatform`` reads
/// its fields out of the interpreter rather than from an `#available` check.
public struct PythonMarkerEnvironment: Sendable, Equatable {

    /// `"3.13"` — `sys.version_info[:2]`, which is what markers compare against.
    public var pythonVersion: String

    /// `"3.13.15"` — `platform.python_version()`.
    public var pythonFullVersion: String

    /// `"posix"`.
    public var osName: String

    /// `"darwin"` on macOS, `"ios"` on iOS.
    public var sysPlatform: String

    /// `"arm64"`.
    public var platformMachine: String

    /// `"Darwin"` on macOS, `"iOS"` on iOS.
    public var platformSystem: String

    /// The kernel release, `os.uname().release`.
    public var platformRelease: String

    /// The kernel version banner.
    public var platformVersion: String

    /// `"CPython"`.
    public var platformPythonImplementation: String

    /// `"cpython"`.
    public var implementationName: String

    /// `"3.13.15"`, derived from `sys.implementation.version`.
    public var implementationVersion: String

    /// The extras currently being expanded.
    ///
    /// A **set**, not a string, and that is the whole subtlety of `extra`
    /// markers. A dependency guarded by `; extra == "socks"` belongs to the
    /// graph only when the caller asked for `package[socks]`. When nothing was
    /// asked for, this is empty and every `extra == …` comparison is false —
    /// which is exactly the bug the task of "do not install an extra nobody
    /// requested" describes. `requests` pulls in `PySocks` and `chardet` this
    /// way, and neither belongs in a plain install.
    public var activeExtras: Set<String>

    public init(
        pythonVersion: String,
        pythonFullVersion: String,
        osName: String = "posix",
        sysPlatform: String,
        platformMachine: String = "",
        platformSystem: String = "",
        platformRelease: String = "",
        platformVersion: String = "",
        platformPythonImplementation: String = "CPython",
        implementationName: String = "cpython",
        implementationVersion: String = "",
        activeExtras: Set<String> = []
    ) {
        self.pythonVersion = pythonVersion
        self.pythonFullVersion = pythonFullVersion
        self.osName = osName
        self.sysPlatform = sysPlatform
        self.platformMachine = platformMachine
        self.platformSystem = platformSystem
        self.platformRelease = platformRelease
        self.platformVersion = platformVersion
        self.platformPythonImplementation = platformPythonImplementation
        self.implementationName = implementationName
        self.implementationVersion = implementationVersion
        self.activeExtras = activeExtras
    }

    /// The same environment with a different set of extras in play.
    public func withExtras(_ extras: Set<String>) -> Self {
        var copy = self
        copy.activeExtras = extras
        return copy
    }

    func value(for variable: String) -> String? {
        switch variable {
        case "python_version": pythonVersion
        case "python_full_version": pythonFullVersion
        case "os_name": osName
        case "sys_platform": sysPlatform
        case "platform_machine": platformMachine
        case "platform_system": platformSystem
        case "platform_release": platformRelease
        case "platform_version": platformVersion
        case "platform_python_implementation", "python_implementation": platformPythonImplementation
        case "implementation_name": implementationName
        case "implementation_version": implementationVersion
        default: nil
        }
    }

    /// The variables whose comparisons use version ordering rather than string
    /// ordering. `"3.10" < "3.9"` as text and `3.10 > 3.9` as a version, and
    /// the difference decides whether a dependency is installed.
    static let versionVariables: Set<String> = [
        "python_version", "python_full_version", "implementation_version",
    ]

    /// Reads the environment out of a running interpreter.
    ///
    /// - Throws: ``PythonError`` if the interpreter cannot answer, which would
    ///   mean something is wrong with the driver rather than with the caller.
    public static func read(from runtime: PythonRuntime) throws -> PythonMarkerEnvironment {
        struct Raw: Decodable {
            let python_version: String
            let python_full_version: String
            let os_name: String
            let sys_platform: String
            let platform_machine: String
            let platform_system: String
            let platform_release: String
            let platform_version: String
            let platform_python_implementation: String
            let implementation_name: String
            let implementation_version: String
        }

        let evaluation = try runtime.evaluate(
            """
            __import__('json').dumps({
                "python_version": "%d.%d" % __import__('sys').version_info[:2],
                "python_full_version": __import__('platform').python_version(),
                "os_name": __import__('os').name,
                "sys_platform": __import__('sys').platform,
                "platform_machine": __import__('platform').machine(),
                "platform_system": __import__('platform').system(),
                "platform_release": __import__('platform').release(),
                "platform_version": __import__('platform').version(),
                "platform_python_implementation": __import__('platform').python_implementation(),
                "implementation_name": __import__('sys').implementation.name,
                "implementation_version": ".".join(
                    str(part) for part in __import__('sys').implementation.version[:3]),
            })
            """)
        guard let text = evaluation.value.string, let data = text.data(using: .utf8),
            let raw = try? JSONDecoder().decode(Raw.self, from: data)
        else {
            throw PythonError.driverFailed(reason: "the interpreter's marker environment was not decodable")
        }
        return PythonMarkerEnvironment(
            pythonVersion: raw.python_version,
            pythonFullVersion: raw.python_full_version,
            osName: raw.os_name,
            sysPlatform: raw.sys_platform,
            platformMachine: raw.platform_machine,
            platformSystem: raw.platform_system,
            platformRelease: raw.platform_release,
            platformVersion: raw.platform_version,
            platformPythonImplementation: raw.platform_python_implementation,
            implementationName: raw.implementation_name,
            implementationVersion: raw.implementation_version
        )
    }
}

// MARK: - The marker itself

/// A PEP 508 environment marker — the part of a requirement after the `;`.
///
/// ```text
/// PySocks!=1.5.7,>=1.5.6 ; extra == "socks"
/// tomli>=1.1.0 ; python_version < "3.11"
/// colorama ; sys_platform == "win32" and platform_machine != "arm64"
/// ```
///
/// Markers are the difference between installing five packages and installing
/// fifteen. `requests` declares `charset_normalizer`, `idna`, `urllib3` and
/// `certifi` unconditionally and `PySocks` and `chardet` only under extras;
/// a resolver that ignores markers installs all six, and two of them are
/// compiled — so the install does not merely become wasteful, it becomes
/// impossible on a device.
public indirect enum PythonMarker: Sendable, Equatable {

    public enum Comparison: String, Sendable, Equatable {
        case equal = "=="
        case notEqual = "!="
        case lessThan = "<"
        case lessThanOrEqual = "<="
        case greaterThan = ">"
        case greaterThanOrEqual = ">="
        case compatible = "~="
        case arbitrary = "==="
        case contains = "in"
        case notContains = "not in"
    }

    public enum Term: Sendable, Equatable {
        case variable(String)
        case literal(String)
    }

    case comparison(left: Term, comparison: Comparison, right: Term)
    case and(PythonMarker, PythonMarker)
    case or(PythonMarker, PythonMarker)

    /// Evaluates the marker.
    ///
    /// An unknown variable evaluates the comparison to `false` rather than
    /// throwing. A marker naming a variable this code does not know is a marker
    /// about something this platform is not, and treating "I do not know" as
    /// "do not install" is the safe direction: the failure mode is a missing
    /// optional dependency with a clear `ImportError`, not a compiled wheel
    /// that cannot be installed at all.
    public func evaluate(in environment: PythonMarkerEnvironment) -> Bool {
        switch self {
        case let .and(left, right):
            return left.evaluate(in: environment) && right.evaluate(in: environment)
        case let .or(left, right):
            return left.evaluate(in: environment) || right.evaluate(in: environment)
        case let .comparison(left, comparison, right):
            return Self.evaluate(left, comparison, right, in: environment)
        }
    }

    /// `true` when the marker mentions `extra` anywhere — used to explain *why*
    /// a dependency was left out.
    public var mentionsExtra: Bool {
        switch self {
        case let .and(left, right), let .or(left, right):
            return left.mentionsExtra || right.mentionsExtra
        case let .comparison(left, _, right):
            return left == .variable("extra") || right == .variable("extra")
        }
    }

    private static func evaluate(
        _ left: Term, _ comparison: Comparison, _ right: Term, in environment: PythonMarkerEnvironment
    ) -> Bool {
        // `extra` is set-valued, so it is handled before the string machinery:
        // `extra == "socks"` asks whether socks is among the extras being
        // expanded, and `extra != "socks"` is its negation.
        if case let .variable(name) = left, name == "extra", case let .literal(wanted) = right {
            let present = environment.activeExtras.contains(PythonRequirement.canonicalExtra(wanted))
            switch comparison {
            case .equal: return present
            case .notEqual: return !present
            case .contains: return present
            case .notContains: return !present
            default: return false
            }
        }
        if case let .variable(name) = right, name == "extra", case let .literal(wanted) = left {
            let present = environment.activeExtras.contains(PythonRequirement.canonicalExtra(wanted))
            return comparison == .equal ? present : (comparison == .notEqual ? !present : false)
        }

        guard let leftValue = resolve(left, in: environment), let rightValue = resolve(right, in: environment) else {
            return false
        }

        switch comparison {
        case .contains: return rightValue.contains(leftValue)
        case .notContains: return !rightValue.contains(leftValue)
        case .arbitrary: return leftValue == rightValue
        default: break
        }

        // Version ordering when the comparison is *about* a version, string
        // ordering otherwise. `platform_release == "24.0"` is a string; it only
        // looks like a version.
        let isVersionComparison =
            isVersionTerm(left, in: environment) || isVersionTerm(right, in: environment)
        if isVersionComparison,
            let specifier = PythonVersionSpecifier(parsing: comparison.rawValue + rightValue),
            let candidate = PythonPackageVersion(parsing: leftValue)
        {
            return specifier.isSatisfied(by: candidate)
        }

        switch comparison {
        case .equal: return leftValue == rightValue
        case .notEqual: return leftValue != rightValue
        case .lessThan: return leftValue < rightValue
        case .lessThanOrEqual: return leftValue <= rightValue
        case .greaterThan: return leftValue > rightValue
        case .greaterThanOrEqual: return leftValue >= rightValue
        default: return false
        }
    }

    private static func isVersionTerm(_ term: Term, in environment: PythonMarkerEnvironment) -> Bool {
        if case let .variable(name) = term { return PythonMarkerEnvironment.versionVariables.contains(name) }
        return false
    }

    private static func resolve(_ term: Term, in environment: PythonMarkerEnvironment) -> String? {
        switch term {
        case let .literal(text): return text
        case let .variable(name): return name == "extra" ? environment.activeExtras.sorted().first ?? "" : environment.value(for: name)
        }
    }

    // MARK: Parsing

    /// - Throws: ``PythonPackageError/malformedRequirement(_:reason:)``.
    ///   A marker that cannot be parsed is **not** treated as absent: "install
    ///   it unconditionally" is the wrong guess for text whose entire purpose is
    ///   to say "only sometimes".
    public static func parse(_ text: String) throws -> PythonMarker {
        var tokens = try MarkerTokenizer.tokenize(text, in: text)
        let marker = try parseOr(&tokens, source: text)
        guard tokens.isEmpty else {
            throw PythonPackageError.malformedRequirement(text, reason: "trailing text in the marker")
        }
        return marker
    }

    private static func parseOr(_ tokens: inout [MarkerToken], source: String) throws -> PythonMarker {
        var left = try parseAnd(&tokens, source: source)
        while tokens.first == .or {
            tokens.removeFirst()
            left = .or(left, try parseAnd(&tokens, source: source))
        }
        return left
    }

    private static func parseAnd(_ tokens: inout [MarkerToken], source: String) throws -> PythonMarker {
        var left = try parseAtom(&tokens, source: source)
        while tokens.first == .and {
            tokens.removeFirst()
            left = .and(left, try parseAtom(&tokens, source: source))
        }
        return left
    }

    private static func parseAtom(_ tokens: inout [MarkerToken], source: String) throws -> PythonMarker {
        guard let first = tokens.first else {
            throw PythonPackageError.malformedRequirement(source, reason: "the marker ends early")
        }
        if first == .openParenthesis {
            tokens.removeFirst()
            let inner = try parseOr(&tokens, source: source)
            guard tokens.first == .closeParenthesis else {
                throw PythonPackageError.malformedRequirement(source, reason: "unbalanced parentheses in the marker")
            }
            tokens.removeFirst()
            return inner
        }

        let left = try parseTerm(&tokens, source: source)
        guard case let .comparison(text)? = tokens.first, let comparison = Comparison(rawValue: text) else {
            throw PythonPackageError.malformedRequirement(
                source, reason: "expected a comparison operator in the marker")
        }
        tokens.removeFirst()
        let right = try parseTerm(&tokens, source: source)
        return .comparison(left: left, comparison: comparison, right: right)
    }

    private static func parseTerm(_ tokens: inout [MarkerToken], source: String) throws -> Term {
        switch tokens.first {
        case let .identifier(name)?:
            tokens.removeFirst()
            return .variable(name)
        case let .string(value)?:
            tokens.removeFirst()
            return .literal(value)
        default:
            throw PythonPackageError.malformedRequirement(
                source, reason: "expected a marker variable or a quoted string")
        }
    }
}

// MARK: - Marker tokens

enum MarkerToken: Equatable {
    case identifier(String)
    case string(String)
    case comparison(String)
    case and
    case or
    case openParenthesis
    case closeParenthesis
}

enum MarkerTokenizer {

    private static let operators = ["===", "==", "!=", "<=", ">=", "~=", "<", ">"]

    static func tokenize(_ text: String, in source: String) throws -> [MarkerToken] {
        var tokens: [MarkerToken] = []
        let characters = Array(text)
        var index = 0

        /// Whether the text at `index` begins with `candidate`, without
        /// materialising the rest of the string to ask.
        func matches(_ candidate: String) -> Bool {
            let wanted = Array(candidate)
            guard index + wanted.count <= characters.count else { return false }
            return Array(characters[index..<(index + wanted.count)]) == wanted
        }

        while index < characters.count {
            let character = characters[index]

            if character.isWhitespace {
                index += 1
                continue
            }
            if character == "(" {
                tokens.append(.openParenthesis)
                index += 1
                continue
            }
            if character == ")" {
                tokens.append(.closeParenthesis)
                index += 1
                continue
            }
            if character == "'" || character == "\"" {
                let quote = character
                index += 1
                var value = ""
                while index < characters.count, characters[index] != quote {
                    value.append(characters[index])
                    index += 1
                }
                guard index < characters.count else {
                    throw PythonPackageError.malformedRequirement(source, reason: "an unterminated string in the marker")
                }
                index += 1
                tokens.append(.string(value))
                continue
            }
            if let matched = operators.first(where: matches) {
                tokens.append(.comparison(matched))
                index += matched.count
                continue
            }
            if character.isLetter || character == "_" {
                var word = ""
                while index < characters.count, characters[index].isLetter || characters[index].isNumber || characters[index] == "_" {
                    word.append(characters[index])
                    index += 1
                }
                switch word.lowercased() {
                case "and": tokens.append(.and)
                case "or": tokens.append(.or)
                case "in": tokens.append(.comparison("in"))
                case "not":
                    // `not in` is one operator with whitespace inside it.
                    while index < characters.count, characters[index].isWhitespace { index += 1 }
                    guard matches("in") else {
                        throw PythonPackageError.malformedRequirement(source, reason: "`not` must be followed by `in`")
                    }
                    index += 2
                    tokens.append(.comparison("not in"))
                default: tokens.append(.identifier(word))
                }
                continue
            }

            throw PythonPackageError.malformedRequirement(
                source, reason: "unexpected character \(String(character)) in the marker")
        }

        return tokens
    }
}

// MARK: - The requirement

/// One PEP 508 requirement: a name, optional extras, an optional constraint and
/// an optional marker.
///
/// ```text
/// requests[socks]>=2.28,<3 ; python_version >= "3.8"
/// ```
///
/// This is the unit a `Requires-Dist` line carries, the unit a caller types,
/// and the unit the resolver works in.
public struct PythonRequirement: Sendable, Equatable, CustomStringConvertible {

    /// The project name exactly as written.
    public let name: String

    /// The PEP 503 canonical name — this is what the resolver keys on, so
    /// `charset_normalizer` and `charset-normalizer` are one node in the graph
    /// rather than two.
    public let canonicalName: String

    /// `[socks]` → `["socks"]`, canonicalised.
    public let extras: Set<String>

    public let specifier: PythonVersionSpecifierSet

    public let marker: PythonMarker?

    public var description: String {
        var text = name
        if !extras.isEmpty { text += "[\(extras.sorted().joined(separator: ","))]" }
        if !specifier.isEmpty { text += specifier.description }
        return text
    }

    public init(
        name: String,
        extras: Set<String> = [],
        specifier: PythonVersionSpecifierSet = PythonVersionSpecifierSet(),
        marker: PythonMarker? = nil
    ) {
        self.name = name
        self.canonicalName = PythonPackageInstaller.canonicalName(name)
        self.extras = Set(extras.map(Self.canonicalExtra))
        self.specifier = specifier
        self.marker = marker
    }

    /// PEP 685: an extra name normalises the same way a project name does.
    static func canonicalExtra(_ name: String) -> String {
        PythonPackageInstaller.canonicalName(name)
    }

    /// - Throws: ``PythonPackageError/malformedRequirement(_:reason:)`` for
    ///   anything unreadable, and
    ///   ``PythonPackageError/unsupportedRequirement(_:reason:)`` for a PEP 508
    ///   direct reference (`name @ https://…`). The latter is refused rather
    ///   than fetched: this installer will not download a file that an index has
    ///   published no hash for, and a direct URL has none.
    public init(parsing text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw PythonPackageError.malformedRequirement(text, reason: "it is empty")
        }

        // Split the marker off first: everything before the first top-level `;`
        // is the requirement, everything after is the marker.
        var head = trimmed
        var markerText: String?
        if let semicolon = trimmed.firstIndex(of: ";") {
            head = String(trimmed[trimmed.startIndex..<semicolon]).trimmingCharacters(in: .whitespaces)
            markerText = String(trimmed[trimmed.index(after: semicolon)...]).trimmingCharacters(in: .whitespaces)
        }

        if let at = head.range(of: "@") {
            let reference = head[at.upperBound...].trimmingCharacters(in: .whitespaces)
            throw PythonPackageError.unsupportedRequirement(
                trimmed,
                reason: "it is a direct reference to \(reference). Only packages an index publishes with a "
                    + "SHA-256 can be installed, because an unverified download executed as code is the "
                    + "one risk this installer exists to bound."
            )
        }

        // The name runs until the first `[`, a comparison character, or a space.
        var nameEnd = head.startIndex
        while nameEnd < head.endIndex, head[nameEnd].isLetter || head[nameEnd].isNumber || "-_.".contains(head[nameEnd]) {
            nameEnd = head.index(after: nameEnd)
        }
        let parsedName = String(head[head.startIndex..<nameEnd])
        guard !parsedName.isEmpty else {
            throw PythonPackageError.malformedRequirement(trimmed, reason: "it does not start with a project name")
        }

        var rest = String(head[nameEnd...]).trimmingCharacters(in: .whitespaces)
        var parsedExtras: Set<String> = []
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else {
                throw PythonPackageError.malformedRequirement(trimmed, reason: "the extras list is not closed")
            }
            let inside = rest[rest.index(after: rest.startIndex)..<close]
            parsedExtras = Set(
                inside.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty })
            rest = String(rest[rest.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }

        // Parentheses around a specifier are legal PEP 508 and appear in real
        // metadata: `requests (>=2.0)`.
        if rest.hasPrefix("("), rest.hasSuffix(")") {
            rest = String(rest.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }

        self.init(
            name: parsedName,
            extras: parsedExtras,
            specifier: try PythonVersionSpecifierSet(parsing: rest),
            marker: try markerText.flatMap { $0.isEmpty ? nil : try PythonMarker.parse($0) }
        )
    }

    /// Whether this requirement applies in `environment`.
    ///
    /// No marker means it always applies — which is the common case and the one
    /// that must stay cheap.
    public func applies(in environment: PythonMarkerEnvironment) -> Bool {
        marker?.evaluate(in: environment) ?? true
    }
}
