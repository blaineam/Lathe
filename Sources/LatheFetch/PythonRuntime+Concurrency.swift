import Foundation
import LatheCore

extension PythonRuntime {

    // MARK: - Where detached calls run

    /// The queue detached Python calls run on.
    ///
    /// **Not the cooperative pool**, and that is the entire reason it exists —
    /// the same rule `LatheWork` enforces for encodes, for the same reason.
    /// Swift Concurrency sizes its pool to the core count and assumes every
    /// thread in it makes forward progress; a Python call that runs for forty
    /// seconds occupies one of those threads for forty seconds, and a handful of
    /// them starve unrelated actors or deadlock them outright.
    ///
    /// Concurrent rather than serial because the interpreter is already
    /// concurrent: CPython drops the GIL around blocking I/O, which is exactly
    /// when a second caller should be allowed to run. Serialising here would
    /// undo the property ``PythonRuntime`` goes out of its way to preserve.
    ///
    /// `userInitiated` rather than `utility` because the caller is awaiting the
    /// result — unlike a background encode, nothing else is going to happen
    /// until this finishes.
    public static let workQueue = DispatchQueue(
        label: "dev.lathe.python.work",
        qos: .userInitiated,
        attributes: .concurrent
    )

    /// Cancellation requests go on their own queue, never on the caller's
    /// thread.
    ///
    /// Delivering one needs the GIL, and acquiring the GIL means waiting for
    /// the running call to reach a bytecode boundary and drop it — a few
    /// milliseconds, usually. `withTaskCancellationHandler`'s `onCancel` runs
    /// synchronously on whatever cancelled the task, which may well be an actor
    /// or the main thread, and blocking either for milliseconds to deliver a
    /// cancellation is the kind of thing that turns up later as a scroll hitch.
    private static let cancellationQueue = DispatchQueue(
        label: "dev.lathe.python.cancel",
        qos: .userInitiated
    )

    private static let callCounter = CallCounter()

    /// A monotonic id per detached call. A class with a lock rather than an
    /// atomic: this package has no atomics dependency, and one lock acquisition
    /// per call to Python is not measurable against the call itself.
    private final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var next = 1
        func take() -> Int {
            lock.lock()
            defer { lock.unlock() }
            next += 1
            return next
        }
    }

    // MARK: - The async surface

    /// Runs `source` as statements, on a dedicated thread, without blocking the
    /// caller.
    ///
    /// ## Which of these two to use
    ///
    /// * **This one**, from anything `async` — a `Task`, an actor, a SwiftUI
    ///   `.task {}`. The Python runs on ``workQueue`` and the calling
    ///   thread is released at the `await`, so an actor stays responsive and the
    ///   cooperative pool keeps its threads.
    /// * ``execute(_:arguments:)``, the synchronous one, when the caller is
    ///   already on a thread of its own and wants to block it — a
    ///   `Thread`-based worker, a command-line tool's `main`, or code already
    ///   inside a `LatheWork.run` body. Calling *that* one from a `Task` is the
    ///   hazard this method exists to remove.
    ///
    /// ## Cancellation, and what it cannot do
    ///
    /// Cancelling the enclosing `Task` asks the interpreter to raise
    /// `KeyboardInterrupt` in the thread running this call, and this method then
    /// throws `CancellationError`. That request is **cooperative and is
    /// delivered at a bytecode boundary**, which has three consequences worth
    /// knowing before relying on it:
    ///
    /// * Pure-Python loops and anything doing I/O through Python stop
    ///   promptly — a few milliseconds.
    /// * A C extension blocked in a syscall executes no bytecode, so **nothing
    ///   stops until it returns**. A compiled decompressor chewing through a
    ///   gigabyte will finish chewing.
    /// * Python code that catches `BaseException` broadly — and a surprising
    ///   amount of published Python does — swallows the interrupt exactly as it
    ///   swallows a user's ^C, and the call runs to completion.
    ///
    /// In all three cases this method returns when the Python call actually
    /// returns. It does not abandon the work and resume early: that would hand
    /// the caller a `CancellationError` while a thread carried on holding the
    /// GIL and mutating the interpreter's state behind it.
    ///
    /// - Throws: `CancellationError` when the task was cancelled and the
    ///   interpreter honoured it; otherwise whatever ``execute(_:arguments:)``
    ///   would throw.
    @discardableResult
    public func executeDetached(_ source: String, arguments: [String: String] = [:]) async throws -> PythonOutput {
        let report = try await detached(source, mode: .execute, arguments: arguments)
        return report.output
    }

    /// Evaluates an expression on a dedicated thread and reads its value back.
    ///
    /// The async form of ``evaluate(_:arguments:)``; see
    /// ``executeDetached(_:arguments:)`` for which surface to use when, and for
    /// what cancellation can and cannot do.
    public func evaluateDetached(
        _ expression: String, arguments: [String: String] = [:]
    ) async throws -> PythonEvaluation {
        let report: Report
        do {
            report = try await detached(expression, mode: .evaluate, arguments: arguments)
        } catch let PythonError.raised(exception) where exception.type == "SyntaxError" {
            throw PythonError.notAnExpression(source: expression)
        }
        guard let repr = report.repr, let typeName = report.type else {
            throw PythonError.notAnExpression(source: expression)
        }
        return PythonEvaluation(
            value: PythonValue(repr: repr, typeName: typeName, jsonEncoded: report.json),
            output: report.output
        )
    }

    /// Imports a module on a dedicated thread.
    ///
    /// Worth having as its own method rather than as `executeDetached("import x")`
    /// because importing is the *long* Python operation in practice — a large
    /// package takes seconds of pure interpretation — and it is therefore the
    /// one most likely to be called from a `Task` and to hurt when it blocks.
    public func importModuleDetached(_ name: String) async throws {
        do {
            try await executeDetached("import \(name)")
        } catch let PythonError.raised(exception)
            where exception.type == "ModuleNotFoundError" || exception.type.hasSuffix("ImportError")
        {
            throw PythonError.raised(
                PythonException(
                    type: exception.type,
                    message: exception.message + "\n\nsys.path:\n"
                        + platform.searchPath.map { "  · \($0)" }.joined(separator: "\n"),
                    traceback: exception.traceback,
                    standardOutput: exception.standardOutput,
                    standardError: exception.standardError,
                    isPlatformRestriction: exception.isPlatformRestriction
                ))
        }
    }

    // MARK: - The bridge

    private func detached(
        _ source: String, mode: PythonDriver.Mode, arguments: [String: String]
    ) async throws -> Report {
        let callID = Self.callCounter.take()

        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Report, any Error>) in
                    Self.workQueue.async {
                        do {
                            continuation.resume(returning: try self.call(
                                source, mode: mode, arguments: arguments, callID: callID))
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } onCancel: {
                // Off the cancelling thread, and fire-and-forget: the call's own
                // return is what resumes the continuation, never this.
                Self.cancellationQueue.async { self.requestCancellation(of: callID) }
            }
        } catch let PythonError.raised(exception) where exception.type == "KeyboardInterrupt" {
            // A KeyboardInterrupt with the task cancelled is *this* cancellation
            // arriving; one without is Python's own, and misreporting it as a
            // cancellation would hide a real exception.
            if Task.isCancelled { throw CancellationError() }
            throw PythonError.raised(exception)
        }
    }

}

// MARK: - Trust

extension PythonRuntime {

    /// Points the **already running** interpreter at a CA bundle.
    ///
    /// The counterpart to ``Configuration/trustStore``, and necessary because
    /// of the order these things happen in on a first launch: the bundle is
    /// acquired by installing a package, installing a package needs a running
    /// interpreter, and the interpreter cannot be restarted afterwards. This
    /// method closes that circle.
    ///
    /// ## What it affects, and what it does not
    ///
    /// Anything that builds an `SSLContext` **after** this call —
    /// `ssl.create_default_context()`, and therefore `urllib`, `http.client`
    /// and `requests` sessions created from here on. OpenSSL reads
    /// `SSL_CERT_FILE` when a context loads its default verify paths, not once
    /// at start-up, which is what makes this work at all.
    ///
    /// A context that already exists keeps the anchors it was built with. In
    /// practice that means a package which built a session before this call
    /// will keep failing verification until it builds another, and the fix is to
    /// call this *before* importing the package that reaches the network rather
    /// than after it has already tried.
    public func useTrustStore(_ store: PythonTrustStore) throws {
        // Both halves are needed. `setenv` is what any C code in the process
        // reads; `os.environ` is what Python reads, and assigning to it also
        // calls `putenv`, which is belt and braces rather than redundancy —
        // the two are the same environment only because CPython makes them so.
        for (name, value) in store.environment {
            setenv(name, value, 1)
        }
        try execute(
            "import os; os.environ.update(dict(lathe_arguments.items()))",
            arguments: store.environment
        )
        LatheFetchLog.python.notice(
            "Python TLS anchored on \(store.certificateCount, privacy: .public) root certificates")
    }
}
