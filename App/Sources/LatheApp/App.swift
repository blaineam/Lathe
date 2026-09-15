import AppKit
import LatheCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct LatheApp: App {
    @State private var runner = Runner()

    var body: some Scene {
        Window("Lathe", id: "main") {
            ContentView(runner: runner)
                .frame(minWidth: 620, minHeight: 440)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

struct ContentView: View {
    @Bindable var runner: Runner
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if runner.jobs.isEmpty {
                dropZone
            } else {
                list
            }
            Divider()
            footer
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            load(providers)
            return true
        }
    }

    // MARK: - Chrome

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("", selection: $runner.operation) {
                ForEach(Operation.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .disabled(runner.isRunning)

            Text(runner.operation.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Add…") { chooseFiles() }
                .disabled(runner.isRunning)
        }
        .padding(12)
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Drop files here")
                .font(.title3)
            Text("Video, images, audio, PDFs and comic archives")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    private var list: some View {
        List(runner.jobs) { job in
            HStack(spacing: 10) {
                statusIcon(for: job)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(job.name).lineLimit(1)
                    detail(for: job)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if let savings = job.savings {
                    Text(savings > 0
                         ? "−\(Int(savings * 100))%"
                         : "+\(Int(-savings * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(savings > 0 ? .green : .orange)
                }

                if let output = job.outputURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([output])
                    } label: {
                        Image(systemName: "folder")
                    }
                    .buttonStyle(.borderless)
                    .help("Show in Finder")
                }
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack {
            if let summary = runner.lastSummary {
                Text(summary).font(.caption).foregroundStyle(.secondary)
            } else if !runner.jobs.isEmpty {
                Text("\(runner.jobs.count) file(s)").font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            Button("Clear") { runner.clear() }
                .disabled(runner.isRunning || runner.jobs.isEmpty)

            Button(runner.isRunning ? "Working…" : "Run") {
                Task { await runner.run() }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(runner.isRunning || runner.jobs.isEmpty)
        }
        .padding(12)
    }

    // MARK: - Pieces

    @ViewBuilder
    private func statusIcon(for job: Job) -> some View {
        switch job.state {
        case .waiting:
            Image(systemName: "circle.dotted").foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func detail(for job: Job) -> some View {
        switch job.state {
        case .waiting: Text(job.kind.rawValue)
        case .running: Text("working…")
        case .done(let summary): Text(summary)
        // The reason, not just the fact. A failure a user cannot act on is a
        // failure they report to someone else.
        case .failed(let why): Text(why)
        case .skipped(let why): Text(why)
        }
    }

    // MARK: - Input

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { runner.add(panel.urls) }
    }

    private func load(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in runner.add([url]) }
            }
        }
    }
}
