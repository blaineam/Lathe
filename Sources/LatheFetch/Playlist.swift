import Foundation

/// What a playlist, channel or gallery page holds.
///
/// Deliberately thin. An entry is an identity and a name, not a listing: the
/// point of asking what is in a playlist is to avoid visiting every item, and a
/// richer entry type would mean doing exactly that.
public struct Playlist: Sendable, Equatable, Codable {

    /// One item, as the index page described it.
    public struct Entry: Sendable, Equatable, Codable, Identifiable {

        /// What to pass back to fetch this item.
        ///
        /// Usually an ordinary URL. For extractors whose index pages publish
        /// only an id, this is the `extractor:id` form — `youtube:dQw4w9WgXcQ`
        /// — which yt-dlp resolves the same way it resolves a URL.
        public let url: String

        /// The item's title, when the index page carried one. Many do not, and
        /// a caller should be ready to show the URL instead.
        public let title: String?

        public var id: String { url }

        public init(url: String, title: String? = nil) {
            self.url = url
            self.title = title
        }
    }

    /// The playlist's own title.
    public let title: String?

    public let entries: [Entry]

    /// Whether the walk stopped at the limit rather than at the end.
    ///
    /// Worth surfacing: "500 items" and "at least 500 items" are different
    /// things to tell somebody who is about to start all of them.
    public let isTruncated: Bool

    private enum CodingKeys: String, CodingKey {
        case title, entries
        case isTruncated = "truncated"
    }

    public init(title: String?, entries: [Entry], isTruncated: Bool = false) {
        self.title = title
        self.entries = entries
        self.isTruncated = isTruncated
    }
}
