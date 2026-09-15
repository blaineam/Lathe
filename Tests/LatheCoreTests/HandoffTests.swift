import Foundation
import Testing

@testable import LatheCore

/// The document one application opens in another to ask for work.
@Suite("Handoff")
struct HandoffTests {

    private static func sample(files: [String] = ["/tmp/a.mp4", "/tmp/b.mov"]) -> Handoff {
        Handoff(
            files: files.map { URL(fileURLWithPath: $0) },
            intent: .compress,
            preset: "Small",
            destination: URL(fileURLWithPath: "/tmp/out", isDirectory: true))
    }

    @Test("a request survives the round trip")
    func roundTrip() throws {
        let original = Self.sample()
        let decoded = try Handoff.decode(try original.encoded())
        #expect(decoded.files == original.files)
        #expect(decoded.intent == .compress)
        #expect(decoded.preset == "Small")
        #expect(decoded.destination == original.destination)
        #expect(decoded.origin == "Lathe")
        // To the second: the dates go through ISO-8601, which does not carry
        // sub-second precision, and an equality test on the whole value would
        // fail for a reason that does not matter.
        #expect(abs(decoded.createdAt.timeIntervalSince(original.createdAt)) < 1)
    }

    @Test("anything that is not a handoff is refused")
    func refusesOtherDocuments() {
        // The shape a receiver has to defend against: valid JSON, wrong thing.
        let json = Data(#"{"title":"holiday","tracks":3}"#.utf8)
        #expect(throws: Handoff.Failure.notAHandoff) { try Handoff.decode(json) }
        #expect(throws: Handoff.Failure.notAHandoff) { try Handoff.decode(Data("not json".utf8)) }
    }

    /// A newer sender must not have its request half-understood by an older
    /// receiver — better to say so than to act on the fields that happened to
    /// decode.
    @Test("a newer format is refused by name")
    func refusesNewerVersions() throws {
        var future = Self.sample()
        future.version = Handoff.currentVersion + 1
        #expect(throws: Handoff.Failure.unsupportedVersion(Handoff.currentVersion + 1)) {
            try Handoff.decode(try future.encoded())
        }
    }

    @Test("a request with no files is not a request")
    func refusesEmpty() throws {
        let empty = Handoff(files: [])
        #expect(throws: Handoff.Failure.noFiles) { try Handoff.decode(try empty.encoded()) }
    }

    @Test("it writes a document that reads back")
    func writesAndReads() throws {
        let handoff = Self.sample()
        let url = try handoff.write()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        #expect(Handoff.isHandoff(url))
        #expect(url.pathExtension == Handoff.fileExtension)
        let decoded = try Handoff.decode(try Data(contentsOf: url))
        #expect(decoded.files == handoff.files)
    }

    /// Two handoffs in quick succession must not overwrite each other — each
    /// gets its own directory.
    @Test("two requests do not collide")
    func twoRequestsCoexist() throws {
        let first = try Self.sample(files: ["/tmp/one.mp4"]).write()
        let second = try Self.sample(files: ["/tmp/two.mp4"]).write()
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        #expect(first != second)
        #expect(try Handoff.decode(try Data(contentsOf: first)).files.first?.lastPathComponent
                == "one.mp4")
        #expect(try Handoff.decode(try Data(contentsOf: second)).files.first?.lastPathComponent
                == "two.mp4")
    }

    /// The request leads, so a receiver reading in order knows what is being
    /// asked before it sees what it is being asked about.
    @Test("the request is first in the open list")
    func requestLeadsTheOpenList() throws {
        let handoff = Self.sample()
        let document = URL(fileURLWithPath: "/tmp/req.lathehandoff")
        let list = handoff.openList(documentAt: document)
        #expect(list.first == document)
        #expect(list.count == handoff.files.count + 1)
        #expect(Array(list.dropFirst()) == handoff.files)
    }

    @Test("a handoff document is recognised by extension")
    func recognisesByExtension() {
        #expect(Handoff.isHandoff(URL(fileURLWithPath: "/tmp/x.lathehandoff")))
        #expect(Handoff.isHandoff(URL(fileURLWithPath: "/tmp/x.LATHEHANDOFF")))
        #expect(!Handoff.isHandoff(URL(fileURLWithPath: "/tmp/x.mp4")))
    }
}
