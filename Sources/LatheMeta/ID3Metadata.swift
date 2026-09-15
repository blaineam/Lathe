import Foundation
import LatheCore

/// Translates between ``MediaMetadata`` and ID3 frames.
///
/// ## What ID3 has no way to say
///
/// ID3 was designed for music, and several fields in the model have no frame at
/// all: television's series and episode, a still's coordinates, and the media
/// kind that decides where a player files a video. Nothing in ID3 expresses
/// them, and inventing a private frame for each would produce a file only this
/// module could read.
///
/// So they are **reported rather than silently dropped**:
/// ``MetadataWriteResult/unrepresentedFields`` names what the format could not
/// hold. Same reasoning as the archive editor's dropped entries — a loss the
/// caller is told about is a decision, and a loss they are not told about is a
/// bug they find months later.
///
/// The two that *can* be carried without inventing anything — the long
/// description, and external identifiers — go in `TXXX`, which exists precisely
/// for key/value pairs the standard does not define. Their descriptions are
/// prefixed so a round trip can tell them apart from a `TXXX` some other tagger
/// wrote, and so this module never claims a description another tool might use.
enum ID3Metadata {

    /// The `TXXX` description prefix for values this module places there.
    static let longDescriptionKey = "LATHE:LONG_DESCRIPTION"
    static let identifierPrefix = "LATHE:ID:"

    // MARK: - Reading

    static func metadata(from tag: ID3Tag) -> MediaMetadata {
        var meta = MediaMetadata()
        var show = ShowInfo()
        var track = TrackInfo()

        for frame in tag.frames {
            switch frame.payload {
            case .text(let values):
                guard let first = values.first, !first.isEmpty else { continue }
                switch normalise(frame.id) {
                case "TIT2": meta.title = first
                case "TIT3": meta.summary = first
                case "TPE1": meta.creators = values
                case "TPE2": track.albumArtist = first
                case "TALB": track.albumName = first
                case "TCON": meta.genre = first
                case "TCOP": meta.copyrightNotice = first
                case "TCOM": track.composer = first
                case "TCMP": track.isCompilation = first != "0"
                case "TRCK":
                    let (index, total) = splitIndex(first)
                    track.trackNumber = index
                    track.trackCount = total
                case "TPOS":
                    let (index, total) = splitIndex(first)
                    track.discNumber = index
                    track.discCount = total
                case "TDRC", "TYER", "TDAT":
                    if meta.date == nil { meta.date = MetadataDates.parse(first) }
                default:
                    meta.custom[normalise(frame.id)] = first
                }

            case .comment(_, let description, let text):
                // A tagger writes several COMM frames with different
                // descriptions; the unnamed one is the comment a user sees.
                if description.isEmpty || meta.comment == nil { meta.comment = text }

            case .userText(let description, let value):
                if description == longDescriptionKey {
                    meta.longDescription = value
                } else if description.hasPrefix(identifierPrefix) {
                    meta.identifiers[String(description.dropFirst(identifierPrefix.count))] = value
                } else {
                    meta.custom["TXXX:\(description)"] = value
                }

            case .picture(_, let pictureType, _, let data):
                guard let format = ArtworkFormat(sniffing: data) else { continue }
                meta.artwork.append(Artwork(data: data, format: format, role: role(for: pictureType)))

            case .raw:
                continue
            }
        }

        if show != ShowInfo() { meta.show = show }
        if track != TrackInfo() { meta.track = track }
        return meta
    }

    /// `APIC` picture types, narrowed to the roles the model names. 3 is the
    /// front cover, which is what almost every file carries.
    private static func role(for pictureType: UInt8) -> ArtworkRole {
        switch pictureType {
        case 3: return .cover
        case 8, 18: return .poster
        case 11: return .banner
        default: return .thumbnail
        }
    }

    private static func pictureType(for role: ArtworkRole) -> UInt8 {
        switch role {
        case .cover: return 3
        case .poster: return 8
        case .banner: return 11
        case .thumbnail: return 0
        }
    }

    /// `"7/12"` — the index and the total, which ID3 packs into one string
    /// where the MP4 atom uses two binary fields.
    private static func splitIndex(_ text: String) -> (Int?, Int?) {
        let parts = text.split(separator: "/", maxSplits: 1)
        let index = parts.first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let total = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : nil
        return (index, total)
    }

    private static func normalise(_ id: String) -> String {
        guard id.count == 3 else { return id }
        return [
            "TT2": "TIT2", "TT3": "TIT3", "TP1": "TPE1", "TP2": "TPE2",
            "TAL": "TALB", "TCO": "TCON", "TCR": "TCOP", "TCM": "TCOM",
            "TRK": "TRCK", "TPA": "TPOS", "TYE": "TYER", "TCP": "TCMP",
        ][id] ?? id
    }

    // MARK: - Writing

    /// The frames that carry `metadata`, and the fields ID3 has no way to hold.
    static func frames(for metadata: MediaMetadata) -> (frames: [ID3Tag.Frame], unrepresented: [String]) {
        var frames: [ID3Tag.Frame] = []
        var unrepresented: [String] = []

        func text(_ id: String, _ values: [String]) {
            let kept = values.filter { !$0.isEmpty }
            guard !kept.isEmpty else { return }
            frames.append(ID3Tag.Frame(id: id, payload: .text(kept)))
        }
        func text(_ id: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            text(id, [value])
        }

        text("TIT2", metadata.title)
        text("TIT3", metadata.summary)
        text("TPE1", metadata.creators)
        text("TCON", metadata.genre)
        text("TCOP", metadata.copyrightNotice)
        if let date = metadata.date {
            text("TDRC", MetadataDates.format(date))
        }
        if let comment = metadata.comment, !comment.isEmpty {
            frames.append(ID3Tag.Frame(
                id: "COMM", payload: .comment(language: "eng", description: "", text: comment)
            ))
        }

        if let track = metadata.track {
            text("TALB", track.albumName)
            text("TPE2", track.albumArtist)
            text("TCOM", track.composer)
            if let number = track.trackNumber {
                text("TRCK", track.trackCount.map { "\(number)/\($0)" } ?? "\(number)")
            }
            if let number = track.discNumber {
                text("TPOS", track.discCount.map { "\(number)/\($0)" } ?? "\(number)")
            }
            if let compilation = track.isCompilation {
                text("TCMP", compilation ? "1" : "0")
            }
        }

        if let long = metadata.longDescription, !long.isEmpty {
            frames.append(ID3Tag.Frame(
                id: "TXXX", payload: .userText(description: longDescriptionKey, value: long)
            ))
        }
        for (name, value) in metadata.identifiers.sorted(by: { $0.key < $1.key }) {
            frames.append(ID3Tag.Frame(
                id: "TXXX",
                payload: .userText(description: identifierPrefix + name, value: value)
            ))
        }
        for (key, value) in metadata.custom.sorted(by: { $0.key < $1.key }) {
            if key.hasPrefix("TXXX:") {
                frames.append(ID3Tag.Frame(
                    id: "TXXX",
                    payload: .userText(description: String(key.dropFirst(5)), value: value)
                ))
            } else if key.count == 4, key.hasPrefix("T") {
                text(key, value)
            }
        }

        for art in metadata.artwork {
            frames.append(ID3Tag.Frame(id: "APIC", payload: .picture(
                mimeType: art.format == .png ? "image/png" : "image/jpeg",
                pictureType: pictureType(for: art.role),
                description: "",
                data: art.data
            )))
        }

        // What the format simply cannot say.
        if metadata.show != nil {
            unrepresented.append("show (ID3 has no series, season or episode frames)")
        }
        if metadata.location != nil {
            unrepresented.append("location (ID3 has no coordinate frame)")
        }
        if metadata.kind != nil {
            unrepresented.append("kind (ID3 has no equivalent of the stik atom)")
        }

        return (frames, unrepresented)
    }
}
