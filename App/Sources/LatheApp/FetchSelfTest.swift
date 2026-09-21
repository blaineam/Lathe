import Foundation
import LatheFetch

/// Exercises the downloaders headlessly, in the app's own container, and exits.
///
///     Lathe --fetch-selftest list <url> [--tor]
///     Lathe --fetch-selftest urlopen <url> [--tor | --proxy <url>]
///     Lathe --fetch-selftest gallery <url> [--tor | --proxy <url>]
///
/// `list` extracts with yt-dlp and prints the title and format count — no
/// media is downloaded. `urlopen` fetches a URL through yt-dlp's networking
/// and prints which request handler carried it and the body's first bytes,
/// which is how the URLSession transport (and Tor through it) is checked.
/// `gallery` downloads at most two files with gallery-dl into a temporary
/// folder, reports them, and deletes them. `--tor` starts the embedded client
/// first and routes through it; `--proxy` names any other proxy URL.
///
/// Same rules as `--tor-selftest`: standard error, `dispatchMain`, and it
/// needs yt-dlp already installed in the container. In the simulator only —
/// on a device iOS ends an app that shows no window after about 20 seconds.
enum FetchSelfTest {

    private static func say(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func run() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--fetch-selftest"), arguments.count > index + 2,
            let url = URL(string: arguments[index + 2])
        else {
            say("fetch: usage: --fetch-selftest list|urlopen|gallery <url> [--tor | --proxy <url>]")
            exit(2)
        }
        let mode = arguments[index + 1]
        let wantsTor = arguments.contains("--tor")

        Task { @MainActor in
            do {
                var proxy: String?
                if let flag = arguments.firstIndex(of: "--proxy"), arguments.count > flag + 1 {
                    proxy = arguments[flag + 1]
                }
                if wantsTor {
                    let tor = TorController()
                    await tor.start()
                    guard tor.state == .running else {
                        say("fetch: tor \(tor.state.label)")
                        exit(1)
                    }
                    proxy = tor.endpoint.extractorProxyURL
                    say("fetch: tor running, proxy \(proxy ?? "")")
                }

                let root = FileManager.default
                    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Lathe/python", isDirectory: true)
                var configuration = PythonRuntime.Configuration(layout: try PythonLayout.discover())
                configuration.trustStore = PythonTrustStore.installed(in: root)
                let runtime = try PythonRuntime.current ?? PythonRuntime.bootstrap(configuration)
                let installer = PythonPackageInstaller(runtime: runtime, root: root)
                var options = MediaFetcher.Configuration()
                options.proxy = proxy
                options.cacheDirectory = root.appendingPathComponent("cache")
                let fetcher = MediaFetcher(runtime: runtime, installer: installer, configuration: options)
                say("fetch: system networking \(options.usesSystemNetworking ? "on" : "off")")

                switch mode {
                case "list":
                    let started = Date()
                    let listing = try await fetcher.listing(for: url)
                    say("fetch: \(listing.extractor ?? "?") \"\(listing.title ?? "")\" — "
                        + "\(listing.formats.count) formats in "
                        + String(format: "%.1fs", Date().timeIntervalSince(started)))
                case "urlopen":
                    _ = try await fetcher.readiness()
                    let result = try await runtime.evaluateDetached(
                        """
                        (lambda yt_dlp, Request: (lambda ydl: (
                            ydl._request_director._get_handlers(Request(lathe_arguments["url"]))[0].RH_NAME
                            + " " + ydl.urlopen(lathe_arguments["url"]).read(300).decode("utf-8", "replace")
                        ))(yt_dlp.YoutubeDL({"quiet": True, "proxy": lathe_arguments["proxy"] or None})))(
                            __import__("yt_dlp"), __import__("yt_dlp.networking.common", fromlist=["Request"]).Request)
                        """,
                        arguments: ["url": url.absoluteString, "proxy": proxy ?? ""])
                    say("fetch: via \(result.value.string ?? "?")")
                case "gallery":
                    var galleryOptions = GalleryFetcher.Configuration()
                    galleryOptions.proxy = proxy
                    let gallery = GalleryFetcher(runtime: runtime, installer: installer, configuration: galleryOptions)
                    let folder = FileManager.default.temporaryDirectory
                        .appendingPathComponent("fetch-selftest", isDirectory: true)
                    let haul = try await gallery.download(url, into: folder, limit: 2)
                    say("fetch: gallery-dl wrote \(haul.files.count) file(s), status \(haul.status)"
                        + (haul.problems.isEmpty ? "" : ", problems: \(haul.problems)"))
                    for file in haul.files {
                        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        say("fetch:   \(file.lastPathComponent) \(size) bytes")
                    }
                    try? FileManager.default.removeItem(at: folder)
                default:
                    say("fetch: unknown mode \(mode)")
                    exit(2)
                }
                exit(0)
            } catch {
                say("fetch: failed — \(error.localizedDescription)")
                exit(1)
            }
        }
        dispatchMain()
    }
}
