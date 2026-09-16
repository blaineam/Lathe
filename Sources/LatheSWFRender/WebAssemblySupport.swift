import Foundation
import LatheCore
import WebKit

/// Asks the WebView on *this* system whether it can actually run WebAssembly.
///
/// ## Why this is probed and not assumed
///
/// Ruffle is Rust compiled to WebAssembly. If WebKit cannot run WebAssembly
/// here, nothing else in this module can work, and the failure would otherwise
/// surface as a movie that loads forever.
///
/// The reason it is a live probe rather than an OS-version check is the house
/// rule — Lathe never branches on OS version, it asks the system what it can do
/// — and here that rule earns its keep more than usual, because the honest
/// answer is genuinely complicated:
///
/// - **JavaScriptCore runs WebAssembly without a JIT.** It has an interpreter
///   tier, so WebAssembly executes in a `WKWebView` even where JIT is
///   unavailable.
/// - **On iOS, JIT is unavailable to an ordinary app's `WKWebView`.** Fast
///   tiers need a dynamic-codesigning entitlement that only browsers get. So
///   WebAssembly on an iPhone runs interpreted, which works and is
///   substantially slower than the same code on a Mac.
/// - **The Simulator is not evidence about a device.** It runs against the
///   host's JavaScriptCore with the host's capabilities, so a green Simulator
///   result says the API is present and says nothing about the device's speed.
///
/// A caller that means to render on a phone should therefore run this, and
/// should treat a slow frame rate as expected rather than as a defect. See
/// ``SWFRenderer`` for what "real time" means in practice.
public enum WebAssemblySupport {

    /// What a probe found.
    public enum Result: Sendable, Equatable {
        /// WebAssembly validated, compiled, instantiated and ran.
        case available
        /// It did not. The reason is the JavaScript side's own words.
        case unavailable(reason: String)

        public var isAvailable: Bool { self == .available }
    }

    /// A complete, minimal WebAssembly module that exports one function
    /// returning 42.
    ///
    /// Thirty-four bytes, assembled here from the binary-format specification
    /// rather than fetched, because a probe that needed a file to be present
    /// could not answer the question a missing file raises. The sections are, in
    /// order: magic and version; a type section declaring `() -> i32`; a
    /// function section binding function 0 to it; an export section naming it
    /// `"f"`; and a code section whose body is `i32.const 42; end`.
    ///
    /// It deliberately runs the *whole* pipeline. `WebAssembly.validate` alone
    /// would pass on a system that could not compile, and compiling alone would
    /// pass on one that could not execute — and executing is the part an
    /// interpreter tier has to supply.
    static let probeModule: [UInt8] = [
        0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,  // "\0asm", version 1
        0x01, 0x05, 0x01, 0x60, 0x00, 0x01, 0x7F,        // type:   () -> i32
        0x03, 0x02, 0x01, 0x00,                          // func:   0 : type 0
        0x07, 0x05, 0x01, 0x01, 0x66, 0x00, 0x00,        // export: "f" = func 0
        0x0A, 0x06, 0x01, 0x04, 0x00, 0x41, 0x2A, 0x0B,  // code:   i32.const 42; end
    ]

    /// Runs the probe in a throwaway `WKWebView`.
    ///
    /// Costs a WebView creation and an empty page load — tens of milliseconds,
    /// not free. Probe once and keep the answer.
    @MainActor
    public static func probe(timeout: Duration = .seconds(10)) async -> Result {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        let loader = WebViewLoader()
        webView.navigationDelegate = loader

        do {
            webView.loadHTMLString("<!doctype html><title>probe</title>", baseURL: nil)
            try await loader.waitForLoad(timeout: timeout)

            let answer = try await webView.callAsyncJavaScript(
                """
                if (typeof WebAssembly === "undefined") return "WebAssembly is not defined";
                const bytes = new Uint8Array(moduleBytes);
                if (!WebAssembly.validate(bytes)) return "the module did not validate";
                const { instance } = await WebAssembly.instantiate(bytes);
                const value = instance.exports.f();
                return value === 42 ? "ok" : "the module ran and returned " + value;
                """,
                arguments: ["moduleBytes": probeModule.map { Int($0) }],
                contentWorld: .page
            )
            guard let text = answer as? String else {
                return .unavailable(reason: "the probe returned \(String(describing: answer))")
            }
            return text == "ok" ? .available : .unavailable(reason: text)
        } catch {
            return .unavailable(reason: (error as NSError).localizedDescription)
        }
    }
}

/// Bridges `WKNavigationDelegate` to `async`.
///
/// Separate from everything else because two things need it — the WebAssembly
/// probe and the render host — and because the one rule it exists to enforce is
/// easy to get wrong in either: **a continuation must be resumed exactly once.**
/// A WebView can report both a provisional failure and a failure, or finish
/// after a timeout has already given up, and resuming twice is a crash rather
/// than an error.
@MainActor
final class WebViewLoader: NSObject, WKNavigationDelegate {

    private var continuation: CheckedContinuation<Void, any Error>?

    /// Navigation to anything but these schemes is refused.
    ///
    /// Empty means "allow the initial load only", which is what the probe wants.
    /// The render host sets its own scheme, and the refusal is load-bearing
    /// there: **a Flash movie can ask its player to navigate**, `getURL` and
    /// `navigateToURL` being ordinary ActionScript, and Ruffle faithfully
    /// forwards that to the browser. A movie of unknown provenance must not be
    /// able to make an offscreen WebView inside somebody's application fetch a
    /// URL of its choosing.
    var allowedSchemes: Set<String> = []

    /// Waits for the current navigation, or gives up.
    ///
    /// The timeout is a second `Task` that resumes the same continuation with a
    /// failure rather than a task group racing two children, because the group
    /// spelling puts a main-actor continuation inside a child task and the
    /// isolation checker cannot follow it. This way there is exactly one
    /// continuation, one place that resumes it, and ``finish(_:)`` refusing to
    /// resume it twice is what makes the race safe rather than merely unlikely.
    func waitForLoad(timeout: Duration) async throws {
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.finish(
                .failure(
                    LatheError.invalidInput(
                        reason: "the render host did not finish loading within \(timeout)"
                    )
                )
            )
        }
        defer { timeoutTask.cancel() }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            self.continuation = continuation
        }
    }

    private func finish(_ result: Swift.Result<Void, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(.success(()))
    }

    func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error
    ) {
        finish(.failure(LatheError.wrapping(error)))
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        finish(.failure(LatheError.wrapping(error)))
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard !allowedSchemes.isEmpty else {
            decisionHandler(.allow)
            return
        }
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        decisionHandler(allowedSchemes.contains(scheme) ? .allow : .cancel)
    }
}
