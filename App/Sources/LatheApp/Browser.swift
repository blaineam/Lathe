#if os(macOS)
import AppKit
#else
import UIKit
#endif
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
    let delegate = TabDelegate()

    /// Called when the page asks to close itself — `window.close()`.
    var requestClose: (() -> Void)?

    /// Told when this tab settles on a page, so history can be kept.
    var onNavigate: ((URL, String?) -> Void)?

    static let mediaChannel = "latheMedia"

    /// Mutes the page, and says when it starts making noise.
    ///
    /// Injected at document start into every frame, so it is in place before
    /// any media element exists.
    ///
    /// Muting by setting `muted` on the elements that exist is not enough, and
    /// that is what a muted tab talking again was: a page sets `muted = false`
    /// on its own whenever it likes — when its player is rebuilt for the next
    /// video, when an ad ends, when a script decides the user wants sound —
    /// and nothing put the mute back. So the property itself is taken over.
    /// While the tab is muted, `muted` reads true and cannot be written false;
    /// the page's own wish is remembered and handed back when the tab is
    /// unmuted, so unmuting restores what the page wanted rather than forcing
    /// sound on.
    ///
    /// The rest closes the other ways audio escapes:
    ///
    /// * **Shadow roots** are searched too — a player inside a custom element
    ///   is invisible to `document.querySelectorAll`.
    /// * **`volumechange`** re-asserts, for anything that slips past the
    ///   property (a different realm's prototype, say).
    /// * **Web Audio** is suspended: a player routed through an `AudioContext`
    ///   makes noise with every element muted.
    /// Adds `playsinline` to every <video>, including ones added later. See
    /// the iOS configuration in `init(configuration:url:)`.
    static let inlineVideoScript = """
        (() => {
          const mark = (v) => {
            if (!v.hasAttribute('playsinline')) v.setAttribute('playsinline', '');
            if (!v.hasAttribute('webkit-playsinline')) v.setAttribute('webkit-playsinline', '');
            v.playsInline = true;
          };
          const sweep = (root) => {
            if (root.tagName === 'VIDEO') mark(root);
            if (root.querySelectorAll) root.querySelectorAll('video').forEach(mark);
          };
          sweep(document);
          new MutationObserver((records) => {
            for (const r of records) r.addedNodes.forEach((n) => { if (n.nodeType === 1) sweep(n); });
          }).observe(document.documentElement || document, { childList: true, subtree: true });
        })();
        """

    static let mediaScript = """
        (function () {
          if (window.__lathe) { return; }
          var state = { muted: false, playing: 0, contexts: [] };
          window.__lathe = state;

          // What the page asked for, per element, while we were holding it
          // muted — so unmuting the tab gives the page back its own choice.
          var wanted = new WeakMap();

          function collect(root, out) {
            if (!root || !root.querySelectorAll) { return out; }
            root.querySelectorAll('video, audio').forEach(function (el) { out.push(el); });
            root.querySelectorAll('*').forEach(function (el) {
              if (el.shadowRoot) { collect(el.shadowRoot, out); }
            });
            return out;
          }

          function elements() {
            return collect(document, []);
          }

          function enforce(el) {
            if (!state.muted) { return; }
            try { if (!el.muted) { el.muted = true; } } catch (e) { /* not ours */ }
          }

          function apply() {
            elements().forEach(enforce);
            state.contexts.forEach(function (context) {
              try { state.muted ? context.suspend() : context.resume(); } catch (e) {}
            });
          }

          // The property itself, so a page cannot simply write the mute away.
          var media = window.HTMLMediaElement && window.HTMLMediaElement.prototype;
          var descriptor = media && Object.getOwnPropertyDescriptor(media, 'muted');
          if (descriptor && descriptor.set && descriptor.get) {
            Object.defineProperty(media, 'muted', {
              configurable: true,
              enumerable: descriptor.enumerable,
              get: function () {
                return state.muted ? true : descriptor.get.call(this);
              },
              set: function (value) {
                wanted.set(this, !!value);
                descriptor.set.call(this, state.muted ? true : !!value);
              }
            });
          }

          window.__latheSetMuted = function (on) {
            var was = state.muted;
            state.muted = !!on;
            elements().forEach(function (el) {
              if (state.muted) {
                if (!wanted.has(el)) { wanted.set(el, !!el.muted); }
                enforce(el);
              } else if (was) {
                // Back to whatever the page wanted while it was held.
                try { el.muted = wanted.has(el) ? wanted.get(el) : false; } catch (e) {}
              }
            });
            state.contexts.forEach(function (context) {
              try { state.muted ? context.suspend() : context.resume(); } catch (e) {}
            });
          };

          function report() {
            try {
              window.webkit.messageHandlers.\(mediaChannel).postMessage({
                playing: state.playing > 0
              });
            } catch (e) { /* the channel is gone; nothing to do */ }
          }

          document.addEventListener('play', function (event) {
            enforce(event.target);
            state.playing += 1;
            report();
          }, true);

          // A page that unmutes an element already playing fires this and
          // nothing else.
          document.addEventListener('volumechange', function (event) {
            enforce(event.target);
          }, true);

          ['pause', 'ended', 'emptied'].forEach(function (name) {
            document.addEventListener(name, function () {
              state.playing = Math.max(0, state.playing - 1);
              report();
            }, true);
          });

          // Audio that never goes near a media element.
          ['AudioContext', 'webkitAudioContext'].forEach(function (name) {
            var Original = window[name];
            if (!Original) { return; }
            function Patched() {
              var context = new (Function.prototype.bind.apply(
                Original, [null].concat(Array.prototype.slice.call(arguments))))();
              state.contexts.push(context);
              if (state.muted) { try { context.suspend(); } catch (e) {} }
              return context;
            }
            Patched.prototype = Original.prototype;
            window[name] = Patched;
          });

          new MutationObserver(apply).observe(
            document.documentElement || document,
            { childList: true, subtree: true, attributes: true, attributeFilter: ['muted', 'src'] });
        })();
        """

    convenience init(store: WKWebsiteDataStore, url: URL? = nil) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        self.init(configuration: configuration, url: url)
    }

    /// - Parameter configuration: for an ordinary tab, one we made. For a
    ///   popup, **the one WebKit handed us** — it carries the opener
    ///   relationship, and a view built from a fresh configuration is not the
    ///   window the page asked for.
    init(configuration: WKWebViewConfiguration, url: URL? = nil) {
        // Its own content controller, always — including for a popup, which
        // arrives carrying the *opener's*.
        //
        // `addScriptMessageHandler` raises when a handler with that name is
        // already registered, so reusing the opener's controller crashed the
        // app outright the first time any link opened in a new tab. Removing
        // the existing handler instead would have been worse: it is the
        // opener's, and taking it away would silently break muting in the tab
        // that spawned this one.
        //
        // Replacing it here is safe because a configuration is copied when the
        // web view is created, so the opener's own configuration is untouched.
        let controller = WKUserContentController()
        configuration.userContentController = controller
        #if os(iOS)
        // iPhone WebKit defaults to fullscreen-only video: any <video> the
        // page starts is torn out of the page into the system player, and
        // `playsinline` / muted autoplay previews never play in place. Set here
        // rather than in the convenience init so popup tabs get it as well.
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        // The setting only permits inline play; a <video> without the
        // `playsinline` attribute still leaves the page for fullscreen, and
        // most pages never set it. Mark every video so all of them play in
        // place, as on iPad and desktop. The fullscreen button still works.
        controller.addUserScript(WKUserScript(
            source: Self.inlineVideoScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false))
        #endif
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

        // Held strongly: `uiDelegate` and `navigationDelegate` are both weak,
        // so a delegate nobody else retains is deallocated immediately and
        // every dialog goes back to being silently dropped.
        delegate.tab = self
        webView.uiDelegate = delegate
        webView.navigationDelegate = delegate

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
        webView.uiDelegate = nil
        webView.navigationDelegate = nil
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
        adopt(BrowserTab(store: store, url: url))
    }

    /// A tab for a page that asked for a new window.
    ///
    /// Built from WebKit's configuration rather than ours, and deliberately
    /// **not** loaded here: WebKit performs the navigation itself once this
    /// returns the view. Loading the request as well would fetch it twice.
    private func popupTab(_ configuration: WKWebViewConfiguration) -> BrowserTab {
        adopt(BrowserTab(configuration: configuration))
    }

    @discardableResult
    private func adopt(_ tab: BrowserTab) -> BrowserTab {
        tab.onNavigate = { [weak self] url, title in
            self?.places.record(url: url, title: title)
        }
        tab.requestClose = { [weak self, weak tab] in
            guard let self, let tab else { return }
            close(tab)
        }
        tab.delegate.bringForward = { [weak self, weak tab] in
            guard let self, let tab else { return }
            selectedID = tab.id
        }
        tab.delegate.openTab = { [weak self] configuration, request in
            guard let self else { return nil }
            let opened = popupTab(configuration)
            // A `window.open()` with no URL is a page that means to write into
            // the new window itself, so there is nothing to show in the bar
            // until it does.
            if let url = request?.url { opened.address = url.absoluteString }
            return opened.webView
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
/// The platform's own container type. Everything else about this view — that
/// the tab owns the web view, that switching tabs swaps which one is on
/// screen rather than building a new one — is the same on both.
#if os(macOS)
typealias BrowserContainer = NSView
#else
typealias BrowserContainer = UIView
#endif

struct BrowserView {
    let tab: BrowserTab

    @MainActor
    fileprivate func container(_ context: CoordinatorHolder) -> BrowserContainer {
        let container = BrowserContainer()
        #if os(macOS)
        // The view a representable hands back is positioned by SwiftUI itself,
        // which on iOS means through the autoresizing mask. Turning that off
        // here leaves nothing to size the container and it comes out at zero,
        // so the page loads, reports no error, and is never drawn. AppKit's
        // side has always wanted it off.
        container.translatesAutoresizingMaskIntoConstraints = false
        #endif
        install(tab.webView, in: container)
        context.shown = tab.webView
        return container
    }

    @MainActor
    fileprivate func refresh(_ container: BrowserContainer, _ context: CoordinatorHolder) {
        // Switching tabs swaps which web view is on screen rather than making
        // a new one. The one that leaves keeps its page, its history and its
        // scroll position, because nothing tore it down.
        guard context.shown !== tab.webView else { return }
        let webView = tab.webView
        context.shown = webView
        #if os(macOS)
        container.subviews.forEach { $0.removeFromSuperview() }
        install(webView, in: container)
        #else
        // Never inside this update pass on iOS. The leaving web view usually
        // holds first responder (the page was just typed into, or the address
        // bar handed it focus), and removing it makes WebKit resign — which
        // SwiftUI answers with a focus update of its own, re-entering the
        // graph update that called us. Opening a new tab spun there until the
        // watchdog killed the app. On the next turn, focus is dropped first,
        // explicitly, and only then is the view swapped. A later switch that
        // overtakes this one wins: the check skips a stale swap.
        DispatchQueue.main.async { [self] in
            guard context.shown === webView else { return }
            container.endEditing(true)
            container.subviews.forEach { $0.removeFromSuperview() }
            install(webView, in: container)
        }
        #endif
    }

    @MainActor
    private func install(_ webView: WKWebView, in container: BrowserContainer) {
        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }

    func makeCoordinator() -> CoordinatorHolder { CoordinatorHolder() }
}

/// Remembers which web view is currently installed, so a redraw that is not a
/// tab change does not tear the page down.
@MainActor
final class CoordinatorHolder {
    var shown: WKWebView?
}

#if os(macOS)
extension BrowserView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { container(context.coordinator) }
    func updateNSView(_ view: NSView, context: Context) { refresh(view, context.coordinator) }
}
#else
extension BrowserView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { container(context.coordinator) }
    func updateUIView(_ view: UIView, context: Context) { refresh(view, context.coordinator) }
}
#endif
