import Foundation

/// A distribution's `METADATA`, in the two fields resolution actually needs.
///
/// ## Where this text comes from
///
/// The same file, reached three ways, and the parser is shared so all three
/// agree:
///
/// 1. **From the index, before anything is downloaded.** PEP 658 has an index
///    serve `<wheel-url>.metadata` — the wheel's own `METADATA` member,
///    separately addressable. That is what makes walking a dependency graph
///    cheap: resolving `gallery-dl` reads a few kilobytes per package instead of
///    downloading every wheel to look inside it.
/// 2. **From what is already installed.** `<root>/<name>-<version>.dist-info/METADATA`
///    is written by the unpack, so an installed package's own requirements are
///    readable with no network at all — which is what lets an already-satisfied
///    subtree still be walked rather than merely skipped.
/// 3. **From a fixture.** The test suite's dependency graphs are this text and
///    nothing else, so the resolver tests are pure functions with no index, no
///    interpreter and no network in them.
///
/// ## What is read, and what is ignored
///
/// `Name`, `Version`, `Requires-Python`, `Requires-Dist` and `Provides-Extra`.
/// Everything else in a `METADATA` file — the description, the classifiers, the
/// author's email — is either irrelevant to resolution or is personal data that
/// has no reason to be held in memory, so none of it is retained.
public struct PythonPackageMetadata: Sendable, Equatable {

    /// The project name as the metadata spells it.
    public let name: String

    /// The PEP 503 canonical name.
    public let canonicalName: String

    public let version: String

    /// `Requires-Python: >=3.8`. `nil` when the distribution does not say.
    public let requiresPython: PythonVersionSpecifierSet?

    /// Every `Requires-Dist` line, parsed. Markers are **kept**, not evaluated:
    /// which of these apply depends on the environment and on which extras were
    /// asked for, and that is the resolver's decision rather than the parser's.
    public let requirements: [PythonRequirement]

    /// Every `Provides-Extra` line, canonicalised. Used to tell "you asked for
    /// an extra this package does not have" from "the extra exists and is
    /// empty" — a typo in an extra name is otherwise completely silent.
    public let providedExtras: Set<String>

    public init(
        name: String,
        version: String,
        requiresPython: PythonVersionSpecifierSet? = nil,
        requirements: [PythonRequirement] = [],
        providedExtras: Set<String> = []
    ) {
        self.name = name
        self.canonicalName = PythonPackageInstaller.canonicalName(name)
        self.version = version
        self.requiresPython = requiresPython
        self.requirements = requirements
        self.providedExtras = providedExtras
    }

    /// Parses `METADATA` text (RFC 822 headers, then a blank line, then the
    /// description).
    ///
    /// - Throws: ``PythonPackageError/metadataUnreadable(package:reason:)`` when
    ///   a `Requires-Dist` line cannot be parsed. A dropped requirement is an
    ///   install that is quietly missing a package, and the `ImportError` it
    ///   eventually produces points at the wrong place entirely — so an
    ///   unreadable line stops resolution rather than being skipped.
    public static func parse(_ text: String, describedAs describedName: String? = nil) throws -> PythonPackageMetadata {
        var name = ""
        var version = ""
        var requiresPython: PythonVersionSpecifierSet?
        var requirements: [PythonRequirement] = []
        var extras: Set<String> = []

        var pendingField: String?
        var pendingValue = ""

        func flush() throws {
            guard let field = pendingField else { return }
            let value = pendingValue.trimmingCharacters(in: .whitespacesAndNewlines)
            pendingField = nil
            pendingValue = ""
            guard !value.isEmpty else { return }

            switch field {
            case "name": name = value
            case "version": version = value
            case "requires-python":
                do {
                    requiresPython = try PythonVersionSpecifierSet(parsing: value)
                } catch {
                    throw PythonPackageError.metadataUnreadable(
                        package: describedName ?? name, reason: "Requires-Python: \(value) is not a specifier")
                }
            case "requires-dist":
                do {
                    requirements.append(try PythonRequirement(parsing: value))
                } catch let error as PythonPackageError {
                    throw PythonPackageError.metadataUnreadable(
                        package: describedName ?? name,
                        reason: "Requires-Dist: \(value) — \(error.localizedDescription)")
                }
            case "provides-extra":
                extras.insert(PythonRequirement.canonicalExtra(value))
            default:
                break
            }
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let raw = String(line).replacingOccurrences(of: "\r", with: "")
            if raw.trimmingCharacters(in: .whitespaces).isEmpty {
                // The blank line ends the headers; everything after it is the
                // long description, which can contain anything at all —
                // including lines that look like headers.
                break
            }
            if raw.first == " " || raw.first == "\t" {
                // A folded continuation line belongs to the field above it.
                pendingValue += " " + raw.trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let colon = raw.firstIndex(of: ":") else { continue }
            try flush()
            pendingField = raw[raw.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            pendingValue = String(raw[raw.index(after: colon)...])
        }
        try flush()

        guard !name.isEmpty else {
            throw PythonPackageError.metadataUnreadable(
                package: describedName ?? "(unnamed)", reason: "the metadata has no Name field")
        }

        return PythonPackageMetadata(
            name: name,
            version: version,
            requiresPython: requiresPython,
            requirements: requirements,
            providedExtras: extras
        )
    }

    /// The requirements that apply in `environment`, with the given extras in
    /// play.
    ///
    /// The one place the extras rule is implemented, so it cannot be
    /// implemented differently twice: a requirement guarded by
    /// `extra == "socks"` is in the result **only** when `socks` was asked for.
    /// Everything unguarded is always in it.
    public func requirements(
        in environment: PythonMarkerEnvironment,
        extras: Set<String>
    ) -> [PythonRequirement] {
        let resolved = environment.withExtras(Set(extras.map(PythonRequirement.canonicalExtra)))
        return requirements.filter { $0.applies(in: resolved) }
    }
}
