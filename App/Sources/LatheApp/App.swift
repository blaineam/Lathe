import AppKit
import LatheCore
import LatheFetch
import SwiftUI

/// The entry point.
///
/// Its own type rather than `@main` on the `App`, because defining
/// `static func main()` on the App itself replaces the one SwiftUI synthesises
/// and there is then no way to call the original. This runs the diagnostic
/// when asked and hands over to SwiftUI otherwise.
@main
enum Entry {
    static func main() {
        /// Starts the embedded Tor client, waits for its SOCKS port, and exits.
        ///
        ///     Lathe.app/Contents/MacOS/Lathe --tor-selftest
        ///
        /// A real check that the linked daemon runs, rather than a check that
        /// it linked. "The symbols resolved" and "it reaches the Tor network"
        /// are very different claims, and only one of them is worth making to
        /// somebody who turned the toggle on.
        if CommandLine.arguments.contains("--tor-selftest") {
            TorSelfTest.run()
            return
        }
        /// Reports whether macOS will accept a login registration from this
        /// build. It refuses one from an app it cannot verify, and the failure
        /// is worth knowing about before somebody flips the switch and it
        /// silently does nothing.
        ///
        ///     Lathe.app/Contents/MacOS/Lathe --login-selftest
        if CommandLine.arguments.contains("--login-selftest") {
            LoginSelfTest.run()
            return
        }
        LatheApp.main()
    }
}

struct LatheApp: App {
    @State private var queue = Queue()
    @State private var browser = BrowserModel()
    @State private var presence = Presence()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Lathe", id: "main") {
            RootView(queue: queue, browser: browser)
                .frame(minWidth: 900, minHeight: 580)
                .task { await queue.refreshTools() }
                .task(id: presence.style) { presence.apply() }
                // Browsing and downloading go the same way. A toggle that
                // routed the downloader but left the browser in the clear
                // would be worse than no toggle: the page you visited to find
                // the link is the part that identifies you.
                .task(id: queue.routingSignature) {
                    browser.setProxy(queue.useTor ? queue.activeProxy : nil)
                }
        }
        .windowResizability(.contentMinSize)
        // One continuous surface: no title bar, no separator, the traffic
        // lights sitting in the same row as the app's own controls. The
        // segmented control moves into the toolbar to fill that row — a
        // hidden title bar with the picker still below it would leave an empty
        // strip where the title used to be, which is worse than the title.
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { CommandGroup(replacing: .newItem) {} }

        // The menu bar item. Always present in menu-bar mode, because it is
        // the only way back to the app; optional in Dock mode, where the Dock
        // icon already does that job.
        MenuBarExtra(isInserted: Binding(
            get: { presence.menuBarItemIsVisible },
            set: { presence.showsMenuBarItem = $0 })
        ) {
            MenuBarContents(queue: queue, presence: presence)
        } label: {
            // The count, so a glance at the menu bar answers the only question
            // anybody has of a downloader that is not on screen.
            Label {
                Text(queue.activeCount == 0 ? "" : "\(queue.activeCount)")
            } icon: {
                Image(systemName: queue.isRunning
                      ? "arrow.down.circle.fill" : "arrow.down.circle")
            }
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(queue: queue, browser: browser, presence: presence)
        }
    }
}

enum Pane: String, CaseIterable, Identifiable {
    case queue = "Downloads"
    case browse = "Browse"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .queue: return "arrow.down.circle"
        case .browse: return "globe"
        }
    }
}

struct RootView: View {
    @Bindable var queue: Queue
    @Bindable var browser: BrowserModel
    @State private var pane: Pane = .queue

    var body: some View {
        VStack(spacing: 0) {
            // Both panes stay in the hierarchy, and switching changes which
            // one is visible.
            //
            // A `switch` here destroys the pane that leaves, which for the
            // browser means tearing down its web views: coming back found a
            // blank page, signed out, with the history gone. The tabs own
            // their web views now, but a pane that is rebuilt from nothing
            // every time is still the wrong shape for something you switch
            // away from and expect to find as you left it.
            ZStack {
                QueueView(queue: queue)
                    .opacity(pane == .queue ? 1 : 0)
                    .allowsHitTesting(pane == .queue)
                    .accessibilityHidden(pane != .queue)
                BrowsePane(queue: queue, browser: browser)
                    .opacity(pane == .browse ? 1 : 0)
                    .allowsHitTesting(pane == .browse)
                    .accessibilityHidden(pane != .browse)
            }
        }
        .background {
            // A soft ground so the glass above it has something to refract.
            // Glass over a flat fill reads as a grey box.
            LinearGradient(
                colors: [Color.accentColor.opacity(0.18), Color.clear],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $pane) {
                    ForEach(Pane.allCases) { pane in
                        Label(pane.rawValue, systemImage: pane.icon).tag(pane)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
                .fixedSize()
            }
            ToolbarItem(placement: .primaryAction) {
                Button { queue.revealDestination() } label: {
                    Label("Downloads folder", systemImage: "folder")
                }
                .help("Open the folder downloads go into")
            }
        }
    }
}

// MARK: - Downloads

struct QueueView: View {
    @Bindable var queue: Queue
    @State private var input = ""

    var body: some View {
        VStack(spacing: 12) {
            if !queue.tools.ytdlpInstalled || !queue.tools.galleryDLInstalled {
                OnboardingBanner(queue: queue)
                    .padding(.horizontal, 16)
            }

            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                    TextField("Paste a link, or several", text: $input, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .onSubmit(add)
                    Picker("", selection: $queue.defaultScope) {
                        ForEach(Scope.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .help("Whether a link that names a collection means the one item or all of it")

                    Button("Add", action: add)
                        .buttonStyle(.glassProminent)
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(14)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
            }
            .padding(.horizontal, 16)

            if queue.downloads.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(queue.downloads) { download in
                            DownloadRow(download: download) { queue.remove(download) }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            footer
        }
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("Nothing queued")
                .font(.title3)
            Text("Paste a link above, or find something in Browse.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                queue.chooseDestination()
            } label: {
                Label(
                    queue.destination?.lastPathComponent
                        ?? queue.defaultDestination()?.lastPathComponent ?? "Choose folder",
                    systemImage: "folder"
                )
            }
            .buttonStyle(.glass)

            if let summary = queue.summary {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            Button("Clear finished") { queue.clearFinished() }
                .buttonStyle(.glass)
                .disabled(queue.isRunning)

            Button(queue.isRunning ? "Downloading…" : "Download") {
                Task { await queue.start() }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(queue.isRunning || queue.downloads.allSatisfy(\.state.isTerminal))
        }
        .padding(.horizontal, 16)
    }

    private func add() {
        queue.add(text: input)
        input = ""
    }
}

struct DownloadRow: View {
    @Bindable var download: Download
    let remove: () -> Void

    private var isFailed: Bool {
        if case .failed = download.state { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 12) {
            icon
                .font(.title3)
                .frame(width: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(download.displayTitle).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }

            Spacer()

            if !download.state.isTerminal || isFailed {
                Picker("", selection: Binding(
                    get: { download.scope }, set: { download.scope = $0 })
                ) {
                    ForEach(Scope.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help("Whether this link means the one item or everything it points at")
            }

            if download.cookieFile != nil {
                Image(systemName: "person.badge.key.fill")
                    .foregroundStyle(.tint)
                    .help("Using the session you signed in to in Browse")
            }

            if case .finished(let url) = download.state {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: { Image(systemName: "folder") }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
            } else {
                Button(action: remove) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }

    @ViewBuilder private var icon: some View {
        switch download.state {
        case .queued: Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        case .inspecting, .running: ProgressView().controlSize(.small)
        case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var detail: String {
        switch download.state {
        case .queued: return download.host
        case .inspecting: return "looking at what this is…"
        case .running:
            let tool = download.resolvedTool.map { " with \($0.label)" } ?? ""
            return download.detail ?? "downloading\(tool)…"
        case .finished(let url):
            if let detail = download.detail { return "\(url.lastPathComponent) — \(detail)" }
            return url.lastPathComponent
        // The reason, in full. A failure a user cannot act on is one they have
        // to ask somebody else about.
        case .failed(let why): return why
        }
    }
}

// MARK: - Onboarding

struct OnboardingBanner: View {
    @Bindable var queue: Queue

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.title2)
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 3) {
                Text("Add a downloader").font(.headline)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            if queue.tools.ytdlpInstalling || queue.tools.galleryDLInstalling {
                ProgressView().controlSize(.small)
            } else {
                if !queue.tools.ytdlpInstalled {
                    Button("Install yt-dlp") {
                        Task { await queue.installYouTubeDL() }
                    }
                    .buttonStyle(.glassProminent)
                    .help("Video and audio sites")
                }
                if !queue.tools.galleryDLInstalled {
                    Button("Install gallery-dl") {
                        Task { await queue.installGalleryDL() }
                    }
                    .buttonStyle(.glass)
                    .help("Image and gallery sites")
                }
            }
        }
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var message: String {
        if let error = queue.tools.lastError { return error }
        if let note = queue.tools.installMessage { return note }
        // Said plainly, because it is the honest description of the product:
        // Lathe ships no extractor, and a direct link needs none.
        if !queue.tools.anyExtractor {
            return "Lathe ships no extractor. Direct links to media files already work; "
                + "sites that need one can use yt-dlp for video and gallery-dl for images, "
                + "installed here from PyPI."
        }
        if !queue.tools.galleryDLInstalled {
            return "yt-dlp handles video and audio. gallery-dl covers the image and gallery "
                + "sites it does not — they are picked per link, automatically."
        }
        return "gallery-dl is installed. yt-dlp covers video and audio sites."
    }
}

// MARK: - Browse

struct BrowsePane: View {
    @Bindable var queue: Queue
    @Bindable var browser: BrowserModel
    @FocusState private var addressFocused: Bool
    @State private var adopted: Set<String> = []

    private var tab: BrowserTab? { browser.selected }

    var body: some View {
        VStack(spacing: 8) {
            TabStrip(browser: browser)
                .onAppear { browser.ensureTab() }

            if let tab {
                AddressBar(queue: queue, browser: browser, tab: tab,
                           adopted: $adopted, addressFocused: $addressFocused)
                .padding(.horizontal, 16)

                if let error = tab.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 20)
                }

                BrowserView(tab: tab)
                    .clipShape(.rect(cornerRadius: 14))
                    .padding(.horizontal, 16)
            }

            // The point of this rail: start something and keep browsing. A
            // download you have to leave the page to watch is a download you
            // stop watching.
            ActivityRail(queue: queue)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
        }
        .padding(.top, 10)
    }
}

/// The row of tabs.
struct TabStrip: View {
    @Bindable var browser: BrowserModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(browser.tabs) { tab in
                    TabChip(tab: tab,
                            isSelected: tab.id == browser.selected?.id,
                            canClose: browser.tabs.count > 1,
                            select: { browser.select(tab) },
                            close: { browser.close(tab) })
                }
                Button { browser.newTab() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24)
                }
                // `.circle` rather than a rounded rectangle: the tabs beside
                // it are rectangles, and a round button is read as an action
                // rather than as another tab.
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("New tab")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
        .frame(height: 34)
    }
}

struct TabChip: View {
    @Bindable var tab: BrowserTab
    let isSelected: Bool
    let canClose: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    /// The speaker stays put once a tab has made a sound.
    ///
    /// Showing it only while audio is actually playing means it appears and
    /// disappears between tracks, and the button moves out from under the
    /// pointer just as it is reached for. A tab that has played something
    /// keeps its control.
    private var showsSound: Bool { tab.isPlayingAudio || tab.isMuted }

    var body: some View {
        HStack(spacing: 6) {
            if tab.isLoading {
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 11)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Text(tab.label)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)

            // On the chip rather than in the toolbar, so a tab that starts
            // talking can be silenced without switching to it first — which is
            // the entire situation this is for.
            if showsSound {
                Button { tab.toggleMute() } label: {
                    Image(systemName: tab.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 9))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(tab.isMuted ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                .help(tab.isMuted ? "Unmute this tab" : "Mute this tab")
            }

            // The close button appears on hover or on the selected tab, so a
            // row of tabs is a row of titles rather than a row of crosses.
            if (hovering || isSelected) && canClose {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.borderless)
                .help("Close tab")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(minWidth: 96, maxWidth: 200)
        .glassEffect(isSelected ? .regular.tint(.accentColor.opacity(0.35)) : .regular,
                     in: .rect(cornerRadius: 9))
        .contentShape(.rect)
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
    }
}

struct AddressBar: View {
    @Bindable var queue: Queue
    @Bindable var browser: BrowserModel
    @Bindable var tab: BrowserTab
    @Binding var adopted: Set<String>
    @FocusState.Binding var addressFocused: Bool
    @State private var asking: StartIntent?

    private var signedIn: Bool {
        if let host = tab.host { return adopted.contains(host) }
        return false
    }

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 8) {
                Button { tab.back() } label: { Image(systemName: "chevron.left") }
                    .disabled(!tab.canGoBack)
                Button { tab.forward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!tab.canGoForward)
                // An explicit closure, not `tab.isLoading ? tab.stop : tab.reload`.
                // A ternary between two method references gives the type checker
                // two unbound `(BrowserTab) -> () -> Void` values to reconcile
                // inside a ViewBuilder, and it gives up without a diagnostic.
                Button {
                    if tab.isLoading { tab.stop() } else { tab.reload() }
                } label: {
                    Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                }

                TextField("Search, or enter an address", text: $tab.address)
                    .textFieldStyle(.plain)
                    .focused($addressFocused)
                    .onSubmit(tab.go)
                    .onChange(of: addressFocused) { tab.isEditingAddress = addressFocused }

                Menu {
                    if !browser.places.bookmarks.isEmpty {
                        Section("Bookmarks") {
                            ForEach(browser.places.bookmarks.prefix(12)) { place in
                                Button(place.label) { tab.load(place.url) }
                            }
                        }
                    }
                    if !browser.places.recent.isEmpty {
                        Section("Recent") {
                            ForEach(browser.places.recent.prefix(12)) { place in
                                Button(place.label) { tab.load(place.url) }
                            }
                        }
                        Divider()
                        // Where somebody actually looks for it: in the list
                        // they want emptied, not three panes away in Settings.
                        Button("Clear recently visited", role: .destructive) {
                            browser.places.clearRecent()
                        }
                    }
                    if browser.places.bookmarks.isEmpty && browser.places.recent.isEmpty {
                        Text("Nothing yet")
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Bookmarks and recently visited")

                Button {
                    if let url = tab.currentURL {
                        browser.places.toggleBookmark(url: url, title: tab.title)
                    }
                } label: {
                    Image(systemName: browser.places.isBookmarked(tab.currentURL)
                          ? "bookmark.fill" : "bookmark")
                }
                .buttonStyle(.glass)
                .disabled(tab.currentURL == nil)
                .help("Bookmark this page")

                if tab.isPlayingAudio || tab.isMuted {
                    Button { tab.toggleMute() } label: {
                        Image(systemName: tab.isMuted
                              ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .buttonStyle(.glass)
                    .help(tab.isMuted ? "Unmute this tab" : "Mute this tab")
                }

                if queue.useTor {
                    Image(systemName: "eye.slash.fill")
                        .foregroundStyle(.tint)
                        .help("This tab's traffic is going through the proxy. "
                              + "That hides where you are connecting from — it does not "
                              + "sign you out of anything.")
                }

                Button {
                    Task {
                        if let host = await queue.adoptCookies(from: tab) {
                            adopted.insert(host)
                        }
                    }
                } label: {
                    Image(systemName: signedIn ? "person.badge.key.fill" : "person.badge.key")
                }
                .buttonStyle(.glass)
                .disabled(tab.host == nil)
                .help("Hand this site's cookies to the downloader, so it sees the same "
                      + "signed-in session you do. Only this site's cookies, never the rest.")

                Button("Queue") { asking = .queue }
                    .buttonStyle(.glass)
                    .disabled(tab.currentURL == nil)
                    .help("Add to the queue and download it with everything else")

                Button { asking = .now } label: {
                    Label("Download", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.glassProminent)
                .disabled(tab.currentURL == nil)
                .help("Start this one now, without waiting for the rest of the queue")
            }
            .padding(10)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        }
        // Asked rather than assumed. A page in a browser is as likely to be a
        // gallery, a playlist or a profile as it is to be one item, and
        // silently taking "just this" off a page of two hundred pictures is
        // the wrong guess often enough to be worth one tap.
        .confirmationDialog(
            "How much of this page?",
            isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } }),
            titleVisibility: .visible
        ) {
            Button("Just this one") { start(.single) }
            Button("Everything on this page") { start(.all) }
            Button("Cancel", role: .cancel) { asking = nil }
        } message: {
            Text(tab.currentURL?.absoluteString ?? "")
        }
    }

    private func start(_ scope: Scope) {
        guard let url = tab.currentURL, let intent = asking else { return }
        asking = nil
        Task {
            // Carry the session automatically.
            //
            // They are looking at the page, signed in as themselves — that is
            // the whole reason the browser exists. Making them press a separate
            // button first meant the common case failed with "nothing was
            // downloaded" on every site that shows its content only to
            // members, which is most of the sites worth having a browser for.
            if let host = await queue.adoptCookies(from: tab) {
                adopted.insert(host)
            }
            switch intent {
            case .queue:
                queue.add(text: url.absoluteString, scope: scope)
            case .now:
                await queue.downloadNow(url, scope: scope)
            }
        }
    }
}

/// What the address bar is about to do, once the scope is chosen.
enum StartIntent: Identifiable {
    case queue
    case now
    var id: Int { self == .queue ? 0 : 1 }
}

/// A compact strip of whatever is downloading, so the browser does not have to
/// be left to find out how it is going.
struct ActivityRail: View {
    @Bindable var queue: Queue

    private var active: [Download] {
        queue.downloads.filter { !$0.state.isTerminal }
    }
    private var finished: Int {
        queue.downloads.filter { if case .finished = $0.state { return true } else { return false } }
            .count
    }

    var body: some View {
        if active.isEmpty && finished == 0 {
            EmptyView()
        } else {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 14) {
                    if active.isEmpty {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("\(finished) finished")
                            .font(.callout)
                    } else {
                        ScrollView(.horizontal) {
                            HStack(spacing: 12) {
                                ForEach(active) { download in
                                    ActivityChip(download: download,
                                                 cancel: { queue.cancel(download) })
                                }
                            }
                        }
                        .scrollIndicators(.never)
                    }

                    Spacer(minLength: 0)

                    if finished > 0, !active.isEmpty {
                        Text("\(finished) done")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .rect(cornerRadius: 14))
            }
        }
    }
}

struct ActivityChip: View {
    @Bindable var download: Download
    let cancel: () -> Void

    private var fraction: Double? {
        if case .running(let f) = download.state, f > 0 { return f }
        return nil
    }

    var body: some View {
        HStack(spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                Text(download.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                // A determinate bar when the downloader knows the total and an
                // indeterminate one when it does not, rather than a bar that
                // pretends: a gallery finds its files as it goes and a fake
                // percentage on that is a lie with a progress bar around it.
                if let fraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .frame(width: 130)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .frame(width: 130)
                }

                Text(download.stage ?? download.host)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Button(action: cancel) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Stop this download")
        }
        .frame(maxWidth: 230, alignment: .leading)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Bindable var queue: Queue
    var browser: BrowserModel
    @Bindable var presence: Presence

    var body: some View {
        TabView {
            GeneralSettings(queue: queue, presence: presence)
                .tabItem { Label("General", systemImage: "gearshape") }
            ToolsSettings(queue: queue)
                .tabItem { Label("Downloaders", systemImage: "shippingbox") }
            PrivacySettings(queue: queue)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            ShortcutsSettings(queue: queue)
                .tabItem { Label("Shortcuts", systemImage: "square.stack.3d.up") }
            PlacesSettings(places: browser.places)
                .tabItem { Label("Places", systemImage: "bookmark") }
        }
        .frame(width: 520, height: 430)
    }
}

struct GeneralSettings: View {
    @Bindable var queue: Queue
    @Bindable var presence: Presence
    @State private var loginFailure: String?

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Show Lathe", selection: $presence.style) {
                    ForEach(Presence.Style.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)

                Text(presence.style.explanation)
                    .font(.caption).foregroundStyle(.secondary)

                if presence.style == .dock {
                    Toggle("Also show a menu bar item", isOn: $presence.showsMenuBarItem)
                }
            }

            Section("Startup") {
                Toggle("Start Lathe when I log in", isOn: Binding(
                    get: { presence.startsAtLogin },
                    set: { wanted in
                        do {
                            loginFailure = nil
                            try presence.setStartsAtLogin(wanted)
                        } catch {
                            loginFailure = error.localizedDescription
                        }
                    }))

                if presence.loginApprovalPending {
                    // The system asks separately, and there is nothing this app
                    // can do about it except say where to go.
                    Label("macOS is waiting for you to allow this in System "
                          + "Settings → General → Login Items.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }

                if let loginFailure {
                    Text(loginFailure).font(.caption).foregroundStyle(.orange)
                }

                Text(presence.style == .menuBar
                     ? "Starts with no window and no Dock icon — just the menu "
                       + "bar item, ready for anything the Shortcut sends it."
                     : "Opens normally at login. Switch to menu bar only above "
                       + "if you would rather it started out of the way.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Downloads") {
                LabeledContent("Folder") {
                    Button(queue.destination?.path ?? "Downloads") { queue.chooseDestination() }
                        .buttonStyle(.link)
                }
                Picker("Default scope", selection: $queue.defaultScope) {
                    ForEach(Scope.allCases) { Text($0.label).tag($0) }
                }
                Text("What a new link means when it names both an item and a "
                     + "collection. Browsing asks each time instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Sami") {
                Toggle("Hand finished files to Sami", isOn: $queue.handOffToSami)
                    .disabled(!queue.samiInstalled)

                if queue.samiInstalled {
                    Picker("Ask for", selection: $queue.samiIntent) {
                        Text("Compression").tag(Handoff.Intent.compress)
                        Text("Conversion").tag(Handoff.Intent.convert)
                        Text("Let me choose in Sami").tag(Handoff.Intent.ask)
                    }
                    .disabled(!queue.handOffToSami)

                    TextField("Preset name (optional)", text: $queue.samiPreset)
                        .disabled(!queue.handOffToSami)

                    Text("The request travels as a document opened alongside the "
                         + "media, because that is the one thing a sandboxed app is "
                         + "allowed to read from another.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Sami is not installed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Install, update and remove the extractors.
///
/// They are fetched rather than bundled, which is what makes them updatable at
/// all — a downloader that needs a new app release every time a site changes
/// its markup is broken most weeks. So there has to be somewhere to do it.
struct ToolsSettings: View {
    @Bindable var queue: Queue
    @State private var packages: [PythonPackageInstaller.InstalledPackage] = []
    @State private var confirmingRemoval: Tool?

    var body: some View {
        Form {
            Section("Extractors") {
                ToolRow(queue: queue, tool: .media, name: "yt-dlp",
                        summary: "Video and audio sites",
                        installed: queue.tools.ytdlpInstalled,
                        version: queue.tools.ytdlpVersion,
                        busy: queue.tools.ytdlpInstalling,
                        remove: { confirmingRemoval = .media })
                ToolRow(queue: queue, tool: .gallery, name: "gallery-dl",
                        summary: "Image and gallery sites",
                        installed: queue.tools.galleryDLInstalled,
                        version: queue.tools.galleryDLVersion,
                        busy: queue.tools.galleryDLInstalling,
                        remove: { confirmingRemoval = .gallery })
            }

            if let error = queue.tools.lastError {
                Section { Text(error).font(.caption).foregroundStyle(.orange) }
            }

            Section("Everything installed") {
                if packages.isEmpty {
                    Text("Nothing yet.").font(.caption).foregroundStyle(.secondary)
                } else {
                    // The dependencies as well, because "install gallery-dl"
                    // is really six packages and a few megabytes, and somebody
                    // deciding whether to keep it should be able to see that.
                    ForEach(packages, id: \.name) { package in
                        LabeledContent(package.name) {
                            Text(package.version)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                Text("Installed into this app's own folder in Application Support. "
                     + "Nothing is written outside it and no system Python is touched.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { packages = await queue.installedPackages() }
        .onChange(of: queue.tools.ytdlpInstalled) { Task { packages = await queue.installedPackages() } }
        .onChange(of: queue.tools.galleryDLInstalled) { Task { packages = await queue.installedPackages() } }
        .confirmationDialog(
            "Remove this downloader?",
            isPresented: Binding(get: { confirmingRemoval != nil },
                                 set: { if !$0 { confirmingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let tool = confirmingRemoval {
                    confirmingRemoval = nil
                    Task {
                        await queue.remove(tool)
                        packages = await queue.installedPackages()
                    }
                }
            }
            Button("Cancel", role: .cancel) { confirmingRemoval = nil }
        } message: {
            Text("Sites that need it will stop working until it is installed again. "
                 + "Python is left in place; only the extractor's own files are removed.")
        }
    }
}

struct ToolRow: View {
    @Bindable var queue: Queue
    let tool: Tool
    let name: String
    let summary: String
    let installed: Bool
    let version: String?
    let busy: Bool
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 7) {
                    Text(name).font(.body.weight(.medium))
                    if let version, installed {
                        Text(version)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            if busy {
                ProgressView().controlSize(.small)
            } else if installed {
                Button("Update") { Task { await queue.update(tool) } }
                Button("Remove", role: .destructive, action: remove)
            } else {
                Button("Install") { Task { await queue.update(tool) } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 2)
    }
}

struct PrivacySettings: View {
    @Bindable var queue: Queue

    var body: some View {
        Form {
            Section("Tor") {
                Toggle("Route everything through Tor", isOn: Binding(
                    get: { queue.useTor },
                    set: { queue.setTorRouting($0) }))
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(queue.torStatusColor)
                            .frame(width: 7, height: 7)
                        Text(queue.torStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Browsing and downloading both go through it. A toggle that "
                     + "routed one and not the other would be worse than none: the "
                     + "page you visited to find the link is the part that "
                     + "identifies you.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Proxy") {
                Picker("Use", selection: $queue.torMode) {
                    ForEach(TorMode.allCases) { Text($0.label).tag($0) }
                }
                if queue.torMode == .external {
                    HStack {
                        TextField("Host", text: $queue.proxy.host)
                        TextField("Port", value: $queue.proxy.port,
                                  format: .number.grouping(.never))
                            .frame(width: 70)
                    }
                }
                Text(queue.torMode.explanation)
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Text("This is not anonymity. It is the same browser with the same "
                     + "logins in it, so a site you are signed in to knows exactly "
                     + "who you are wherever the packets came from.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PlacesSettings: View {
    var places: Places

    var body: some View {
        Form {
            Section("Bookmarks") {
                if places.bookmarks.isEmpty {
                    Text("None yet. Use the bookmark button in Browse.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(places.bookmarks) { place in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(place.label).lineLimit(1)
                                Text(place.host).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove", role: .destructive) {
                                places.removeBookmark(place)
                            }
                            .buttonStyle(.link)
                        }
                    }
                }
            }

            Section("Recently visited") {
                LabeledContent("\(places.recent.count) pages") {
                    Button("Clear") { places.clearRecent() }
                        .buttonStyle(.link)
                        .disabled(places.recent.isEmpty)
                }
                Text("Kept so you can find yesterday's page, capped at 40, and never "
                     + "recorded at all while Tor routing is on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}


/// Walks somebody through setting up the phone-to-Mac hand-off.
///
/// Instructions rather than a generated shortcut, because a `.shortcut` file is
/// a signed archive that only the Shortcuts app can produce — there is no
/// supported way for another application to write one. What there is, is a
/// folder both devices can see and four steps that take about a minute.
struct ShortcutsSettings: View {
    @Bindable var queue: Queue
    @State private var folder: URL?
    @State private var copied = false
    @State private var installing = false
    @State private var installed = false
    @State private var failure: String?

    var body: some View {
        Form {
            Section("Send links from your phone") {
                Text("Lathe watches a folder in iCloud Drive. Share a link to it "
                     + "from your iPhone and the download starts here — even if the "
                     + "Mac was asleep when you shared it.")
                    .font(.callout)

                if let folder {
                    LabeledContent("Folder") {
                        HStack(spacing: 8) {
                            Button(copied ? "Copied" : "Copy path") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(folder.path, forType: .string)
                                copied = true
                            }
                            .buttonStyle(.link)
                            Button("Open") {
                                NSWorkspace.shared.activateFileViewerSelecting([folder])
                            }
                            .buttonStyle(.link)
                        }
                    }
                }

                if !Inbox.isUsingiCloud {
                    // Said plainly, because the iPhone half simply cannot work
                    // without it and discovering that after building the
                    // shortcut would be infuriating.
                    Label("iCloud Drive is off on this Mac, so the folder is local "
                          + "only. The steps below still work for Shortcuts on this "
                          + "Mac; the iPhone half needs iCloud Drive.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Add the shortcut") {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("“Send to Lathe”").font(.body.weight(.medium))
                        Text("Built with the folder above already filled in, and "
                             + "set to appear in the share sheet.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if installing {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Add Shortcut") {
                            installing = true
                            Task {
                                defer { installing = false }
                                do {
                                    try ShortcutExport.install()
                                    installed = true
                                } catch {
                                    failure = error.localizedDescription
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                if installed {
                    Label("Shortcuts is open — press Add Shortcut there, then turn on "
                          + "iCloud syncing for Shortcuts on your iPhone if it is not "
                          + "already. It appears in the share sheet on both.",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Right now") {
                Toggle("Watch the folder", isOn: Binding(
                    get: { queue.watchesInbox },
                    set: { queue.setInboxWatching($0) }))
                Button("Check the folder now") { queue.drainInbox() }
                    .buttonStyle(.link)
            }
        }
        .formStyle(.grouped)
        .task { folder = try? Inbox.location() }
    }
}

struct StepRow: View {
    let number: Int
    let text: String

    init(_ number: Int, _ text: String) {
        self.number = number
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.monospaced().weight(.bold))
                .foregroundStyle(.tint)
                .frame(width: 14, alignment: .trailing)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}


// MARK: - Menu bar

/// What the menu bar item drops down.
///
/// Deliberately short. This exists so that an app with no Dock icon is still
/// reachable and still says what it is doing — not so that the whole interface
/// can be operated from a menu.
struct MenuBarContents: View {
    @Bindable var queue: Queue
    @Bindable var presence: Presence
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if queue.activeCount > 0 {
            Text("\(queue.activeCount) downloading")
            Divider()
        } else if queue.downloads.isEmpty {
            Text("Nothing queued")
            Divider()
        }

        Button("Open Lathe") {
            // Both, and in this order: a menu-bar-only app is `.accessory`,
            // which cannot come forward on its own, so the window would open
            // behind whatever is in front.
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "main")
        }

        Button("Paste and Download") {
            guard let text = NSPasteboard.general.string(forType: .string) else { return }
            let added = queue.add(text: text)
            guard added > 0 else { return }
            Task { await queue.start() }
        }
        .help("Takes whatever links are on the clipboard and starts them")

        Divider()

        Button("Downloads Folder") { queue.revealDestination() }

        if queue.isRunning {
            Button("Stop All") { queue.cancelAll() }
        }

        Divider()

        Button("Settings…") {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        Button("Quit Lathe") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
