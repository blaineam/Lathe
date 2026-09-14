import Foundation
import JavaScriptCore
import LatheCore

/// Runs a self-contained JavaScript program and hands back what it printed.
///
/// ## What this is for
///
/// Since late 2025, `yt-dlp` solves YouTube's player challenges — the `n`
/// parameter and the signature cipher — by running a JavaScript program in an
/// **external runtime**: `deno`, `node`, `bun` or `quickjs`, discovered on
/// `PATH` and started as a **subprocess**. PEP 730 removes process spawning on
/// iOS, so all four are unavailable, and a `yt-dlp` with no JavaScript runtime
/// cannot produce a playable URL for any YouTube client whose formats are
/// signature-protected.
///
/// `JavaScriptCore` is a system framework on both platforms, needs no
/// subprocess, no download and no entitlement, and is the same engine Safari
/// runs. The program `yt-dlp` wants executed is an ordinary self-contained
/// script — it declares its own browser stubs and its only output channel is
/// `console.log` — so "run it in a `JSContext` and capture `console.log`" is
/// the whole of what a runtime has to do.
///
/// ## The JIT, and the number
///
/// An ordinary application does not get the JavaScriptCore JIT on iOS: the
/// dynamic-codesigning entitlement it needs is not available outside the
/// system's own web content process. So this runs **interpreter-only** there,
/// and it is worth knowing what that costs rather than assuming.
///
/// Measured against `yt-dlp` 2026.8.19's solver, a ~3.0 MB YouTube player and a
/// batch of three `n` challenges plus one signature challenge, on an Apple
/// silicon Mac:
///
/// | | |
/// |---|---|
/// | JIT enabled | **≈0.24 s** |
/// | interpreter only | **≈1.6 s** |
///
/// Seven times slower, and still fine: this runs **once per player per
/// session**, `yt-dlp` batches every challenge for an item into a single
/// solve, and 1.6 s of one-off setup is not what a download's duration is made
/// of. A phone's core is slower than a Mac's, so budget a few seconds rather
/// than one — but the conclusion does not change. Interpreter-only
/// JavaScriptCore is a viable signature solver; ``benchmark(_:iterations:)``
/// is here so that claim can be re-checked on a real device rather than
/// inherited from this table.
///
/// ## Isolation
///
/// A fresh `JSContext` per evaluation. The program being run is a 3 MB script
/// downloaded from YouTube minutes ago, wrapped in a solver from a package
/// index: it gets no access to anything, keeps no state between calls, and is
/// released the moment the call returns. A long-lived context would be faster
/// on the second call and is not worth what it would retain.
public enum JavaScriptEngine {

    /// What one evaluation produced.
    public struct Evaluation: Sendable, Equatable {
        /// Everything the program passed to `console.log`, newline-joined.
        /// This is the result channel: the solver's last statement is a
        /// `console.log` of its JSON answer.
        public let output: String

        /// Everything it passed to `console.warn` or `console.error`.
        public let diagnostics: String

        /// The uncaught exception's message, when one escaped.
        public let exception: String?

        /// Wall-clock seconds spent inside `evaluateScript`, parse included.
        public let duration: TimeInterval

        public var succeeded: Bool { exception == nil }
    }

    /// Whether this process has a usable JavaScript engine.
    ///
    /// Always `true` in practice — `JavaScriptCore` is a system framework on
    /// every platform this package supports. It exists as a probe rather than
    /// as a constant so that "can this device solve YouTube challenges?" is
    /// answered the same way every other capability question in this package
    /// is: by trying it, not by checking a version.
    public static var isAvailable: Bool {
        (try? evaluate("1 + 1").output) != nil
    }

    /// Evaluates `program` and returns what it printed.
    ///
    /// Never throws on a JavaScript error — an exception is *data* in
    /// ``Evaluation/exception``, in the same way the Python driver treats a
    /// raised Python exception as data. The caller here is a `yt-dlp` provider
    /// that has to turn a failure into a rejected challenge rather than a
    /// crash, and a thrown Swift error would only have to be caught and
    /// converted back.
    ///
    /// - Throws: ``MediaFetchError/runtimeFailed(reason:)`` only when a
    ///   `JSContext` could not be created at all, which is not a thing that
    ///   happens outside of memory exhaustion.
    public static func evaluate(_ program: String) throws -> Evaluation {
        guard let context = JSContext() else {
            throw MediaFetchError.runtimeFailed(reason: "JavaScriptCore would not create a context")
        }

        let sink = OutputSink()

        var thrown: String?
        context.exceptionHandler = { _, value in
            thrown = value.map(Self.describe) ?? "an unnamed JavaScript exception"
        }

        // The solver's only output channel. `warn`, `error`, `info` and `debug`
        // are installed too, not for their output but because a bare context
        // has no `console` at all and an incidental `console.warn` inside three
        // megabytes of someone else's minified JavaScript would otherwise abort
        // the whole program with a TypeError.
        let log: @convention(block) (JSValue?) -> Void = { value in
            sink.appendOutput(value.map(Self.describe) ?? "undefined")
        }
        let note: @convention(block) (JSValue?) -> Void = { value in
            sink.appendDiagnostic(value.map(Self.describe) ?? "undefined")
        }

        let console = JSValue(newObjectIn: context)
        console?.setObject(log, forKeyedSubscript: "log" as NSString)
        console?.setObject(note, forKeyedSubscript: "warn" as NSString)
        console?.setObject(note, forKeyedSubscript: "error" as NSString)
        console?.setObject(note, forKeyedSubscript: "info" as NSString)
        console?.setObject(note, forKeyedSubscript: "debug" as NSString)
        context.setObject(console, forKeyedSubscript: "console" as NSString)

        let started = Date.timeIntervalSinceReferenceDate
        context.evaluateScript(program)
        let duration = Date.timeIntervalSinceReferenceDate - started

        return Evaluation(
            output: sink.output,
            diagnostics: sink.diagnostics,
            exception: thrown,
            duration: duration
        )
    }

    /// Runs `program` several times and reports the timings.
    ///
    /// For answering "how slow is interpreter-only JavaScriptCore on *this*
    /// device" with a measurement rather than with the table above. The first
    /// iteration is reported separately because it is the only one that pays
    /// for a cold framework.
    public static func benchmark(_ program: String, iterations: Int = 3) throws -> [TimeInterval] {
        try (0..<max(1, iterations)).map { _ in try evaluate(program).duration }
    }

    /// `String(describing:)` for a `JSValue`, without tripping over `undefined`.
    private static func describe(_ value: JSValue) -> String {
        if value.isUndefined { return "undefined" }
        if value.isNull { return "null" }
        return value.toString() ?? "undefined"
    }

    /// Accumulates what the program printed.
    ///
    /// A class with a lock rather than captured `var`s: the blocks installed on
    /// the context are `@convention(block)` and therefore escaping, and Swift 6
    /// will not let them mutate locals. The lock is not for concurrency — one
    /// context runs on one thread — it is what makes the class legitimately
    /// `Sendable`.
    private final class OutputSink: @unchecked Sendable {
        private let lock = NSLock()
        private var outputLines: [String] = []
        private var diagnosticLines: [String] = []

        func appendOutput(_ line: String) {
            lock.lock(); outputLines.append(line); lock.unlock()
        }
        func appendDiagnostic(_ line: String) {
            lock.lock(); diagnosticLines.append(line); lock.unlock()
        }
        var output: String {
            lock.lock(); defer { lock.unlock() }
            return outputLines.joined(separator: "\n")
        }
        var diagnostics: String {
            lock.lock(); defer { lock.unlock() }
            return diagnosticLines.joined(separator: "\n")
        }
    }
}

// MARK: - The call Python makes

/// The C entry points the in-interpreter `yt-dlp` provider calls through
/// `ctypes`.
///
/// ## Why a raw function pointer, and not a symbol name
///
/// The obvious route is `ctypes.CDLL(None)` plus `dlsym` on an `@_cdecl`
/// symbol. It is fragile in exactly the situations this package ships into: a
/// static library linked into an application can have an unreferenced `@_cdecl`
/// symbol dead-stripped, and whether the main executable exports its symbols to
/// `dlsym(RTLD_DEFAULT, …)` at all depends on link flags the package does not
/// control.
///
/// So no symbol is looked up. Swift takes the **address** of its own function
/// and passes it to Python as an integer, and Python rebuilds a callable from
/// that address with `ctypes.CFUNCTYPE`. Taking the address is itself the
/// reference that keeps the linker from stripping it, and nothing about the
/// host application's link configuration can break it.
///
/// ## Ownership across the boundary
///
/// The evaluate function returns a `malloc`-ed NUL-terminated UTF-8 buffer that
/// **the caller must free** with ``freeAddress``'s function. Python copies the
/// bytes with `ctypes.string_at` and frees in a `finally`. Returning a
/// `strdup`-ed buffer rather than a pointer into a Swift `String` is the
/// difference between a defined lifetime and a use-after-free: a Swift string's
/// storage can be released the instant the function returns.
///
/// ## The GIL
///
/// `ctypes.CFUNCTYPE` releases the GIL for the duration of the call, which is
/// correct here and worth being deliberate about: nothing below touches the
/// Python C API, so holding it would only block the interpreter for the second
/// or two the evaluation takes.
enum JavaScriptBridge {

    /// The C function `yt-dlp`'s provider calls. Takes a UTF-8 JavaScript
    /// program, returns `malloc`-ed UTF-8 JSON.
    ///
    /// Never returns `NULL` except on allocation failure, and never lets an
    /// error escape as anything but a field in the JSON — a Swift error
    /// unwinding into a C caller inside CPython is undefined behaviour.
    private static let evaluateFunction: @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = {
        program in
        let source = program.map { String(cString: $0) } ?? ""
        let payload: [String: Any]
        do {
            let evaluation = try JavaScriptEngine.evaluate(source)
            payload = [
                "ok": evaluation.succeeded,
                "stdout": evaluation.output,
                "stderr": evaluation.diagnostics,
                "error": evaluation.exception ?? "",
                "duration": evaluation.duration,
            ]
        } catch {
            payload = [
                "ok": false, "stdout": "", "stderr": "",
                "error": (error as NSError).localizedDescription, "duration": 0,
            ]
        }
        let json =
            (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? #"{"ok":false,"stdout":"","stderr":"","error":"the result could not be encoded","duration":0}"#
        return UnsafeMutableRawPointer(strdup(json))
    }

    /// Frees what ``evaluateFunction`` returned.
    private static let freeFunction: @convention(c) (UnsafeMutableRawPointer?) -> Void = { pointer in
        free(pointer)
    }

    /// The evaluate function's address, as a decimal string.
    ///
    /// A string because it crosses on ``PythonRuntime``'s `arguments`
    /// dictionary, which is `[String: String]` — the same channel every other
    /// value in this package takes, and the reason nothing is ever interpolated
    /// into Python source.
    static var evaluateAddress: String {
        String(UInt(bitPattern: unsafeBitCast(evaluateFunction, to: UnsafeRawPointer.self)))
    }

    /// The free function's address, as a decimal string.
    static var freeAddress: String {
        String(UInt(bitPattern: unsafeBitCast(freeFunction, to: UnsafeRawPointer.self)))
    }
}
