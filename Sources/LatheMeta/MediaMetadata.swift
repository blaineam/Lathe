import Foundation

/// What a media file says about itself, in one shape regardless of where the
/// file actually keeps it.
///
/// ## Why one model rather than four editors
///
/// "Metadata" is four unrelated storage systems that happen to share a name:
///
/// | Media | Store | Spelled |
/// |---|---|---|
/// | MP4 / M4V / MOV / M4A | iTunes-style atoms in `moov/udta/meta/ilst` | `©nam`, `tvsh`, `covr`, `stik` |
/// | MP3 | ID3v2 frames | `TIT2`, `APIC`, `TPE1` |
/// | Stills | EXIF, IPTC and XMP | `{Exif}`, `{IPTC}`, `{GPS}` dictionaries |
/// | PDF | the Info dictionary, and XMP | `Title`, `Author`, `Subject` |
///
/// A tool that edits each in its own vocabulary is four tools, and the user has
/// to know which one they are in to know what a field is called. One normalised
/// model is what makes "edit the title" a single feature — and it is also what
/// lets an online lookup fill a film's details once and have them land correctly
/// whether the file is an MP4 or a folder of stills.
///
/// ## The field that decides where a file files itself
///
/// ``MediaKind`` is not decoration. Apple's players read the `stik` atom to
/// decide whether a file belongs under Movies or under TV Shows, and a file with
/// a perfect title, artwork and episode number still lands in the wrong library
/// section if `stik` is wrong or missing. It is the single most consequential
/// field here and the easiest to leave unset.
///
/// ## EXIF is not involved in video
///
/// Worth stating because the mistake is common and produces a file that looks
/// edited and reads as blank: EXIF is a stills format. Nothing reads EXIF out of
/// an MP4, and nothing reads an iTunes atom out of a JPEG. That is exactly the
/// translation this type exists to hide.
public struct MediaMetadata: Sendable, Equatable {

    // MARK: - What it is

    /// The work's own name. For a TV episode this is the EPISODE title; the
    /// series name lives in ``show``.
    public var title: String?

    /// A short one-line description. Maps to `desc` on an MP4, `Subject` on a
    /// PDF, and the IPTC caption on a still.
    public var summary: String?

    /// The long description — a film synopsis, a book blurb. Kept separate from
    /// ``summary`` because MP4 has both (`desc` and `ldes`) and players show
    /// them in different places; collapsing them loses that.
    public var longDescription: String?

    /// Who made it: artist, author, director, photographer. Plural because a
    /// track can have several and a document can have several.
    public var creators: [String]

    /// The release, publication or capture date.
    public var date: Date?

    public var genre: String?
    public var comment: String?
    public var copyrightNotice: String?

    /// What sort of thing this is, which is what decides where a player files
    /// it. See the type's note.
    public var kind: MediaKind?

    // MARK: - Typed extensions

    /// Series, season and episode, for television.
    public var show: ShowInfo?

    /// Album, track and disc, for music.
    public var track: TrackInfo?

    /// Where it was taken. Stills mostly, though MP4 carries a location too.
    public var location: Location?

    // MARK: - Attachments and identity

    /// Cover art, poster, or thumbnail. Several because a file may legitimately
    /// carry more than one, and dropping the extras on a round trip would be a
    /// silent loss.
    public var artwork: [Artwork]

    /// External identities — `"tmdb"`, `"imdb"`, `"musicbrainz"`. Kept as a map
    /// rather than named fields so a provider this package has never heard of
    /// can still record what it matched, and so a later correction can tell
    /// which lookup produced the current values.
    public var identifiers: [String: String]

    /// Fields with no home in the model, kept under the source's own spelling so
    /// a read-modify-write does not quietly discard them.
    public var custom: [String: String]

    public init(
        title: String? = nil,
        summary: String? = nil,
        longDescription: String? = nil,
        creators: [String] = [],
        date: Date? = nil,
        genre: String? = nil,
        comment: String? = nil,
        copyrightNotice: String? = nil,
        kind: MediaKind? = nil,
        show: ShowInfo? = nil,
        track: TrackInfo? = nil,
        location: Location? = nil,
        artwork: [Artwork] = [],
        identifiers: [String: String] = [:],
        custom: [String: String] = [:]
    ) {
        self.title = title
        self.summary = summary
        self.longDescription = longDescription
        self.creators = creators
        self.date = date
        self.genre = genre
        self.comment = comment
        self.copyrightNotice = copyrightNotice
        self.kind = kind
        self.show = show
        self.track = track
        self.location = location
        self.artwork = artwork
        self.identifiers = identifiers
        self.custom = custom
    }

    /// Whether every field is empty — what a file with no metadata reads as.
    public var isEmpty: Bool {
        self == MediaMetadata()
    }
}

/// What sort of media this is, which is what a player uses to decide where the
/// file belongs in a library.
///
/// The raw values are the `stik` atom's, because that is the only place the
/// distinction is actually recorded and inventing a parallel numbering would
/// mean maintaining a mapping for no benefit.
public enum MediaKind: Int, Sendable, Equatable, CaseIterable {
    case music = 1
    case audiobook = 2
    case musicVideo = 6
    case movie = 9
    case tvShow = 10
    case booklet = 11
    case ringtone = 14

    /// The name Apple's tools show for this kind.
    public var displayName: String {
        switch self {
        case .music: return "Music"
        case .audiobook: return "Audiobook"
        case .musicVideo: return "Music Video"
        case .movie: return "Movie"
        case .tvShow: return "TV Show"
        case .booklet: return "Booklet"
        case .ringtone: return "Ringtone"
        }
    }
}

/// Television specifics.
public struct ShowInfo: Sendable, Equatable {
    /// The series name — `tvsh`. Distinct from ``MediaMetadata/title``, which
    /// for an episode is the episode's own name.
    public var seriesName: String?
    public var seasonNumber: Int?
    /// The episode's number within its season — `tves`.
    public var episodeNumber: Int?
    /// The production episode ID — `tven`, a string because it is routinely
    /// something like `"305"` or `"S03E05"` rather than a number.
    public var episodeID: String?
    public var network: String?

    public init(
        seriesName: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil,
        episodeID: String? = nil,
        network: String? = nil
    ) {
        self.seriesName = seriesName
        self.seasonNumber = seasonNumber
        self.episodeNumber = episodeNumber
        self.episodeID = episodeID
        self.network = network
    }
}

/// Music specifics.
public struct TrackInfo: Sendable, Equatable {
    public var albumName: String?
    /// The album's own artist, which is not always the track's — a compilation
    /// has one album artist and many track artists, and collapsing them is how
    /// a library ends up with forty copies of the same album.
    public var albumArtist: String?
    public var trackNumber: Int?
    public var trackCount: Int?
    public var discNumber: Int?
    public var discCount: Int?
    public var composer: String?
    public var isCompilation: Bool?

    public init(
        albumName: String? = nil,
        albumArtist: String? = nil,
        trackNumber: Int? = nil,
        trackCount: Int? = nil,
        discNumber: Int? = nil,
        discCount: Int? = nil,
        composer: String? = nil,
        isCompilation: Bool? = nil
    ) {
        self.albumName = albumName
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
        self.trackCount = trackCount
        self.discNumber = discNumber
        self.discCount = discCount
        self.composer = composer
        self.isCompilation = isCompilation
    }
}

/// Where the item was captured.
public struct Location: Sendable, Equatable {
    public var latitude: Double
    public var longitude: Double
    /// Metres above sea level, when the source recorded one.
    public var altitude: Double?

    public init(latitude: Double, longitude: Double, altitude: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
    }
}

/// An embedded image.
public struct Artwork: Sendable, Equatable {
    /// The encoded image, exactly as it will be embedded. Not decoded on read
    /// and not re-encoded on write — artwork that survives a round trip
    /// unchanged is the point.
    public var data: Data
    /// What the bytes are, sniffed rather than declared, because a container
    /// frequently records the wrong type and readers go by the bytes.
    public var format: ArtworkFormat
    /// What the image is for, where the format records it.
    public var role: ArtworkRole

    public init(data: Data, format: ArtworkFormat, role: ArtworkRole = .cover) {
        self.data = data
        self.format = format
        self.role = role
    }

    /// Artwork whose format is read from the bytes.
    ///
    /// - Returns: `nil` if the bytes are not an image this can name, which is
    ///   how a caller finds out before writing something no player will show.
    public init?(sniffing data: Data, role: ArtworkRole = .cover) {
        guard let format = ArtworkFormat(sniffing: data) else { return nil }
        self.init(data: data, format: format, role: role)
    }
}

public enum ArtworkFormat: String, Sendable, Equatable, CaseIterable {
    case jpeg
    case png

    /// The type the first bytes say it is.
    ///
    /// Sniffed rather than taken from the container's declaration: an MP4's
    /// `covr` atom records a type flag that writers get wrong often enough that
    /// every player ignores it, and a file whose artwork is declared PNG and is
    /// really JPEG must round-trip as JPEG.
    public init?(sniffing data: Data) {
        if data.count >= 3, data[data.startIndex] == 0xFF,
           data[data.index(data.startIndex, offsetBy: 1)] == 0xD8,
           data[data.index(data.startIndex, offsetBy: 2)] == 0xFF {
            self = .jpeg
            return
        }
        let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        if data.count >= 8, Array(data.prefix(8)) == pngMagic {
            self = .png
            return
        }
        return nil
    }
}

public enum ArtworkRole: String, Sendable, Equatable, CaseIterable {
    case cover
    case poster
    case banner
    case thumbnail
}
