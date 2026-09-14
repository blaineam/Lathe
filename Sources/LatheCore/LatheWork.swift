import Foundation

/// What a streamed operation emits.
public enum LatheEvent<Value: Sendable>: Sendable {
    case progress(LatheProgress)
    case finished(Value)
}

/// The bridge between Swift Concurrency and Lathe's blocking work bodies.
///
/// Two rules are enforced here so no call site has to remember them:
///
/// 1. **Never run a long blocking call on the cooperative pool.** Swift
///    concurrency sizes its pool to the core count and assumes threads make
///    forward progress; a 40-second blocking encode starves it and can deadlock
///    unrelated actors. Work bodies therefore run on a dedicated
///    `DispatchQueue` and are bridged with `withCheckedThrowingContinuation`.
///
/// 2. **`Task` cancellation must reach the work body.**
///    `withTaskCancellationHandler` trips the ``ProgressHandle``'s latch,
///    which the body observes at its next ``ProgressHandle/report(_:)`` or
///    ``ProgressHandle/checkCancellation()``.
///
/// Cancel latency is therefore **one work unit** — one image, one document page,
/// one archive entry, N video frames. That is stated rather than pretended away:
/// most C libraries do not poll for cancellation internally, so chunking at unit
/// boundaries is the honest granularity. Some framework operations do cancel
/// promptly and should be wired to ``ProgressHandle/cancel()`` directly.
public enum LatheWork {

    /// The default worker queue. Concurrent, utility QoS, and deliberately *not*
    /// the cooperative pool. Callers with their own admission control should
    /// pass their own queue.
    public static let defaultQueue = DispatchQueue(
        label: "dev.lathe.work",
        qos: .utility,
        attributes: .concurrent
    )

    /// Run a blocking operation off the cooperative pool, with progress reporting
    /// and with `Task` cancellation wired into the handle.
    ///
    /// - Parameters:
    ///   - sink: receives throttled progress samples; returning `false` from it
    ///     cancels the operation.
    ///   - throttle: delivery rate limit. Cancellation is never throttled.
    ///   - queue: the worker queue. Must not be the cooperative pool.
    ///   - operation: the blocking body. Call
    ///     ``ProgressHandle/checkpoint(_:)`` at unit boundaries.
    /// - Throws: whatever `operation` throws, normalised through
    ///   ``LatheError/wrapping(_:)``; ``LatheError/cancelled(atUnit:)`` if the
    ///   enclosing `Task` was cancelled and the body honoured it.
    public static func run<T: Sendable>(
        reporting sink: (any ProgressSink)? = nil,
        throttle: ProgressThrottle = .standard,
        on queue: DispatchQueue = defaultQueue,
        operation: @escaping @Sendable (ProgressHandle) throws -> T
    ) async throws -> T {
        let handle = ProgressHandle(sink: sink, throttle: throttle)
        return try await run(with: handle, on: queue, operation: operation)
    }

    /// As ``run(reporting:throttle:on:operation:)``, but against a handle the
    /// caller already owns — so the work can also be cancelled from outside the
    /// `Task`, by a UI stop button or a memory-pressure handler.
    public static func run<T: Sendable>(
        with handle: ProgressHandle,
        on queue: DispatchQueue = defaultQueue,
        operation: @escaping @Sendable (ProgressHandle) throws -> T
    ) async throws -> T {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                queue.async {
                    do {
                        // Covers the "cancelled before the queue picked it up" race.
                        try handle.checkCancellation()
                        continuation.resume(returning: try operation(handle))
                    } catch {
                        continuation.resume(throwing: LatheError.wrapping(error))
                    }
                }
            }
        } onCancel: {
            // Trips the next callback tick. See ProgressHandle.cancel().
            handle.cancel()
        }
    }

    /// The streaming form: progress samples arrive as they happen, the result
    /// arrives last.
    ///
    /// `.bufferingNewest(1)` is deliberate. Progress is a *sample*, not an event
    /// log; unbounded buffering lets a slow consumer backpressure the encoder or
    /// grow memory without bound. Terminating the stream cancels the work.
    public static func stream<T: Sendable>(
        throttle: ProgressThrottle = .standard,
        on queue: DispatchQueue = defaultQueue,
        operation: @escaping @Sendable (ProgressHandle) throws -> T
    ) -> AsyncThrowingStream<LatheEvent<T>, any Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let sink = ClosureProgressSink { sample in
                // `yield` is thread-safe, so yield straight from the worker
                // thread. Don't hop to @MainActor per tick — let the consumer do
                // that once, at the UI.
                continuation.yield(.progress(sample))
                return true
            }
            let handle = ProgressHandle(sink: sink, throttle: throttle)
            let task = Task.detached(priority: .utility) {
                do {
                    let value = try await run(with: handle, on: queue, operation: operation)
                    continuation.yield(.finished(value))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: LatheError.wrapping(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
