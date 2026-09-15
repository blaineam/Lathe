import Foundation
import SwiftUI
import WebKit

/// A browser, so a download can inherit a session the user already signed in to.
///
/// ## Why the app has a browser at all
///
/// Most of what people want to download is behind a login, and an extractor
/// invoked from outside has no idea who the user is. Every existing answer to
/// that is bad: typing credentials into a downloader, or scraping cookies out of
/// Safari's store behind the user's back. Browsing *inside* the app means the
/// session is one the user made, in view, and can see — and the cookies handed
/// to the extractor are only the ones for the site they were looking at.
@MainActor
@Observable
final class BrowserModel {
    var address = "https://"
    var currentURL: URL?
    var title: String?
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var lastError: String?

    /// Whether the address field has focus.
    ///
    /// Set by the view so that a page navigating in the background does not
    /// overwrite a half-typed address.
    var isEditingAddress = false

    /// Set by the view once its WKWebView exists.
    weak var webView: WKWebView?

    func go() {
        var text = address.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text) else { return }
        webView?.load(URLRequest(url: url))
    }

    func back() { webView?.goBack() }
    func forward() { webView?.goForward() }
    func reload() { webView?.reload() }

    /// Writes the current page's cookies in the Netscape format extractors read.
    ///
    /// **Only the cookies for this page's domain**, not the whole store. An
    /// extractor needs the session for the site being downloaded and has no use
    /// for anything else, so handing it everything would be a larger disclosure
    /// than the job requires — to a tool the user installed themselves, but
    /// still larger than necessary.
    func exportCookies(to url: URL) async throws {
        guard let host = currentURL?.host() else { return }
        let store = webView?.configuration.websiteDataStore ?? .default()
        let cookies = await store.httpCookieStore.allCookies()

        var text = "# Netscape HTTP Cookie File\n"
        text += "# Written by Lathe from the page you were looking at.\n"
        for cookie in cookies where host.hasSuffix(cookie.domain.drop(while: { $0 == "." })) {
            let includeSubdomains = cookie.domain.hasPrefix(".") ? "TRUE" : "FALSE"
            let secure = cookie.isSecure ? "TRUE" : "FALSE"
            let expiry = Int(cookie.expiresDate?.timeIntervalSince1970 ?? 0)
            text += [cookie.domain, includeSubdomains, cookie.path, secure,
                     String(expiry), cookie.name, cookie.value].joined(separator: "\t") + "\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}

struct BrowserView: NSViewRepresentable {
    let model: BrowserModel

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // A persistent store, so a login survives a relaunch and the user does
        // not have to sign in every time they want to fetch something.
        configuration.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        model.webView = view
        context.coordinator.observe(view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let model: BrowserModel
        private var observations: [NSKeyValueObservation] = []

        init(model: BrowserModel) { self.model = model }

        /// Follow the web view's own properties rather than its navigations.
        ///
        /// The navigation delegate is not enough on its own. Every large site
        /// is a single-page application now: YouTube, Reddit and the rest move
        /// between pages with `history.pushState`, which changes the URL and
        /// the document without starting a navigation, so `didFinish` never
        /// fires and an address bar updated only from there sits on whatever
        /// page the user first landed on while they browse away from it.
        ///
        /// `url` and `title` are KVO-compliant precisely for this, and
        /// observing them catches both kinds of change with one code path.
        func observe(_ view: WKWebView) {
            observations = [
                view.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
                    MainActor.assumeIsolated { self?.sync(view) }
                },
                view.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
                    MainActor.assumeIsolated { self?.model.title = view.title }
                },
                view.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                    MainActor.assumeIsolated { self?.model.canGoBack = view.canGoBack }
                },
                view.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                    MainActor.assumeIsolated { self?.model.canGoForward = view.canGoForward }
                },
                view.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
                    MainActor.assumeIsolated { self?.model.isLoading = view.isLoading }
                },
            ]
        }

        func stopObserving() { observations.removeAll() }

        private func sync(_ view: WKWebView) {
            model.currentURL = view.url
            // Not while the field has focus: overwriting what somebody is
            // halfway through typing because a background frame navigated is
            // the single most irritating thing an address bar can do.
            if !model.isEditingAddress {
                model.address = view.url?.absoluteString ?? model.address
            }
        }

        func webView(_ webView: WKWebView, didFail: WKNavigation!, withError error: any Error) {
            model.isLoading = false
            model.lastError = (error as NSError).localizedDescription
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation: WKNavigation!, withError error: any Error
        ) {
            model.isLoading = false
            // -999 is "cancelled", which is what a redirect or a user clicking
            // again looks like. Reporting it as a failure would mean the bar
            // shows an error every time a site bounces through a redirect.
            let failure = error as NSError
            if failure.code != NSURLErrorCancelled {
                model.lastError = failure.localizedDescription
            }
        }
    }
}
