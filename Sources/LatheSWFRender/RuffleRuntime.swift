import Foundation
import LatheCore

/// Where the Ruffle web build lives, and whether it is actually there.
///
/// ## Where it comes from
///
/// Ruffle's self-hosted web build is **committed to this repository**, as a
/// resource of this target, because that is the only way it reaches an
/// application: SwiftPM gives a package consumer exactly the resources that are
/// in the package when it builds, and nothing a script would have fetched.
/// Five files, byte-identical to upstream's release — the entry point, the core
/// chunk, the WebAssembly module and the two licences — about 14.8 MB on disk.
/// `fetch-upstream.sh` is how they got there and how to check they still match;
/// see `VENDORING.md` for the pin, the provenance, the licence, and what was
/// deliberately left out of the archive.
///
/// This type stays pluggable anyway. A caller can point it at another copy —
/// a newer Ruffle, or one downloaded on demand to keep it out of the app
/// bundle — and a copy that is not there is refused by name,
/// ``LatheError/unsupportedOnThisPlatform(feature:)``, rather than failing
/// somewhere deep inside a WebView with a blank page.
///
/// ## Why a whole directory, and not three named files
///
/// `ruffle.js` is only the entry point. It lazily loads its core JavaScript and
/// its `.wasm` from the directory it was itself served from, and **those
/// filenames carry a content hash that changes with every Ruffle release**.
/// Naming them here would mean editing Swift on every version bump, and getting
/// one wrong produces a player that loads and never starts. So the directory is
/// served whole and its contents are upstream's business.
public struct RuffleRuntime: Sendable, Equatable {

    /// The directory holding `ruffle.js` and everything it loads.
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The runtime bundled with this module, wherever SwiftPM put it.
    ///
    /// Returns a value whether or not the files are actually present — asking
    /// "is it installed" is ``isInstalled``, and conflating "I know where it
    /// goes" with "it is there" is how a missing-resource bug turns into a
    /// nil-coalescing chain that reports the wrong reason.
    public static var bundled: RuffleRuntime? {
        guard let resources = Bundle.module.resourceURL else { return nil }
        return RuffleRuntime(
            directory: resources.appendingPathComponent("RenderHost/ruffle", isDirectory: true)
        )
    }

    /// The file `ruffle.js`, which is the entry point and the presence check.
    public var entryPoint: URL { directory.appendingPathComponent("ruffle.js") }

    /// Whether the entry point is present in ``directory``.
    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: entryPoint.path)
    }

    /// Every file the runtime directory holds, for diagnostics and for the
    /// report a caller may want to log. Empty when the directory is missing.
    public var installedFileNames: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.sorted() ?? []
    }

    /// Throws unless the runtime is installed, with an error that says what to
    /// run.
    public func requireInstalled() throws {
        guard isInstalled else {
            throw LatheError.unsupportedOnThisPlatform(
                feature: "SWF rendering — there is no Ruffle runtime (ruffle.js) at "
                    + "\(directory.path). The bundled one ships with the package; if it is "
                    + "missing, the package checkout is incomplete — "
                    + "Sources/LatheSWFRender/fetch-upstream.sh restores and verifies it. "
                    + "See Sources/LatheSWFRender/VENDORING.md"
            )
        }
    }

    // MARK: - Serving

    /// Resolves a path requested by the page to a file inside this directory,
    /// or `nil` if it escapes.
    ///
    /// **The requests come from third-party JavaScript**, so this is a boundary
    /// and not a convenience. The check is on the *resolved* path — symlinks and
    /// `..` collapsed — because a prefix test against the unresolved string
    /// accepts `ruffle/../../../../etc/passwd`, and comparing whole path
    /// components rather than a raw string prefix because `/x/ruffle-evil`
    /// begins with `/x/ruffle`.
    func fileURL(forRelativePath path: String) -> URL? {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !trimmed.isEmpty else { return nil }

        let base = URL(fileURLWithPath: directory.path)
            .standardizedFileURL.resolvingSymlinksInPath()
        let candidate = base.appendingPathComponent(trimmed).standardizedFileURL
            .resolvingSymlinksInPath()

        let baseComponents = base.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count > baseComponents.count,
              Array(candidateComponents.prefix(baseComponents.count)) == baseComponents
        else { return nil }

        return candidate
    }
}
