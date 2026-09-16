import Foundation
import LatheCore

/// Finds the lowest setting whose output still looks like the original.
///
/// "Setting" is whatever the caller turns: a still-image quality, a video
/// bitrate expressed as a fraction, anything where a higher value means a
/// more faithful and larger result. The search tries the top of ``range``
/// first — if even that is visibly different, nothing lower will do — and then
/// halves the interval, keeping the lowest value that passed, until
/// ``maximumAttempts`` encodes have been spent.
///
/// It assumes fidelity rises with the value. Real encoders are nearly but not
/// perfectly monotonic, so the answer is the lowest value *found* to pass, not
/// a proof that nothing lower would.
public struct QualitySearch: Sendable, Equatable {
    public var threshold: VisualThreshold
    public var range: ClosedRange<Double>
    public var maximumAttempts: Int

    public init(
        threshold: VisualThreshold = .visuallyLossless,
        range: ClosedRange<Double> = 0.4...0.98,
        maximumAttempts: Int = 6
    ) {
        self.threshold = threshold
        self.range = range
        self.maximumAttempts = max(1, maximumAttempts)
    }

    public struct Attempt: Sendable, Equatable {
        public var value: Double
        public var similarity: VisualSimilarity
        public var passed: Bool
    }

    public struct Outcome<Output: Sendable>: Sendable {
        /// The output at ``value``, or `nil` when nothing in the range passed.
        public var output: Output?
        /// The lowest value that passed.
        public var value: Double?
        public var similarity: VisualSimilarity?
        /// Every encode tried, in order.
        public var attempts: [Attempt]

        public var found: Bool { value != nil }
    }

    /// Runs the search. `attempt` encodes at a value and measures the result.
    public func run<Output: Sendable>(
        progress: ProgressHandle = .ignoring(),
        _ attempt: (Double) async throws -> (output: Output, similarity: VisualSimilarity)
    ) async throws -> Outcome<Output> {
        var outcome = Outcome<Output>(output: nil, value: nil, similarity: nil, attempts: [])
        var low = range.lowerBound
        var high = range.upperBound
        var value = high

        for index in 0..<maximumAttempts {
            try progress.checkpoint(LatheProgress(
                fraction: Double(index) / Double(maximumAttempts), stage: "search"))
            let (output, similarity) = try await attempt(value)
            let passed = similarity.meets(threshold)
            outcome.attempts.append(Attempt(value: value, similarity: similarity, passed: passed))
            if passed {
                outcome.output = output
                outcome.value = value
                outcome.similarity = similarity
                high = value
            } else {
                if index == 0 { break }
                low = value
            }
            guard high - low > 0.01 else { break }
            value = (low + high) / 2
        }
        try progress.checkpoint(LatheProgress(fraction: 1, stage: "search"))
        return outcome
    }

    /// The search for a still image held in memory.
    ///
    /// `encode` turns a quality into encoded bytes; each result is decoded
    /// and compared with `reference`, which is decoded once.
    public func still(
        reference: Data,
        progress: ProgressHandle = .ignoring(),
        encode: (Double) async throws -> Data
    ) async throws -> Outcome<Data> {
        let prepared = try VisualComparison.Reference(data: reference)
        return try await run(progress: progress) { quality in
            let data = try await encode(quality)
            return (data, try prepared.similarity(ofImageData: data))
        }
    }
}
