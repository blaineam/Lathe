import Foundation
import Testing

@testable import LatheFetch

/// Where the interpreter's standard library is, and how that is decided.
///
/// None of this needs an interpreter: it is all filesystem shape, and the whole
/// point of the type is to answer "would this abort?" *before* anything is
/// initialised. So it is tested against fabricated directories, which is also
/// the only way to test the failure cases — a machine with a broken Python
/// installation is not something a suite can require.
@Suite("Python layout discovery")
struct PythonLayoutTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lathe-layout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Fabricates `<root>/lib/python<version>/os.py`.
    private func fabricateStandardLibrary(_ version: String, under root: URL) throws {
        let stdlib = root.appendingPathComponent("lib/python\(version)", isDirectory: true)
        try FileManager.default.createDirectory(at: stdlib, withIntermediateDirectories: true)
        try Data("# not really os.py\n".utf8).write(to: stdlib.appendingPathComponent("os.py"))
    }

    @Test("a home with a standard library validates")
    func acceptsWellFormedLayout() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try fabricateStandardLibrary("3.13", under: root)

        let layout = PythonLayout(home: root, version: "3.13")
        #expect(throws: Never.self) { try layout.validate() }
        #expect(layout.standardLibrary.lastPathComponent == "python3.13")
        #expect(layout.dynamicLoadDirectory.lastPathComponent == "lib-dynload")
    }

    @Test("a home that is not a directory is refused")
    func refusesMissingHome() {
        let layout = PythonLayout(
            home: URL(fileURLWithPath: "/definitely/not/here", isDirectory: true), version: "3.13")
        #expect(throws: PythonError.self) { try layout.validate() }
    }

    @Test("an empty lib/pythonX.Y is refused, because CPython would abort on it")
    func refusesEmptyStandardLibrary() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // The directory exists and is empty — the case a `fileExists` check on
        // the directory alone would wave through, and the case where CPython's
        // response is Py_FatalError and abort() rather than an error.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("lib/python3.13"), withIntermediateDirectories: true)

        let error = #expect(throws: PythonError.self) {
            try PythonLayout(home: root, version: "3.13").validate()
        }
        #expect(error?.localizedDescription.contains("os.py") == true)
    }

    @Test("a library path that does not exist is refused")
    func refusesMissingLibrary() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try fabricateStandardLibrary("3.13", under: root)

        let layout = PythonLayout(home: root, version: "3.13", libraryPath: "/definitely/not/here/libpython.dylib")
        #expect(throws: PythonError.self) { try layout.validate() }
    }

    @Test("the version is probed from the layout, never assumed")
    func probesHighestVersion() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try fabricateStandardLibrary("3.9", under: root)
        try fabricateStandardLibrary("3.13", under: root)
        // 3.13 sorts *below* 3.9 as a string. Comparing the components is the
        // only thing that gets this right, and it is the case that catches a
        // lexicographic comparison.
        #expect(PythonLayout.highestStandardLibraryVersion(under: root) == "3.13")
    }

    @Test("a lib/pythonX.Y with no os.py is not a candidate version")
    func ignoresHollowVersionDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try fabricateStandardLibrary("3.11", under: root)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("lib/python3.14"), withIntermediateDirectories: true)
        #expect(PythonLayout.highestStandardLibraryVersion(under: root) == "3.11")
    }

    @Test("a directory with no lib at all yields no version")
    func yieldsNothingForEmptyRoot() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(PythonLayout.highestStandardLibraryVersion(under: root) == nil)
    }

    @Test("PYTHONPATH puts the caller's paths ahead of the standard library")
    func composesSearchPath() {
        let layout = PythonLayout(
            home: URL(fileURLWithPath: "/python", isDirectory: true),
            version: "3.13",
            extraSearchPaths: [URL(fileURLWithPath: "/packages", isDirectory: true)]
        )
        #expect(
            layout.searchPathValue
                == "/packages:/python/lib/python3.13:/python/lib/python3.13/lib-dynload")
    }

    @Test("a bundle with no Python in it is refused with a reason a build engineer can act on")
    func refusesBundleWithoutPython() {
        // `Bundle(for:)` of the test bundle: a real bundle that certainly has no
        // embedded interpreter, which is the state of every app before the
        // build phase that copies one has been added.
        let error = #expect(throws: PythonError.self) {
            try PythonLayout.inBundle(Bundle(for: BundleAnchor.self))
        }
        #expect(error?.localizedDescription.contains("lib/pythonX.Y") == true)
    }

    /// Reported, not asserted: which interpreters a machine has is exactly what
    /// discovery exists to find out.
    @Test("host framework candidates (report)")
    func candidateReport() {
        let candidates = PythonLayout.frameworkVersionDirectories()
        print("")
        print("  host Python framework candidates (\(candidates.count)):")
        for candidate in candidates {
            let version = PythonLayout.highestStandardLibraryVersion(under: candidate)
            let library = version.flatMap { PythonLayout.sharedLibrary(in: candidate, version: $0) }
            print("    · \(candidate.path)")
            print("        stdlib \(version ?? "—"), library \(library ?? "—")")
        }
        print("")
    }
}

/// Only here to give `Bundle(for:)` a class to look up.
private final class BundleAnchor {}
