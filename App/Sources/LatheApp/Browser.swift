import AppKit
import Foundation
import Network
import SwiftUI
import WebKit

/// One browser tab, and the web view that belongs to it.
///
/// ## Why the tab owns the view
///
/// A `WKWebView` created inside `makeNSView` lives and dies with the SwiftUI
/// view that made it, so switching to the Downloads pane and back threw the
/// page away and left a blank browser. Keeping the web view on the model makes
/// it outlive the view hierarchy, which is what makes a tab a tab: switching
/// away and back finds the page where you left it, still signed in, still
/// scrolled to where you were.
@MainActor
@Observable
final class BrowserTab: Identifiable {
    let id = UUID()

    var title: String?
    var currentURL: URL?
    var address: String
    var isLoading = false
    var canGoBack = false
    var canGoForward = false
    var lastError: String?

    /// Whether the address field for this tab has focus, so a page navigating
    /// in the background does not overwrite a half-typed address.
    var isEditingAddress = false

    /// Whether this tab's audio is silenced.
    ///
    /// There is no public API for this. `WKWebView` exposes
    /// `pauseAllMediaPlayback` and `setAllMediaPlaybackSuspended`, which stop
    /// playback rather than silence it — no use for a video you want to keep
    /// watching in one tab while another is talking over it — and the real
    /// mute is private SPI. So it is done in the page: see ``mediaScript``.
    var isMuted = false {
        didSet { applyMute() }
    }

    /// Whether something in this tab is making noise.
    ///
    /// Reported by the page rather than polled, so the speaker appears on the
    /// tab the moment audio starts rather than up to a second later.
    private(set) var isPlayingAudio = false

    /// Created once, here, and handed to whatever view is showing this tab.
    let webView: WKWebView

    private var observations: [NSKeyValueObservation] = []
    private var mediaRelay: MediaRelay?

    /// Told when this tab settles on a page, so history can be kept.
    var onNavigate: ((URL, String?) -> Void)?

    static let mediaChannel = "latheMedia"

    /// Mutes the page, and says when it starts making noise.
    ///
    /// Injected at document start into every frame, so it is in place before
    /// any media element exists. Three things are needed and none of them is
    /// optional:
    ///
    /// * **Apply on demand**, for the toggle.
    /// * **A `MutationObserver`**, because a page adds media elements long
    ///   after load and a mute applied once would not reach them.
    /// * **A capturing `play` listener**, because an element can be created,
    ///   muted-state read, and played inside one tick — faster than the
    ///   observer runs.
    static let mediaScript = """
        (function () {
          if (window.__lathe) { return; }
          var state = { muted: false, playing: 0 };
          window.__lathe = state;

          function elements() {
            return document.querySelectorAll('video, audio');
          }

          function apply() {
            elements().forEach(function (el) {
              if (state.muted) { el.muted = true; }
            });
          }

          window.__latheSetMuted = function (on) {
            state.muted = !!on;
            elements().forEach(function (el) { el.muted = state.muted; });
          };

          function report() {
            try {
              window.webkit.messageHandlers.\(mediaChannel).postMessage({
                playing: state.playing > 0
              });
            } catch (e) { /* the channel is gone; nothing to do */ }
          }

          document.addEventListener('play', function (event) {
            if (state.muted) { event.target.muted = true; }
            state.playing += 1;
            report();
          }, true);

          ['pause', 'ended', 'emptied'].forEach(function (name) {
            document.addEventListener(name, function () {
              state.playing = Math.max(0, state.playing - 1);
              report();
            }, true);
          });

          new MutationObserver(apply).observe(
            document.documentElement || document,
            { childList: true, subtree: true });
        })();
        """

    init(store: WKWebsiteDataStore, url: URL? = nil) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store

        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(
            source: Self.mediaScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false))
        configuration.userContentController = controller

        webView = WKWebView(frame: .zero, configuration: configuration)

        // A separate object holds the handler, because the content controller
        // retains it and a tab that held its own handler would never be
        // deallocated — a closed tab would keep its page, and its audio, alive
        // forever.
        webView.allowsBackForwardNavigationGestures = true
        // Sites serve very different pages to a browser they do not recognise,
        // and an embedded web view with no application name is one of those.
        webView.customUserAgent = nil
        address = url?.absoluteString ?? ""

        // After every stored property is initialised, because both of these
        // capture `self`.
        let relay = MediaRelay()
        mediaRelay = relay
        controller.add(relay, name: Self.mediaChannel)
        relay.onAudioChange = { [weak self] playing in
            MainActor.assumeIsolated { self?.isPlayingAudio = playing }
        }
        observe()
        if let url { webView.load(URLRequest(url: url)) }
    }

    /// Follow the web view's own properties rather than its navigations.
    ///
    /// The navigation delegate is not enough on its own. Every large site is a
    /// single-page application now — YouTube, Reddit and the rest move between
    /// pages with `history.pushState`, which changes the URL and the document
    /// without starting a navigation. `didFinish` never fires, and an address
    /// bar updated only from there sits on whatever page you first landed on
    /// while you browse away from it.
    private func observe() {
        observations = [
            webView.observe(\.url, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.currentURL = view.url
                    if !self.isEditingAddress, let url = view.url {
                        self.address = url.absoluteString
                    }
                    // A new document means a new copy of the script with its
                    // own state, so the mute has to be re-asserted.
                    if self.isMuted { self.applyMute() }
                    self.isPlayingAudio = false
                }
            },
            webView.observe(\.title, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.title = view.title
                    // Recorded on the title rather than on the URL: a page's
                    // title arrives after its address, and an entry saved at
                    // navigation time is an entry with no name on it.
                    if let url = view.url, view.title?.isEmpty == false {
                        self.onNavigate?(url, view.title)
                    }
                }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.isLoading = view.isLoading }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] view, _ in
                MainActor.assumeIsolated { self?.canGoForward = view.canGoForward }
            },
        ]
    }

    /// Re-asserts the mute, in the page.
    ///
    /// Also called after a navigation: the script is injected fresh into every
    /// document, so a tab muted on one page would start talking on the next
    /// without this.
    private func applyMute() {
        webView.evaluateJavaScript("window.__latheSetMuted && window.__latheSetMuted(\(isMuted))")
    }

    func toggleMute() { isMuted.toggle() }

    /// What to put on the tab.
    var label: String {
        if let title, !title.isEmpty { return title }
        if let host = currentURL?.host() { return host }
        return "New tab"
    }

    var host: String? { currentURL?.host() }

    func go() {
        var text = address.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if !text.contains("://") {
            // A single word with no dot is a search, not a hostname. Typing
            // "swift" and being sent to http://swift/ is not what anybody meant.
            if text.contains(".") && !text.contains(" ") {
                text = "https://" + text
            } else {
                let terms = text.addingPercentEncoding(
                    withAllowedCharacters: .urlQueryAllowed) ?? text
                text = "https://duckduckgo.com/?q=" + terms
            }
        }
        guard let url = URL(string: text) else { return }
        lastError = nil
        webView.load(URLRequest(url: url))
    }

    func load(_ url: URL) {
        address = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    /// Releases what would otherwise outlive the tab.
    ///
    /// The message handler is retained by the content controller, and the
    /// observations are retained by this object. Without both, a closed tab's
    /// web view stays alive with its page still running — which for a video is
    /// audible.
    func tearDown() {
        observations.removeAll()
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: Self.mediaChannel)
        mediaRelay = nil
        webView.loadHTMLString("", baseURL: nil)
    }

    func back() { webView.goBack() }
    func forward() { webView.goForward() }
    func reload() { webView.reload() }
    func stop() { webView.stopLoading() }

    /// Writes this page's cookies in the Netscape format extractors read.
    ///
    /// **Only the cookies for this page's domain**, not the whole store. An
    /// extractor needs the session for the site being downloaded and has no use
    /// for anything else, so handing it everything would be a larger disclosure
    /// than the job requires — to a tool the user installed themselves, but
    /// still larger than necessary.
    func exportCookies(to url: URL) async throws {
        guard let host = currentURL?.host() else { return }
        let cookies = await webView.configuration.websiteDataStore
            .httpCookieStore.allCookies()

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

/// Carries the page's media notices back to its tab.
///
/// Its own object because `WKUserContentController` retains a message handler
/// for as long as it lives, and it lives as long as the web view. A tab that
/// registered itself would be in a cycle with its own web view and would never
/// be released — so a closed tab would keep playing.
final class MediaRelay: NSObject, WKScriptMessageHandler {
    var onAudioChange: ((Bool) -> Void)?

    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let playing = body["playing"] as? Bool
        else { return }
        onAudioChange?(playing)
    }
}

/// The browser: a set of tabs and which one is showing.
@MainActor
@Observable
final class BrowserModel {
    private(set) var tabs: [BrowserTab] = []
    var selectedID: BrowserTab.ID?

    /// The proxy every tab's traffic goes through, or `nil` for direct.
    ///
    /// Held here rather than read from the queue because changing it has to
    /// rebuild the data store, and that is this type's business.
    private(set) var proxy: SOCKSProxy?

    /// Where the tabs have been, and where they are bookmarked.
    let places = Places()

    private var store: WKWebsiteDataStore

    init() {
        store = WKWebsiteDataStore.default()
    }

    /// Makes sure there is a tab to show.
    ///
    /// Not done in `init`, because the model is created as `@State` on the
    /// `App` struct — which runs before `NSApplication` has finished launching.
    /// Building a `WKWebView` that early brings WebKit up before AppKit is
    /// ready, and the window never appears at all: no crash, no log, just an
    /// application sitting in its run loop with nothing on screen.
    func ensureTab() {
        if tabs.isEmpty { newTab() }
    }

    var selected: BrowserTab? {
        tabs.first { $0.id == selectedID } ?? tabs.first
    }

    @discardableResult
    func newTab(_ url: URL? = nil) -> BrowserTab {
        let tab = BrowserTab(store: store, url: url)
        tab.onNavigate = { [weak self] url, title in
            self?.places.record(url: url, title: title)
        }
        tabs.append(tab)
        selectedID = tab.id
        return tab
    }

    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        // Stop the page before dropping it: a video left playing in a closed
        // tab keeps playing, because nothing else is holding the web view and
        // deallocation is not immediate.
        tab.stop()
        tab.tearDown()
        tabs.remove(at: index)

        if tabs.isEmpty {
            newTab()
        } else if selectedID == tab.id {
            // Select the neighbour on the left, which is where the eye already
            // is after a close.
            selectedID = tabs[max(0, index - 1)].id
        }
    }

    func select(_ tab: BrowserTab) { selectedID = tab.id }

    /// Routes every tab through a SOCKS proxy, or stops doing so.
    ///
    /// ## What this does and does not buy you
    ///
    /// It routes the browser's traffic, name resolution included. It does
    /// **not** make you anonymous, and the interface says so: this is the same
    /// data store with the same logins in it, so a site you are signed in to
    /// knows exactly who you are regardless of where the packets came from.
    /// What it does give you is a network path that does not identify your
    /// address — useful for reaching something, not for being nobody.
    ///
    /// Existing tabs keep their pages; the new routing takes effect on their
    /// next load, which is why this reloads them.
    func setProxy(_ proxy: SOCKSProxy?) {
        guard proxy != self.proxy else { return }
        self.proxy = proxy

        let store = WKWebsiteDataStore.default()
        if let proxy {
            store.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: proxy.endpoint)]
        } else {
            store.proxyConfigurations = []
        }
        self.store = store
        // Nothing visited over the proxy is written down. Recording it would
        // undo most of the point of turning it on.
        places.isPrivate = proxy != nil

        for tab in tabs where tab.currentURL != nil {
            tab.reload()
        }
    }
}

/// Shows one tab's web view.
///
/// The view is created by the tab, not here, which is the whole reason a tab
/// survives being switched away from.
struct BrowserView: NSViewRepresentable {
    let tab: BrowserTab

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        install(tab.webView, in: container)
        context.coordinator.shown = tab.webView
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        // Switching tabs swaps which web view is on screen rather than making
        // a new one. The one that leaves keeps its page, its history and its
        // scroll position, because nothing tore it down.
        guard context.coordinator.shown !== tab.webView else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        install(tab.webView, in: container)
        context.coordinator.shown = tab.webView
    }

    private func install(_ webView: WKWebView, in container: NSView) {
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var shown: WKWebView?
    }
}
