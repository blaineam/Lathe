import Foundation
import Testing

@testable import LatheCore

/// The folder a sandboxed app chooses and an unsandboxed one writes into.
@Suite("Shared folder")
struct SharedFolderTests {

    /// A bundle identifier of its own per test, so the publication path is
    /// unique and the tests do not tread on each other or on a real app.
    private static func identifier() -> String {
        "com.example.sharedfolder.test.\(UUID().uuidString)"
    }

    private static func cleanUp(_ identifier: String) {
        SharedFolder.withdraw(forBundleIdentifier: identifier)
    }

    @Test("a published folder reads back")
    func roundTrip() throws {
        let id = Self.identifier()
        defer { Self.cleanUp(id) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try SharedFolder(path: directory.path, chosenBy: "Sami").publish(forBundleIdentifier: id)

        let read = try #require(SharedFolder.published(byBundleIdentifier: id))
        #expect(read.path == directory.path)
        #expect(read.chosenBy == "Sami")
        #expect(read.url.isFileURL)
    }

    /// Not installed, never configured — both are ordinary, and neither is an
    /// error the caller should have to catch.
    @Test("nothing published is nil, not a failure")
    func nothingPublished() {
        #expect(SharedFolder.published(byBundleIdentifier: Self.identifier()) == nil)
    }

    /// The folder can be moved or deleted long after it was chosen, and the
    /// publisher has no way to notice.
    @Test("a folder that has gone is not a destination")
    func staleFolderIsIgnored() throws {
        let id = Self.identifier()
        defer { Self.cleanUp(id) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try SharedFolder(path: directory.path, chosenBy: "Sami").publish(forBundleIdentifier: id)
        #expect(SharedFolder.published(byBundleIdentifier: id) != nil)

        try FileManager.default.removeItem(at: directory)
        #expect(SharedFolder.published(byBundleIdentifier: id) == nil)
    }

    /// A file rather than a directory is not a destination either.
    @Test("a file where a folder should be is refused")
    func fileIsNotAFolder() throws {
        let id = Self.identifier()
        defer { Self.cleanUp(id) }

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-folder-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        try SharedFolder(path: file.path, chosenBy: "Sami").publish(forBundleIdentifier: id)
        #expect(SharedFolder.published(byBundleIdentifier: id) == nil)
    }

    @Test("withdrawing removes it")
    func withdraw() throws {
        let id = Self.identifier()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try SharedFolder(path: directory.path, chosenBy: "Sami").publish(forBundleIdentifier: id)
        #expect(SharedFolder.published(byBundleIdentifier: id) != nil)

        SharedFolder.withdraw(forBundleIdentifier: id)
        #expect(SharedFolder.published(byBundleIdentifier: id) == nil)
    }

    /// The publication lives in the publishing app's own container, which is
    /// the only place a sandboxed app can write without a grant.
    @Test("it publishes inside the app's container")
    func publicationPath() {
        let path = SharedFolder.publicationURL(forBundleIdentifier: "com.example.app").path
        #expect(path.contains("Library/Containers/com.example.app/Data"))
        #expect(path.hasSuffix(".json"))
    }

    // MARK: - Finding the file from the inside

    /// The publisher and the reader have to land on the same file, and they
    /// compute it from opposite sides of the sandbox. This is the seam where
    /// they could silently disagree.
    @Test func sandboxedHomeResolvesToItsOwnApplicationSupport() throws {
        let identifier = "com.example.Sandboxed"
        let home = URL(fileURLWithPath: "/Users/someone/Library/Containers/\(identifier)/Data")

        let inside = try SharedFolder.selfPublicationURL(home: home, bundleIdentifier: identifier)

        // Under a sandbox the process's Application Support *is* the
        // container's, so the resolved file is the reader's file. The test
        // runner is not sandboxed, so all that can be asserted here is that
        // the container branch was taken — not the literal path, which would
        // have a Containers segment nested inside the container.
        #expect(inside.lastPathComponent == SharedFolder.fileName)
        #expect(!inside.path.contains("/Library/Containers/\(identifier)/Data/Library/Containers"))
    }

    @Test func unsandboxedHomeResolvesToTheContainerPathTheReaderUses() throws {
        let identifier = "com.example.Plain"
        let home = URL(fileURLWithPath: "/Users/someone")

        let inside = try SharedFolder.selfPublicationURL(home: home, bundleIdentifier: identifier)

        #expect(inside == SharedFolder.publicationURL(forBundleIdentifier: identifier))
    }

    @Test func aMissingBundleIdentifierDoesNotCrash() throws {
        let url = try SharedFolder.selfPublicationURL(
            home: URL(fileURLWithPath: "/Users/someone"), bundleIdentifier: nil)
        #expect(url.lastPathComponent == SharedFolder.fileName)
    }

    @Test func publishingToAnExplicitFileRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(SharedFolder.fileName)

        let folder = SharedFolder(path: "/Users/someone/Downloads", chosenBy: "Sami")
        try folder.publish(to: file)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let read = try decoder.decode(SharedFolder.self, from: Data(contentsOf: file))
        #expect(read.path == folder.path)
        #expect(read.chosenBy == "Sami")
    }


    // MARK: - App groups

    /// **On iOS a path is not enough.** Neither side is unsandboxed and no app
    /// can open another's container, so the folder itself has to live inside
    /// ground both are entitled to.
    ///
    /// None of these ask the system for a container. On macOS that call
    /// returns a URL for any identifier at all and **creates the directory**,
    /// so a test that used it to stand in for "not entitled" would be testing
    /// a behaviour that only exists on the other platform — and would litter
    /// the developer's Group Containers folder on the way past. Which is
    /// exactly what the first version of this suite did.
    @Test func theChoiceSitsAtTheContainerRoot() {
        let container = URL(fileURLWithPath: "/data/shared", isDirectory: true)
        let url = SharedFolder.publicationURL(inContainer: container)

        #expect(url.lastPathComponent == SharedFolder.fileName)
        #expect(SharedFolder.isWithin(url, container))
    }

    @Test func aFolderInsideTheContainerRoundTrips() throws {
        // A stand-in container, which is all the placement rules need.
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let target = container.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        let folder = SharedFolder(path: target.path, chosenBy: "Sami")
        try folder.publish(to: SharedFolder.publicationURL(inContainer: container))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: SharedFolder.publicationURL(inContainer: container))
        #expect(try decoder.decode(SharedFolder.self, from: data).path == target.path)
    }

    @Test func withdrawingFromAGroupThatIsNotThereIsQuiet() {
        // Withdrawing is cleanup, and cleanup that throws on "there was
        // nothing to clean" makes every caller write a guard. Safe to call
        // with a real identifier shape because removeItem on a missing file
        // is already a no-op here.
        SharedFolder.withdraw(fromAppGroup: "group.com.blainemiller.absent")
    }

    @Test func reachabilityComparesWholePathComponents() throws {
        // A prefix match on raw strings would call "/data/shared-evil"
        // reachable from "/data/shared". The boundary matters because the
        // answer gates a publish.
        let container = URL(fileURLWithPath: "/data/shared", isDirectory: true)
        let inside = URL(fileURLWithPath: "/data/shared/Downloads", isDirectory: true)
        let sibling = URL(fileURLWithPath: "/data/shared-evil", isDirectory: true)

        #expect(SharedFolder.isWithin(inside, container))
        #expect(SharedFolder.isWithin(container, container))
        #expect(!SharedFolder.isWithin(sibling, container))
    }

}
