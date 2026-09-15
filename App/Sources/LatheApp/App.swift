import AppKit
import SwiftUI

@main
struct LatheApp: App {
    @State private var queue = Queue()
    @State private var browser = BrowserModel()

    var body: some Scene {
        Window("Lathe", id: "main") {
            RootView(queue: queue, browser: browser)
                .frame(minWidth: 860, minHeight: 560)
                .task { await queue.refreshTools() }
                // Browsing and downloading go the same way. A toggle that
                // routed the downloader but left the browser in the clear
                // would be worse than no toggle: the page you visited to find
                // the link is the part that identifies you.
                .task(id: queue.routingSignature) {
                    browser.setProxy(queue.useTor ? queue.proxy : nil)
                }
        }
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }

        Settings {
            SettingsView(queue: queue)
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
            Picker("", selection: $pane) {
                ForEach(Pane.allCases) { pane in
                    Label(pane.rawValue, systemImage: pane.icon).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.titleAndIcon)
            .fixedSize()
            .padding(.top, 10)

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
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.glass)
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

                Button("Queue") {
                    if let url = tab.currentURL { queue.add(text: url.absoluteString) }
                }
                .buttonStyle(.glass)
                .disabled(tab.currentURL == nil)
                .help("Add to the queue and download it with everything else")

                Button {
                    if let url = tab.currentURL {
                        Task { await queue.downloadNow(url) }
                    }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.glassProminent)
                .disabled(tab.currentURL == nil)
                .help("Start this one now, without waiting for the rest of the queue")
            }
            .padding(10)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
        }
    }
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

    var body: some View {
        Form {
            Section("Downloads") {
                LabeledContent("Folder") {
                    Button(queue.destination?.path ?? "Downloads") { queue.chooseDestination() }
                        .buttonStyle(.link)
                }
            }

            Section("Privacy") {
                Toggle("Route through a SOCKS proxy", isOn: Binding(
                    get: { queue.useTor },
                    set: { queue.setTorRouting($0) }))
                HStack {
                    TextField("Host", text: $queue.proxy.host)
                    TextField("Port", value: $queue.proxy.port, format: .number.grouping(.never))
                        .frame(width: 70)
                }
                .disabled(!queue.useTor)
                Text("Checked with a real SOCKS5 handshake before anything downloads. If the "
                     + "proxy is not there the download fails rather than quietly going out "
                     + "in the clear. 9050 is Tor's default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !queue.cookieHosts.isEmpty {
                Section("Signed-in sites") {
                    ForEach(queue.cookieHosts, id: \.self) { host in
                        LabeledContent(host) {
                            Button("Forget") { queue.forgetCookies(for: host) }
                                .buttonStyle(.link)
                        }
                    }
                    Text("Sessions you handed to the downloader from Browse. Each site's "
                         + "cookies are kept separately and only sent to that site.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Sami") {
                Toggle("Hand finished files to Sami", isOn: $queue.handOffToSami)
                    .disabled(!queue.samiInstalled)
                Text(queue.samiInstalled
                     ? "Finished downloads open in Sami for compression or conversion."
                     : "Sami is not installed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding()
    }
}
