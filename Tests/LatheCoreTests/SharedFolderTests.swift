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

}
