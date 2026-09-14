import Foundation
import Testing

@testable import LatheFetch

/// The embedded interpreter, actually running.
///
/// The split mirrors the capability suite's: **invariants are asserted, and
/// what the machine happens to have is reported.** Which CPython this host
/// carries is exactly what the discovery code exists to find out, and freezing
/// today's answer into an assertion would reintroduce the version-gating the
/// package's rules forbid.
@Suite("Embedded CPython runtime")
struct PythonRuntimeTests {

    // MARK: - The report

    /// Always runs. Prints what was found, or records why nothing was.
    @Test("discovered interpreter (report)")
    func report() {
        print("")
        guard let runtime = SharedInterpreter.runtimeOrKnownIssue() else {
            print("  no CPython: \(SharedInterpreter.outcome.reason ?? "unknown")")
            print("  candidate framework version directories:")
            for candidate in PythonLayout.frameworkVersionDirectories() {
                print("    · \(candidate.path)")
            }
            print("")
            return
        }
        print(runtime.platform.diagnosticReport)
        print("")
        print("  PYTHONHOME:  \(runtime.layout.home.path)")
        print("  stdlib:      \(runtime.layout.standardLibrary.path)")
        print("  library:     \(runtime.layout.libraryPath ?? "(already in the process)")")
        print("")
    }

    // MARK: - Evaluating

    @Test("an expression evaluates and its value comes back", .enabled(if: SharedInterpreter.isAvailable))
    func evaluatesExpression() throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)

        let integer = try runtime.evaluate("2 ** 16 + 1")
        #expect(integer.value.int == 65537)
        #expect(integer.value.typeName == "int")
        #expect(integer.value.repr == "65537")

        #expect(try runtime.evaluate("'lathe'.upper()").value.string == "LATHE")
        #expect(try runtime.evaluate("[c for c in 'abc']").value.stringArray == ["a", "b", "c"])
        #expect(try runtime.evaluate("1 == 1").value.bool == true)
        #expect(try runtime.evaluate("3 / 4").value.double == 0.75)
    }

    @Test("a structured value decodes", .enabled(if: SharedInterpreter.isAvailable))
    func decodesStructuredValue() throws {
        struct Release: Decodable, Equatable {
            let name: String
            let parts: [Int]
        }
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let evaluation = try runtime.evaluate("{'name': 'cpython', 'parts': [3, 13]}")
        #expect(try evaluation.value.decode(Release.self) == Release(name: "cpython", parts: [3, 13]))
    }

    @Test("a value with no JSON form still has a repr", .enabled(if: SharedInterpreter.isAvailable))
    func reprWithoutJSON() throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let evaluation = try runtime.evaluate("object()")
        #expect(evaluation.value.jsonEncoded == nil)
        #expect(evaluation.value.repr.contains("object"))
        #expect(throws: PythonError.self) { try evaluation.value.decode([String].self) }
    }

    @Test("a statement handed to evaluate is named as such", .enabled(if: SharedInterpreter.isAvailable))
    func rejectsStatement() throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let error = #expect(throws: PythonError.self) { try runtime.evaluate("x = 1") }
        guard case .notAnExpression = error else {
            Issue.record("expected notAnExpression, got \(String(describing: error))")
            return
        }
    }

    // MARK: - Capturing output

    @Test("printed output is captured, not lost to file descriptor 1", .enabled(if: SharedInterpreter.isAvailable))
    func capturesOutput() throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let output = try runtime.execute(
            """
            import sys
            print("first line")
            print("second line")
            sys.stderr.write("a warning\\n")
            """)
        #expect(output.standardOutput == "first line\nsecond line\n")
        #expect(output.standardError == "a warning\n")
    }

    @Test("output written to the binary buffer is captured too", .enabled(if: SharedInterpreter.isAvailable))
    func capturesBinaryOutput() throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let output = try runtime.execute("import sys; sys.stdout.buffer.write(b'bytes\\n')")
        #expect(output.standardOutput == "bytes\n")
    }

    @Test("a call captures only its own output", .enabled(if: SharedInterpreter.isAvailable))
    func outputDoesNotLeakBetweenCalls() throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        _ = try runtime.execute("print('one')")
        let second = try runtime.execute("print('two')")
        #expect(second.standardOutput == "two\n")
    }

    @Test("an expression's output arrives with its value", .enabled(if: SharedInterpreter.isAvailable))
    func capturesOutputFromExpression() throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let evaluation = try runtime.evaluate("[print('side effect'), 42][1]")
        #expect(evaluation.value.int == 42)
        #expect(evaluation.output.standardOutput == "side effect\n")
    }

    // MARK: - Errors

    @Test("a Python exception arrives as a Swift error with its traceback", .enabled(if: SharedInterpreter.isAvailable))
    func surfacesTraceback() throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let error = #expect(throws: PythonError.self) {
            try runtime.execute(
                """
                def inner():
                    return 1 / 0

                def outer():
                    return inner()

                outer()
                """)
        }
        guard case let .raised(exception) = error else {
            Issue.record("expected .raised, got \(String(describing: error))")
            return
        }

        #expect(exception.type == "ZeroDivisionError")
        #expect(exception.message == "division by zero")

        // The frame list is the whole reason to carry a traceback at all.
        #expect(exception.traceback.contains("Traceback (most recent call last)"))
        #expect(exception.traceback.contains("in inner"))
        #expect(exception.traceback.contains("in outer"))
        #expect(exception.traceback.contains("ZeroDivisionError"))

        // …and Lathe's own driver frame is not in it. A traceback whose first
        // frame is inside the bridge sends the reader to the wrong file.
        #expect(!exception.traceback.contains("_lathe_call"))

        #expect(error?.localizedDescription.contains("ZeroDivisionError") == true)
    }

    @Test("output printed before a raise survives the raise", .enabled(if: SharedInterpreter.isAvailable))
    func keepsOutputFromFailedCall() throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let error = #expect(throws: PythonError.self) {
            try runtime.execute("print('got this far'); raise ValueError('and then not')")
        }
        guard case let .raised(exception) = error else { return }
        #expect(exception.standardOutput == "got this far\n")
        #expect(exception.message == "and then not")
    }

    @Test("a failed import says where it looked", .enabled(if: SharedInterpreter.isAvailable))
    func importFailureNamesSearchPath() throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let error = #expect(throws: PythonError.self) {
            try runtime.importModule("a_module_that_is_not_installed_anywhere")
        }
        guard case let .raised(exception) = error else {
            Issue.record("expected .raised, got \(String(describing: error))")
            return
        }
        #expect(exception.message.contains("sys.path"))
    }

    @Test("the interpreter survives a raise and keeps working", .enabled(if: SharedInterpreter.isAvailable))
    func recoversFromException() throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        #expect(throws: PythonError.self) { try runtime.execute("raise RuntimeError('boom')") }
        // A left-over error indicator would make the *next* unrelated call fail,
        // which is the classic embedding bug.
        #expect(try runtime.evaluate("'still here'").value.string == "still here")
    }

    // MARK: - Threads

    @Test("concurrent calls from many tasks do not crash", .enabled(if: SharedInterpreter.isAvailable))
    func survivesConcurrentCalls() async throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)

        // The interpreter is not thread-safe; the GIL is what makes this legal,
        // and every entry point taking it correctly is what this asserts. The
        // work per task is deliberately long enough to be preempted — CPython
        // drops the GIL every few milliseconds, so short calls would serialise
        // by accident and prove nothing.
        let answers = try await withThrowingTaskGroup(of: (Int, Int?).self) { group in
            for index in 0..<64 {
                group.addTask {
                    let evaluation = try runtime.evaluate("sum(range(20000)) + \(index)")
                    return (index, evaluation.value.int)
                }
            }
            var collected: [Int: Int?] = [:]
            for try await (index, value) in group { collected[index] = value }
            return collected
        }

        #expect(answers.count == 64)
        for index in 0..<64 {
            #expect(answers[index] == 199_990_000 + index)
        }
    }

    @Test("concurrent calls do not steal each other's output", .enabled(if: SharedInterpreter.isAvailable))
    func outputIsPerThread() async throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)

        // Capture is thread-local for exactly this reason: the GIL serialises
        // bytecode, not whole calls, so two callers printing at once genuinely
        // interleave in time.
        let results = try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for index in 0..<32 {
                group.addTask {
                    let output = try runtime.execute(
                        """
                        for _ in range(50):
                            pass
                        print("task-\(index)")
                        """)
                    return (index, output.standardOutput)
                }
            }
            var collected: [(Int, String)] = []
            for try await pair in group { collected.append(pair) }
            return collected
        }

        for (index, output) in results {
            #expect(output == "task-\(index)\n", "task \(index) saw \(output.debugDescription)")
        }
    }

    // MARK: - Lifecycle

    @Test("bootstrapping again returns the same interpreter", .enabled(if: SharedInterpreter.isAvailable))
    func bootstrapIsIdempotent() throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let again = try PythonRuntime.bootstrap(PythonRuntime.Configuration(layout: runtime.layout))
        #expect(again === runtime)
        #expect(PythonRuntime.current === runtime)
    }

    @Test("a second, different layout is refused rather than ignored", .enabled(if: SharedInterpreter.isAvailable))
    func refusesSecondLayout() throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)

        // A valid layout at a different path: a temporary directory whose `lib`
        // is a symlink to the real one. It passes validation — the point is that
        // the *latch* refuses it, not that the layout is bad.
        let alternate = FileManager.default.temporaryDirectory
            .appendingPathComponent("lathe-alt-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: alternate, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: alternate) }
        try FileManager.default.createSymbolicLink(
            at: alternate.appendingPathComponent("lib"),
            withDestinationURL: runtime.layout.home.appendingPathComponent("lib"))

        var layout = runtime.layout
        layout.home = alternate
        #expect(throws: Never.self) { try layout.validate() }

        let error = #expect(throws: PythonError.self) {
            try PythonRuntime.bootstrap(PythonRuntime.Configuration(layout: layout))
        }
        guard case let .alreadyBootstrapped(existingHome) = error else {
            Issue.record("expected alreadyBootstrapped, got \(String(describing: error))")
            return
        }
        #expect(existingHome == runtime.layout.home.path)
    }

    @Test("names defined by one call are visible to the next", .enabled(if: SharedInterpreter.isAvailable))
    func namespacePersists() throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        try runtime.execute("lathe_persisted_marker = 'kept'")
        #expect(try runtime.evaluate("lathe_persisted_marker").value.string == "kept")
    }

    // MARK: - Arguments

    @Test("arguments cross as data, not as interpolated syntax", .enabled(if: SharedInterpreter.isAvailable))
    func argumentsAreNotInterpolated() throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        // A value that would end the string literal, comment out the rest, and
        // run something else — if the bridge built Python source by splicing.
        let hostile = #"'); import os; os.environ["LATHE_PWNED"] = "1"; ("#
        let evaluation = try runtime.evaluate("lathe_arguments['value']", arguments: ["value": hostile])
        #expect(evaluation.value.string == hostile)
        #expect(try runtime.evaluate("__import__('os').environ.get('LATHE_PWNED')").value.repr == "None")
    }

    @Test("a source containing every awkward character round-trips", .enabled(if: SharedInterpreter.isAvailable))
    func sourceSurvivesQuoting() throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let awkward = #"""
            "double" 'single' \backslash\ """triple""" \n literal
            emoji 🧵 and a tab	here
            """#
        let evaluation = try runtime.evaluate("lathe_arguments['text']", arguments: ["text": awkward])
        #expect(evaluation.value.string == awkward)
    }

    // MARK: - Platform restrictions

    /// Reported, never asserted. Whether *this* build can spawn a process is a
    /// property of the build, and asserting today's answer is how a suite starts
    /// version-gating by accident.
    @Test("PEP 730 process-spawning restrictions (report)", .enabled(if: SharedInterpreter.isAvailable))
    func platformRestrictionReport() throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let platform = runtime.platform

        print("")
        print("  os.fork present:        \(platform.hasFork)")
        print("  os.posix_spawn present: \(platform.hasPosixSpawn)")
        print("  subprocess importable:  \(platform.subprocessIsImportable)")
        if let reason = platform.subprocessImportError { print("    reason: \(reason)") }
        print("  can spawn processes:    \(platform.canSpawnProcesses)")
        print("")

        if !platform.canSpawnProcesses {
            // Where the restriction applies, it must be *legible* — a raised
            // OSError that reads as a bug in the Python being run is exactly
            // what the flag exists to prevent.
            let error = #expect(throws: PythonError.self) {
                try runtime.execute("import subprocess; subprocess.run(['/bin/echo', 'hi'])")
            }
            if case let .raised(exception) = error {
                #expect(exception.isPlatformRestriction)
                #expect(error?.localizedDescription.contains("PEP 730") == true)
            }
        }
    }

    @Test("the interpreter's own version is read from it, never assumed", .enabled(if: SharedInterpreter.isAvailable))
    func versionComesFromTheInterpreter() throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let reported = try runtime.evaluate("'.'.join(str(n) for n in __import__('sys').version_info[:3])")
        #expect(reported.value.string == runtime.platform.versionNumber)
        #expect(runtime.platform.versionNumber.hasPrefix("3."))
    }
}
