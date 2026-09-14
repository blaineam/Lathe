import Foundation

/// Everything that can go wrong between "there might be a CPython here" and "the
/// expression evaluated".
///
/// Deliberately a closed enum, for the same reason `LatheError` is one: a caller
/// needs to *route* on the answer. "No interpreter on this system" is a
/// configuration problem the host application can fix; a raised Python exception
/// is the user's script being wrong; a missing symbol means the loaded library
/// is not the CPython this code was written against. Those three want three
/// different responses and a string cannot carry the distinction.
public enum PythonError: Error, Sendable, Equatable {

    // MARK: Acquisition

    /// No CPython dynamic library could be found or loaded.
    ///
    /// This is the *expected* state on a machine that has not been set up, and
    /// on any iOS app that has not embedded `Python.framework`. It is a reason
    /// to disable a feature, not a reason to crash. See
    /// ``PythonLayout/discover(searching:)`` and `Sources/LatheFetch/VENDORING.md`.
    case interpreterUnavailable(reason: String)

    /// The library loaded, but does not export a function this wrapper needs.
    ///
    /// Means the dylib is not a CPython 3.9+ build, or is a stripped/partial
    /// one. The name is included because the *first* missing symbol is the
    /// diagnostic — it says how far off the build is.
    case symbolMissing(name: String, library: String)

    /// `PYTHONHOME` does not look like a Python installation.
    ///
    /// Checked **before** `Py_Initialize`, on purpose. CPython's response to an
    /// unfindable stdlib is `Py_FatalError` — it writes to stderr and calls
    /// `abort()`, which on a device is a crash report and not an error anyone
    /// can catch. Validating the layout first turns that crash into this value.
    case invalidLayout(reason: String)

    // MARK: Lifecycle

    /// ``PythonRuntime/bootstrap(_:)`` was called a second time with a different
    /// configuration.
    ///
    /// There is exactly one interpreter per process and it is never torn down;
    /// see the type-level documentation on ``PythonRuntime``. The already-live
    /// configuration is reported so the caller can see which one won.
    case alreadyBootstrapped(existingHome: String)

    /// `Py_Initialize` returned, but the interpreter did not come up, or the
    /// in-process Python driver failed to install.
    case bootstrapFailed(reason: String)

    // MARK: Execution

    /// Python raised. Carries the formatted traceback.
    case raised(PythonException)

    /// The Swift↔Python driver itself misbehaved — it returned a non-string, or
    /// emitted JSON this module could not decode.
    ///
    /// Always a bug in this package rather than in the caller's Python.
    case driverFailed(reason: String)

    /// ``PythonRuntime/evaluate(_:arguments:)`` was given something that is a
    /// statement, not an expression, and so produced no value.
    case notAnExpression(source: String)
}

extension PythonError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .interpreterUnavailable(reason):
            "No embedded CPython is available: \(reason)"
        case let .symbolMissing(name, library):
            "\(library) does not export \(name); it is not a CPython 3.9+ runtime library."
        case let .invalidLayout(reason):
            "The Python layout is not usable: \(reason)"
        case let .alreadyBootstrapped(home):
            "A Python interpreter is already running in this process (PYTHONHOME=\(home)). "
                + "There is one interpreter per process and it cannot be replaced."
        case let .bootstrapFailed(reason):
            "The Python interpreter failed to start: \(reason)"
        case let .raised(exception):
            exception.description
        case let .driverFailed(reason):
            "The Lathe Python driver failed: \(reason)"
        case let .notAnExpression(source):
            "Not an expression, so it has no value to read back: \(source)"
        }
    }
}

// MARK: - A raised Python exception

/// A Python exception, carried across into Swift with its traceback intact.
///
/// The traceback is the whole point. A `case failed` with no detail is useless
/// against a 30,000-line third-party Python package: the only actionable thing
/// is the frame list, and it is free to carry.
public struct PythonException: Error, Sendable, Equatable, CustomStringConvertible {

    /// The exception class name — `"ZeroDivisionError"`, `"HTTPError"`.
    public let type: String

    /// `str(exception)`.
    public let message: String

    /// The full formatted traceback, exactly as `traceback.format_exc()` would
    /// print it, minus this module's own driver frame.
    public let traceback: String

    /// Anything the failing code printed before it raised.
    public let standardOutput: String

    /// Anything it wrote to `sys.stderr` before it raised. Distinct from
    /// ``traceback``: warnings land here, the traceback does not.
    public let standardError: String

    /// `true` when the exception is one of the platform restrictions described
    /// by **PEP 730** (Python on iOS) rather than a fault in the Python code.
    ///
    /// On iOS the kernel does not permit a process to spawn another, so
    /// `os.fork`, `os.forkpty` and the whole `subprocess` module raise. A great
    /// deal of published Python assumes otherwise — it shells out to `ffmpeg`,
    /// to `curl`, to itself — and the resulting `OSError` looks like a bug in
    /// the caller's own code until somebody knows to expect it.
    ///
    /// **Nothing here shims those call sites.** This flag exists so the failure
    /// is legible, not so it can be ignored: a caller that hits it needs to
    /// replace the call, not retry it.
    public let isPlatformRestriction: Bool

    public init(
        type: String,
        message: String,
        traceback: String,
        standardOutput: String = "",
        standardError: String = "",
        isPlatformRestriction: Bool = false
    ) {
        self.type = type
        self.message = message
        self.traceback = traceback
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.isPlatformRestriction = isPlatformRestriction
    }

    public var description: String {
        var text = "\(type): \(message)"
        if isPlatformRestriction {
            text += "\n\nThis is a platform restriction, not a defect in the Python code. "
                + "iOS does not allow a process to spawn another (PEP 730), so os.fork, "
                + "os.forkpty and subprocess raise. The call site has to be replaced; "
                + "retrying it will not help."
        }
        if !traceback.isEmpty {
            text += "\n\n" + traceback
        }
        if !standardError.isEmpty {
            text += "\nstderr:\n" + standardError
        }
        return text
    }
}
