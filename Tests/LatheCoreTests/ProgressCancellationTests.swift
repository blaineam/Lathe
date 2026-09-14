import Foundation
import Testing

@testable import LatheCore

/// A stand-in for a long media operation: N units, each taking a little real
/// time, each preceded by a progress checkpoint.
///
/// No codecs are involved on purpose. What is under test is the *seam* — that a
/// cancellation request reaches a blocking work body running off the cooperative
/// pool, and that the body unwinds at the next unit boundary.
private struct FakeLongRunningOperation: Sendable {
    let unitCount: UInt64
    let unitDuration: TimeInterval

    /// Opened once the first unit has begun, so a test can cancel a job that is
    /// provably already running rather than racing the dispatch.
    let started: AsyncGate

    /// Units actually completed. Read after the operation ends.
    let completed: UnitCounter

    init(unitCount: UInt64 = 50,
         unitDuration: TimeInterval = 0.01,
         started: AsyncGate = AsyncGate(),
         completed: UnitCounter = UnitCounter()) {
        self.unitCount = unitCount
        self.unitDuration = unitDuration
        self.started = started
        self.completed = completed
    }

    /// The blocking body. Runs on a dedicated worker thread, and checkpoints at
    /// every unit boundary — which is exactly the contract a real encoder loop
    /// would follow.
    func run(_ progress: ProgressHandle) throws -> UInt64 {
        for index in 0..<unitCount {
            try progress.checkpoint(
                LatheProgress(stage: "unit", unitIndex: index, unitCount: unitCount)
            )
            if index == 0 { started.open() }
            Thread.sleep(forTimeInterval: unitDuration)
            completed.increment()
        }
        try progress.checkpoint(
            LatheProgress(stage: "unit", unitIndex: unitCount, unitCount: unitCount)
        )
        return completed.value
    }
}

/// A one-shot gate the blocking worker can open and an `async` test can await.
/// `DispatchSemaphore.wait()` is unavailable from an async context — it would
/// block a cooperative-pool thread, which is the exact mistake `LatheWork` exists
/// to prevent — so the waiting side suspends instead.
private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Callable from any thread, including a blocking worker.
    func open() {
        lock.lock()
        guard !isOpen else { lock.unlock(); return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in pending { continuation.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// A trivially thread-safe counter, so the fake operation can be observed from
/// the test thread without data races.
private final class UnitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count: UInt64 = 0

    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }

    var value: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

@Suite("Progress and cancellation")
struct ProgressCancellationTests {

    // MARK: - Task cancellation reaches the work body

    @Test("cancelling the Task cancels the operation")
    func taskCancellationPropagates() async throws {
        let started = AsyncGate()
        let completed = UnitCounter()
        let operation = FakeLongRunningOperation(
            unitCount: 1_000, unitDuration: 0.002, started: started, completed: completed
        )

        let task = Task {
            try await LatheWork.run(throttle: .unthrottled) { progress in
                try operation.run(progress)
            }
        }

        // Only cancel once the body is provably running, so this tests
        // propagation rather than the pre-start short-circuit below.
        await started.wait()
        task.cancel()

        let result = await task.result
        let error = try #require(result.failureAsLatheError)
        #expect(error.isCancellation)

        // It stopped early: far short of 1,000 units.
        #expect(completed.value < 1_000)
        #expect(completed.value >= 1, "it should have finished at least the unit that was in flight")
    }

    @Test("cancel latency is bounded by one work unit")
    func cancelStopsAtNextUnitBoundary() async throws {
        let started = AsyncGate()
        let completed = UnitCounter()
        let operation = FakeLongRunningOperation(
            unitCount: 10_000, unitDuration: 0.001, started: started, completed: completed
        )

        let task = Task {
            try await LatheWork.run(throttle: .unthrottled) { progress in
                try operation.run(progress)
            }
        }
        await started.wait()
        let unitsAtCancel = completed.value
        task.cancel()
        _ = await task.result

        // After the cancel lands, at most one more unit may finish before the
        // next checkpoint trips. Allow generous slack for scheduling on a busy
        // CI machine — the assertion that matters is "bounded", not "instant".
        #expect(completed.value - unitsAtCancel < 200,
                "cancellation should be observed within a small number of units")
    }

    @Test("cancelling before the work starts means it never runs")
    func cancellationBeforeStart() async throws {
        let completed = UnitCounter()
        let operation = FakeLongRunningOperation(unitCount: 10, unitDuration: 0.001, completed: completed)

        let task = Task {
            // Yield first so cancel() lands before LatheWork.run is entered.
            await Task.yield()
            return try await LatheWork.run(throttle: .unthrottled) { progress in
                try operation.run(progress)
            }
        }
        task.cancel()

        let result = await task.result
        let error = try #require(result.failureAsLatheError)
        #expect(error.isCancellation)
        #expect(completed.value == 0, "the body should not have run at all")
    }

    @Test("an uncancelled operation runs to completion")
    func uncancelledOperationCompletes() async throws {
        let operation = FakeLongRunningOperation(unitCount: 20, unitDuration: 0.001)
        let units = try await LatheWork.run(throttle: .unthrottled) { progress in
            try operation.run(progress)
        }
        #expect(units == 20)
    }

    // MARK: - The sink's return value is the cancellation signal

    @Test("returning false from the sink cancels the operation")
    func sinkReturningFalseCancels() async throws {
        let completed = UnitCounter()
        let operation = FakeLongRunningOperation(unitCount: 500, unitDuration: 0.001, completed: completed)

        // Stop after five samples. This is the whole mechanism: no cancel token,
        // no shared atomic at the call site — just a `false`.
        let seen = UnitCounter()
        let sink = ClosureProgressSink { _ in
            seen.increment()
            return seen.value < 5
        }

        await #expect(throws: LatheError.self) {
            try await LatheWork.run(reporting: sink, throttle: .unthrottled) { progress in
                try operation.run(progress)
            }
        }
        #expect(completed.value < 500)
        #expect(seen.value == 5, "the sink should not be called again after it says stop")
    }

    @Test("cancellation latches: once tripped it stays tripped")
    func cancellationLatches() {
        let progress = ProgressHandle(sink: ClosureProgressSink { _ in false }, throttle: .unthrottled)
        #expect(!progress.isCancelled)

        #expect(progress.report(LatheProgress(fraction: 0, stage: "a")) == false)
        #expect(progress.isCancelled)
        // Every later call agrees, without consulting the sink again.
        #expect(progress.report(LatheProgress(fraction: 0.5, stage: "b")) == false)
        #expect(progress.report(LatheProgress(fraction: 1, stage: "c")) == false)
        #expect(throws: LatheError.self) { try progress.checkCancellation() }
    }

    @Test("an explicit cancel() is observed by the next checkpoint")
    func explicitCancel() async throws {
        let progress = ProgressHandle(throttle: .unthrottled)
        let started = AsyncGate()
        let completed = UnitCounter()
        let operation = FakeLongRunningOperation(
            unitCount: 1_000, unitDuration: 0.002, started: started, completed: completed
        )

        let task = Task {
            try await LatheWork.run(with: progress) { progress in
                try operation.run(progress)
            }
        }

        await started.wait()
        progress.cancel()   // not Task.cancel() — an external stop signal

        let result = await task.result
        let error = try #require(result.failureAsLatheError)
        #expect(error.isCancellation)
        #expect(completed.value < 1_000)
    }

    @Test("checkpoint reports the unit it failed at")
    func cancelledErrorCarriesUnitIndex() throws {
        let progress = ProgressHandle(throttle: .unthrottled)
        progress.cancel()
        #expect(throws: LatheError.cancelled(atUnit: 7)) {
            try progress.checkpoint(LatheProgress(stage: "unit", unitIndex: 7, unitCount: 99))
        }
    }

    // MARK: - Throttling

    @Test("throttling drops samples but never delays cancellation")
    func throttleDoesNotDelayCancellation() {
        // A one-hour minimum interval: nothing after the first sample would ever
        // be delivered on merit.
        let progress = ProgressHandle(
            sink: ObservingProgressSink { _ in },
            throttle: ProgressThrottle(minimumInterval: 3600, minimumFractionDelta: 1)
        )
        for index in 0..<50 {
            _ = progress.report(LatheProgress(fraction: Double(index) / 100, stage: "same"))
        }
        #expect(progress.observedSampleCount == 50)
        #expect(progress.deliveredSampleCount < 50, "the throttle should have dropped samples")

        progress.cancel()
        // Still refuses immediately, even though this tick would be throttled.
        #expect(progress.report(LatheProgress(fraction: 0.99, stage: "same")) == false)
    }

    @Test("a stage change is never throttled away")
    func stageChangesAlwaysDeliver() {
        let progress = ProgressHandle(
            sink: ObservingProgressSink { _ in },
            throttle: ProgressThrottle(minimumInterval: 3600, minimumFractionDelta: 1)
        )
        _ = progress.report(LatheProgress(fraction: 0, stage: "decode"))
        _ = progress.report(LatheProgress(fraction: 0.1, stage: "decode"))
        _ = progress.report(LatheProgress(fraction: 0.2, stage: "encode"))
        _ = progress.report(LatheProgress(fraction: 0.3, stage: "mux"))
        #expect(progress.deliveredSampleCount == 3, "each new stage should get through")
    }

    @Test("the terminal tick is never throttled away")
    func terminalTickAlwaysDelivers() {
        let progress = ProgressHandle(
            sink: ObservingProgressSink { _ in },
            throttle: ProgressThrottle(minimumInterval: 3600, minimumFractionDelta: 1)
        )
        _ = progress.report(LatheProgress(stage: "unit", unitIndex: 0, unitCount: 10))
        for index in 1..<10 {
            _ = progress.report(LatheProgress(stage: "unit", unitIndex: UInt64(index), unitCount: 10))
        }
        let beforeFinal = progress.deliveredSampleCount
        _ = progress.report(LatheProgress(stage: "unit", unitIndex: 10, unitCount: 10))
        #expect(progress.deliveredSampleCount == beforeFinal + 1)
    }

    @Test("a nil sink never cancels and never crashes")
    func ignoringReporter() throws {
        let progress = ProgressHandle.ignoring()
        for index in 0..<100 {
            #expect(progress.report(LatheProgress(stage: "unit", unitIndex: UInt64(index), unitCount: 100)))
        }
        #expect(!progress.isCancelled)
        #expect(throws: Never.self) { try progress.checkCancellation() }
    }

    // MARK: - Streaming

    @Test("the stream yields progress then the result")
    func streamYieldsProgressThenResult() async throws {
        let operation = FakeLongRunningOperation(unitCount: 20, unitDuration: 0.001)
        var progressCount = 0
        var finished: UInt64?

        for try await event in LatheWork.stream(throttle: .unthrottled, operation: { try operation.run($0) }) {
            switch event {
            case .progress: progressCount += 1
            case let .finished(value): finished = value
            }
        }

        #expect(finished == 20)
        #expect(progressCount > 0)
    }

    @Test("abandoning the stream cancels the work")
    func abandoningStreamCancels() async throws {
        let completed = UnitCounter()
        let operation = FakeLongRunningOperation(unitCount: 5_000, unitDuration: 0.002, completed: completed)

        // Consume exactly one sample and walk away. Leaving the loop destroys
        // the iterator, which fires `onTermination`, which cancels the work.
        await Task {
            do {
                for try await event in LatheWork.stream(throttle: .unthrottled,
                                                        operation: { try operation.run($0) }) {
                    if case .progress = event { break }
                }
            } catch {
                // A cancellation surfacing here is the expected outcome too.
            }
        }.value

        // Let any in-flight unit finish, then confirm the count stops moving.
        try await Task.sleep(nanoseconds: 300_000_000)
        let settled = completed.value
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(completed.value == settled, "work should have stopped after the stream was abandoned")
        #expect(completed.value < 5_000)
    }
}

// MARK: - Helpers

extension Result where Failure == any Error {
    /// The failure as a ``LatheError``, or `nil` if the result succeeded.
    var failureAsLatheError: LatheError? {
        switch self {
        case .success: nil
        case let .failure(error): LatheError.wrapping(error)
        }
    }
}
