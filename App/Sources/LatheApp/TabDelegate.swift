import AppKit
import WebKit

/// Answers the things a page asks of its browser.
///
/// A `WKWebView` with no `uiDelegate` does not ignore `alert()` gracefully —
/// it discards the call, and the page carries on as though the user had
/// dismissed a dialog they never saw. `confirm()` returns false forever and
/// `prompt()` returns nil, so any site gated behind one simply does not work.
/// The same delegate is what makes `target="_blank"` open anything at all:
/// without it those links are inert.
///
/// ## The rule that matters most
///
/// **Every completion handler here must be called exactly once.** WebKit
/// serialises page-initiated dialogs, so one that is never answered stops the
/// page — and often the whole web content process — from ever showing another.
/// One that is answered twice traps. Hence `Answer`, which makes both mistakes
/// impossible rather than relying on every path being written correctly.
@MainActor
final class TabDelegate: NSObject, WKUIDelegate, WKNavigationDelegate {

    weak var tab: BrowserTab?

    /// Asks the browser for a new tab to load into. Returns the web view
    /// WebKit should use, or nil to refuse.
    var openTab: ((WKWebViewConfiguration, URLRequest?) -> WKWebView?)?

    /// Brings this tab forward, because a dialog belongs to a page the user
    /// can see. A sheet over a tab that is not showing is a sheet about
    /// nothing.
    var bringForward: (() -> Void)?

    /// A completion handler that fires exactly once — no more, and no fewer.
    ///
    /// The "no fewer" half is what the fallback is for. If the dialog is
    /// destroyed without being answered — a window that went away, a tab
    /// closed mid-question — WebKit is still waiting, and it will wait
    /// forever. The fallback is the answer it gets instead, which is always
    /// the same as dismissing: no, nothing, cancelled.
    private final class Answer<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: ((Value) -> Void)?
        private let fallback: Value

        init(fallback: Value, _ handler: @escaping (Value) -> Void) {
            self.fallback = fallback
            self.handler = handler
        }

        func callAsFunction(_ value: Value) {
            lock.lock()
            let handler = self.handler
            self.handler = nil
            lock.unlock()
            handler?(value)
        }

        deinit {
            lock.lock()
            let unanswered = handler
            handler = nil
            lock.unlock()
            unanswered?(fallback)
        }
    }

    // MARK: - Dialogs

    /// The page's own origin, shown on every dialog.
    ///
    /// Not decoration. A page can put "macOS needs your password to continue"
    /// inside an `alert()`, and an unattributed dialog in the middle of the
    /// window is indistinguishable from one the application put there.
    /// Naming the site is what makes the difference visible.
    private func alert(_ frame: WKFrameInfo, _ message: String) -> NSAlert {
        let alert = NSAlert()
        let host = frame.request.url?.host() ?? tab?.host ?? "This page"
        alert.messageText = host
        alert.informativeText = message
        alert.alertStyle = .informational
        return alert
    }

    private func present(_ alert: NSAlert, then respond: @escaping (NSApplication.ModalResponse) -> Void) {
        bringForward?()
        // A sheet on the page's own window, so it is visibly attached to the
        // page rather than floating as though the app raised it.
        if let window = tab?.webView.window {
            alert.beginSheetModal(for: window, completionHandler: respond)
        } else {
            respond(alert.runModal())
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let answer = Answer<Void>(fallback: ()) { completionHandler() }
        let panel = alert(frame, message)
        panel.addButton(withTitle: "OK")
        present(panel) { _ in answer(()) }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let answer = Answer<Bool>(fallback: false, completionHandler)
        let panel = alert(frame, message)
        panel.addButton(withTitle: "OK")
        panel.addButton(withTitle: "Cancel")
        present(panel) { response in answer(response == .alertFirstButtonReturn) }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let answer = Answer<String?>(fallback: nil, completionHandler)
        let panel = alert(frame, prompt)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        panel.accessoryView = field
        panel.addButton(withTitle: "OK")
        panel.addButton(withTitle: "Cancel")
        present(panel) { response in
            // nil, not "", for a cancel: a page distinguishes them, and
            // returning an empty string reads as "they typed nothing".
            answer(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    /// `<input type="file">`.
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let answer = Answer<[URL]?>(fallback: nil, completionHandler)
        bringForward?()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        if let window = tab?.webView.window {
            panel.beginSheetModal(for: window) { response in
                answer(response == .OK ? panel.urls : nil)
            }
        } else {
            answer(panel.runModal() == .OK ? panel.urls : nil)
        }
    }

    // MARK: - New windows

    /// A link that asked for a new window — `target="_blank"`, or
    /// `window.open`.
    ///
    /// Returning nil means "refused", and WebKit then does nothing at all,
    /// which is what made those links inert. The web view returned here has to
    /// be built with **the configuration WebKit passed**: it carries the
    /// opener relationship, and a view made with a fresh configuration is not
    /// the window the page asked for.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // `targetFrame == nil` is the signal that the navigation had nowhere
        // to go. When it is non-nil the page is targeting a frame it already
        // has, and WebKit handles it without this.
        let request = navigationAction.targetFrame == nil ? navigationAction.request : nil
        return openTab?(configuration, request)
    }

    /// `window.close()`.
    func webViewDidClose(_ webView: WKWebView) {
        tab?.requestClose?()
    }

    // MARK: - Navigation

    func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error
    ) {
        tab?.lastError = (error as NSError).localizedDescription
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        let failure = error as NSError
        // -999 is "cancelled", which is what a redirect, a stopped load, or a
        // second click looks like. Reporting it would put an error in the bar
        // every time a site bounces through a redirect.
        guard failure.code != NSURLErrorCancelled else { return }
        tab?.lastError = failure.localizedDescription
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        tab?.lastError = nil
    }
}
