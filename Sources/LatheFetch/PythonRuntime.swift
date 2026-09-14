import Foundation
import LatheCore

// MARK: - Results

/// Whatever the executed Python printed.
public struct PythonOutput: Sendable, Equatable {
    /// Everything written to `sys.stdout` **by this call, on this thread**.
    public let standardOutput: String

    /// Everything written to `sys.stderr` by this call. Warnings live here;
    /// a traceback does not — that travels on ``PythonException/traceback``.
    public let standardError: String

    public var isEmpty: Bool { standardOutput.isEmpty && standardError.isEmpty }

    public init(standardOutput: String, standardError: String) {
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

/// The value of an evaluated expression, in the two forms that survive the
/// boundary.
///
/// Python objects are not bridged. Handing a caller a live `PyObject *` would
/// mean handing it refcount ownership, a GIL obligation, and a lifetime tied to
/// an interpreter that never shuts down — for the benefit of code that almost
/// always wants a number, a string, or a list of strings. So a value crosses as
/// its `repr()` (for a human, and always available) and its `json.dumps()` (for
/// a decoder, when the value is JSON-representable at all).
public struct PythonValue: Sendable, Equatable, CustomStringConvertible {

    /// `repr(value)`. Always present.
    public let repr: String

    /// `type(value).__name__` — `"int"`, `"list"`, `"NoneType"`.
    public let typeName: String

    /// `json.dumps(value)`, or `nil` when the value is not JSON-representable —
    /// a socket, a module, a compiled regex.
    public let jsonEncoded: String?

    public var description: String { repr }

    public init(repr: String, typeName: String, jsonEncoded: String?) {
        self.repr = repr
        self.typeName = typeName
        self.jsonEncoded = jsonEncoded
    }

    /// The JSON form as a Foundation object, with fragments allowed so a bare
    /// number or string decodes rather than failing as "not a top-level object".
    private var jsonObject: Any? {
        guard let jsonEncoded, let data = jsonEncoded.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    public var int: Int? { jsonObject as? Int }
    public var double: Double? { (jsonObject as? NSNumber)?.doubleValue }
    public var bool: Bool? { jsonObject as? Bool }
    public var string: String? { jsonObject as? String }
    public var stringArray: [String]? { jsonObject as? [String] }

    /// Decodes the JSON form into a `Decodable`.
    ///
    /// - Throws: ``PythonError/driverFailed(reason:)`` when the value had no
    ///   JSON form — which is a fact about the Python object, and worth
    ///   distinguishing from a decoding mismatch.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        guard let jsonEncoded, let data = jsonEncoded.data(using: .utf8) else {
            throw PythonError.driverFailed(
                reason: "a Python \(typeName) has no JSON representation, so it cannot be decoded as \(T.self)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// An evaluated expression: its value, plus anything it printed on the way.
public struct PythonEvaluation: Sendable, Equatable {
    public let value: PythonValue
    public let output: PythonOutput
}

// MARK: - The interpreter's own account of itself

/// What the running interpreter is, and what this platform will not let it do.
///
/// Every field is **read out of the live interpreter**, never inferred from an
/// OS version — the same rule the image capability probe follows, for the same
/// reason. Which restrictions apply to a given CPython build is not reliably
/// derivable from its version number, and an `#available` check would be a guess
/// dressed up as a fact.
public struct PythonPlatform: Sendable, Equatable {

    /// `sys.version` — the full banner, compiler included.
    public let version: String

    /// `"3.13.15"`.
    public let versionNumber: String

    /// `sys.platform` — `"darwin"` on macOS, `"ios"` on iOS.
    public let platformName: String

    /// `sys.prefix`. Should equal the layout's `PYTHONHOME`; when it does not,
    /// the environment did not take and imports are about to fail oddly.
    public let prefix: String

    /// `sys.path`, as initialised.
    public let searchPath: [String]

    /// Whether `os.fork` exists at all.
    public let hasFork: Bool

    /// Whether `os.posix_spawn` exists.
    public let hasPosixSpawn: Bool

    /// Whether `import subprocess` succeeded.
    public let subprocessIsImportable: Bool

    /// Why it did not, when it did not.
    public let subprocessImportError: String?

    /// A conservative "this interpreter can probably start a child process".
    ///
    /// Conservative because the only conclusive test is a call that either works
    /// or raises, and running one as a probe would spawn a process for no
    /// reason. **PEP 730** removes process spawning on iOS, so this is `false`
    /// there; a `false` here means no Python that shells out to a helper binary
    /// can work, however it is configured.
    public var canSpawnProcesses: Bool { hasFork && subprocessIsImportable }

    /// A block suitable for a log line at startup or a bug report — the same
    /// role `Lathe.capabilityReport` plays for the media modules.
    public var diagnosticReport: String {
        var lines = [
            "CPython \(versionNumber) — sys.platform \(platformName)",
            "  banner:        \(version.replacingOccurrences(of: "\n", with: " "))",
            "  sys.prefix:    \(prefix)",
            "  os.fork:       \(hasFork ? "present" : "absent")",
            "  os.posix_spawn:\(hasPosixSpawn ? " present" : " absent")",
            "  subprocess:    "
                + (subprocessIsImportable
                    ? "importable" : "NOT importable — \(subprocessImportError ?? "no reason given")"),
            "  process spawning: \(canSpawnProcesses ? "probably available" : "unavailable (PEP 730)")",
            "  sys.path (\(searchPath.count) entries):",
        ]
        lines += searchPath.map { "    · \($0)" }
        return lines.joined(separator: "\n")
    }
}

// MARK: - The runtime

/// An embedded CPython interpreter.
///
/// ## One per process, forever
///
/// `Py_Initialize` may be called once. `Py_Finalize` is documented as
/// re-entrant and is not reliably so in practice: third-party extension modules
/// leak static state across it, and a re-initialised interpreter has been
/// observed to crash on the second `import` of a module that was loaded before
/// the finalize. This package therefore **never finalises**, and there is no
/// `shutdown()` to call — deliberately, rather than as an omission.
///
/// The consequences are in the API rather than in a footnote:
///
/// * ``bootstrap(_:)`` is a **static** factory returning a **shared** instance.
///   Calling it again with the same layout returns the same interpreter;
///   calling it with a different one throws ``PythonError/alreadyBootstrapped(existingHome:)``
///   rather than pretending to honour it.
/// * There is no initialiser. A `PythonRuntime` cannot be created per operation,
///   held in a view model, or torn down in a `deinit`, because none of those
///   things are possible for the thing it wraps.
/// * The interpreter lives for the lifetime of the process, holding its imported
///   modules. That is a feature for the intended workload — a package like
///   `yt-dlp` takes real time to import and should be imported once.
///
/// ## Thread safety
///
/// **This type is safe to call from any thread, concurrently.** The interpreter
/// is not; the GIL is what makes the difference, and every entry point here
/// acquires it with `PyGILState_Ensure` and releases it with
/// `PyGILState_Release` around the whole of its work.
///
/// No Swift-level lock guards execution, on purpose. Serialising calls in Swift
/// as well would defeat the interpreter's own concurrency — Python releases the
/// GIL around blocking I/O, which is precisely when a second caller should be
/// allowed to run. Concurrent calls therefore genuinely interleave, which is why
/// captured output is thread-local rather than shared; see ``PythonDriver``.
///
/// ## What it is for
///
/// Running unmodified, published pure-Python packages on device. The design
/// premise is that reimplementing a large Python ecosystem in Swift is a
/// permanent maintenance liability, and running the real thing is not.
///
/// ```swift
/// let runtime = try PythonRuntime.bootstrap(.discovered())
/// print(runtime.platform.diagnosticReport)
///
/// let evaluation = try runtime.evaluate("sum(range(10))")
/// evaluation.value.int        // 45
///
/// let output = try runtime.execute("print('on device')")
/// output.standardOutput       // "on device\n"
/// ```
public final class PythonRuntime: @unchecked Sendable {

    // MARK: Configuration

    /// How the interpreter is started. Everything here is applied **before**
    /// `Py_Initialize` and cannot be changed afterwards.
    public struct Configuration: Sendable, Equatable {

        /// Where the interpreter and its standard library are.
        public var layout: PythonLayout

        /// Whether to let Python write `.pyc` files.
        ///
        /// Defaults to `false`. The bundled standard library inside an iOS
        /// application is read-only, and every import would try and fail to
        /// write beside it; on macOS it would scatter `__pycache__` through a
        /// directory this package does not own.
        public var writesBytecode: Bool = false

        /// Whether `~/.local/lib/pythonX.Y/site-packages` joins `sys.path`.
        ///
        /// Defaults to `false`. A developer's own installed packages silently
        /// changing what an application imports is a reproducibility problem,
        /// and on a device the directory does not exist at all.
        public var usesUserSitePackages: Bool = false

        /// Whether CPython installs its own `SIGINT` handler.
        ///
        /// Defaults to `false`, which is `Py_InitializeEx(0)`. An embedded
        /// interpreter that installs signal handlers takes them away from the
        /// host application — the host stops being able to handle its own
        /// interrupt, and Python's handler runs in a process whose main loop
        /// knows nothing about it.
        public var installsSignalHandlers: Bool = false

        /// The certificate authorities Python's TLS verifies against.
        ///
        /// `nil` — the default — leaves the interpreter with whatever OpenSSL
        /// was built to look for, which inside an application sandbox is
        /// nothing: every Python-side HTTPS request then fails certificate
        /// verification. That is a *safe* failure rather than a silent one, and
        /// it is why this is `nil` by default instead of quietly disabling
        /// verification.
        ///
        /// Setting it contributes `SSL_CERT_FILE` (and `REQUESTS_CA_BUNDLE`) to
        /// ``additionalEnvironment``'s mechanism, before the caller's own
        /// entries, so an explicit `additionalEnvironment["SSL_CERT_FILE"]`
        /// still wins. On a first launch, when the bundle has not been fetched
        /// yet, use ``PythonRuntime/useTrustStore(_:)`` instead — the
        /// interpreter is already running by then and cannot be restarted.
        ///
        /// - SeeAlso: ``PythonTrustStore``
        public var trustStore: PythonTrustStore?

        /// Extra environment variables to set before initialisation.
        ///
        /// For the things CPython only reads from the environment, such as
        /// `SSL_CERT_FILE`. Applied after this package's own variables, so a
        /// caller can override them knowingly.
        public var additionalEnvironment: [String: String] = [:]

        public init(layout: PythonLayout) {
            self.layout = layout
        }

        /// The layout found by ``PythonLayout/discover(bundle:)`` — the bundled
        /// interpreter if the application embedded one, otherwise the host's.
        public static func discovered(bundle: Bundle = .main) throws -> Configuration {
            Configuration(layout: try PythonLayout.discover(bundle: bundle))
        }
    }

    // MARK: Stored state

    /// The layout this interpreter was started with.
    public let layout: PythonLayout

    /// What the live interpreter reports about itself. Read once at bootstrap.
    public let platform: PythonPlatform

    private let symbols: PythonSymbols

    // MARK: The process-wide latch

    private static let latch = NSLock()
    nonisolated(unsafe) private static var instance: PythonRuntime?

    /// Serialises only the *handing over* of a call's source and arguments —
    /// never its execution. See ``call(_:mode:arguments:)``.
    private static let handoff = NSLock()

    /// The interpreter, if one has been bootstrapped in this process.
    ///
    /// Non-throwing, so a caller that merely wants to know whether the feature
    /// is on does not have to phrase the question as an error.
    public static var current: PythonRuntime? {
        latch.lock()
        defer { latch.unlock() }
        return instance
    }

    private init(layout: PythonLayout, platform: PythonPlatform, symbols: PythonSymbols) {
        self.layout = layout
        self.platform = platform
        self.symbols = symbols
    }

    // MARK: Bootstrap

    /// Starts the process's one interpreter, or returns the one already running.
    ///
    /// - Returns: the shared runtime. The same object every time, for the
    ///   lifetime of the process.
    /// - Throws: ``PythonError/interpreterUnavailable(reason:)`` when there is no
    ///   CPython to load — the ordinary state on an unconfigured machine and on
    ///   any iOS application that has not embedded `Python.framework`, and a
    ///   reason to disable a feature rather than to fail;
    ///   ``PythonError/invalidLayout(reason:)`` when the standard library is not
    ///   where the layout says, checked *before* initialising because CPython's
    ///   own response to that is `abort()`;
    ///   ``PythonError/alreadyBootstrapped(existingHome:)`` when a different
    ///   layout is already running.
    @discardableResult
    public static func bootstrap(_ configuration: Configuration) throws -> PythonRuntime {
        try configuration.layout.validate()

        latch.lock()
        defer { latch.unlock() }

        if let existing = instance {
            guard existing.layout.home == configuration.layout.home else {
                throw PythonError.alreadyBootstrapped(existingHome: existing.layout.home.path)
            }
            return existing
        }

        let symbols = try PythonSymbols.bind(loading: configuration.layout.libraryPath)

        // Somebody else may have started the interpreter — an application that
        // initialises Python itself and then wants this wrapper on top of it.
        // Re-initialising would be undefined; attaching is well defined.
        let wasAlreadyRunning = symbols.Py_IsInitialized() != 0

        if !wasAlreadyRunning {
            applyEnvironment(for: configuration)
            symbols.Py_InitializeEx(configuration.installsSignalHandlers ? 1 : 0)
            guard symbols.Py_IsInitialized() != 0 else {
                throw PythonError.bootstrapFailed(reason: "Py_InitializeEx returned without an interpreter")
            }
        }

        // Install the driver. On the path this package initialised, the calling
        // thread already holds the GIL; on the attach path it does not, and
        // PyGILState_Ensure is correct in both cases.
        let gil = symbols.PyGILState_Ensure()
        let installed = PythonDriver.source.withCString { symbols.PyRun_SimpleString($0) }
        if installed != 0 {
            symbols.PyErr_Clear()
            symbols.PyGILState_Release(gil)
            throw PythonError.bootstrapFailed(
                reason: "the Lathe Python driver failed to compile. CPython wrote the reason to "
                    + "file descriptor 2, which is the only place it can write before the driver exists."
            )
        }
        symbols.PyGILState_Release(gil)

        if !wasAlreadyRunning {
            // Py_Initialize leaves the GIL held by the initialising thread.
            // Dropping it here is what lets every later PyGILState_Ensure, from
            // any thread including this one, succeed rather than deadlock. The
            // returned thread state is intentionally discarded: it is only
            // needed by a PyEval_RestoreThread this package never performs,
            // because it never finalises.
            _ = symbols.PyEval_SaveThread()
        }

        let runtime = PythonRuntime(
            layout: configuration.layout,
            platform: try readPlatform(using: symbols),
            symbols: symbols
        )
        instance = runtime
        LatheFetchLog.python.notice("Embedded CPython started: \(runtime.platform.versionNumber, privacy: .public)")
        return runtime
    }

    /// Applies `PYTHONHOME`, `PYTHONPATH` and the rest.
    ///
    /// `setenv` rather than `PyConfig`: see the type documentation on
    /// ``PythonLayout``. These are process globals set exactly once, immediately
    /// before `Py_Initialize`, under the bootstrap latch.
    private static func applyEnvironment(for configuration: Configuration) {
        for (name, value) in environment(for: configuration) {
            setenv(name, value, 1)
        }
    }

    /// The variables ``applyEnvironment(for:)`` will set, as a value.
    ///
    /// Separated from the `setenv` loop so that what a configuration *means* can
    /// be asserted without a test mutating the process environment — which, for
    /// a process that runs one interpreter and never restarts it, would be a
    /// test with consequences for every test after it.
    static func environment(for configuration: Configuration) -> [String: String] {
        let layout = configuration.layout
        var variables: [String: String] = [
            "PYTHONHOME": layout.home.path,
            "PYTHONPATH": layout.searchPathValue,
            // Force UTF-8 and skip the locale-derived filesystem encoding
            // dance. Without this an interpreter started from a process with no
            // locale set — a launchd job, an app — picks ASCII and then fails on
            // the first non-ASCII filename.
            "PYTHONIOENCODING": "utf-8",
            "PYTHONUTF8": "1",
            "PYTHONUNBUFFERED": "1",
        ]
        if !configuration.writesBytecode { variables["PYTHONDONTWRITEBYTECODE"] = "1" }
        if !configuration.usesUserSitePackages { variables["PYTHONNOUSERSITE"] = "1" }
        if let trustStore = configuration.trustStore {
            variables.merge(trustStore.environment) { _, store in store }
        }
        variables.merge(configuration.additionalEnvironment) { _, caller in caller }
        return variables
    }

    private static func readPlatform(using symbols: PythonSymbols) throws -> PythonPlatform {
        struct Raw: Decodable {
            let version: String
            let version_info: [Int]
            let platform: String
            let prefix: String
            let path: [String]
            let has_os_fork: Bool
            let has_posix_spawn: Bool
            let subprocess_importable: Bool
            let subprocess_error: String?
        }

        let gil = symbols.PyGILState_Ensure()
        defer { symbols.PyGILState_Release(gil) }

        guard let module = symbols.PyImport_AddModule(PythonDriver.moduleName),
            let namespace = symbols.PyModule_GetDict(module)
        else {
            throw PythonError.bootstrapFailed(reason: "__main__ has no namespace")
        }

        let json = try evaluateToString(
            PythonDriver.platformExpression, in: namespace, using: symbols)
        guard let data = json.data(using: .utf8), let raw = try? JSONDecoder().decode(Raw.self, from: data) else {
            throw PythonError.bootstrapFailed(reason: "the driver's platform report was not decodable: \(json)")
        }

        return PythonPlatform(
            version: raw.version,
            versionNumber: raw.version_info.map(String.init).joined(separator: "."),
            platformName: raw.platform,
            prefix: raw.prefix,
            searchPath: raw.path,
            hasFork: raw.has_os_fork,
            hasPosixSpawn: raw.has_posix_spawn,
            subprocessIsImportable: raw.subprocess_importable,
            subprocessImportError: raw.subprocess_error
        )
    }

    // MARK: - Running Python

    /// Runs `source` as statements.
    ///
    /// - Parameters:
    ///   - source: any Python suite. Executed in `__main__`, so names defined
    ///     here are visible to later calls — that is what makes an
    ///     import-once-use-many workload possible.
    ///   - arguments: made available to the source as the dictionary
    ///     `lathe_arguments`. Values cross as JSON, so nothing in them is ever
    ///     interpolated into Python syntax and a path containing a quote is not
    ///     a code-injection bug.
    /// - Returns: whatever the source printed, captured from `sys.stdout` and
    ///   `sys.stderr` on the calling thread.
    /// - Throws: ``PythonError/raised(_:)`` carrying the full traceback.
    @discardableResult
    public func execute(_ source: String, arguments: [String: String] = [:]) throws -> PythonOutput {
        let report = try call(source, mode: .execute, arguments: arguments)
        return report.output
    }

    /// Evaluates a single expression and reads its value back.
    ///
    /// - Throws: ``PythonError/notAnExpression(source:)`` when `expression` is a
    ///   statement — `SyntaxError` from `compile(…, "eval")` is reported as that
    ///   rather than as a Python error, because it is a caller mistake about
    ///   which method to use.
    public func evaluate(_ expression: String, arguments: [String: String] = [:]) throws -> PythonEvaluation {
        let report: Report
        do {
            report = try call(expression, mode: .evaluate, arguments: arguments)
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

    /// Imports a module, and says so plainly when it cannot.
    ///
    /// A convenience with a purpose: `import` failures are the single most
    /// common way an embedded interpreter goes wrong, and routing them through
    /// one method means the diagnostic — which includes `sys.path` — is written
    /// once.
    public func importModule(_ name: String) throws {
        do {
            try execute("import \(name)")
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

    /// Takes everything printed by threads Python started for itself.
    ///
    /// Output from a call made through ``execute(_:arguments:)`` is captured per
    /// call and never appears here. Output from a worker thread inside a Python
    /// package has no call to belong to, so it accumulates in a bounded buffer
    /// until something drains it. Nothing drains it automatically: a caller that
    /// wants that logging is the one that knows where it should go.
    public func drainBackgroundOutput() throws -> PythonOutput {
        struct Drained: Decodable {
            let stdout: String
            let stderr: String
        }
        let gil = symbols.PyGILState_Ensure()
        defer { symbols.PyGILState_Release(gil) }

        guard let module = symbols.PyImport_AddModule(PythonDriver.moduleName),
            let namespace = symbols.PyModule_GetDict(module)
        else {
            throw PythonError.driverFailed(reason: "__main__ has no namespace")
        }
        let json = try Self.evaluateToString(PythonDriver.drainExpression, in: namespace, using: symbols)
        guard let data = json.data(using: .utf8), let drained = try? JSONDecoder().decode(Drained.self, from: data)
        else {
            throw PythonError.driverFailed(reason: "the drain report was not decodable")
        }
        return PythonOutput(standardOutput: drained.stdout, standardError: drained.stderr)
    }

    // MARK: - The bridge

    struct Report: Decodable {
        let ok: Bool
        let repr: String?
        let type: String?
        let json: String?
        let stdout: String
        let stderr: String
        let excType: String?
        let excMessage: String?
        let traceback: String?
        let restricted: Bool?

        var output: PythonOutput { PythonOutput(standardOutput: stdout, standardError: stderr) }

        enum CodingKeys: String, CodingKey {
            case ok, repr, type, json, stdout, stderr, traceback, restricted
            case excType = "exc_type"
            case excMessage = "exc_message"
        }
    }

    /// The one place the GIL is taken, and the one place anything crosses.
    ///
    /// - Parameter callID: an identifier the driver registers against the
    ///   running thread, so ``cancel(callID:)`` can reach it. `nil` for the
    ///   synchronous surface, which has no `Task` to be cancelled and should not
    ///   pay for the bookkeeping.
    func call(
        _ source: String, mode: PythonDriver.Mode, arguments: [String: String], callID: Int? = nil
    ) throws -> Report {
        var request: [String: Any] = ["source": source, "mode": mode.rawValue, "arguments": arguments]
        if let callID { request["id"] = callID }
        guard let data = try? JSONSerialization.data(withJSONObject: request),
            let requestJSON = String(data: data, encoding: .utf8)
        else {
            throw PythonError.driverFailed(reason: "the call could not be encoded as JSON")
        }

        // Lock order is *always* handoff then GIL, and the handoff is never
        // taken while holding the GIL. That is what keeps this from deadlocking
        // against a caller already running Python: a thread inside user code
        // holds the GIL and wants nothing else.
        Self.handoff.lock()
        var handoffHeld = true
        func releaseHandoff() {
            if handoffHeld {
                handoffHeld = false
                Self.handoff.unlock()
            }
        }
        defer { releaseHandoff() }

        // Ensure/Release around the *whole* of the work, including reading the
        // result string back: PyUnicode_AsUTF8AndSize returns a pointer into the
        // object's own storage, which is only valid while the GIL is held and
        // the object is alive.
        let gil = symbols.PyGILState_Ensure()
        defer { symbols.PyGILState_Release(gil) }

        guard let module = symbols.PyImport_AddModule(PythonDriver.moduleName),
            let namespace = symbols.PyModule_GetDict(module)
        else {
            throw PythonError.driverFailed(reason: "__main__ has no namespace")
        }

        // Publish the request and have the driver take it into thread-local
        // storage, both under the handoff lock. The interpreter may drop the
        // GIL between any two bytecodes, so without this a second caller could
        // overwrite the global between this write and the driver's read.
        try setGlobal(PythonDriver.requestGlobal, to: requestJSON, in: namespace)
        _ = try Self.evaluateToString(PythonDriver.acceptExpression, in: namespace, using: symbols)
        releaseHandoff()

        // From here on nothing shared is in play, so callers run concurrently —
        // which is the point of not holding a Swift lock across execution.
        let json = try Self.evaluateToString(PythonDriver.runExpression, in: namespace, using: symbols)

        guard let data = json.data(using: .utf8), let report = try? JSONDecoder().decode(Report.self, from: data)
        else {
            throw PythonError.driverFailed(reason: "the driver returned undecodable JSON: \(json.prefix(512))")
        }

        guard report.ok else {
            throw PythonError.raised(
                PythonException(
                    type: report.excType ?? "Exception",
                    message: report.excMessage ?? "",
                    traceback: report.traceback ?? "",
                    standardOutput: report.stdout,
                    standardError: report.stderr,
                    isPlatformRestriction: report.restricted ?? false
                ))
        }
        return report
    }

    /// Asks the driver to interrupt an in-flight call.
    ///
    /// Best effort by construction, and silent by design: everything that can
    /// go wrong here — the call already finished, the driver has no `ctypes`,
    /// the thread is inside a C extension — means "it did not stop", and the
    /// caller already handles that case because it is the ordinary one.
    ///
    /// Taking the GIL is what makes this *arrive*: acquiring it means waiting
    /// for the running call to reach a bytecode boundary and drop it, which is
    /// the same boundary the interrupt will be raised at. It is also why this
    /// must never be called from the thread running the call it is cancelling,
    /// and why ``PythonRuntime/workQueue`` and the cancellation queue are
    /// separate.
    func requestCancellation(of callID: Int) {
        let gil = symbols.PyGILState_Ensure()
        defer { symbols.PyGILState_Release(gil) }
        guard let module = symbols.PyImport_AddModule(PythonDriver.moduleName),
            let namespace = symbols.PyModule_GetDict(module)
        else { return }
        _ = try? Self.evaluateToString(
            PythonDriver.cancelExpression(callID: callID), in: namespace, using: symbols)
    }

    /// Binds a Swift string to a Python global.
    ///
    /// Length-explicit rather than NUL-terminated, so a source file containing a
    /// literal NUL is rejected by Python's compiler rather than silently
    /// truncated here.
    private func setGlobal(_ name: String, to text: String, in namespace: UnsafeMutableRawPointer) throws {
        let bytes = Array(text.utf8CString)
        let object = bytes.withUnsafeBufferPointer {
            symbols.PyUnicode_FromStringAndSize($0.baseAddress, $0.count - 1)
        }
        guard let object else {
            symbols.PyErr_Clear()
            throw PythonError.driverFailed(reason: "could not create a Python str for \(name)")
        }
        defer { symbols.Py_DecRef(object) }
        guard name.withCString({ symbols.PyDict_SetItemString(namespace, $0, object) }) == 0 else {
            symbols.PyErr_Clear()
            throw PythonError.driverFailed(reason: "could not bind \(name) in __main__")
        }
    }

    /// Evaluates an expression that the driver guarantees returns a `str`.
    ///
    /// Static because bootstrap needs it before a `PythonRuntime` exists. The
    /// caller must already hold the GIL.
    private static func evaluateToString(
        _ expression: String,
        in namespace: UnsafeMutableRawPointer,
        using symbols: PythonSymbols
    ) throws -> String {
        let result = expression.withCString {
            symbols.PyRun_String($0, PythonSymbols.evalInput, namespace, namespace)
        }
        guard let result else {
            // The driver catches everything, so a NULL here means the driver
            // itself is missing or broken — not that the caller's Python raised.
            symbols.PyErr_Clear()
            throw PythonError.driverFailed(reason: "\(expression) raised out of the driver")
        }
        defer { symbols.Py_DecRef(result) }

        var length = 0
        guard let cString = symbols.PyUnicode_AsUTF8AndSize(result, &length) else {
            symbols.PyErr_Clear()
            throw PythonError.driverFailed(reason: "\(expression) did not return a str")
        }
        return String(decoding: UnsafeRawBufferPointer(start: cString, count: length), as: UTF8.self)
    }
}
