import Foundation
import Testing

@testable import LatheCore

@Suite("Job identity")
struct JobDescriptorTests {

    private func withFile(_ bytes: Data, _ body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lathe-job-\(UUID().uuidString).bin")
        try bytes.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try body(url)
    }

    private func pattern(_ count: Int, seed: UInt8 = 7) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    @Test("the fingerprint is stable for the same file")
    func fingerprintIsStable() throws {
        try withFile(pattern(3 << 20)) { url in
            let first = try ContentFingerprint.compute(for: url)
            let second = try ContentFingerprint.compute(for: url)
            #expect(first == second)
            #expect(first.value.hasPrefix("v1:"))
            #expect(first.value.count == 3 + 64)
        }
    }

    @Test("the fingerprint changes when a sampled region changes", arguments: [
        0,               // the head
        (1 << 20) + (3 << 20) * 2 / 5,   // the centre of the second window
        (5 << 20) - 1,   // the tail
    ])
    func fingerprintSeesSampledChanges(offset: Int) throws {
        var bytes = pattern(5 << 20)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var before: ContentFingerprint?
        try withFile(bytes) { url in
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            before = try ContentFingerprint.compute(for: url)
        }
        bytes[offset] ^= 0xFF
        try withFile(bytes) { url in
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            #expect(try ContentFingerprint.compute(for: url) != before)
        }
    }

    @Test("a small file is hashed whole")
    func smallFilesAreHashedWhole() throws {
        var bytes = pattern(1 << 20)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var before: ContentFingerprint?
        try withFile(bytes) { url in
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            before = try ContentFingerprint.compute(for: url)
        }
        bytes[bytes.count / 3] ^= 0xFF
        try withFile(bytes) { url in
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            #expect(try ContentFingerprint.compute(for: url) != before)
        }
    }

    @Test("a missing file is a read failure")
    func missingFile() {
        let url = URL(fileURLWithPath: "/nonexistent/lathe-\(UUID().uuidString)")
        #expect(throws: LatheError.self) { try ContentFingerprint.compute(for: url) }
    }

    private struct Settings: Encodable {
        var quality: Double
        var codec: String
    }

    @Test("canonical JSON sorts keys and keeps no whitespace")
    func canonicalJSON() throws {
        let json = try JobDescriptor.canonicalJSON(Settings(quality: 0.5, codec: "hevc"))
        #expect(json == #"{"codec":"hevc","quality":0.5}"#)
    }

    @Test("the job ID follows the content and settings, not the path")
    func jobIdentity() throws {
        let bytes = pattern(64 << 10)
        let settings = try JobDescriptor.canonicalJSON(Settings(quality: 0.5, codec: "hevc"))
        let other = try JobDescriptor.canonicalJSON(Settings(quality: 0.6, codec: "hevc"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var ids: [String] = []
        for _ in 0..<2 {
            try withFile(bytes) { url in
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
                let out = URL(fileURLWithPath: "/tmp/out-\(UUID().uuidString).mov")
                ids.append(try JobDescriptor(source: url, destination: out, canonicalSettingsJSON: settings).jobID())
                ids.append(try JobDescriptor(source: url, destination: out, canonicalSettingsJSON: other).jobID())
                ids.append(try JobDescriptor(
                    source: url, destination: out, canonicalSettingsJSON: settings,
                    engineVersion: "0.0.0").jobID())
            }
        }
        // Two different paths, same content: same IDs.
        #expect(ids[0] == ids[3])
        #expect(ids[0].count == 64)
        // A different setting or engine version: a different job.
        #expect(ids[0] != ids[1])
        #expect(ids[0] != ids[2])
    }
}
