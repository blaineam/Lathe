import Foundation
import Testing

@testable import LatheFetch

/// The one interpreter the suite runs against.
///
/// `Py_Initialize` happens once per **process**, and a Swift Testing run is one
/// process, so the interpreter is bootstrapped once here and shared by every
/// test — which also makes the suite an honest exercise of the shared-runtime
/// design rather than a workaround for it.
///
/// A machine with no CPython is a normal state, not a failure: this package
/// builds, ships and tests everything else without one. Tests that need an
/// interpreter are therefore gated on ``isAvailable`` and skip cleanly, and one
/// always-running test reports *why* it was unavailable so a red-free run on a
/// bare machine still says what it did not cover.
enum SharedInterpreter {

    struct Outcome: Sendable {
        let runtime: PythonRuntime?
        let reason: String?
    }

    /// Bootstrapped on first touch. `static let` is the latch.
    static let outcome: Outcome = {
        do {
            let runtime = try PythonRuntime.bootstrap(.discovered())
            return Outcome(runtime: runtime, reason: nil)
        } catch {
            return Outcome(runtime: nil, reason: error.localizedDescription)
        }
    }()

    static var isAvailable: Bool { outcome.runtime != nil }

    /// The runtime, or `nil` after recording a known issue naming the reason.
    ///
    /// The same shape the media suites use for a fixture that cannot be
    /// generated: a machine that cannot run the test should not report a green
    /// tick, and should not report a failure that looks like a bug in the code
    /// under test either.
    static func runtimeOrKnownIssue() -> PythonRuntime? {
        if let runtime = outcome.runtime { return runtime }
        withKnownIssue("no CPython on this machine: \(outcome.reason ?? "unknown")") {
            Issue.record("the embedded interpreter is unavailable")
        }
        return nil
    }

    /// Whether the opt-in network tests should run.
    ///
    /// Off by default. A default test run that reaches PyPI is a test run that
    /// fails on an aeroplane, fails behind a proxy, and fails when somebody
    /// else's release breaks — none of which is a fact about this package.
    static var networkTestsEnabled: Bool {
        ProcessInfo.processInfo.environment["LATHE_FETCH_NETWORK_TESTS"] == "1"
    }
}
