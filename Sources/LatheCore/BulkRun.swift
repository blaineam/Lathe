import Foundation

/// Runs many pieces of media work at once, within a ``ResourcePool``.
///
/// ## What it guarantees
///
/// - **Never more than the pool allows**, in total or within a class.
/// - **One failure does not stop the run.** A bulk pass over a library meets a
///   corrupt file eventually, and abandoning the other nine hundred because of
///   it is the wrong answer. Every item gets an outcome and the caller decides.
/// - **Results come back in input order**, whatever order they finished in, so
///   a caller can line them up against what it submitted without matching on
///   identity.
/// - **Cancellation is prompt and honest**: work already running is cancelled
///   through its own task, work not yet started is reported as cancelled rather
///   than silently missing, and the call returns rather than hanging on a lane
///   that will never free.
public struct BulkRun: Sendable {

    public let pool: ResourcePool

    public init(pool: ResourcePool = .automatic) {
        self.pool = pool
    }

    /// One item to process, and what it will contend for.
    public struct Item<Input: Sendable>: Sendable {
        public var input: Input
        public var workload: Workload

        public init(_ input: Input, workload: Workload) {
            self.input = input
            self.workload = workload
        }
    }

    /// What became of one item.
    public enum Outcome<Output: Sendable>: Sendable {
        case succeeded(Output)
        case failed(any Error)
        /// Never started, or stopped part-way, because the run was cancelled.
        case cancelled

        public var value: Output? {
            if case .succeeded(let output) = self { return output }
            return nil
        }

        public var error: (any Error)? {
            if case .failed(let error) = self { return error }
            return nil
        }

        public var wasCancelled: Bool {
            if case .cancelled = self { return true }
            return false
        }
    }

    /// The whole run's result.
    public struct Report<Input: Sendable, Output: Sendable>: Sendable {
        /// One entry per submitted item, in submission order.
        public var outcomes: [Outcome<Output>]
        public var inputs: [Input]
        public var wallTime: TimeInterval

        public var succeeded: [Output] { outcomes.compactMap(\.value) }
        public var failures: [any Error] { outcomes.compactMap(\.error) }
        public var cancelledCount: Int { outcomes.filter(\.wasCancelled).count }

        /// Whether every item succeeded — the question a caller actually asks.
        public var isCompleteSuccess: Bool {
            outcomes.allSatisfy { if case .succeeded = $0 { return true } else { return false } }
        }

        /// The inputs whose work failed, paired with why. What a retry pass and
        /// a report to the user both need.
        public var failedInputs: [(input: Input, error: any Error)] {
            zip(inputs, outcomes).compactMap { input, outcome in
                outcome.error.map { (input, $0) }
            }
        }
    }

    /// Runs `body` over every item.
    ///
    /// `body` is called on its own task, so it may suspend freely; the lane it
    /// occupies is held for exactly as long as it runs.
    public func run<Input: Sendable, Output: Sendable>(
        _ items: [Item<Input>],
        progress: ProgressHandle = .ignoring(),
        _ body: @Sendable @escaping (Input) async throws -> Output
    ) async -> Report<Input, Output> {
        let started = Date()
        guard !items.isEmpty else {
            return Report(outcomes: [], inputs: [], wallTime: 0)
        }

        let broker = LaneBroker(pool: pool)
        let counter = CompletionCounter(total: items.count)

        var results = [Outcome<Output>?](repeating: nil, count: items.count)

        await withTaskGroup(of: (Int, Outcome<Output>).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    // The lane is acquired inside the task, not before adding
                    // it, so that the group holds every item from the start and
                    // the broker — rather than the group's own concurrency —
                    // decides what runs. Adding tasks lazily would make the
                    // per-class limits unenforceable across classes.
                    guard await broker.acquire(item.workload) else {
                        return (index, .cancelled)
                    }

                    // Released with a direct await rather than from a `defer`
                    // that spawns a Task. A detached release escapes structured
                    // concurrency and lands whenever it lands, so a lane can sit
                    // held after its work finished — which is invisible in the
                    // results and shows up only as a bulk run that does not
                    // quite use the pool it was given.
                    let outcome: Outcome<Output>
                    if Task.isCancelled {
                        outcome = .cancelled
                    } else {
                        do {
                            outcome = .succeeded(try await body(item.input))
                        } catch is CancellationError {
                            outcome = .cancelled
                        } catch {
                            outcome = .failed(error)
                        }
                    }
                    await broker.release(item.workload)
                    return (index, outcome)
                }
            }

            for await (index, outcome) in group {
                results[index] = outcome
                let done = await counter.increment()
                // Reported rather than checkpointed: a checkpoint throws on
                // cancellation, and cancelling here would abandon the outcomes
                // already collected. The run cancels through the task tree
                // instead, and still returns a full report.
                progress.report(LatheProgress(
                    stage: "bulk",
                    unitIndex: UInt64(done),
                    unitCount: UInt64(items.count)
                ))
            }
        }

        return Report(
            outcomes: results.map { $0 ?? .cancelled },
            inputs: items.map(\.input),
            wallTime: Date().timeIntervalSince(started)
        )
    }

    /// Runs `body` over items that all contend for the same thing.
    public func run<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        workload: Workload,
        progress: ProgressHandle = .ignoring(),
        _ body: @Sendable @escaping (Input) async throws -> Output
    ) async -> Report<Input, Output> {
        await run(inputs.map { Item($0, workload: workload) }, progress: progress, body)
    }
}

/// Counts finished items across the group.
private actor CompletionCounter {
    private var done = 0
    let total: Int

    init(total: Int) { self.total = total }

    func increment() -> Int {
        done += 1
        return done
    }
}
