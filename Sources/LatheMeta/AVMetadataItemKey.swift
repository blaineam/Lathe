#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// The normalised name for one container metadata item — the translation table
/// that makes an MP4 and an MP3 describable in the same words.
///
/// ## Why this is a table and not a lookup through the common keyspace
///
/// AVFoundation's *common* keyspace already unifies a handful of facts, and it
/// is used below as a fallback. It is not enough on its own, because the fields
/// that matter most for film and television have no common key at all: `stik`,
/// which decides whether a player files something under Movies or TV Shows;
/// `tvsh`, `tvsn`, `tves`; and `ldes`, the long description. A model built only
/// on common keys can carry a title and cannot carry the thing that makes the
/// title show up in the right place.
///
/// Identifiers are matched as raw strings — `"itsk/%A9nam"`, `"id3/TIT2"` —
/// because the iTunes atom names begin with a `©` that arrives percent-encoded,
/// and because most of these atoms have no `AVMetadataIdentifier` constant.
enum AVMetadataItemKey: Equatable {
    case title
    case summary
    case longDescription
    case artist
    case genre
    case comment
    case copyright
    case creationDate
    case mediaKind
    case artwork

    case seriesName
    case seasonNumber
    case episodeNumber
    case episodeID
    case network

    case albumName
    case albumArtist
    case composer
    case trackNumber
    case discNumber
    case compilation

    /// Something with no place in the model, carried under its own identifier so
    /// a read-modify-write does not discard it.
    case unmapped(String)

    /// The key for an item, by identifier first and common key second.
    init(item: AVMetadataItem) async throws {
        if let raw = item.identifier?.rawValue, let mapped = Self.byIdentifier[raw] {
            self = mapped
            return
        }
        if let common = item.commonKey, let mapped = Self.byCommonKey[common] {
            self = mapped
            return
        }
        self = .unmapped(item.identifier?.rawValue ?? "unknown")
    }

    /// iTunes-style atoms and ID3 frames, in one table.
    ///
    /// Two stores in one map rather than two maps because nothing ever needs to
    /// ask which store a key came from — the whole point is that `TIT2` and
    /// `©nam` are the same fact — and a single table makes a missing entry on
    /// one side visible next to its counterpart on the other.
    static let byIdentifier: [String: AVMetadataItemKey] = [
        // iTunes-style atoms. `%A9` is the `©` these atom names begin with.
        "itsk/%A9nam": .title,
        "itsk/desc": .summary,
        "itsk/ldes": .longDescription,
        "itsk/%A9ART": .artist,
        "itsk/%A9gen": .genre,
        "itsk/gnre": .genre,
        "itsk/%A9cmt": .comment,
        "itsk/cprt": .copyright,
        "itsk/%A9day": .creationDate,
        "itsk/stik": .mediaKind,
        "itsk/covr": .artwork,
        "itsk/tvsh": .seriesName,
        "itsk/tvsn": .seasonNumber,
        "itsk/tves": .episodeNumber,
        "itsk/tven": .episodeID,
        "itsk/tvnn": .network,
        "itsk/%A9alb": .albumName,
        "itsk/aART": .albumArtist,
        "itsk/%A9wrt": .composer,
        "itsk/trkn": .trackNumber,
        "itsk/disk": .discNumber,
        "itsk/cpil": .compilation,

        // ID3v2.
        "id3/TIT2": .title,
        "id3/TIT3": .summary,
        "id3/TPE1": .artist,
        "id3/TPE2": .albumArtist,
        "id3/TALB": .albumName,
        "id3/TCON": .genre,
        "id3/COMM": .comment,
        "id3/TCOP": .copyright,
        "id3/APIC": .artwork,
        "id3/TCOM": .composer,
        "id3/TRCK": .trackNumber,
        "id3/TPOS": .discNumber,
        "id3/TCMP": .compilation,
        "id3/TDRC": .creationDate,
        "id3/TYER": .creationDate,
    ]

    static let byCommonKey: [AVMetadataKey: AVMetadataItemKey] = [
        .commonKeyTitle: .title,
        .commonKeyDescription: .summary,
        .commonKeyArtist: .artist,
        .commonKeyCreator: .artist,
        .commonKeyAuthor: .artist,
        .commonKeyAlbumName: .albumName,
        .commonKeyArtwork: .artwork,
        .commonKeyCreationDate: .creationDate,
        .commonKeyCopyrights: .copyright,
        .commonKeyType: .genre,
    ]

    /// The identifier to WRITE this key under, in the iTunes keyspace.
    ///
    /// Writing is keyspace-specific in a way reading is not: `AVAssetWriter`
    /// silently drops an item whose identifier does not belong to the
    /// destination container, so a title written as `id3/TIT2` into an MP4
    /// vanishes without a word. Every write here therefore names the atom.
    var iTunesIdentifier: AVMetadataIdentifier? {
        switch self {
        case .title: return AVMetadataIdentifier("itsk/%A9nam")
        case .summary: return AVMetadataIdentifier("itsk/desc")
        case .longDescription: return AVMetadataIdentifier("itsk/ldes")
        case .artist: return AVMetadataIdentifier("itsk/%A9ART")
        case .genre: return AVMetadataIdentifier("itsk/%A9gen")
        case .comment: return AVMetadataIdentifier("itsk/%A9cmt")
        case .copyright: return AVMetadataIdentifier("itsk/cprt")
        case .creationDate: return AVMetadataIdentifier("itsk/%A9day")
        case .mediaKind: return AVMetadataIdentifier("itsk/stik")
        case .artwork: return AVMetadataIdentifier("itsk/covr")
        case .seriesName: return AVMetadataIdentifier("itsk/tvsh")
        case .seasonNumber: return AVMetadataIdentifier("itsk/tvsn")
        case .episodeNumber: return AVMetadataIdentifier("itsk/tves")
        case .episodeID: return AVMetadataIdentifier("itsk/tven")
        case .network: return AVMetadataIdentifier("itsk/tvnn")
        case .albumName: return AVMetadataIdentifier("itsk/%A9alb")
        case .albumArtist: return AVMetadataIdentifier("itsk/aART")
        case .composer: return AVMetadataIdentifier("itsk/%A9wrt")
        case .trackNumber: return AVMetadataIdentifier("itsk/trkn")
        case .discNumber: return AVMetadataIdentifier("itsk/disk")
        case .compilation: return AVMetadataIdentifier("itsk/cpil")
        case .unmapped: return nil
        }
    }
}

extension AVMetadataItem {

    func stringValue() async throws -> String? {
        let value = try? await load(.value)
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        if let data = value as? Data, let text = String(data: data, encoding: .utf8) {
            return text.isEmpty ? nil : text
        }
        return nil
    }

    func dataValue() async throws -> Data? {
        (try? await load(.value)) as? Data
    }

    /// An integer, however the atom chose to store one.
    ///
    /// `trkn` and `disk` are not numbers at all: they are an 8-byte record whose
    /// second 16-bit field is the number and whose third is the total. Reading
    /// them as a number yields nothing, which is why a file's track numbers
    /// appear to be missing when they are plainly visible in every player.
    func intValue() async throws -> Int? {
        let value = try? await load(.value)
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string.prefix(while: \.isNumber)) }
        if let data = value as? Data {
            let bytes = [UInt8](data)
            if bytes.count >= 4 {
                return Int(bytes[2]) << 8 | Int(bytes[3])
            }
            if bytes.count == 1 { return Int(bytes[0]) }
            if bytes.count == 2 { return Int(bytes[0]) << 8 | Int(bytes[1]) }
        }
        return nil
    }

    func dateValue() async throws -> Date? {
        let value = try? await load(.value)
        if let date = value as? Date { return date }
        guard let text = (value as? String) ?? (value as? NSNumber)?.stringValue else { return nil }
        return MetadataDates.parse(text)
    }
}

/// The date spellings that turn up in container metadata.
///
/// A `©day` atom is whatever the tagger wrote: a full ISO 8601 timestamp, a bare
/// `YYYY-MM-DD`, or just `YYYY`. Refusing the short forms would drop the release
/// year off most of a library, so each is tried in turn, longest first.
enum MetadataDates {
    static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withFullDate]
        if let date = iso.date(from: trimmed) { return date }

        for format in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    /// The spelling to write. ISO 8601 with a full timestamp, which every
    /// reader accepts and which round-trips without losing the day.
    static func format(_ date: Date) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone(secondsFromGMT: 0)
        return iso.string(from: date)
    }
}
#endif
