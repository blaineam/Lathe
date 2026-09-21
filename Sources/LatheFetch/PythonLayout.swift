import Foundation

/// Where the interpreter is, and where its standard library is.
///
/// ## Why this type exists at all
///
/// An embedded CPython that cannot find its standard library does not return an
/// error. It calls `Py_FatalError`, writes a line to file descriptor 2, and
/// `abort()`s:
///
/// ```text
/// Fatal Python error: init_fs_encoding: failed to get the Python codec of the filesystem encoding
/// ```
///
/// On a device that is a crash report, not a diagnosis — file descriptor 2 goes
/// nowhere, and the abort happens inside `Py_Initialize` before any of this
/// package's error handling exists. The only defence is to establish that the
/// layout is real *before* initialising, which is what ``validate()`` does and
/// what every constructor here calls.
///
/// ## Why the environment rather than `PyConfig`
///
/// CPython 3.13 removed `Py_SetPythonHome` and `Py_SetPath`, and PEP 587's
/// replacement is `PyConfig` — a large C struct whose layout changes between
/// minor versions. Reading and writing that struct from Swift would mean
/// hand-transcribing a layout that is explicitly not stable, which is exactly
/// the failure mode ``PythonSymbols`` is shaped to avoid.
///
/// `PYTHONHOME` and `PYTHONPATH` are read by CPython's own path calculation on
/// every version from 2.x to today, cost two `setenv` calls, and cannot be
/// misaligned by a point release. The trade is that the variables are process
/// globals, so they are set once, immediately before initialisation, and never
/// changed afterwards — which matches the one-interpreter-per-process rule
/// anyway.
public struct PythonLayout: Sendable, Equatable {

    /// The CPython dynamic library to load, or `nil` to use what the process has
    /// already linked.
    ///
    /// `nil` is the iOS case: the application embeds `Python.framework` and the
    /// symbols are present at launch. iOS only permits loading code from inside
    /// the application's own signed bundle, so there is nothing else this could
    /// usefully point at there.
    public var libraryPath: String?

    /// `PYTHONHOME`. The directory whose `lib/pythonX.Y` holds the standard
    /// library.
    public var home: URL

    /// `X.Y` — `"3.13"`. Derived from the on-disk layout, never assumed.
    public var version: String

    /// Prepended to `PYTHONPATH`, ahead of the standard library.
    ///
    /// Where an installed-package directory goes when a host wants it on the
    /// path from the first line of Python executed, rather than appended later
    /// through ``PythonPackageInstaller/activate()``.
    public var extraSearchPaths: [URL]

    /// `home/lib/pythonX.Y`.
    public var standardLibrary: URL {
        home.appendingPathComponent("lib", isDirectory: true)
            .appendingPathComponent("python\(version)", isDirectory: true)
    }

    /// `home/lib/pythonX.Y/lib-dynload` — the compiled stdlib extension modules.
    public var dynamicLoadDirectory: URL {
        standardLibrary.appendingPathComponent("lib-dynload", isDirectory: true)
    }

    public init(
        home: URL,
        version: String,
        libraryPath: String? = nil,
        extraSearchPaths: [URL] = []
    ) {
        self.home = home
        self.version = version
        self.libraryPath = libraryPath
        self.extraSearchPaths = extraSearchPaths
    }

    // MARK: - Validation

    /// Throws unless this layout could plausibly start an interpreter.
    ///
    /// The landmark is `os.py`, because that is the landmark CPython's own path
    /// calculation uses. Checking for the *directory* is not enough: an empty
    /// `lib/python3.13` passes that check and still aborts.
    public func validate() throws {
        let fileManager = FileManager.default

        if let libraryPath, !fileManager.isReadableFile(atPath: libraryPath) {
            throw PythonError.invalidLayout(reason: "no readable library at \(libraryPath)")
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: home.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PythonError.invalidLayout(reason: "PYTHONHOME \(home.path) is not a directory")
        }

        let landmark = standardLibrary.appendingPathComponent("os.py")
        guard fileManager.isReadableFile(atPath: landmark.path) else {
            throw PythonError.invalidLayout(
                reason: "\(standardLibrary.path) has no os.py, so it is not a Python \(version) "
                    + "standard library. CPython would abort rather than report this."
            )
        }
    }

    /// The `PYTHONPATH` value: extra paths, then the standard library, then its
    /// `lib-dynload`.
    ///
    /// `PYTHONHOME` alone would imply the last two, but stating them costs
    /// nothing and removes a class of "it works on macOS and not in the app"
    /// problem caused by a relocated or partially copied bundle.
    var searchPathValue: String {
        (extraSearchPaths.map(\.path) + [standardLibrary.path, dynamicLoadDirectory.path])
            .joined(separator: ":")
    }

    // MARK: - Discovery

    /// The layout an application bundle carries, following the directory shape
    /// that `Python-Apple-support` installs.
    ///
    /// Expects `<resources>/<subdirectory>/lib/pythonX.Y/…`, which is what the
    /// `install_target` build phase in that project's `Xcode-support` produces.
    /// The library path is left `nil`: the embedded `Python.framework` is linked
    /// by the application, so its symbols are already in the process.
    ///
    /// - SeeAlso: `Sources/LatheFetch/VENDORING.md`, "What a consumer has to do".
    public static func inBundle(_ bundle: Bundle = .main, subdirectory: String = "python") throws -> PythonLayout {
        guard let resources = bundle.resourceURL else {
            throw PythonError.invalidLayout(reason: "\(bundle.bundlePath) has no resource directory")
        }
        let home = resources.appendingPathComponent(subdirectory, isDirectory: true)
        guard let version = highestStandardLibraryVersion(under: home) else {
            throw PythonError.invalidLayout(
                reason: "\(home.path) contains no lib/pythonX.Y directory. The application's build "
                    + "phase that copies the standard library into the bundle has not run."
            )
        }
        let layout = PythonLayout(home: home, version: version)
        try layout.validate()
        return layout
    }

    /// A CPython the host operating system already has — a framework build with
    /// a shared library beside it.
    ///
    /// This is how the test suite runs, and how a macOS tool can use `LatheFetch`
    /// with nothing downloaded. It is **not** how an iOS application works, and
    /// it deliberately returns nothing there: the standard search locations are
    /// all outside an application's sandbox.
    ///
    /// Search order, first match wins:
    ///
    /// 1. `LATHE_PYTHON_LIBRARY` / `LATHE_PYTHON_HOME` from the environment,
    ///    which is how a specific interpreter is pinned in CI.
    /// 2. Homebrew's versioned kegs, then its linked framework.
    /// 3. A python.org framework install in `/Library/Frameworks`.
    /// 4. The `Python3.framework` inside Xcode or the Command Line Tools. This
    ///    is the backstop that makes the test suite runnable on a machine
    ///    nobody prepared: any Mac that can build this package at all has one,
    ///    because Xcode's own tooling is written in Python.
    public static func hostInstalled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> PythonLayout {
        #if os(macOS)
            if let home = environment["LATHE_PYTHON_HOME"] {
                let homeURL = URL(fileURLWithPath: home, isDirectory: true)
                guard let version = highestStandardLibraryVersion(under: homeURL) else {
                    throw PythonError.invalidLayout(
                        reason: "LATHE_PYTHON_HOME=\(home) contains no lib/pythonX.Y directory")
                }
                let layout = PythonLayout(
                    home: homeURL,
                    version: version,
                    libraryPath: environment["LATHE_PYTHON_LIBRARY"] ?? sharedLibrary(in: homeURL, version: version)
                )
                try layout.validate()
                return layout
            }

            for candidate in frameworkVersionDirectories(environment: environment) {
                guard let version = highestStandardLibraryVersion(under: candidate),
                    let library = environment["LATHE_PYTHON_LIBRARY"] ?? sharedLibrary(in: candidate, version: version)
                else { continue }
                let layout = PythonLayout(home: candidate, version: version, libraryPath: library)
                if (try? layout.validate()) != nil { return layout }
            }

            throw PythonError.interpreterUnavailable(
                reason: "no CPython framework with a shared library was found. Install one "
                    + "(`brew install python@3.13`, or python.org), or set LATHE_PYTHON_HOME and "
                    + "LATHE_PYTHON_LIBRARY."
            )
        #else
            throw PythonError.interpreterUnavailable(
                reason: "there is no host-installed Python on this platform; an application must "
                    + "embed Python.framework and use PythonLayout.inBundle(_:)."
            )
        #endif
    }

    /// The bundle first, then the host. What a cross-platform caller wants.
    ///
    /// An iOS application that has embedded Python gets it; a macOS tool or test
    /// that has not falls through to whatever the machine has.
    public static func discover(bundle: Bundle = .main) throws -> PythonLayout {
        #if os(macOS)
            if let bundled = try? inBundle(bundle) { return bundled }
            return try hostInstalled()
        #else
            // No host fallback exists here, so the bundle's own reason is the
            // useful one: "the standard library build phase has not run" says
            // what to fix, where "there is no host-installed Python" does not.
            return try inBundle(bundle)
        #endif
    }

    // MARK: - Layout probing

    /// The highest `lib/pythonX.Y` under `root` that actually contains `os.py`.
    ///
    /// Probed rather than assumed, for the same reason the image capability
    /// probe attempts an encode rather than reading a list: a version number
    /// baked into this source would be wrong the moment anyone bumped theirs.
    static func highestStandardLibraryVersion(under root: URL) -> String? {
        let libraryDirectory = root.appendingPathComponent("lib", isDirectory: true)
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: libraryDirectory, includingPropertiesForKeys: nil)
        else { return nil }

        let versions = entries.compactMap { entry -> (major: Int, minor: Int, text: String)? in
            let name = entry.lastPathComponent
            guard name.hasPrefix("python") else { return nil }
            let text = String(name.dropFirst("python".count))
            let parts = text.split(separator: ".")
            guard parts.count == 2, let major = Int(parts[0]), let minor = Int(parts[1]) else { return nil }
            guard FileManager.default.isReadableFile(atPath: entry.appendingPathComponent("os.py").path) else {
                return nil
            }
            return (major, minor, text)
        }

        return versions.max { ($0.major, $0.minor) < ($1.major, $1.minor) }?.text
    }

    /// The loadable dylib inside a framework version directory.
    ///
    /// `lib/libpythonX.Y.dylib` is checked first because it is spelled the same
    /// way in every framework build. The framework binary itself is the
    /// fallback, and it has two spellings: `Python` for Homebrew and python.org,
    /// `Python3` for the Command Line Tools copy.
    static func sharedLibrary(in versionDirectory: URL, version: String) -> String? {
        let candidates = [
            versionDirectory.appendingPathComponent("lib/libpython\(version).dylib"),
            versionDirectory.appendingPathComponent("Python"),
            versionDirectory.appendingPathComponent("Python3"),
        ]
        return candidates.first { FileManager.default.isReadableFile(atPath: $0.path) }?.path
    }

    /// Every `…/Python*.framework/Versions/X.Y` worth trying, newest-looking
    /// first within each prefix.
    ///
    /// Ordered by how deliberately the interpreter was installed: something the
    /// machine's owner chose beats the one Xcode happens to carry. The developer
    /// directory comes last and is never omitted — it is what makes a CI runner
    /// with no Python setup step still able to run this package's Python tests.
    static func frameworkVersionDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        var roots = [
            "/opt/homebrew/opt",  // brew install python@3.13 — versioned keg
            "/usr/local/opt",  // the same, on Intel
            "/opt/homebrew/Frameworks",
            "/usr/local/Frameworks",
            "/Library/Frameworks",
            "/Library/Developer/CommandLineTools/Library/Frameworks",
            "/Applications/Xcode.app/Contents/Developer/Library/Frameworks",
        ]
        // xcodebuild exports DEVELOPER_DIR, and a runner image may have several
        // Xcodes with only one of them selected. Honour the selection rather
        // than assuming the default path.
        if let developerDirectory = environment["DEVELOPER_DIR"] {
            roots.append(developerDirectory + "/Library/Frameworks")
        }

        var found: [URL] = []
        let fileManager = FileManager.default

        for root in roots {
            guard
                let entries = try? fileManager.contentsOfDirectory(
                    at: URL(fileURLWithPath: root, isDirectory: true), includingPropertiesForKeys: nil)
            else { continue }

            // A keg directory (`python@3.13`) holds the framework one level
            // down, under `Frameworks/`; a Frameworks directory holds it
            // directly. Try both shapes rather than encoding which is which.
            let frameworks =
                entries.filter { $0.lastPathComponent.hasSuffix(".framework") }
                + entries
                .filter { $0.lastPathComponent.hasPrefix("python@") }
                .flatMap { keg -> [URL] in
                    let inner = keg.appendingPathComponent("Frameworks", isDirectory: true)
                    let contents = (try? fileManager.contentsOfDirectory(at: inner, includingPropertiesForKeys: nil))
                    return (contents ?? []).filter { $0.lastPathComponent.hasSuffix(".framework") }
                }

            for framework in frameworks where framework.lastPathComponent.hasPrefix("Python") {
                let versions = framework.appendingPathComponent("Versions", isDirectory: true)
                guard let entries = try? fileManager.contentsOfDirectory(at: versions, includingPropertiesForKeys: nil)
                else { continue }
                found += entries
                    .filter { $0.lastPathComponent != "Current" }
                    .sorted { $0.lastPathComponent > $1.lastPathComponent }
            }
        }
        return found
    }
}
