#if os(iOS)
import QuickLook
import SwiftUI
import UIKit

// MARK: - Where downloads are

/// The Files app's view of this app's Documents, which is where downloads go
/// on iOS (see `Queue.downloadsFolder()`).
enum FilesApp {
    /// What to tell somebody looking for their downloads.
    static let downloadsLocation = "Files › On My iPhone › Lathe › Downloads"

    /// `shareddocuments://<path>` opens the Files app at that folder. It only
    /// resolves inside this app's own container, which is the only place a
    /// download can be anyway.
    static func url(for folder: URL) -> URL? {
        guard let path = folder.standardizedFileURL.path
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return URL(string: "shareddocuments://\(path)")
    }

    /// Opens Files at a folder, or at the folder holding a file.
    @MainActor
    static func show(_ item: URL) {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: item.path, isDirectory: &isDirectory)
        let folder = isDirectory.boolValue ? item : item.deletingLastPathComponent()
        guard let url = url(for: folder) else { return }
        UIApplication.shared.open(url)
    }

    @MainActor
    static func showDownloads() {
        guard let folder = Queue.downloadsFolder() else { return }
        show(folder)
    }
}

// MARK: - Settings

/// The iPhone's settings: a sheet, pushing the same panes the Mac shows as
/// tabs. The download folder is fixed on iOS — there is no folder a sandboxed
/// app could be handed that the Files app would show more plainly than its
/// own — so the section says where it is and opens it, rather than offering
/// a picker.
struct IOSSettingsView: View {
    @Bindable var queue: Queue
    var browser: BrowserModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Saved to") {
                        Text(FilesApp.downloadsLocation)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        FilesApp.showDownloads()
                    } label: {
                        Label("Open in Files", systemImage: "folder")
                    }
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("Everything Lathe downloads lands in this folder. The Files app shows it, "
                         + "and so does anything that can open files from it.")
                }

                Section {
                    Picker("Default scope", selection: $queue.defaultScope) {
                        ForEach(Scope.allCases) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text("What a new link means when it names both an item and a "
                         + "collection. Browsing asks each time instead.")
                }

                Section {
                    NavigationLink {
                        ToolsSettings(queue: queue).navigationTitle("Downloaders")
                    } label: {
                        Label("Downloaders", systemImage: "shippingbox")
                    }
                    NavigationLink {
                        PrivacySettings(queue: queue).navigationTitle("Privacy")
                    } label: {
                        Label("Privacy", systemImage: "hand.raised")
                    }
                    NavigationLink {
                        PlacesSettings(places: browser.places).navigationTitle("Places")
                    } label: {
                        Label("Places", systemImage: "bookmark")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - A finished row

/// Preview, share, and find what a finished row downloaded.
///
/// A row that says "finished" and gives no way to the file is the reason
/// somebody asked where their downloads went.
struct FinishedActions: View {
    let output: URL
    @State private var previewing: URL?

    /// The files themselves: the one file, or what a gallery wrote into its
    /// folder.
    private var files: [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: output.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else { return [output] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: output, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    var body: some View {
        let files = files
        Menu {
            Button {
                previewing = files.first
            } label: {
                Label(files.count > 1 ? "Preview \(files.count) files" : "Preview", systemImage: "eye")
            }
            .disabled(files.isEmpty)

            ShareLink(items: files) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(files.isEmpty)

            Button {
                FilesApp.show(output)
            } label: {
                Label("Show in Files", systemImage: "folder")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .accessibilityLabel("Open download")
        .quickLookPreview($previewing, in: files)
    }
}
#endif
