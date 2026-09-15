import Foundation

/// Somewhere the user has been, or wants to go back to.
struct Place: Codable, Identifiable, Hashable {
    var url: URL
    var title: String
    var lastVisited: Date

    var id: URL { url }

    var host: String { url.host() ?? url.absoluteString }

    /// What to show when the page had no title of its own.
    var label: String { title.isEmpty ? host : title }
}

/// Recently visited pages and bookmarks.
///
/// ## Why history is not every page
///
/// A browser inside a downloader is used to *find* things, so its history is
/// worth keeping — but a full log of every URL visited is a privacy liability
/// sitting in a plist for no benefit. So: one entry per page, capped, with the
/// most recent first, and a single button that empties it. Pages visited while
/// proxy routing is on are not recorded at all, because recording them would
/// undo the point of turning it on.
@MainActor
@Observable
final class Places {
    private(set) var recent: [Place] = []
    private(set) var bookmarks: [Place] = []

    /// Enough to find yesterday's page, not enough to be a dossier.
    private static let recentLimit = 40

    private static let recentKey = "browser.recent"
    private static let bookmarksKey = "browser.bookmarks"

    /// Set while the browser is routed through a proxy.
    var isPrivate = false

    init() {
        recent = Self.load(Self.recentKey)
        bookmarks = Self.load(Self.bookmarksKey)
    }

    func record(url: URL, title: String?) {
        guard !isPrivate else { return }
        guard let scheme = url.scheme, scheme == "http" || scheme == "https" else { return }

        // One entry per page. Re-visiting moves it to the top rather than
        // adding a second copy, which is what makes a short list useful.
        recent.removeAll { $0.url == url }
        recent.insert(Place(url: url, title: title ?? "", lastVisited: .now), at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
        Self.save(recent, to: Self.recentKey)
    }

    func clearRecent() {
        recent.removeAll()
        Self.save(recent, to: Self.recentKey)
    }

    func isBookmarked(_ url: URL?) -> Bool {
        guard let url else { return false }
        return bookmarks.contains { $0.url == url }
    }

    func toggleBookmark(url: URL, title: String?) {
        if let index = bookmarks.firstIndex(where: { $0.url == url }) {
            bookmarks.remove(at: index)
        } else {
            bookmarks.insert(Place(url: url, title: title ?? "", lastVisited: .now), at: 0)
        }
        Self.save(bookmarks, to: Self.bookmarksKey)
    }

    func removeBookmark(_ place: Place) {
        bookmarks.removeAll { $0.url == place.url }
        Self.save(bookmarks, to: Self.bookmarksKey)
    }

    // MARK: - Storage

    private static func load(_ key: String) -> [Place] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Place].self, from: data)) ?? []
    }

    private static func save(_ places: [Place], to key: String) {
        guard let data = try? JSONEncoder().encode(places) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
