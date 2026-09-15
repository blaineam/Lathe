import Foundation

/// The folder two applications agree to meet in.
///
/// A macOS arrangement in practice — it exists because one app is sandboxed
/// and the other is not, and on iOS there is no unsandboxed peer to meet. It
/// compiles everywhere regardless, because LatheCore is linked by iOS targets
/// that use entirely unrelated parts of it.
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

    public static let fileName = "shared-download-folder.json"

    /// This process's home directory.
    ///
    /// `NSHomeDirectory()` rather than `homeDirectoryForCurrentUser`, which
    /// **does not exist on iOS** — the package builds for every Apple platform,
    /// and an API that compiles only on the Mac breaks every iOS consumer of
    /// LatheCore, whatever it uses the module for.
    ///
    /// The two agree wherever this type is used: unsandboxed they are both the
    /// real home, and sandboxed they are both the container. That equivalence
    /// is what makes the substitution safe rather than merely convenient.
    public static func home() -> URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// Where a given application publishes its choice, **as seen from outside
    /// that application** — which is the only vantage point this can be
    /// computed from.
    ///
    /// Inside that application's own container, because a sandboxed app can
    /// write nowhere else without a grant — and its container is at a path
    /// anybody unsandboxed can compute and read.
    ///
    /// The publisher must not call this about itself. A sandboxed process's
    /// home directory *is* its container, so computing this from the inside
    /// produces a Containers path nested inside the container — a real file,
    /// in a place nobody looks. The publisher uses ``publish()``, which finds
    /// the same file from the inside.
    public static func publicationURL(forBundleIdentifier identifier: String) -> URL {
        home()
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(identifier, isDirectory: true)
            .appendingPathComponent("Data/Library/Application Support", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// Publishes this choice. Called by the application that owns the grant,
    /// about itself.
    ///
    /// Sandboxed, Application Support *is* the container's, so this lands
    /// exactly where a reader computing ``publicationURL(forBundleIdentifier:)``
    /// will look. Unsandboxed — under a test runner, or if the sandbox is ever
    /// turned off — Application Support is the user's own, which no reader
    /// consults, so the container path is written explicitly instead.
    public func publish() throws {
        try publish(to: Self.selfPublicationURL())
    }

    /// Publishes this choice on behalf of another application. For tests, and
    /// for an unsandboxed publisher naming itself.
    public func publish(forBundleIdentifier identifier: String) throws {
        try publish(to: Self.publicationURL(forBundleIdentifier: identifier))
    }

    /// Stops publishing this application's own choice.
    public static func withdraw() {
        guard let url = try? selfPublicationURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    public func publish(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// The file this process should write, found from the inside.
    ///
    /// Public because the publisher is the one side that cannot check its own
    /// work with ``published(byBundleIdentifier:)`` — that call is computed
    /// from a vantage point the publisher does not have.
    public static func selfPublicationURL(
        home: URL = SharedFolder.home(),
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) throws -> URL {
        let identifier = bundleIdentifier ?? ""

        // A sandboxed home directory ends in the container's Data directory.
        // When it does, Application Support beneath it is the file the reader
        // is looking for, and asking FileManager keeps us honest about a
        // container laid out differently than we assumed.
        if !identifier.isEmpty,
           home.path.hasSuffix("/Library/Containers/\(identifier)/Data")
        {
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
            return support.appendingPathComponent(fileName)
        }

        return publicationURL(forBundleIdentifier: identifier)
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

    /// Reads back what *this* application published, or nil.
    public static func publishedByThisApplication() -> SharedFolder? {
        guard let url = try? selfPublicationURL(),
              let data = try? Data(contentsOf: url)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SharedFolder.self, from: data)
    }

    /// Stops publishing on behalf of another application.
    public static func withdraw(forBundleIdentifier identifier: String) {
        try? FileManager.default.removeItem(at: publicationURL(forBundleIdentifier: identifier))
    }
}
