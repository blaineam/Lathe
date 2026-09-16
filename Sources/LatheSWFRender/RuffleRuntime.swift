import Foundation
import LatheCore

/// Where the Ruffle web build lives, and whether it is actually there.
///
/// ## Why this is pluggable rather than simply present
///
/// Ruffle's self-hosted web build is about 10 MB of JavaScript and WebAssembly,
/// and **it is not committed to this repository**. That is the same arrangement
/// `LatheFetch` uses for CPython, taken for the same reasons, and it is a house
/// rule rather than a shortcut: nothing binary lives in this package, so there
/// is no artifact in git, no checksum drifting out of step with a tag, and no
/// 10 MB every consumer of every other module pays for.
///
/// `fetch-upstream.sh` downloads the pinned release, verifies it against a
/// recorded SHA-256, and unpacks it into the bundled `RenderHost/ruffle`
/// directory. See `VENDORING.md` for the pin, the provenance and the licence.
///
/// The consequence a caller has to know about: **`LatheSWFRender` builds, links
/// and passes its tests with no Ruffle present.** What it cannot do is render,
/// and it refuses by name — ``LatheError/unsupportedOnThisPlatform(feature:)``
/// naming the script to run — rather than failing somewhere deep inside a
/// WebView with a blank page.
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

    /// Whether the fetch has been run.
    public var isInstalled: Bool {
        FileManager.default.fileExists(atPath: entryPoint.path)
    }

    /// Every file the runtime directory holds, for diagnostics and for the
    /// report a caller may want to log. Empty when nothing has been fetched.
    public var installedFileNames: [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.sorted() ?? []
    }

    /// Throws unless the runtime is installed, with an error that says what to
    /// run.
    public func requireInstalled() throws {
        guard isInstalled else {
            throw LatheError.unsupportedOnThisPlatform(
                feature: "SWF rendering — the Ruffle runtime is not present in this build. "
                    + "It is fetched, not committed: run Sources/LatheSWFRender/fetch-upstream.sh "
                    + "to download the pinned release into \(directory.lastPathComponent)/. "
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
