import Foundation
import Testing

@testable import LatheFetch

/// The async surface: Python off the cooperative pool, and cancellation that
/// actually reaches the interpreter.
///
/// The two things worth asserting here are the two that are invisible when they
/// are wrong. A call that blocks the caller's actor still returns the right
/// answer — it just wedges the UI. A cancellation that is never delivered still
/// ends the `Task` — it just leaves a thread burning until it finishes. Both
/// pass a naive test and fail in an application, so both are measured.
@Suite("Detached Python calls")
struct PythonConcurrencyTests {

    /// Whether the interpreter can deliver an interrupt to a worker thread.
    ///
    /// `ctypes` needs libFFI, which every build in practice has and a
    /// hand-configured one might not. Reported rather than assumed, for the
    /// same reason every other capability here is.
    static let canInterrupt: Bool = {
        guard let runtime = SharedInterpreter.outcome.runtime else { return false }
        return (try? runtime.evaluate("__import__('ctypes') is not None").value.bool) == true
    }()

    // MARK: - It is the same interpreter

    @Test("a detached call returns what the synchronous one would", .enabled(if: SharedInterpreter.isAvailable))
    func agreesWithTheSynchronousSurface() async throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)

        let output = try await runtime.executeDetached("print('detached')")
        #expect(output.standardOutput == "detached\n")

        let evaluation = try await runtime.evaluateDetached("2 ** 10")
        #expect(evaluation.value.int == 1024)
        #expect(evaluation.value.typeName == "int")

        // Arguments cross the same way, which means they cross as data.
        let echoed = try await runtime.evaluateDetached(
            "lathe_arguments['value']", arguments: ["value": "'); import os; ("])
        #expect(echoed.value.string == "'); import os; (")
    }

    @Test("a detached statement handed to evaluate is still named as such", .enabled(if: SharedInterpreter.isAvailable))
    func rejectsStatements() async throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let error = await #expect(throws: PythonError.self) { try await runtime.evaluateDetached("x = 1") }
        guard case .notAnExpression = error else {
            Issue.record("expected notAnExpression, got \(String(describing: error))")
            return
        }
    }

    @Test("a detached exception arrives with its traceback", .enabled(if: SharedInterpreter.isAvailable))
    func carriesTracebacks() async throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let error = await #expect(throws: PythonError.self) {
            try await runtime.executeDetached("raise ValueError('from a worker thread')")
        }
        guard case let .raised(exception) = error else {
            Issue.record("expected .raised, got \(String(describing: error))")
            return
        }
        #expect(exception.type == "ValueError")
        #expect(exception.traceback.contains("ValueError"))
    }

    @Test("a detached import failure still says where it looked", .enabled(if: SharedInterpreter.isAvailable))
    func importFailureNamesSearchPath() async throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        let error = await #expect(throws: PythonError.self) {
            try await runtime.importModuleDetached("a_module_that_is_not_installed_anywhere")
        }
        guard case let .raised(exception) = error else { return }
        #expect(exception.message.contains("sys.path"))
    }

    // MARK: - It does not block the caller

    /// The test the whole async surface exists for.
    ///
    /// Running on the main actor, with a one-second Python call in flight: if
    /// the call were made synchronously the main actor would be stuck inside it
    /// and the ticking below could not happen until it finished. Measuring the
    /// tick loop rather than merely counting it is what distinguishes "it ran"
    /// from "it ran after waiting a second".
    @Test("a long detached call leaves the caller's actor free", .enabled(if: SharedInterpreter.isAvailable))
    @MainActor
    func doesNotBlockTheCallersActor() async throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)

        let wholeThing = Date()
        async let slow: PythonOutput = runtime.executeDetached("import time; time.sleep(1.0)")

        let tickingStarted = Date()
        var ticks = 0
        while ticks < 20 {
            try await Task.sleep(nanoseconds: 5_000_000)
            ticks += 1
        }
        let tickingTook = Date().timeIntervalSince(tickingStarted)

        _ = try await slow
        let everythingTook = Date().timeIntervalSince(wholeThing)

        #expect(ticks == 20)
        #expect(
            tickingTook < 0.7,
            "the main actor was blocked for \(tickingTook)s while Python ran — the call is not detached")
        #expect(everythingTook >= 0.9, "the Python call did not actually take the second it slept for")
    }

    @Test("many detached calls run concurrently and keep their own answers",
          .enabled(if: SharedInterpreter.isAvailable))
    func runsConcurrently() async throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)

        let answers = try await withThrowingTaskGroup(of: (Int, Int?).self) { group in
            for index in 0..<24 {
                group.addTask {
                    let evaluation = try await runtime.evaluateDetached("sum(range(5000)) + \(index)")
                    return (index, evaluation.value.int)
                }
            }
            var collected: [Int: Int?] = [:]
            for try await (index, value) in group { collected[index] = value }
            return collected
        }

        #expect(answers.count == 24)
        for index in 0..<24 {
            #expect(answers[index] == 12_497_500 + index)
        }
    }

    // MARK: - Cancellation

    @Test(
        "cancelling the task interrupts the Python call",
        .enabled(if: SharedInterpreter.isAvailable && PythonConcurrencyTests.canInterrupt))
    func cancellationReachesTheInterpreter() async throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)

        // Bounded rather than `while True`: a cancellation that is never
        // delivered should make this test slow and red, not hang forever. Each
        // sleep releases the GIL and returns to a bytecode boundary within ten
        // milliseconds, which is where the interrupt lands.
        let task = Task {
            try await runtime.executeDetached(
                """
                import time
                for _ in range(2000):
                    time.sleep(0.01)
                print("this must not be reached")
                """)
        }

        try await Task.sleep(nanoseconds: 300_000_000)
        let cancelled = Date()
        task.cancel()

        let result = await task.result
        let stoppingTook = Date().timeIntervalSince(cancelled)

        switch result {
        case .success:
            Issue.record("the call ran to completion; the interrupt was not delivered")
        case let .failure(error):
            #expect(error is CancellationError, "expected CancellationError, got \(error)")
        }
        #expect(stoppingTook < 5, "the interrupt took \(stoppingTook)s to land")

        // And the interpreter is not left holding a set error indicator, which
        // is the classic way an interrupted embedding breaks the *next* call.
        #expect(try runtime.evaluate("'still here'").value.string == "still here")
    }

    @Test(
        "a task cancelled before its call starts never runs it",
        .enabled(if: SharedInterpreter.isAvailable && PythonConcurrencyTests.canInterrupt))
    func cancellationBeforeTheCallStarts() async throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)

        let task = Task {
            try await runtime.executeDetached("lathe_cancel_marker = 'this should not have run'")
        }
        task.cancel()

        let result = await task.result
        if case .success = result {
            // A genuine race the other way: the call may have completed before
            // the cancellation was delivered. Not a failure — but then the
            // marker is legitimately set, and there is nothing to assert.
            return
        }
        #expect(
            try runtime.evaluate("globals().get('lathe_cancel_marker')").value.repr == "None",
            "the cancelled call ran anyway")
    }

    @Test("a KeyboardInterrupt that is not a cancellation stays a Python error",
          .enabled(if: SharedInterpreter.isAvailable))
    func doesNotMisreportPythonsOwnInterrupt() async throws {
        let runtime = try #require(SharedInterpreter.outcome.runtime)
        // Python raising KeyboardInterrupt by itself, in a task nobody
        // cancelled, is an exception and not a cancellation. Reporting it as
        // CancellationError would swallow a real error.
        let error = await #expect(throws: PythonError.self) {
            try await runtime.executeDetached("raise KeyboardInterrupt('not a cancellation')")
        }
        guard case let .raised(exception) = error else {
            Issue.record("expected .raised, got \(String(describing: error))")
            return
        }
        #expect(exception.type == "KeyboardInterrupt")
    }

    // MARK: - The report

    @Test("interrupt capability (report)", .enabled(if: SharedInterpreter.isAvailable))
    func interruptReport() {
        print("")
        print("  cancellation can be delivered: \(PythonConcurrencyTests.canInterrupt)")
        if !PythonConcurrencyTests.canInterrupt {
            print("    ctypes is unavailable in this build, so a detached call cannot be interrupted;")
            print("    cancelling a Task will end the Task and leave the Python running to completion.")
        }
        print("")
    }
}
