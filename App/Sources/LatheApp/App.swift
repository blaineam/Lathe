import AppKit
import SwiftUI

@main
struct LatheApp: App {
    @State private var queue = Queue()
    @State private var browser = BrowserModel()

    var body: some Scene {
        Window("Lathe", id: "main") {
            RootView(queue: queue, browser: browser)
                .frame(minWidth: 720, minHeight: 520)
                .task { await queue.refreshTools() }
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

            switch pane {
            case .queue: QueueView(queue: queue)
            case .browse: BrowsePane(queue: queue, browser: browser)
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
    @State private var adopted: String?
    @State private var queued = false

    var body: some View {
        VStack(spacing: 10) {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 8) {
                    Button(action: browser.back) { Image(systemName: "chevron.left") }
                        .disabled(!browser.canGoBack)
                    Button(action: browser.forward) { Image(systemName: "chevron.right") }
                        .disabled(!browser.canGoForward)
                    Button(action: browser.reload) { Image(systemName: "arrow.clockwise") }

                    TextField("Search or enter address", text: $browser.address)
                        .textFieldStyle(.plain)
                        .focused($addressFocused)
                        .onSubmit(browser.go)
                        .onChange(of: addressFocused) { browser.isEditingAddress = addressFocused }

                    if browser.isLoading { ProgressView().controlSize(.small) }

                    Button {
                        Task {
                            if let host = await queue.adoptCookies(from: browser) {
                                adopted = host
                            }
                        }
                    } label: {
                        let signedIn = adopted != nil && adopted == browser.currentURL?.host()
                        Label(
                            signedIn ? "Signed in" : "Use this session",
                            systemImage: signedIn ? "person.badge.key.fill" : "person.badge.key")
                    }
                    .buttonStyle(.glass)
                    .disabled(browser.currentURL?.host() == nil)
                    .help("Hand this site's cookies to the downloader, so it sees the same "
                          + "signed-in session you do. Only this site's cookies, never the rest.")

                    Button {
                        if let url = browser.currentURL {
                            queued = queue.add(text: url.absoluteString) > 0
                        }
                    } label: {
                        Label(queued ? "Queued" : "Queue this",
                              systemImage: queued ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(browser.currentURL == nil)
                }
                .padding(10)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
            }
            .padding(.horizontal, 16)

            BrowserView(model: browser)
                .clipShape(.rect(cornerRadius: 14))
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                // The queued and signed-in confirmations belong to the page
                // they were pressed on, not to the session.
                .onChange(of: browser.currentURL) { queued = false }
        }
        .padding(.top, 12)
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
