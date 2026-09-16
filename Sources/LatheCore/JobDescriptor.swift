import CryptoKit
import Foundation

/// Lathe's engine version, as a cache key.
///
/// It is a **cache-invalidation input, not the package's release tag**: it
/// changes whenever output for the same input and settings could change —
/// codec settings, a vendored library, decision logic — so a cache keyed on it
/// drops stale results after an upgrade. The two numbers may diverge.
public enum LatheVersion {
    public static let engine = "1.0.0"
}

/// A content fingerprint used as a **cache key, not a security hash**.
///
/// Hashing all of a 4 GB video to ask "have I seen this?" is too slow, so the
/// recipe samples it:
/// `size ‖ mtime ‖ first 1 MiB ‖ 4 evenly spaced 256 KiB windows ‖ last 1 MiB`,
/// through SHA-256. A file of 2 MiB or less is hashed whole.
///
/// It is deliberately forgeable — a change that avoids every sampled window and
/// restores the modification date goes unnoticed — and that is fine for a
/// cache. It is said out loud here so nobody mistakes it for integrity.
public struct ContentFingerprint: Sendable, Hashable, CustomStringConvertible {
    /// Lowercase hex SHA-256, prefixed with the recipe version: `v1:…`.
    public let value: String
    public init(value: String) { self.value = value }
    public var description: String { value }

    static let edge = 1 << 20
    static let window = 256 << 10
    static let windowCount = 4

    /// Fingerprints the file at `url`.
    ///
    /// - Throws: ``LatheError/readFailed(path:reason:)`` when the file cannot be
    ///   opened or read.
    public static func compute(for url: URL) throws -> ContentFingerprint {
        let name = url.lastPathComponent
        let attributes: [FileAttributeKey: Any]
        let handle: FileHandle
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw LatheError.readFailed(path: name, reason: (error as NSError).localizedDescription)
        }
        defer { try? handle.close() }

        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0

        var hasher = SHA256()
        hasher.update(data: Data("size=\(size);mtime=\(Int64((modified * 1000).rounded()))".utf8))

        func read(at offset: UInt64, count: Int) throws {
            do {
                try handle.seek(toOffset: offset)
                if let chunk = try handle.read(upToCount: count) { hasher.update(data: chunk) }
            } catch {
                throw LatheError.readFailed(path: name, reason: (error as NSError).localizedDescription)
            }
        }

        if size <= UInt64(2 * edge) {
            try read(at: 0, count: Int(size))
        } else {
            try read(at: 0, count: edge)
            let middle = size - UInt64(2 * edge)
            for index in 1...windowCount {
                let centre = UInt64(edge) + middle * UInt64(index) / UInt64(windowCount + 1)
                try read(at: centre - min(centre, UInt64(window / 2)), count: window)
            }
            try read(at: size - UInt64(edge), count: edge)
        }

        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return ContentFingerprint(value: "v1:" + hex)
    }
}

/// Everything needed to identify one unit of work.
///
/// Job identity is derived from the **inputs to the decision**, never from the
/// path: `SHA256(contentFingerprint ‖ canonicalSettingsJSON ‖ engineVersion)`.
/// Moving or renaming a file keeps its job ID; changing a setting or upgrading
/// Lathe changes it.
public struct JobDescriptor: Sendable, Equatable {
    public var source: URL
    public var destination: URL
    /// The settings, as JSON in one canonical spelling: sorted keys, no
    /// whitespace, and **explicit defaults**. Never omit a field because it is
    /// at its default — a later change to that default would silently collide
    /// with cache entries written under the old one.
    ///
    /// ``canonicalJSON(_:)`` produces this from any `Encodable` settings value.
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

    /// Settings encoded in the one spelling a job ID may be computed from.
    ///
    /// The only place canonical JSON is produced: two independent spellings
    /// would diverge on key order or number formatting and quietly split one
    /// job into two.
    public static func canonicalJSON<Settings: Encodable>(_ settings: Settings) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        encoder.nonConformingFloatEncodingStrategy = .throw
        do {
            return String(decoding: try encoder.encode(settings), as: UTF8.self)
        } catch {
            throw LatheError.invalidConfiguration(
                reason: "the settings cannot be written as JSON: \(error.localizedDescription)")
        }
    }

    /// The deterministic job ID: 64 lowercase hex characters.
    ///
    /// - Throws: ``LatheError/readFailed(path:reason:)`` when the source cannot
    ///   be fingerprinted.
    public func jobID() throws -> String {
        let fingerprint = try ContentFingerprint.compute(for: source)
        var hasher = SHA256()
        for part in [fingerprint.value, canonicalSettingsJSON, engineVersion] {
            // Length-prefixed, so no two different triples can concatenate to
            // the same bytes.
            let bytes = Data(part.utf8)
            hasher.update(data: Data("\(bytes.count):".utf8))
            hasher.update(data: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
