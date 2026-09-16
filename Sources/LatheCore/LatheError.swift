import Foundation

/// The error taxonomy for every Lathe module.
///
/// Deliberately a closed enum rather than a protocol: callers need to make
/// *routing* decisions from an error — retry elsewhere, tell the user, degrade
/// to another format — and that is only reliable if the set of cases is
/// enumerable.
///
/// `Equatable` so tests can assert on a specific case without string matching.
/// Foreign errors are carried in ``underlying(_:)``, which compares on the
/// captured description rather than on identity.
public enum LatheError: Error, Sendable, Equatable {

    // MARK: Cancellation

    /// The operation stopped because the progress callback returned `false`, or
    /// because the enclosing `Task` was cancelled.
    ///
    /// Distinct from `CancellationError` on purpose: it carries how far the work
    /// got, which is what a resumable multi-unit job needs in order to restart
    /// without redoing finished units.
    case cancelled(atUnit: UInt64?)

    // MARK: Capability

    /// The platform cannot encode this format *on this system*, as reported by a
    /// runtime capability probe.
    ///
    /// Never derived from an OS version check. See `EncodeSupport` in
    /// `LatheImage`.
    case encodeUnavailable(format: String)

    /// The platform cannot decode this format.
    case decodeUnavailable(format: String)

    /// The feature is not available in this build or on this platform.
    case unsupportedOnThisPlatform(feature: String)

    // MARK: Input / output

    /// The input could not be read, or is not what it claims to be.
    case invalidInput(reason: String)

    /// A source file could not be opened or read.
    case readFailed(path: String, reason: String)

    /// A destination could not be created or written.
    case writeFailed(path: String, reason: String)

    /// The requested parameters are self-contradictory — a resize target with a
    /// zero dimension, a quality outside `0...1`, and so on.
    case invalidConfiguration(reason: String)

    // MARK: Runtime

    /// The codec or encoder itself failed. `code` is the framework's own status
    /// where one exists.
    case encodingFailed(stage: String, code: Int32?, reason: String)

    /// Refused *before starting* because the process is too close to its memory
    /// limit to run this job. Admission control, not a crash report.
    case insufficientMemory(requiredBytes: UInt64?, availableBytes: UInt64?)

    /// Something a framework handed back that has no better home.
    case underlying(String)

    /// Wrap a foreign error without losing it.
    public static func wrapping(_ error: some Error) -> LatheError {
        if let lathe = error as? LatheError { return lathe }
        if error is CancellationError { return .cancelled(atUnit: nil) }
        let ns = error as NSError
        return .underlying("\(ns.domain) \(ns.code): \(ns.localizedDescription)")
    }
}

extension LatheError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .cancelled(unit):
            unit.map { "Cancelled after unit \($0)." } ?? "Cancelled."
        case let .encodeUnavailable(format):
            "This system cannot encode \(format). (Runtime-probed, not version-gated.)"
        case let .decodeUnavailable(format):
            "This system cannot decode \(format)."
        case let .unsupportedOnThisPlatform(feature):
            "\(feature) is not available on this platform."
        case let .invalidInput(reason):
            "Invalid input: \(reason)"
        case let .readFailed(path, reason):
            "Could not read \(path): \(reason)"
        case let .writeFailed(path, reason):
            "Could not write \(path): \(reason)"
        case let .invalidConfiguration(reason):
            "Invalid configuration: \(reason)"
        case let .encodingFailed(stage, code, reason):
            code.map { "Encoding failed during \(stage) (code \($0)): \(reason)" }
                ?? "Encoding failed during \(stage): \(reason)"
        case let .insufficientMemory(required, available):
            "Not enough memory headroom to start"
                + (required.map { " (needs ~\($0) bytes" } ?? " (needs unknown")
                + (available.map { ", \($0) available)." } ?? ", available unknown).")
        case let .underlying(message):
            message
        }
    }
}

extension LatheError {
    /// `true` for the cancellation case, so callers can suppress user-facing
    /// error reporting in one check.
    public var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }
}
