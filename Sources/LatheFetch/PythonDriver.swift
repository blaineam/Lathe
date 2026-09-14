import Foundation

/// The Python half of the bridge.
///
/// This module keeps its C surface to fifteen symbols (see ``PythonSymbols``) by
/// pushing everything that would need more of the C API down into Python. That
/// is what this source is: a small, fixed, audited module that is compiled once
/// at bootstrap and then called with a string in and a JSON string out.
///
/// Three jobs, none of which is pleasant from C:
///
/// 1. **Output capture.** `sys.stdout` and `sys.stderr` are replaced with
///    objects that append into a **thread-local** buffer. Thread-local rather
///    than global because ``PythonRuntime`` is callable from any thread and two
///    concurrent calls must not harvest each other's output — the GIL serialises
///    bytecode, not whole calls, so their prints genuinely do interleave.
/// 2. **Traceback formatting.** `traceback.format_exception` produces exactly
///    what a Python programmer expects to read. Reconstructing that from
///    `PyErr_Fetch`, `PyErr_NormalizeException` and `PyException_GetTraceback`
///    would be thirty lines of refcount-critical C, and CPython renamed half of
///    those functions in 3.12.
/// 3. **Value read-back.** `repr()` for humans, `json.dumps()` for Swift.
///
/// The driver never lets an exception escape into C. Every entry point returns a
/// JSON string; a raised exception is *data* in that string, not a set error
/// indicator. That means the Swift side does not have to be correct about
/// CPython's error state in order to be safe.
enum PythonDriver {

    /// The module name the driver installs itself under, and the namespace user
    /// code executes in.
    ///
    /// `__main__` is deliberate: it is what a Python programmer expects
    /// module-level code to run in, and packages that check
    /// `if __name__ == "__main__"` behave the way they read.
    static let moduleName = "__main__"

    /// The global ``PythonRuntime`` writes one call's request into, as JSON.
    ///
    /// Passing source text through a variable rather than by interpolating it
    /// into a call expression is a correctness requirement, not tidiness: source
    /// contains quotes, backslashes and newlines, and any escaping scheme this
    /// side invented would eventually disagree with Python's lexer. A
    /// `PyUnicode_FromStringAndSize` of the raw UTF-8 bytes cannot.
    static let requestGlobal = "_lathe_request"

    /// Evaluated to move the pending request out of the shared global and into
    /// the calling thread. Short, and runs no caller code.
    ///
    /// This exists because ``requestGlobal`` is a *module global* and the
    /// interpreter is genuinely concurrent: the eval loop can drop the GIL
    /// between any two bytecodes, so a second caller could rebind that global
    /// between the first caller's write and its read. Moving it to thread-local
    /// storage the instant the interpreter is entered closes that window; see
    /// the handoff lock in ``PythonRuntime``.
    static let acceptExpression = "_lathe_accept()"

    /// Evaluated to run the accepted request. This is the long part, and by the
    /// time it starts nothing shared is left to race over.
    static let runExpression = "_lathe_run()"

    /// Evaluated to take everything Python's own threads have printed.
    static let drainExpression = "_lathe_drain()"

    /// Evaluated to describe the interpreter and its platform restrictions.
    static let platformExpression = "_lathe_platform()"

    /// Evaluated to ask an in-flight call to stop.
    ///
    /// The one expression here that is built rather than fixed. The argument is
    /// an integer this package generated and never anything a caller supplied,
    /// which is what keeps "build a source string" from being the injection it
    /// usually is.
    static func cancelExpression(callID: Int) -> String { "_lathe_cancel(\(callID))" }

    enum Mode: String {
        /// `exec` — statements. No value.
        case execute = "exec"
        /// `eval` — a single expression, whose value is returned.
        case evaluate = "eval"
    }

    /// Compiled by `PyRun_SimpleString` immediately after `Py_InitializeEx`.
    ///
    /// Everything in here is standard library, and all of it is
    /// import-at-bootstrap on purpose: an import that first runs three hours
    /// later, on a device, inside someone else's stack trace, is an import that
    /// fails at the worst possible moment.
    static let source = #"""
        # Lathe's embedded Python driver. Installed once per process by
        # LatheFetch's PythonRuntime; not intended to be imported by hand.
        import io
        import json
        import sys
        import threading
        import traceback

        _LATHE_LOCAL = threading.local()

        # Output from threads Python started itself — a package's own download
        # workers, say — has no Swift call to be harvested by, so it lands here.
        # Bounded, because an unattended loop printing forever must not become a
        # memory leak: the oldest chunks are dropped, which is the right end to
        # lose when the buffer is a debugging aid.
        _LATHE_SHARED = []
        _LATHE_SHARED_LIMIT = 4096

        # Cancellation state. `_LATHE_INFLIGHT` maps a call id to the thread
        # running it; `_LATHE_CANCELLED` holds ids whose cancellation arrived
        # before the call reached the interpreter, which is a real race when a
        # Task is cancelled the instant after it is created.
        #
        # The set is capped because an id that is cancelled but never runs is
        # never removed, and an unbounded set of integers in a process that runs
        # for days is a leak. Dropping the oldest entries loses only cancels for
        # calls that have not started in the last several hundred calls, which
        # is not a state that occurs.
        _LATHE_INFLIGHT = {}
        _LATHE_CANCELLED = set()
        _LATHE_CANCEL_LIMIT = 512
        _LATHE_CANCEL_LOCK = threading.Lock()


        class _LatheBinaryStream:
            """The `.buffer` a text stream is expected to have.

            Python that writes bytes straight to `sys.stdout.buffer` is common
            enough in packages that stream binary output, and a missing
            attribute there surfaces as a baffling AttributeError rather than as
            the missing feature it is.
            """

            def __init__(self, text_stream):
                self._text = text_stream

            def writable(self):
                return True

            def write(self, data):
                self._text.write(bytes(data).decode("utf-8", "replace"))
                return len(data)

            def flush(self):
                pass


        class _LatheStream(io.TextIOBase):
            def __init__(self, channel):
                self._channel = channel
                self._buffer = _LatheBinaryStream(self)

            @property
            def buffer(self):
                return self._buffer

            @property
            def encoding(self):
                return "utf-8"

            @property
            def errors(self):
                return "replace"

            def writable(self):
                return True

            def isatty(self):
                # False, and not merely because there is no terminal: a great
                # deal of Python turns on ANSI colour and carriage-return
                # progress redraw when this says True, and neither survives
                # being read back as a string.
                return False

            def write(self, text):
                if not isinstance(text, str):
                    text = str(text)
                buffer = getattr(_LATHE_LOCAL, "buffer", None)
                if buffer is None:
                    _LATHE_SHARED.append((self._channel, text))
                    excess = len(_LATHE_SHARED) - _LATHE_SHARED_LIMIT
                    if excess > 0:
                        del _LATHE_SHARED[:excess]
                else:
                    buffer.append((self._channel, text))
                return len(text)

            def flush(self):
                pass


        sys.stdout = _LatheStream("out")
        sys.stderr = _LatheStream("err")


        def _lathe_join(chunks, channel):
            return "".join(text for kind, text in chunks if kind == channel)


        def _lathe_is_platform_restriction(exc, formatted):
            """True for PEP 730's iOS process-spawning restrictions.

            Nothing here works around them. The flag exists so the failure reads
            as "this platform cannot do that" instead of as a defect in the
            Python being run, which is what an unadorned OSError looks like.
            """
            if type(exc).__module__ == "subprocess":
                return True
            name = getattr(exc, "name", None)
            if isinstance(exc, ImportError) and name in (
                "subprocess",
                "_posixsubprocess",
                "multiprocessing",
                "_multiprocessing",
            ):
                return True
            if isinstance(exc, OSError):
                text = str(exc).lower()
                if "fork" in text or "posix_spawn" in text:
                    return True
                if "not supported" in text and "subprocess" in formatted:
                    return True
            return False


        class _LatheArguments:
            """The `lathe_arguments` a caller's source reads.

            A live view of the *calling thread's* arguments rather than a plain
            dict, for the same reason output capture is thread-local: two
            concurrent calls share this namespace, and a dict rebound on each
            call is a dict the other caller can have replaced mid-run.
            """

            def _current(self):
                request = getattr(_LATHE_LOCAL, "request", None)
                return (request or {}).get("arguments") or {}

            def __getitem__(self, key):
                return self._current()[key]

            def __contains__(self, key):
                return key in self._current()

            def __iter__(self):
                return iter(self._current())

            def __len__(self):
                return len(self._current())

            def __repr__(self):
                return repr(self._current())

            def get(self, key, default=None):
                return self._current().get(key, default)

            def keys(self):
                return self._current().keys()

            def values(self):
                return self._current().values()

            def items(self):
                return self._current().items()


        lathe_arguments = _LatheArguments()

        _lathe_request = ""


        def _lathe_accept():
            """Move the pending request into this thread, and clear the global.

            Deliberately trivial: it runs no caller code, so the window in which
            the shared global matters is a handful of bytecodes long. Everything
            after this reads thread-local state.
            """
            global _lathe_request
            request = json.loads(_lathe_request)
            _LATHE_LOCAL.request = request
            _lathe_request = ""
            call_id = request.get("id")
            if call_id is not None:
                # Registered here rather than in `_lathe_run` because this is
                # the earliest point at which the call has a thread, and a
                # cancellation arriving between the two would otherwise find
                # nothing to interrupt.
                with _LATHE_CANCEL_LOCK:
                    _LATHE_INFLIGHT[call_id] = threading.get_ident()
            return ""


        def _lathe_cancel(call_id):
            """Ask an in-flight call to stop, and say whether it was delivered.

            `PyThreadState_SetAsyncExc` sets a pending exception on one specific
            thread; the interpreter raises it at that thread's next bytecode
            boundary. `PyErr_SetInterrupt` is the better-known spelling and is
            the wrong one here: it raises in the *main* thread, and these calls
            never run there.

            It is cooperative, and the limits are real rather than theoretical.
            A thread inside a C extension that is blocked in a syscall executes
            no bytecode, so nothing is raised until it comes back; a bare
            `try/except BaseException` in the package being run swallows the
            KeyboardInterrupt the same way it swallows a user's ^C. Neither is
            fixable from here, and both are documented rather than papered over.
            """
            with _LATHE_CANCEL_LOCK:
                thread_id = _LATHE_INFLIGHT.get(call_id)
                if len(_LATHE_CANCELLED) >= _LATHE_CANCEL_LIMIT:
                    _LATHE_CANCELLED.clear()
                _LATHE_CANCELLED.add(call_id)

            if thread_id is None:
                # Not started yet, or already finished. The flag above covers
                # the first case; the second needs nothing.
                return json.dumps({"delivered": False, "reason": "the call is not running"})

            try:
                import ctypes
            except BaseException as exc:  # noqa: BLE001
                return json.dumps(
                    {"delivered": False, "reason": "ctypes is unavailable: %s" % exc}
                )

            setter = ctypes.pythonapi.PyThreadState_SetAsyncExc
            setter.argtypes = [ctypes.c_ulong, ctypes.py_object]
            setter.restype = ctypes.c_int
            affected = setter(ctypes.c_ulong(thread_id), ctypes.py_object(KeyboardInterrupt))
            if affected > 1:
                # Documented as impossible; undoing it is what the CPython
                # documentation says to do if it ever is not.
                setter(ctypes.c_ulong(thread_id), ctypes.py_object())
                return json.dumps({"delivered": False, "reason": "more than one thread matched"})
            return json.dumps(
                {
                    "delivered": affected == 1,
                    "reason": "" if affected == 1 else "the thread had already finished",
                }
            )


        def _lathe_run():
            """Run this thread's accepted request. Returns JSON. Never raises.

            The outer guard is not belt and braces. Cancellation delivers an
            asynchronous exception at an arbitrary bytecode boundary, and a few
            of those boundaries are inside this function's own bookkeeping
            rather than inside the caller's code. Catching it here reports it as
            what it is instead of letting it escape into C, where the Swift side
            would read it as a broken driver.
            """
            try:
                return _lathe_run_request()
            except BaseException as exc:  # noqa: BLE001
                return json.dumps(
                    {
                        "ok": False,
                        "repr": None,
                        "type": None,
                        "json": None,
                        "stdout": "",
                        "stderr": "",
                        "exc_type": type(exc).__name__,
                        "exc_message": str(exc),
                        "traceback": "",
                        "restricted": False,
                    }
                )


        def _lathe_run_request():
            request = getattr(_LATHE_LOCAL, "request", None)
            if request is None:
                return json.dumps(
                    {
                        "ok": False,
                        "repr": None,
                        "type": None,
                        "json": None,
                        "stdout": "",
                        "stderr": "",
                        "exc_type": "RuntimeError",
                        "exc_message": "no request was accepted on this thread",
                        "traceback": "",
                        "restricted": False,
                    }
                )
            source = request["source"]
            mode = request["mode"]
            call_id = request.get("id")

            _LATHE_LOCAL.buffer = []
            report = {"ok": True, "repr": None, "type": None, "json": None}
            namespace = sys.modules["__main__"].__dict__
            try:
                if call_id is not None:
                    with _LATHE_CANCEL_LOCK:
                        already = call_id in _LATHE_CANCELLED
                    if already:
                        # Cancelled between being handed over and starting. Not
                        # running it at all is the whole point of recording the
                        # id rather than only interrupting a live thread.
                        raise KeyboardInterrupt("cancelled before it started")
                code = compile(source, "<lathe>", mode)
                if mode == "eval":
                    value = eval(code, namespace, namespace)  # noqa: S307
                    report["repr"] = repr(value)
                    report["type"] = type(value).__name__
                    try:
                        report["json"] = json.dumps(value)
                    except (TypeError, ValueError):
                        # Not every Python value is JSON. `repr` still is, and
                        # for a value the caller only wants to look at that is
                        # the whole requirement.
                        report["json"] = None
                else:
                    exec(code, namespace, namespace)  # noqa: S102
            except BaseException as exc:  # noqa: BLE001 — reporting, not handling
                # tb_next drops this function's own frame, so the traceback
                # starts at the caller's first line rather than inside Lathe.
                _, _, tb = sys.exc_info()
                formatted = "".join(
                    traceback.format_exception(type(exc), exc, tb.tb_next if tb is not None else None)
                )
                report["ok"] = False
                report["exc_type"] = type(exc).__name__
                report["exc_message"] = str(exc)
                report["traceback"] = formatted
                report["restricted"] = _lathe_is_platform_restriction(exc, formatted)
            finally:
                if call_id is not None:
                    with _LATHE_CANCEL_LOCK:
                        _LATHE_INFLIGHT.pop(call_id, None)
                        _LATHE_CANCELLED.discard(call_id)
                chunks = _LATHE_LOCAL.buffer
                _LATHE_LOCAL.buffer = None
                _LATHE_LOCAL.request = None
                report["stdout"] = _lathe_join(chunks, "out")
                report["stderr"] = _lathe_join(chunks, "err")
            return json.dumps(report)


        def _lathe_drain():
            """Take and clear whatever Python's own threads have printed."""
            chunks = list(_LATHE_SHARED)
            del _LATHE_SHARED[:]
            return json.dumps(
                {"stdout": _lathe_join(chunks, "out"), "stderr": _lathe_join(chunks, "err")}
            )


        def _lathe_platform():
            """What this interpreter is, and what it is not allowed to do.

            Reported rather than asserted. Which of these are true on a given
            build is exactly the thing a caller should not be guessing at from a
            version number, and the definitive test for a restriction is a call
            that raises — see `_lathe_is_platform_restriction`.
            """
            import os

            report = {
                "version": sys.version,
                "version_info": list(sys.version_info[:3]),
                "platform": sys.platform,
                "prefix": sys.prefix,
                "path": list(sys.path),
                "has_os_fork": hasattr(os, "fork"),
                "has_posix_spawn": hasattr(os, "posix_spawn"),
            }
            try:
                import subprocess  # noqa: F401

                report["subprocess_importable"] = True
            except BaseException as exc:  # noqa: BLE001
                report["subprocess_importable"] = False
                report["subprocess_error"] = "%s: %s" % (type(exc).__name__, exc)
            return json.dumps(report)
        """#
}
