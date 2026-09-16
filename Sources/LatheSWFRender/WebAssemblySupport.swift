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
/// - **It can be switched off by the user.** Lockdown Mode blocks what Apple
///   calls "certain complex web technologies" in every `WKWebView`, and
///   WebAssembly has been among them — so the same device can answer
///   differently from one day to the next, and a build that rendered yesterday
///   has to be able to say why it cannot today.
/// - **Speed is not what this measures.** `WKWebView` content runs in WebKit's
///   own process, not the app's, so an App Store app's lack of a JIT
///   entitlement does not decide how fast Ruffle runs there — but a phone is
///   still not a Mac, and nothing here should be read as a promise of real-time
///   capture on one.
/// - **The Simulator is not evidence about a device.** It runs against the
///   host's WebKit with the host's capabilities.
///
/// ## Which WebAssembly, precisely
///
/// Ruffle publishes two builds of its core — one using the post-MVP
/// extensions (bulk memory, SIMD, non-trapping float-to-int, sign extension and
/// reference types) and a "vanilla" one without — and picks between them at
/// run time by validating five tiny modules. **Only the extensions build is
/// bundled**: every WebKit this package supports (iOS 17, macOS 14 and later)
/// has all five, and the vanilla build would add another 14 MB that no
/// supported system loads. So this probe checks the same five features with
/// the same five modules, and reports which one is missing — because without
/// it Ruffle would reach for the build that is not there, and the render would
/// fail with "Failed to load Ruffle WASM" and no mention of why.
///
/// A caller that means to render on a phone should run this, and should treat
/// a slow frame rate as possible rather than as a defect. See ``SWFRenderer``
/// for what "real time" means in practice.
public enum WebAssemblySupport {

    /// What a probe found.
    public enum Result: Sendable, Equatable {
        /// WebAssembly validated, compiled, instantiated and ran, with every
        /// extension the bundled Ruffle build needs.
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

    /// The five feature-detection modules Ruffle 0.6 validates before choosing
    /// its extensions build, byte for byte as `ruffle.js` has them. If any is
    /// refused, Ruffle falls back to the vanilla build, which is not bundled.
    static let rufflesRequiredExtensions: [(name: String, module: [UInt8])] = [
        ("bulk memory", [
            0, 97, 115, 109, 1, 0, 0, 0, 1, 4, 1, 96, 0, 0, 3, 2, 1, 0, 5, 3, 1, 0, 1, 10, 14, 1,
            12, 0, 65, 0, 65, 0, 65, 0, 252, 10, 0, 0, 11,
        ]),
        ("SIMD", [
            0, 97, 115, 109, 1, 0, 0, 0, 1, 5, 1, 96, 0, 1, 123, 3, 2, 1, 0, 10, 10, 1, 8, 0, 65,
            0, 253, 15, 253, 98, 11,
        ]),
        ("non-trapping float-to-int", [
            0, 97, 115, 109, 1, 0, 0, 0, 1, 4, 1, 96, 0, 0, 3, 2, 1, 0, 10, 12, 1, 10, 0, 67, 0,
            0, 0, 0, 252, 0, 26, 11,
        ]),
        ("sign extension", [
            0, 97, 115, 109, 1, 0, 0, 0, 1, 4, 1, 96, 0, 0, 3, 2, 1, 0, 10, 8, 1, 6, 0, 65, 0,
            192, 26, 11,
        ]),
        ("reference types", [
            0, 97, 115, 109, 1, 0, 0, 0, 1, 4, 1, 96, 0, 0, 3, 2, 1, 0, 10, 7, 1, 5, 0, 208, 112,
            26, 11,
        ]),
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
                if (value !== 42) return "the module ran and returned " + value;
                const missing = extensions
                    .filter((feature) => !WebAssembly.validate(new Uint8Array(feature.module)))
                    .map((feature) => feature.name);
                if (missing.length) {
                    return "WebAssembly runs, but without " + missing.join(", ")
                        + ", which the bundled Ruffle build requires";
                }
                return "ok";
                """,
                arguments: [
                    "moduleBytes": probeModule.map { Int($0) },
                    "extensions": rufflesRequiredExtensions.map {
                        ["name": $0.name, "module": $0.module.map { Int($0) }] as [String: Any]
                    },
                ],
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
