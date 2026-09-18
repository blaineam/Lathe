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
    var onURL: ((Request) -> Void)?

    /// A link, and what the sender already decided about it.
    ///
    /// The share sheet asks the questions Lathe would otherwise have to: one
    /// item or the whole collection, start now or just queue it, and where the
    /// files should land. Carrying the answers means the download begins the
    /// moment the file arrives rather than waiting for someone to come back to
    /// the Mac and choose.
    struct Request {
        var url: URL
        var scope: Scope?
        /// Where the finished files go, when the sender asked for somewhere
        /// other than the folder set in Lathe.
        var destination: Destination?
        /// Queue it and leave it alone.
        var queueOnly: Bool = false

        enum Destination: String {
            /// A "Lathe Output" folder beside the inbox, which the shortcut
            /// can reach from the phone as well.
            case shared
            case downloads
        }
    }

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

    /// Every folder worth draining.
    ///
    /// Save File's path is relative to whatever storage the Shortcuts app
    /// decided on, and on iOS that is its own folder — so the same shortcut
    /// that writes to `iCloud Drive/Lathe Inbox` here can land in
    /// `iCloud Drive/Shortcuts/Lathe Inbox` there. Rather than fight it for
    /// a folder nobody looks at, both are watched. Only the first is created:
    /// the other exists only if Shortcuts made it.
    nonisolated static func locations() -> [URL] {
        var folders: [URL] = []
        if let inbox = try? location() { folders.append(inbox) }
        if let drive = iCloudDrive {
            let viaShortcuts = drive
                .appendingPathComponent("Shortcuts", isDirectory: true)
                .appendingPathComponent(folderName, isDirectory: true)
            if FileManager.default.fileExists(atPath: viaShortcuts.path) {
                folders.append(viaShortcuts)
            }
        }
        return folders
    }

    nonisolated static var isUsingiCloud: Bool { iCloudDrive != nil }

    /// Where a share can ask for its finished files to be put: beside the
    /// inbox, so a phone that sent the link can open the result.
    nonisolated static let outputFolderName = "Lathe Output"

    nonisolated static func outputLocation() throws -> URL {
        let base = iCloudDrive ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = base.appendingPathComponent(outputFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

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
        for folder in Self.locations() { drain(folder) }
    }

    private func drain(_ folder: URL) {
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
            let found = Self.requests(in: entry)
            guard !found.isEmpty else { continue }
            for request in found { onURL?(request) }
            try? fileManager.removeItem(at: entry)
        }
    }

    /// Directives read from a file's name.
    ///
    /// The contents are the link and nothing else, on purpose. Getting a
    /// Shortcut to write text it composed from its own answers means wiring
    /// one action's output into another's input, and Shortcuts quietly
    /// substituted the share's URL instead — the answers were asked for and
    /// then thrown away. A filename it can be told verbatim cannot be
    /// substituted, so that is where the answers ride.
    ///
    /// `single-shared`, `all-downloads`, `queue`, and the numbered copies
    /// Shortcuts makes of them ("all-shared 2") all read correctly.
    private static func directives(fromName name: String) -> (Scope?, Request.Destination?, Bool) {
        let stem = (name as NSString).deletingPathExtension.lowercased()
        let words = stem.split(whereSeparator: { $0 == "-" || $0 == " " || $0 == "_" })
        var scope: Scope?
        var destination: Request.Destination?
        var queueOnly = false
        for word in words {
            switch word {
            case "single", "this", "one": scope = .single
            case "all", "everything": scope = .all
            case "queue", "queued": queueOnly = true
            case "shared", "output": destination = .shared
            case "downloads": destination = .downloads
            default: break
            }
        }
        return (scope, destination, queueOnly)
    }

    private static func requests(in file: URL) -> [Request] {
        // A .webloc is a property list; everything else is read as text, which
        // covers .url shortcuts and the plain file a Shortcut writes.
        if file.pathExtension == "webloc",
           let data = try? Data(contentsOf: file),
           let plist = try? PropertyListSerialization.propertyList(
               from: data, format: nil) as? [String: Any],
           let string = plist["URL"] as? String,
           let url = URL(string: string) {
            let (scope, destination, queueOnly) = directives(fromName: file.lastPathComponent)
            return [Request(url: url, scope: scope, destination: destination, queueOnly: queueOnly)]
        }

        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }

        // Directives apply to every link in the file they appear in: one share
        // is one decision, however many links it carried.
        var (scope, destination, queueOnly) = directives(fromName: file.lastPathComponent)
        var urls: [URL] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let value = directive("scope", in: line) {
                switch value {
                case "everything", "all", "collection": scope = .all
                case "single", "this", "one": scope = .single
                case "queue": queueOnly = true
                default: break
                }
                continue
            }
            if let value = directive("destination", in: line) {
                destination = Request.Destination(rawValue: value)
                continue
            }
            if let value = directive("queue", in: line) {
                queueOnly = (value == "1" || value == "true" || value == "yes")
                continue
            }
            for piece in line.split(whereSeparator: \.isWhitespace) {
                // .url shortcut files carry `URL=https://…` among INI keys.
                let trimmed = piece.hasPrefix("URL=") ? String(piece.dropFirst(4)) : String(piece)
                guard let url = URL(string: trimmed), let scheme = url.scheme,
                      scheme == "http" || scheme == "https"
                else { continue }
                urls.append(url)
            }
        }

        return urls.map { Request(url: $0, scope: scope, destination: destination, queueOnly: queueOnly) }
    }

    /// `lathe-<name>: value`, case-insensitive, as the shortcut writes it.
    private static func directive(_ name: String, in line: String) -> String? {
        let prefix = "lathe-\(name):"
        guard line.lowercased().hasPrefix(prefix) else { return nil }
        return line.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }
}
