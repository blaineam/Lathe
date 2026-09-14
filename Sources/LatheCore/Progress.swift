import Foundation

/// One progress sample.
///
/// A *sample*, not an event. Dropping an intermediate tick is always correct;
/// the consumer only ever wants the latest one.
public struct LatheProgress: Sendable, Equatable {
    /// `0...1` where known. `nil` for genuinely indeterminate work — a first
    /// pass that has not yet learned the unit count, for instance.
    public let fraction: Double?

    /// A short, stable, machine-comparable stage name: `"decode"`, `"encode"`,
    /// `"mux"`, `"page"`. Not a localised UI string.
    public let stage: String

    /// Index of the unit currently being worked, 0-based.
    public let unitIndex: UInt64

    /// Total unit count, or `0` when unknown.
    public let unitCount: UInt64

    public init(fraction: Double?, stage: String, unitIndex: UInt64 = 0, unitCount: UInt64 = 0) {
        self.fraction = fraction.map { min(max($0, 0), 1) }
        self.stage = stage
        self.unitIndex = unitIndex
        self.unitCount = unitCount
    }

    /// Derives ``fraction`` from the unit counters.
    public init(stage: String, unitIndex: UInt64, unitCount: UInt64) {
        self.init(
            fraction: unitCount > 0 ? Double(unitIndex) / Double(unitCount) : nil,
            stage: stage,
            unitIndex: unitIndex,
            unitCount: unitCount
        )
    }
}

/// The progress sink.
///
/// **The return value is the cancellation signal.** This is the cleanest
/// cross-language primitive available for a media engine: it needs no shared
/// atomics and no separate cancel token to plumb through every layer, and it
/// makes *every progress tick automatically a cancellation checkpoint*.
///
/// The Swift shape deliberately mirrors the C callback it can sit in front of,
/// so a non-Swift caller can be added later without redesigning the seam:
///
/// ```c
/// // returns false to request cancellation
/// typedef bool (*lathe_progress_cb)(void *user, double fraction,
///                                   const char *stage, uint64_t unit_index,
///                                   uint64_t unit_count);
/// ```
///
/// Implementations are called from a **dedicated worker thread**, never the
/// Swift concurrency cooperative pool, and must be cheap and non-blocking.
public protocol ProgressSink: Sendable {
    /// - Returns: `false` to request cancellation of the running operation.
    func report(_ progress: LatheProgress) -> Bool
}

/// A ``ProgressSink`` built from a closure.
public struct ClosureProgressSink: ProgressSink {
    private let body: @Sendable (LatheProgress) -> Bool

    /// - Parameter body: returns `false` to request cancellation.
    public init(_ body: @escaping @Sendable (LatheProgress) -> Bool) {
        self.body = body
    }

    public func report(_ progress: LatheProgress) -> Bool { body(progress) }
}

/// A sink that observes progress and never cancels.
public struct ObservingProgressSink: ProgressSink {
    private let body: @Sendable (LatheProgress) -> Void

    public init(_ body: @escaping @Sendable (LatheProgress) -> Void) {
        self.body = body
    }

    public func report(_ progress: LatheProgress) -> Bool {
        body(progress)
        return true
    }
}
