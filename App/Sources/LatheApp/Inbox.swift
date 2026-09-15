import Foundation

/// A folder Lathe watches, so anything that can write a file can queue a
/// download.
///
/// ## Why a folder and not an App Intent
///
/// An App Intent would be the tidy answer on the Mac, and it is no answer at
/// all for the thing actually being asked for: sharing a link from an iPhone
/// to a Mac. Intents do not cross devices. What does cross devices, reliably
/// and with no account or server in the middle, is iCloud Drive.
///
/// So the hand-off is a folder. A Shortcut on the phone appends the shared URL
/// to a file in it; the Mac notices within a second and queues it. The same
/// folder works for anything else that can write a file — a Shortcut on the
/// Mac, a script, dragging a `.webloc` in.
///
/// ## What it reads
///
/// Plain text (one URL per line), `.webloc` files, and `.url` shortcuts. Each
/// file is deleted once read, so the folder is a queue rather than a log.
@MainActor
final class Inbox {

    /// Called with each URL found.
    var onURL: ((URL) -> Void)?

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var pollTimer: Timer?

    /// The folder's name, in iCloud Drive and in the Shortcut alike.
    nonisolated static let folderName = "Lathe Inbox"

    /// iCloud Drive's own root, not this app's ubiquity container.
    ///
    /// This distinction is the whole feature. An app's container lives at
    /// `Mobile Documents/iCloud~com~…` and **nothing else can write to it** —
    /// a Shortcut saving a file to "Lathe Inbox" puts it in iCloud Drive
    /// proper, at `com~apple~CloudDocs`. Pointing the watcher at the container
    /// meant the two halves were looking at different folders with the same
    /// name, and the hand-off would have silently never connected.
    ///
    /// Reachable directly because this app is not sandboxed. A sandboxed
    /// build would need the user to grant the folder, which is a different
    /// design and a reason this feature belongs to the Mac app.
    nonisolated private static var iCloudDrive: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs",
                                    isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Where the folder lives.
    nonisolated static func location() throws -> URL {
        let base = iCloudDrive
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Lathe", isDirectory: true)
        let inbox = base.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        return inbox
    }

    nonisolated static var isUsingiCloud: Bool { iCloudDrive != nil }

    func start() {
        guard source == nil, let folder = try? Self.location() else { return }

        descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .extend], queue: .main)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { [weak self] in
            if let fd = self?.descriptor, fd >= 0 { close(fd) }
            self?.descriptor = -1
        }
        source.resume()
        self.source = source

        // A file arriving from iCloud does not always announce itself through
        // the local filesystem event — the download can land without the
        // directory's own mtime changing in a way the source reports. A slow
        // poll alongside the watch costs nothing and is the difference between
        // "usually works" and "works".
        pollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drain() }
        }

        drain()
    }

    func stop() {
        source?.cancel()
        source = nil
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Reads and removes everything in the folder.
    func drain() {
        guard let folder = try? Self.location() else { return }
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil) else { return }

        for entry in entries where !entry.lastPathComponent.hasPrefix(".") {
            // An iCloud file that has not finished downloading reads as empty,
            // and deleting it would throw away the link. Ask for it and come
            // back on the next tick.
            if entry.pathExtension == "icloud" {
                try? fileManager.startDownloadingUbiquitousItem(at: entry)
                continue
            }
            let found = Self.urls(in: entry)
            guard !found.isEmpty else { continue }
            for url in found { onURL?(url) }
            try? fileManager.removeItem(at: entry)
        }
    }

    private static func urls(in file: URL) -> [URL] {
        // A .webloc is a property list; everything else is read as text, which
        // covers .url shortcuts and the plain file a Shortcut appends to.
        if file.pathExtension == "webloc",
           let data = try? Data(contentsOf: file),
           let plist = try? PropertyListSerialization.propertyList(
               from: data, format: nil) as? [String: Any],
           let string = plist["URL"] as? String,
           let url = URL(string: string) {
            return [url]
        }

        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text
            .split(whereSeparator: { $0.isNewline || $0.isWhitespace })
            .compactMap { line -> URL? in
                // .url shortcut files carry `URL=https://…` among INI keys.
                let trimmed = line.hasPrefix("URL=") ? String(line.dropFirst(4)) : String(line)
                guard let url = URL(string: trimmed), let scheme = url.scheme,
                      scheme == "http" || scheme == "https"
                else { return nil }
                return url
            }
    }
}
