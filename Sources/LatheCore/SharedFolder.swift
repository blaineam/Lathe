import Foundation

/// The folder two applications agree to meet in.
///
/// There are two arrangements here, because the platforms differ in what is
/// possible at all.
///
/// **On macOS** one app is sandboxed and the other is not. The sandboxed side
/// owns the choice and publishes a plain path; the unsandboxed side reads it
/// and writes there. See the rest of this note.
///
/// **On iOS** neither side is unsandboxed and no app can read another's
/// container, so a path on its own is worth nothing — whatever it names, the
/// other app is not permitted to open it. The only ground two applications
/// share is an **App Group container**, and the shared folder has to live
/// inside it. See ``publicationURL(inAppGroup:)``.
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

    // MARK: - App groups

    /// The App Group container two applications share, or nil when this
    /// application cannot have one.
    ///
    /// **The two platforms answer differently, and the difference matters.**
    /// On iOS, nil means the entitlement is missing or misspelt — the usual
    /// mistake, and the only signal there is, since the system does not
    /// distinguish "not entitled" from "no such group". On macOS an
    /// unsandboxed process gets a URL for *any* identifier, and asking
    /// **creates the directory**: the call is not an entitlement check there,
    /// and cannot be used as one.
    ///
    /// So a non-nil answer is not proof of a working group. It is only proof
    /// that there is somewhere to write.
    public static func appGroupContainer(_ groupIdentifier: String) -> URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier)
    }

    /// Where the choice is published for an App Group.
    ///
    /// The only arrangement available on iOS, and usable on macOS too when
    /// both sides are sandboxed. Unlike the container path, this one is not
    /// computed from a bundle identifier — a group container's location is the
    /// system's business, and it is only reachable by an application actually
    /// entitled to the group.
    public static func publicationURL(inAppGroup groupIdentifier: String) -> URL? {
        appGroupContainer(groupIdentifier).map(publicationURL(inContainer:))
    }

    /// Where the choice sits inside a container this caller already has.
    ///
    /// Split out from the lookup so the placement can be checked without
    /// asking the system for a container — which, on macOS, would create one.
    public static func publicationURL(inContainer container: URL) -> URL {
        container.appendingPathComponent(fileName)
    }

    /// Publishes into an App Group.
    ///
    /// The folder named should itself be inside the group container. A path
    /// outside it is one the reading side is not permitted to open, and
    /// publishing it produces a destination that fails at the moment it is
    /// used rather than at the moment it is chosen — see ``isReachable(in:)``.
    public func publish(toAppGroup groupIdentifier: String) throws {
        guard let url = Self.publicationURL(inAppGroup: groupIdentifier) else {
            throw SharedFolderError.noAppGroup(groupIdentifier)
        }
        try publish(to: url)
    }

    /// Reads what was published into an App Group, or nil.
    public static func published(inAppGroup groupIdentifier: String) -> SharedFolder? {
        guard let url = publicationURL(inAppGroup: groupIdentifier) else { return nil }
        return decode(at: url)
    }

    /// Stops publishing into an App Group.
    public static func withdraw(fromAppGroup groupIdentifier: String) {
        guard let url = publicationURL(inAppGroup: groupIdentifier) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Whether this folder is somewhere the group's other members can actually
    /// open.
    ///
    /// Checked before publishing rather than discovered afterwards: a path
    /// outside the container is perfectly real to the app that chose it and
    /// completely unreadable to the one it was chosen for, which is a failure
    /// that shows up far from its cause.
    public func isReachable(in groupIdentifier: String) -> Bool {
        guard let container = Self.appGroupContainer(groupIdentifier) else { return false }
        return Self.isWithin(url, container)
    }

    /// Whether `candidate` is the container or sits inside it.
    ///
    /// Compared on whole path components: a raw prefix match would accept
    /// `/data/shared-evil` as being inside `/data/shared`, and this answer
    /// gates a publish.
    static func isWithin(_ candidate: URL, _ container: URL) -> Bool {
        let root = container.standardizedFileURL.pathComponents
        let mine = candidate.standardizedFileURL.pathComponents
        guard mine.count >= root.count else { return false }
        return Array(mine.prefix(root.count)) == root
    }

    /// Reads what another application published, or nil.
    ///
    /// Nil covers every ordinary reason there is nothing: not installed, never
    /// configured, folder since deleted. None of those is a failure worth
    /// raising — the caller falls back to its own destination.
    public static func published(byBundleIdentifier identifier: String) -> SharedFolder? {
        decode(at: publicationURL(forBundleIdentifier: identifier))
    }

    private static func decode(at url: URL) -> SharedFolder? {
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


public enum SharedFolderError: Error, CustomStringConvertible {
    /// This application is not a member of the group it tried to publish into.
    /// An entitlement problem, not a runtime one.
    case noAppGroup(String)

    public var description: String {
        switch self {
        case .noAppGroup(let identifier):
            return "this application is not entitled to the App Group \(identifier)"
        }
    }
}
