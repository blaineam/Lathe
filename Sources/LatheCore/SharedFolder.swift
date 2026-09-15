import Foundation

/// The folder two applications agree to meet in.
///
/// ## The problem this exists for
///
/// A sandboxed application cannot read a folder nobody granted it. Handing it
/// files one at a time works — opening a document grants access to exactly
/// those files — but it only works when there is something to open. It cannot
/// *watch* a folder, cannot pick up what arrived while it was closed, and
/// cannot be pointed at a destination by another application.
///
/// The grant that does all of that is a security-scoped bookmark, and a
/// bookmark can only be made from a folder the user themselves chose, inside
/// the application that will use it. So the sandboxed side owns the choice.
///
/// ## The shape of the agreement
///
/// 1. The user picks a folder **inside the sandboxed app**, which keeps a
///    security-scoped bookmark to it. That is the only step that can create
///    the grant, and it is a step the user has to take.
/// 2. That app publishes the folder's path in its own container, at a path
///    derived from its bundle identifier.
/// 3. The unsandboxed app reads it and writes there.
///
/// The publication is one-way and advisory. The reader treats a missing or
/// stale file as "no shared folder", never as an error — the other app may
/// not be installed, and that is an ordinary state rather than a fault.
///
/// ## Why the path and not the bookmark
///
/// A security-scoped bookmark is only meaningful to the process that made it;
/// it is not a transferable capability. Publishing one would be publishing
/// bytes the other side cannot use. What travels is the plain path, which the
/// *writing* side can use because it is not sandboxed, and which the reading
/// side already has a grant for.
public struct SharedFolder: Codable, Sendable, Equatable {

    /// Where files should be written.
    public var path: String

    /// Which application chose it, for the other side to name in its
    /// interface rather than presenting a bare path with no provenance.
    public var chosenBy: String

    public var updatedAt: Date

    public var url: URL { URL(fileURLWithPath: path, isDirectory: true) }

    public init(path: String, chosenBy: String, updatedAt: Date = Date()) {
        self.path = path
        self.chosenBy = chosenBy
        self.updatedAt = updatedAt
    }

    /// Where a given application publishes its choice.
    ///
    /// Inside that application's own container, because a sandboxed app can
    /// write nowhere else without a grant — and its container is at a path
    /// anybody unsandboxed can compute and read.
    public static func publicationURL(forBundleIdentifier identifier: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent("Data/Library/Application Support", isDirectory: true)
            .appendingPathComponent("shared-download-folder.json")
    }

    /// Publishes this choice. Called by the application that owns the grant.
    public func publish(forBundleIdentifier identifier: String) throws {
        let url = Self.publicationURL(forBundleIdentifier: identifier)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Reads what another application published, or nil.
    ///
    /// Nil covers every ordinary reason there is nothing: not installed, never
    /// configured, folder since deleted. None of those is a failure worth
    /// raising — the caller falls back to its own destination.
    public static func published(byBundleIdentifier identifier: String) -> SharedFolder? {
        let url = publicationURL(forBundleIdentifier: identifier)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let folder = try? decoder.decode(SharedFolder.self, from: data) else { return nil }

        // A path that no longer exists is not a destination. Checked on read
        // rather than trusted, because the folder can be moved or deleted long
        // after it was chosen and the publisher has no way to notice.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return folder
    }

    /// Stops publishing.
    public static func withdraw(forBundleIdentifier identifier: String) {
        try? FileManager.default.removeItem(at: publicationURL(forBundleIdentifier: identifier))
    }
}
