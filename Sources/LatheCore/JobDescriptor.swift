import Foundation

/// Lathe's engine version. Bump on any change to codec settings, library
/// version, or decision logic, so upgrades invalidate cached job results rather
/// than serving stale output.
public enum LatheVersion {
    public static let engine = "0.1.0-scaffold"
}

/// A content fingerprint used as a **cache key, not a security hash**.
///
/// Fully hashing a 4 GB video is unacceptable, so the recipe is
/// `size ‖ first 1 MiB ‖ last 1 MiB ‖ 4 evenly-spaced 256 KiB windows ‖ mtime`.
/// It is deliberately forgeable, and that is fine for its purpose — which is
/// said out loud here so nobody later mistakes it for integrity.
///
/// Not yet implemented.
public struct ContentFingerprint: Sendable, Hashable, CustomStringConvertible {
    public let value: String
    public init(value: String) { self.value = value }
    public var description: String { value }

    /// - Throws: ``LatheError/notImplemented(feature:)``.
    public static func compute(for url: URL) throws -> ContentFingerprint {
        throw LatheError.todo("ContentFingerprint.compute(for:)")
    }
}

/// Everything needed to identify one unit of work.
///
/// Job identity is derived from the **inputs to the decision**, never from the
/// path: `SHA256(contentFingerprint ‖ canonicalJSON(settings) ‖ engineVersion)`.
public struct JobDescriptor: Sendable, Equatable {
    public var source: URL
    public var destination: URL
    /// Canonical JSON of the settings: sorted keys, no whitespace, fixed number
    /// formatting, **explicit defaults**. Never omit a field because it is at
    /// its default — a later change to that default would silently collide with
    /// cache entries written under the old one.
    public var canonicalSettingsJSON: String
    public var engineVersion: String

    public init(
        source: URL,
        destination: URL,
        canonicalSettingsJSON: String,
        engineVersion: String = LatheVersion.engine
    ) {
        self.source = source
        self.destination = destination
        self.canonicalSettingsJSON = canonicalSettingsJSON
        self.engineVersion = engineVersion
    }

    /// The deterministic job ID.
    ///
    /// Not yet implemented. When it lands, the canonicalisation must live in
    /// exactly one place: two independent implementations of "canonical JSON"
    /// *will* diverge on float formatting and on key ordering under Unicode, and
    /// that divergence gets debugged at 2am.
    ///
    /// - Throws: ``LatheError/notImplemented(feature:)``.
    public func jobID() throws -> String {
        throw LatheError.todo("JobDescriptor.jobID()")
    }
}

/// Where a multi-unit job records what it has already finished, so termination
/// or a user cancel does not throw away completed units.
///
/// An append-only manifest of `(unitIndex, outputPath, bytes, hash)` beside the
/// partial output; on resume, read it and skip. Not yet implemented — the shape
/// is fixed now so callers can be written against it.
public struct ResumeManifestEntry: Sendable, Equatable, Codable {
    public var unitIndex: UInt64
    public var outputPath: String
    public var bytes: UInt64
    public var hash: String

    public init(unitIndex: UInt64, outputPath: String, bytes: UInt64, hash: String) {
        self.unitIndex = unitIndex
        self.outputPath = outputPath
        self.bytes = bytes
        self.hash = hash
    }
}
