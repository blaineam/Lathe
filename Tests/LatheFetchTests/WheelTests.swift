import CryptoKit
import Foundation
import Testing

@testable import LatheFetch

/// Wheel naming, wheel contents, and the two refusals that matter.
///
/// **Nothing here touches the network or the interpreter.** That is deliberate,
/// and it is the reason the installer's validation lives in `WheelInspection`
/// rather than inside the actor that unpacks: the decisions that can refuse an
/// install — a hash that does not match, a wheel full of compiled code, a member
/// that would escape the destination — are pure functions of bytes, and a suite
/// that can only exercise them by downloading twenty megabytes is a suite nobody
/// runs.
@Suite("Wheel naming and inspection")
struct WheelTests {

    // MARK: - Filenames

    @Test(
        "PEP 427 filenames parse",
        arguments: [
            ("gallery_dl-1.29.7-py3-none-any.whl", "gallery_dl", "1.29.7", ["py3"], ["none"], ["any"]),
            ("requests-2.32.3-py3-none-any.whl", "requests", "2.32.3", ["py3"], ["none"], ["any"]),
            ("six-1.17.0-py2.py3-none-any.whl", "six", "1.17.0", ["py2", "py3"], ["none"], ["any"]),
            (
                "lxml-5.3.0-cp313-cp313-macosx_10_9_universal2.whl", "lxml", "5.3.0",
                ["cp313"], ["cp313"], ["macosx_10_9_universal2"]
            ),
        ])
    func parses(
        filename: String, distribution: String, version: String,
        python: [String], abi: [String], platform: [String]
    ) throws {
        let name = try WheelName(parsing: filename)
        #expect(name.distribution == distribution)
        #expect(name.version == version)
        #expect(name.pythonTags == python)
        #expect(name.abiTags == abi)
        #expect(name.platformTags == platform)
    }

    @Test("the optional build tag is recognised, not mistaken for a version")
    func parsesBuildTag() throws {
        let name = try WheelName(parsing: "example-1.0-77-py3-none-any.whl")
        #expect(name.version == "1.0")
        #expect(name.buildTag == "77")
        #expect(name.platformTags == ["any"])
        #expect(name.claimsPurePython)
    }

    @Test(
        "malformed filenames are refused",
        arguments: [
            "gallery_dl-1.29.7.tar.gz",  // an sdist, not a wheel
            "not-a-wheel.whl",  // too few components
            "a-b-c-d-e-f-g-py3-none-any.whl",  // too many
            "-1.0-py3-none-any.whl",  // empty distribution
        ])
    func refusesMalformedNames(filename: String) {
        #expect(throws: PythonPackageError.self) { try WheelName(parsing: filename) }
    }

    @Test("pure-Python tags are py3-none-any, and nothing else is")
    func recognisesPureTags() throws {
        #expect(try WheelName(parsing: "a-1.0-py3-none-any.whl").claimsPurePython)
        #expect(try WheelName(parsing: "a-1.0-py2.py3-none-any.whl").claimsPurePython)
        #expect(try !WheelName(parsing: "a-1.0-cp313-cp313-macosx_11_0_arm64.whl").claimsPurePython)
        // abi3 is the stable ABI — still compiled, still impossible here.
        #expect(try !WheelName(parsing: "a-1.0-cp39-abi3-manylinux_2_17_x86_64.whl").claimsPurePython)
    }

    // MARK: - Contents

    @Test("a pure wheel inspects as pure")
    func inspectsPureWheel() throws {
        let (filename, data) = WheelFixtures.pureWheel(distribution: "example-pkg", version: "1.0.0")
        let inspection = try WheelInspection.inspect(data, filename: filename)

        #expect(inspection.isPurePython)
        #expect(inspection.compiledExtensions.isEmpty)
        #expect(inspection.unsafeMembers.isEmpty)
        #expect(inspection.members.contains("example_pkg/__init__.py"))
        #expect(inspection.members.contains("example_pkg-1.0.0.dist-info/METADATA"))
        #expect(throws: Never.self) { try inspection.validate() }
    }

    @Test(
        "a compiled member makes a wheel impure whatever the filename claims",
        arguments: [
            "speedups/_speedups.cpython-313-darwin.so",
            "speedups/_speedups.pyd",
            "speedups/libfoo.dylib",
            "speedups.libs/libcrypto-3.so",
        ])
    func detectsCompiledMembers(member: String) throws {
        // The filename says py3-none-any. The contents say otherwise, and the
        // contents win — a mis-tagged wheel that installs and then fails to
        // import is exactly the confusing failure this check replaces.
        let data = WheelFixtures.wheel(["speedups/__init__.py", member])
        let inspection = try WheelInspection.inspect(data, filename: "speedups-1.0-py3-none-any.whl")

        #expect(!inspection.isPurePython)
        #expect(inspection.compiledExtensions == [member])

        let error = #expect(throws: PythonPackageError.self) { try inspection.validate() }
        guard case let .notPurePython(_, _, members) = error else {
            Issue.record("expected notPurePython, got \(String(describing: error))")
            return
        }
        #expect(members == [member])
        // The message has to say *why* this is permanent, not just that it failed.
        #expect(error?.localizedDescription.contains("signed application") == true)
    }

    @Test("a correctly tagged compiled wheel is refused on its tags alone")
    func refusesCompiledTags() throws {
        let data = WheelFixtures.wheel(["lxml/__init__.py"])
        let inspection = try WheelInspection.inspect(
            data, filename: "lxml-5.3.0-cp313-cp313-macosx_10_9_universal2.whl")
        #expect(!inspection.isPurePython)
        #expect(inspection.compiledExtensions.isEmpty)
        #expect(throws: PythonPackageError.self) { try inspection.validate() }
    }

    @Test(
        "members that would escape the destination are refused",
        arguments: [
            "../outside.py",
            "pkg/../../outside.py",
            "/etc/passwd",
            "..\\windows.py",
        ])
    func refusesZipSlip(member: String) throws {
        let data = WheelFixtures.wheel(["pkg/__init__.py", member])
        let inspection = try WheelInspection.inspect(data, filename: "pkg-1.0-py3-none-any.whl")
        #expect(inspection.unsafeMembers == [member])
        #expect(throws: PythonPackageError.self) { try inspection.validate() }
    }

    @Test("a name that merely contains two dots is not an escape")
    func allowsInnocentDots() throws {
        let data = WheelFixtures.wheel(["pkg/data..txt", "pkg/a..b/c.py"])
        let inspection = try WheelInspection.inspect(data, filename: "pkg-1.0-py3-none-any.whl")
        #expect(inspection.unsafeMembers.isEmpty)
    }

    // MARK: - Hash verification

    @Test("the published hash is checked against the bytes")
    func verifiesDigest() throws {
        let (filename, data) = WheelFixtures.pureWheel(distribution: "example-pkg", version: "1.0.0")
        let inspection = try WheelInspection.inspect(data, filename: filename)

        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(inspection.sha256 == expected)
        #expect(throws: Never.self) { try inspection.verify(sha256: expected) }
        // Indexes are inconsistent about hex case; the check must not be.
        #expect(throws: Never.self) { try inspection.verify(sha256: expected.uppercased()) }
    }

    @Test("a hash that does not match refuses, and says both values")
    func refusesDigestMismatch() throws {
        let (filename, data) = WheelFixtures.pureWheel(distribution: "example-pkg", version: "1.0.0")
        let inspection = try WheelInspection.inspect(data, filename: filename)
        let wrong = String(repeating: "0", count: 64)

        let error = #expect(throws: PythonPackageError.self) { try inspection.verify(sha256: wrong) }
        guard case let .digestMismatch(expected, actual) = error else {
            Issue.record("expected digestMismatch, got \(String(describing: error))")
            return
        }
        #expect(expected == wrong)
        #expect(actual == inspection.sha256)
        // A one-byte change has to change the answer.
        var tampered = data
        tampered[tampered.count / 2] ^= 0x01
        #expect(try WheelInspection.inspect(tampered, filename: filename).sha256 != inspection.sha256)
    }

    // MARK: - Archive parsing

    @Test("an archive with a trailing comment still parses")
    func parsesWithComment() throws {
        // The end-of-central-directory record is found by scanning backwards.
        // An archive with a comment is the case that gets that wrong.
        var data = WheelFixtures.wheel(["pkg/__init__.py"])
        let commentLength = 300
        data[data.count - 2] = UInt8(commentLength & 0xFF)
        data[data.count - 1] = UInt8((commentLength >> 8) & 0xFF)
        data.append(Data(repeating: 0x2E, count: commentLength))

        let inspection = try WheelInspection.inspect(data, filename: "pkg-1.0-py3-none-any.whl")
        #expect(inspection.members == ["pkg/__init__.py"])
    }

    @Test("bytes that are not an archive are refused, not misread")
    func refusesGarbage() {
        #expect(throws: PythonPackageError.self) {
            try WheelInspection.inspect(Data(repeating: 0x41, count: 4096), filename: "pkg-1.0-py3-none-any.whl")
        }
        #expect(throws: PythonPackageError.self) {
            try WheelInspection.inspect(Data(), filename: "pkg-1.0-py3-none-any.whl")
        }
    }

    @Test("a truncated central directory is refused")
    func refusesTruncation() {
        var data = WheelFixtures.wheel(["pkg/__init__.py", "pkg/core.py"])
        // Claim four entries where there are two. A reader that trusts the count
        // without bounds-checking walks off the end.
        let eocd = data.count - 22
        data[eocd + 8] = 4
        data[eocd + 10] = 4
        #expect(throws: PythonPackageError.self) {
            try WheelInspection.inspect(data, filename: "pkg-1.0-py3-none-any.whl")
        }
    }

    @Test("ZIP64 is refused rather than half-read")
    func refusesZIP64() {
        var data = WheelFixtures.wheel(["pkg/__init__.py"])
        let eocd = data.count - 22
        // The ZIP64 sentinel in the entry count.
        data[eocd + 10] = 0xFF
        data[eocd + 11] = 0xFF
        let error = #expect(throws: PythonPackageError.self) {
            try WheelInspection.inspect(data, filename: "pkg-1.0-py3-none-any.whl")
        }
        #expect(error?.localizedDescription.contains("ZIP64") == true)
    }
}
