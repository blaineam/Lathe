import CoreGraphics
import Foundation
import ImageIO
import LatheCore

/// What this system's ImageIO can **write**.
///
/// ## Never branch on OS version
///
/// Lathe asks the system what it can do and degrades per-format. That is a
/// runtime query, so it stays correct on every OS release, device class and
/// simulator this package was never tested against — including ones that do not
/// exist yet. There is **no `#available` check anywhere in this file, and there
/// must never be one.**
///
/// The rule is load-bearing rather than stylistic. AVIF, for one, has no
/// `UTTypeAVIF` / `kUTTypeAVIF` constant in any Apple SDK, so it can only be
/// named by its raw identifier `"public.avif"` — and when its encode support
/// actually began is not discoverable from headers at all. An `@available` gate
/// for it would be a guess wearing a compiler's clothes.
///
/// ## Why this asks by attempting, not by reading a list
///
/// The obvious implementation is `CGImageDestinationCopyTypeIdentifiers()`.
/// **That list over-reports.** Measured on current macOS and iOS, it names types
/// that then fail at destination creation — WebP, JPEG XL and `public.heif`
/// among them. A probe built on the list would report WebP as encodable, which
/// is exactly backwards and would send the still-image path down a road that
/// dead-ends at a nil destination.
///
/// So the probe **attempts the thing it is asking about**: it calls
/// `CGImageDestinationCreateWithData` against a scratch buffer for each
/// candidate type and treats a non-nil destination as support. That is the same
/// call the real encode path makes, which makes it the authoritative answer
/// rather than a proxy for one. The attempt happens once per process and the
/// result is cached; ``shared`` is the intended entry point.
///
/// ```swift
/// if EncodeSupport.shared.canEncode(.avif) { … } else { /* fall back to HEIC */ }
/// ```
public struct EncodeSupport: Sendable {

    /// The process-wide instance. Cheap to touch repeatedly.
    public static let shared = EncodeSupport()

    /// Every UTI `CGImageDestinationCopyTypeIdentifiers()` reported, verbatim and
    /// in the order given.
    ///
    /// Kept for diagnostics only — **this is not the capability answer**, see the
    /// type documentation. Compare against ``overReportedTypeIdentifiers`` to see
    /// the gap.
    public let reportedTypeIdentifiers: [String]

    /// Identifiers ImageIO advertised that could not actually produce a
    /// destination. Empty would be nice; in practice it is not.
    public let overReportedTypeIdentifiers: [String]

    private let supported: Set<ImageFormat>
    private let matchedIdentifiers: [ImageFormat: String]

    /// Runs (or reuses) the probe. Prefer ``shared``; this initialiser exists so
    /// tests can prove the cache and the query agree.
    public init() {
        let probe = Self.cachedProbe
        self.reportedTypeIdentifiers = probe.reported
        self.overReportedTypeIdentifiers = probe.overReported

        var supported: Set<ImageFormat> = []
        var matched: [ImageFormat: String] = [:]
        for format in ImageFormat.allCases {
            // Primary identifier first, aliases after, so the canonical spelling
            // wins when more than one works.
            for candidate in format.allTypeIdentifiers
            where probe.encodable.contains(candidate.lowercased()) {
                supported.insert(format)
                matched[format] = candidate
                break
            }
        }
        self.supported = supported
        self.matchedIdentifiers = matched
    }

    // MARK: - The probe

    private struct Probe: Sendable {
        var reported: [String]
        var overReported: [String]
        /// Lowercased identifiers that actually produced a destination.
        var encodable: Set<String>
    }

    /// Whether ImageIO will hand back a destination for this type.
    ///
    /// One scratch buffer, no image added, nothing finalised — this is only
    /// asking whether the encoder exists.
    static func canCreateDestination(for typeIdentifier: String) -> Bool {
        let scratch = NSMutableData()
        return CGImageDestinationCreateWithData(
            scratch as CFMutableData,
            typeIdentifier as CFString,
            1,
            nil
        ) != nil
    }

    /// Run once per process.
    private static let cachedProbe: Probe = {
        let reported = (CGImageDestinationCopyTypeIdentifiers() as NSArray)
            .compactMap { $0 as? String }

        // Probe everything ImageIO advertised *and* every identifier Lathe knows
        // about — an alias can work even when it was never advertised, and the
        // advertised ones need checking precisely because the list over-reports.
        var candidates = Set(reported)
        for format in ImageFormat.allCases {
            candidates.formUnion(format.allTypeIdentifiers)
        }

        var encodable: Set<String> = []
        for identifier in candidates where canCreateDestination(for: identifier) {
            encodable.insert(identifier.lowercased())
        }

        let overReported = reported.filter { !encodable.contains($0.lowercased()) }

        LatheLog.capability.info(
            """
            ImageIO encode probe: \(reported.count, privacy: .public) types advertised, \
            \(encodable.count, privacy: .public) of \(candidates.count, privacy: .public) candidates \
            actually encodable; advertised-but-unusable: \
            \(overReported.joined(separator: ", "), privacy: .public)
            """
        )

        return Probe(reported: reported, overReported: overReported, encodable: encodable)
    }()

    // MARK: - Queries

    /// Whether this system can encode `format`.
    public func canEncode(_ format: ImageFormat) -> Bool {
        supported.contains(format)
    }

    /// Every format this system can encode.
    public var supportedFormats: Set<ImageFormat> { supported }

    /// Every format Lathe knows about that this system cannot encode.
    public var unsupportedFormats: Set<ImageFormat> {
        Set(ImageFormat.allCases).subtracting(supported)
    }

    /// The UTI to hand to `CGImageDestinationCreateWithURL` / `…WithData` for
    /// `format` — one that has been *demonstrated* to work — or `nil` if the
    /// format cannot be encoded here.
    public func destinationTypeIdentifier(for format: ImageFormat) -> String? {
        matchedIdentifiers[format]
    }

    /// The first encodable format from a preference list. The degrade-per-format
    /// primitive: `firstSupported(of: [.avif, .heic, .jpeg])`.
    public func firstSupported(of preferences: [ImageFormat]) -> ImageFormat? {
        preferences.first(where: canEncode)
    }

    /// Throws rather than returning `nil`, for call sites inside a `throws`
    /// function.
    ///
    /// - Throws: ``LatheError/encodeUnavailable(format:)``.
    public func requireEncodable(_ format: ImageFormat) throws {
        guard canEncode(format) else {
            throw LatheError.encodeUnavailable(format: format.description)
        }
    }

    // MARK: - Diagnostics

    /// A human-readable capability table.
    ///
    /// Printed by the test suite on every run, so the CI log is itself a useful
    /// artifact: the table of what encodes where is generated per platform rather
    /// than maintained by hand.
    public var diagnosticReport: String {
        var lines: [String] = []
        lines.append("ImageIO encode capability — \(Self.platformDescription)")
        lines.append("")
        lines.append("  advertised by CGImageDestinationCopyTypeIdentifiers() (\(reportedTypeIdentifiers.count) entries):")
        for identifier in reportedTypeIdentifiers {
            let usable = Self.cachedProbe.encodable.contains(identifier.lowercased())
            lines.append("    \(usable ? "ok  " : "FAIL") \(identifier)")
        }
        lines.append("")
        if overReportedTypeIdentifiers.isEmpty {
            lines.append("  advertised but unusable: none")
        } else {
            lines.append("  advertised but unusable (\(overReportedTypeIdentifiers.count)): "
                         + overReportedTypeIdentifiers.joined(separator: ", "))
        }
        lines.append("")
        lines.append("  Lathe formats (verified by attempting to create a destination):")
        let width = ImageFormat.allCases.map(\.description.count).max() ?? 8
        for format in ImageFormat.allCases.sorted(by: { $0.description < $1.description }) {
            let name = format.description.padding(toLength: width, withPad: " ", startingAt: 0)
            let mark = canEncode(format) ? "encode YES" : "encode no "
            let uti = destinationTypeIdentifier(for: format) ?? format.typeIdentifier
            lines.append("    \(name)  \(mark)  (\(uti))")
        }
        return lines.joined(separator: "\n")
    }

    static var platformDescription: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if targetEnvironment(simulator)
        let environment = "simulator"
        #else
        let environment = "device"
        #endif
        #if os(macOS)
        let platform = "macOS"
        #elseif os(iOS)
        let platform = "iOS"
        #else
        let platform = "unknown platform"
        #endif
        return "\(platform) \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (\(environment))"
    }
}

/// What this system's ImageIO can **read**.
///
/// The counterpart to ``EncodeSupport``, and the thing that makes the WebP story
/// legible: WebP decodes and does not encode. That asymmetry is why writing WebP
/// needs a third-party encoder even though reading it does not.
///
/// Note the weaker guarantee. There is no cheap "try it" for decoding the way
/// there is for encoding — `CGImageSourceCreateWithData` will happily hand back a
/// source object and only fail later — so this reads
/// `CGImageSourceCopyTypeIdentifiers()` and inherits whatever that list gets
/// wrong. Treat it as advisory; treat ``EncodeSupport`` as authoritative.
public struct DecodeSupport: Sendable {

    public static let shared = DecodeSupport()

    public let sourceTypeIdentifiers: [String]
    private let supported: Set<ImageFormat>

    public init() {
        let identifiers = Self.cachedSourceTypeIdentifiers
        self.sourceTypeIdentifiers = identifiers
        let normalised = Set(identifiers.map { $0.lowercased() })
        self.supported = Set(
            ImageFormat.allCases.filter { format in
                format.allTypeIdentifiers.contains { normalised.contains($0.lowercased()) }
            }
        )
    }

    private static let cachedSourceTypeIdentifiers: [String] = {
        (CGImageSourceCopyTypeIdentifiers() as NSArray).compactMap { $0 as? String }
    }()

    public func canDecode(_ format: ImageFormat) -> Bool { supported.contains(format) }
    public var supportedFormats: Set<ImageFormat> { supported }
}
