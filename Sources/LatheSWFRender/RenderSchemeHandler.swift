import Foundation
import LatheCore
import WebKit

/// Serves the render host's page, the Ruffle runtime and the movie itself over
/// a private URL scheme.
///
/// ## Why a scheme handler and not `loadFileURL`
///
/// Loading the shim from `file://` is the obvious route and it does not work,
/// for three separate reasons that each independently rule it out:
///
/// - **`fetch` from a `file://` origin is blocked.** Ruffle loads its core
///   JavaScript and its `.wasm` that way, so the player would never start.
/// - **The `.wasm` must be served as `application/wasm`.** Upstream's own
///   documentation calls this out as the single most common deployment failure,
///   because `WebAssembly.instantiateStreaming` rejects anything else. A file
///   URL carries whatever MIME type the system infers from an extension it has
///   never heard of.
/// - **The movie would need a readable path.** Handing WebKit read access to a
///   directory in order to show it one file is a wider grant than the job needs.
///
/// A custom scheme fixes all three: every response's MIME type is stated here,
/// the origin is a real one so `fetch` is ordinary, and the SWF is served from
/// memory or from its own path without granting access to anything around it.
///
/// ## It is also the security boundary
///
/// Every request that arrives here was made by third-party JavaScript — Ruffle,
/// and through it whatever ActionScript the movie contains. So this refuses
/// anything it does not recognise instead of resolving it: three known paths and
/// one allow-listed directory, with traversal out of that directory checked on
/// the resolved path. Nothing here reaches the network, and
/// ``WebViewLoader/allowedSchemes`` refuses navigation to anything that is not
/// this scheme.
@MainActor
final class RenderSchemeHandler: NSObject, WKURLSchemeHandler {

    /// The private scheme. Not `http`, `https`, `file` or any other scheme
    /// WebKit handles itself — those cannot be registered, and trying is a
    /// runtime exception rather than an error.
    nonisolated static let scheme = "lathe-swf"
    nonisolated static let host = "render"

    nonisolated static var pageURL: URL { URL(string: "\(scheme)://\(host)/index.html")! }
    nonisolated static var movieURL: URL { URL(string: "\(scheme)://\(host)/movie.swf")! }

    private let shim: Data
    private let runtime: RuffleRuntime
    private let movie: URL?

    init(shim: Data, runtime: RuffleRuntime, movie: URL?) {
        self.shim = shim
        self.runtime = runtime
        self.movie = movie
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(Self.refusal("a request with no URL"))
            return
        }
        let path = url.path

        do {
            let (data, mimeType) = try payload(forPath: path)
            task.didReceive(Self.response(for: url, mimeType: mimeType, length: data.count))
            task.didReceive(data)
            task.didFinish()
        } catch {
            task.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        // Every response is delivered synchronously in `start`, so by the time a
        // cancellation arrives the task has already finished. Nothing to undo —
        // and calling `didFailWithError` on a finished task is an exception, so
        // doing nothing is not laziness here, it is the only correct action.
    }

    private func payload(forPath path: String) throws -> (Data, String) {
        switch path {
        case "/", "/index.html":
            return (shim, "text/html")

        case "/movie.swf":
            guard let movie else { throw Self.refusal("no movie is loaded") }
            do {
                return (try Data(contentsOf: movie), "application/x-shockwave-flash")
            } catch {
                throw LatheError.readFailed(
                    path: movie.lastPathComponent, reason: (error as NSError).localizedDescription
                )
            }

        default:
            guard path.hasPrefix("/ruffle/") else {
                throw Self.refusal("nothing is served at \(path)")
            }
            let relative = String(path.dropFirst("/ruffle/".count))
            guard let file = runtime.fileURL(forRelativePath: relative) else {
                throw Self.refusal("\(path) resolves outside the Ruffle runtime directory")
            }
            guard let data = try? Data(contentsOf: file) else {
                throw Self.refusal("\(path) is not in the Ruffle runtime directory")
            }
            return (data, Self.mimeType(forExtension: file.pathExtension))
        }
    }

    /// An HTTP 200, and it has to be HTTP.
    ///
    /// A plain `URLResponse` reaches the page as a `fetch` response whose
    /// `status` is **0**. Most code never looks, but Ruffle does: it wraps the
    /// `.wasm` response in a new `Response(stream, original)` to report
    /// download progress, the `Response` constructor throws `RangeError` for any
    /// status outside 200…599, and the player fails with "Failed to load Ruffle
    /// WASM" — naming neither the status nor this file. So every answer is an
    /// `HTTPURLResponse` with a real status and an explicit `Content-Type`.
    nonisolated static func response(for url: URL, mimeType: String, length: Int) -> URLResponse {
        let contentType = mimeType.hasPrefix("text/") ? "\(mimeType); charset=utf-8" : mimeType
        return HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": contentType,
                "Content-Length": String(length),
                // Nothing served here is ever cached: the movie changes with
                // every render, under the same URL.
                "Cache-Control": "no-store",
            ]
        ) ?? URLResponse(
            url: url, mimeType: mimeType, expectedContentLength: length, textEncodingName: nil
        )
    }

    /// The MIME types this host serves, stated rather than inferred.
    ///
    /// `application/wasm` is the one that matters and the one a system-inferred
    /// type gets wrong; the rest are here so that adding a file type upstream is
    /// a one-line change in a visible table rather than a mystery about why one
    /// request in twenty behaves differently.
    nonisolated static func mimeType(forExtension fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "wasm": "application/wasm"
        case "js", "mjs": "text/javascript"
        case "html", "htm": "text/html"
        case "css": "text/css"
        case "json", "map": "application/json"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "gif": "image/gif"
        case "jpg", "jpeg": "image/jpeg"
        case "woff2": "font/woff2"
        case "woff": "font/woff"
        case "ttf": "font/ttf"
        case "swf": "application/x-shockwave-flash"
        default: "application/octet-stream"
        }
    }

    nonisolated private static func refusal(_ reason: String) -> NSError {
        NSError(
            domain: "dev.lathe.swf-render", code: 404,
            userInfo: [NSLocalizedDescriptionKey: reason]
        )
    }
}
