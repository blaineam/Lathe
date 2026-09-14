import Foundation

/// The entire C surface this package uses, resolved by `dlsym` rather than by
/// `#include <Python.h>`.
///
/// ## Why not a header
///
/// Because there is no version of "just include the header" that works here.
/// `Python.h` arrives with the platform's CPython build; SwiftPM would have to
/// be told where that is *at compile time*, per platform, and on iOS the answer
/// is "inside a 40 MB xcframework the application supplies" — which no manifest
/// can name and no CI runner has. Binding at runtime moves the dependency from
/// build time to run time, where it actually lives. See
/// `Sources/LatheFetch/VENDORING.md` for the full argument.
///
/// ## Why this is safe to hand-declare
///
/// Every function below is part of CPython's **stable ABI** and takes or returns
/// only `int`, `const char *`, `Py_ssize_t` and opaque `PyObject *`. None of
/// them names a struct whose layout this code would have to know — which is the
/// thing that actually breaks between CPython versions, and the reason
/// `PyConfig` (PEP 587) is deliberately *not* used here. Interpreter
/// configuration goes through the environment instead; see ``PythonLayout``.
///
/// These signatures have been unchanged since CPython 3.2. The one late arrival
/// is `PyUnicode_AsUTF8AndSize`, which has existed as an exported function since
/// 3.3 and joined the limited API in 3.10. That sets the floor at **CPython
/// 3.9**, which every Apple platform target and every plausible host satisfies.
///
/// ## Why the surface is this small
///
/// Fifteen symbols is not an accident. Everything that would need more of the C
/// API — formatting a traceback, capturing `sys.stdout`, converting a value,
/// unpacking an archive — is done *in Python*, by the driver in
/// ``PythonDriver/source``. A line of Python is cheaper to get right than a
/// hand-transcribed C signature, and it cannot be silently wrong about a calling
/// convention.
struct PythonSymbols: @unchecked Sendable {

    // Opaque. Every `PyObject *` is a raw pointer here on purpose: this module
    // never dereferences one.
    typealias PyObjectRef = UnsafeMutableRawPointer

    // MARK: Lifecycle

    let Py_IsInitialized: @convention(c) () -> Int32
    let Py_InitializeEx: @convention(c) (Int32) -> Void

    // MARK: Threading and the GIL

    let PyEval_SaveThread: @convention(c) () -> UnsafeMutableRawPointer?
    let PyGILState_Ensure: @convention(c) () -> Int32
    let PyGILState_Release: @convention(c) (Int32) -> Void

    // MARK: Execution

    let PyRun_SimpleString: @convention(c) (UnsafePointer<CChar>) -> Int32
    let PyRun_String:
        @convention(c) (UnsafePointer<CChar>, Int32, PyObjectRef, PyObjectRef) -> PyObjectRef?

    // MARK: Objects

    let PyImport_AddModule: @convention(c) (UnsafePointer<CChar>) -> PyObjectRef?
    let PyModule_GetDict: @convention(c) (PyObjectRef) -> PyObjectRef?
    let PyDict_SetItemString: @convention(c) (PyObjectRef, UnsafePointer<CChar>, PyObjectRef) -> Int32
    let PyUnicode_FromStringAndSize: @convention(c) (UnsafePointer<CChar>?, Int) -> PyObjectRef?
    let PyUnicode_AsUTF8AndSize: @convention(c) (PyObjectRef, UnsafeMutablePointer<Int>?) -> UnsafePointer<CChar>?
    let Py_DecRef: @convention(c) (PyObjectRef?) -> Void

    // MARK: Errors

    let PyErr_Occurred: @convention(c) () -> PyObjectRef?
    let PyErr_Clear: @convention(c) () -> Void

    /// `Py_eval_input` — the start token for `PyRun_String` when the source is a
    /// single expression whose value is wanted back. A stable grammar constant,
    /// unchanged since Python 1.x.
    static let evalInput: Int32 = 258

    // MARK: - Binding

    /// Opens `path` (or, when `path` is `nil`, looks in what the process has
    /// already loaded) and resolves every symbol above.
    ///
    /// Resolution is all-or-nothing and eager. A lazily-resolved symbol would
    /// fail at some unrelated later call site, having already started an
    /// interpreter; failing here means the runtime either comes up completely or
    /// does not come up at all.
    ///
    /// - Parameter path: the CPython dynamic library. `nil` means **look in the
    ///   running process** — the normal case on iOS, where the application links
    ///   and embeds `Python.framework` itself and the symbols are present before
    ///   this code runs. No `dlopen` of an arbitrary path is attempted in that
    ///   case, which matters: iOS only permits loading code from inside the
    ///   application's own signed bundle.
    static func bind(loading path: String?) throws -> PythonSymbols {
        // RTLD_GLOBAL is required rather than merely convenient. CPython's
        // extension modules (`lib-dynload/*.so`) are themselves dlopened later
        // by the import machinery and resolve their `Py*` symbols against the
        // global namespace; loading libpython RTLD_LOCAL makes `import math`
        // fail with an undefined symbol.
        let flags = RTLD_NOW | RTLD_GLOBAL
        let describedPath = path ?? "the running process"

        guard let handle = path.map({ dlopen($0, flags) }) ?? dlopen(nil, flags) else {
            let message = dlerror().map { String(cString: $0) } ?? "unknown dynamic-loader error"
            throw PythonError.interpreterUnavailable(reason: "could not load \(describedPath): \(message)")
        }

        // A handle from `dlopen(nil, …)` always succeeds even in a process with
        // no Python in it, so the absence check is the first `dlsym`, not the
        // `dlopen`. Probe with the cheapest symbol and report the honest reason.
        if path == nil, dlsym(handle, "Py_IsInitialized") == nil {
            throw PythonError.interpreterUnavailable(
                reason: "no CPython is linked into this process. An iOS application must embed "
                    + "Python.framework; a macOS host must pass a library path."
            )
        }

        func resolve<T>(_ name: String, as type: T.Type) throws -> T {
            guard let address = dlsym(handle, name) else {
                throw PythonError.symbolMissing(name: name, library: describedPath)
            }
            return unsafeBitCast(address, to: type)
        }

        return PythonSymbols(
            Py_IsInitialized: try resolve("Py_IsInitialized", as: (@convention(c) () -> Int32).self),
            Py_InitializeEx: try resolve("Py_InitializeEx", as: (@convention(c) (Int32) -> Void).self),
            PyEval_SaveThread: try resolve(
                "PyEval_SaveThread", as: (@convention(c) () -> UnsafeMutableRawPointer?).self),
            PyGILState_Ensure: try resolve("PyGILState_Ensure", as: (@convention(c) () -> Int32).self),
            PyGILState_Release: try resolve("PyGILState_Release", as: (@convention(c) (Int32) -> Void).self),
            PyRun_SimpleString: try resolve(
                "PyRun_SimpleString", as: (@convention(c) (UnsafePointer<CChar>) -> Int32).self),
            PyRun_String: try resolve(
                "PyRun_String",
                as: (@convention(c) (UnsafePointer<CChar>, Int32, PyObjectRef, PyObjectRef) -> PyObjectRef?).self),
            PyImport_AddModule: try resolve(
                "PyImport_AddModule", as: (@convention(c) (UnsafePointer<CChar>) -> PyObjectRef?).self),
            PyModule_GetDict: try resolve(
                "PyModule_GetDict", as: (@convention(c) (PyObjectRef) -> PyObjectRef?).self),
            PyDict_SetItemString: try resolve(
                "PyDict_SetItemString",
                as: (@convention(c) (PyObjectRef, UnsafePointer<CChar>, PyObjectRef) -> Int32).self),
            PyUnicode_FromStringAndSize: try resolve(
                "PyUnicode_FromStringAndSize",
                as: (@convention(c) (UnsafePointer<CChar>?, Int) -> PyObjectRef?).self),
            PyUnicode_AsUTF8AndSize: try resolve(
                "PyUnicode_AsUTF8AndSize",
                as: (@convention(c) (PyObjectRef, UnsafeMutablePointer<Int>?) -> UnsafePointer<CChar>?).self),
            Py_DecRef: try resolve("Py_DecRef", as: (@convention(c) (PyObjectRef?) -> Void).self),
            PyErr_Occurred: try resolve("PyErr_Occurred", as: (@convention(c) () -> PyObjectRef?).self),
            PyErr_Clear: try resolve("PyErr_Clear", as: (@convention(c) () -> Void).self)
        )
    }
}
