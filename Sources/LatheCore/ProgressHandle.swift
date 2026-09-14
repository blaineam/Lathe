import Foundation

/// How often ticks are forwarded to the sink.
///
/// Throttle *at the source* to roughly 10 Hz or 1% granularity — do not yield
/// per frame.
///
/// Throttling applies only to **delivery**. Cancellation is evaluated on every
/// call, so a throttled tick can still trip the cancel flag; a dropped sample
/// never delays a cancel.
public struct ProgressThrottle: Sendable, Equatable {
    /// Minimum interval between delivered samples.
    public var minimumInterval: TimeInterval
    /// Minimum change in `fraction` that forces delivery regardless of interval.
    public var minimumFractionDelta: Double

    public init(minimumInterval: TimeInterval = 0.1, minimumFractionDelta: Double = 0.01) {
        self.minimumInterval = minimumInterval
        self.minimumFractionDelta = minimumFractionDelta
    }

    /// ~10 Hz / 1%. The default.
    public static let standard = ProgressThrottle()
    /// Deliver everything. For tests and for very short jobs.
    public static let unthrottled = ProgressThrottle(minimumInterval: 0, minimumFractionDelta: 0)
}

/// The handle a running operation uses to publish progress and to learn that it
/// should stop.
///
/// Named `ProgressHandle` rather than the more obvious `ProgressReporter`
/// because recent Foundation defines a `ProgressReporter` of its own, and a
/// module that imports both should not have to disambiguate.
///
/// One mechanism does both jobs: the operation calls ``report(_:)`` (or
/// ``checkpoint(_:)``) at unit boundaries, and a `false` return — or a thrown
/// ``LatheError/cancelled(atUnit:)`` — is the only cancellation signal it ever
/// has to understand.
///
/// Cancellation **latches**: once tripped — by the sink returning `false`, by
/// ``cancel()``, or by the enclosing `Task` being cancelled via ``LatheWork`` —
/// every subsequent call reports cancelled. An operation can therefore check
/// once per unit and unwind without racing.
///
/// Safe to call from any thread. Intended to be called from a dedicated worker
/// thread, **never** from the Swift concurrency cooperative pool.
public final class ProgressHandle: @unchecked Sendable {

    private let sink: (any ProgressSink)?
    private let throttle: ProgressThrottle
    private let lock = NSLock()

    // All of the following are guarded by `lock`.
    private var cancelled = false
    private var lastDeliveredAt: TimeInterval = -.greatestFiniteMagnitude
    private var lastDeliveredFraction: Double?
    private var lastStage: String?
    private var lastUnitIndex: UInt64 = 0
    private var deliveredCount: Int = 0
    private var observedCount: Int = 0

    public init(sink: (any ProgressSink)? = nil, throttle: ProgressThrottle = .standard) {
        self.sink = sink
        self.throttle = throttle
    }

    /// A progress that discards progress and is never cancelled. For call sites
    /// that do not care, so the parameter never has to be optional.
    public static func ignoring() -> ProgressHandle { ProgressHandle(sink: nil) }

    // MARK: - State

    /// Whether cancellation has been requested. Latched.
    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// The last unit index seen by ``report(_:)``, for the
    /// ``LatheError/cancelled(atUnit:)`` payload and for resume manifests.
    public var currentUnitIndex: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return lastUnitIndex
    }

    /// Number of samples actually forwarded to the sink (after throttling).
    /// Exposed for tests and for verifying throttle behaviour in the field.
    public var deliveredSampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return deliveredCount
    }

    /// Number of ``report(_:)`` calls, throttled or not.
    public var observedSampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return observedCount
    }

    // MARK: - Signalling

    /// Request cancellation. Idempotent; latches.
    ///
    /// Called by ``LatheWork``'s `Task` cancellation handler, and available
    /// directly for callers that own their own cancel button.
    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    // MARK: - Reporting

    /// Publish a progress sample and ask whether to continue.
    ///
    /// - Returns: `false` if the operation should stop. **The return value is
    ///   the cancellation signal** — there is no other channel.
    @discardableResult
    public func report(_ progress: LatheProgress) -> Bool {
        lock.lock()
        observedCount += 1
        lastUnitIndex = progress.unitIndex

        if cancelled {
            lock.unlock()
            return false
        }

        let now = Date.timeIntervalSinceReferenceDate
        let stageChanged = progress.stage != lastStage
        let unitCompleted = progress.unitCount > 0 && progress.unitIndex >= progress.unitCount
        let intervalElapsed = (now - lastDeliveredAt) >= throttle.minimumInterval
        let fractionMoved: Bool = {
            guard let new = progress.fraction else { return true }
            guard let old = lastDeliveredFraction else { return true }
            return abs(new - old) >= throttle.minimumFractionDelta
        }()

        // Deliver on any of: stage change, terminal tick, or (enough time AND
        // enough movement). Stage changes and the final tick are never dropped —
        // a UI that misses those looks stuck.
        let shouldDeliver = stageChanged || unitCompleted || (intervalElapsed && fractionMoved)
        guard shouldDeliver, let sink else {
            lock.unlock()
            return true
        }

        lastDeliveredAt = now
        lastDeliveredFraction = progress.fraction
        lastStage = progress.stage
        deliveredCount += 1
        lock.unlock()

        // The sink is called outside the lock: it may be slow, and it must never
        // be able to deadlock against `cancel()` arriving on another thread.
        let keepGoing = sink.report(progress)
        if !keepGoing {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
        return keepGoing
    }

    /// ``report(_:)`` in throwing form, for operations that would rather unwind
    /// than thread a `Bool` back up.
    ///
    /// - Throws: ``LatheError/cancelled(atUnit:)``.
    public func checkpoint(_ progress: LatheProgress) throws {
        if !report(progress) {
            throw LatheError.cancelled(atUnit: progress.unitIndex)
        }
    }

    /// Cancellation check with no progress sample attached, for the middle of a
    /// long unit.
    ///
    /// - Throws: ``LatheError/cancelled(atUnit:)``.
    public func checkCancellation() throws {
        lock.lock()
        let isCancelled = cancelled
        let unit = lastUnitIndex
        lock.unlock()
        if isCancelled { throw LatheError.cancelled(atUnit: unit) }
    }
}
