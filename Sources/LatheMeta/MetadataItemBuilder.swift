#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// Turns a ``MediaMetadata`` into the `AVMetadataItem` list a container writer
/// accepts.
///
/// Every item names its atom explicitly. `AVAssetWriter` and
/// `AVAssetExportSession` write only what the DESTINATION container understands
/// and drop anything else without a word, so an item emitted in the common
/// keyspace, or in ID3's, simply does not appear in the resulting MP4 — which
/// looks exactly like a metadata write that did nothing.
enum MetadataItemBuilder {

    static func items(for metadata: MediaMetadata) -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []

        func add(_ key: AVMetadataItemKey, _ value: (any NSCopying & NSObjectProtocol)?) {
            guard let value, let identifier = key.iTunesIdentifier else { return }
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value
            // "und" rather than a real language: a tagger that leaves this unset
            // produces items some readers skip, and claiming a language the text
            // may not be in would be worse than claiming none.
            item.extendedLanguageTag = "und"
            items.append(item)
        }

        add(.title, metadata.title as NSString?)
        add(.summary, metadata.summary as NSString?)
        add(.longDescription, metadata.longDescription as NSString?)
        add(.artist, metadata.creators.isEmpty ? nil : metadata.creators.joined(separator: ", ") as NSString)
        add(.genre, metadata.genre as NSString?)
        add(.comment, metadata.comment as NSString?)
        add(.copyright, metadata.copyrightNotice as NSString?)
        add(.creationDate, metadata.date.map { MetadataDates.format($0) as NSString })

        // The atom that decides where a player files the result. Written as a
        // number because `stik` is one, and omitted entirely when unknown rather
        // than defaulted — guessing "movie" for an unlabelled file would move
        // things into a section the user did not choose.
        add(.mediaKind, metadata.kind.map { NSNumber(value: $0.rawValue) })

        if let show = metadata.show {
            add(.seriesName, show.seriesName as NSString?)
            add(.seasonNumber, show.seasonNumber.map { NSNumber(value: $0) })
            add(.episodeNumber, show.episodeNumber.map { NSNumber(value: $0) })
            add(.episodeID, show.episodeID as NSString?)
            add(.network, show.network as NSString?)
        }

        if let track = metadata.track {
            add(.albumName, track.albumName as NSString?)
            add(.albumArtist, track.albumArtist as NSString?)
            add(.composer, track.composer as NSString?)
            add(.compilation, track.isCompilation.map { NSNumber(value: $0 ? 1 : 0) })
            if let number = track.trackNumber {
                add(.trackNumber, packedIndex(number, of: track.trackCount) as NSData)
            }
            if let number = track.discNumber {
                add(.discNumber, packedIndex(number, of: track.discCount) as NSData)
            }
        }

        for art in metadata.artwork {
            let item = AVMutableMetadataItem()
            item.identifier = AVMetadataItemKey.artwork.iTunesIdentifier
            item.value = art.data as NSData
            // Without a data type the bytes come back as an opaque payload that
            // no player draws — the single most common way cover art is "lost"
            // by a tool that did write it.
            item.dataType = art.format == .png
                ? kCMMetadataBaseDataType_PNG as String
                : kCMMetadataBaseDataType_JPEG as String
            items.append(item)
        }

        return items
    }

    /// The 8-byte record `trkn` and `disk` actually hold.
    ///
    /// Two reserved bytes, the index, then the total, then two more reserved.
    /// Writing a bare number here produces an atom players ignore, which is why
    /// track numbers written by naive taggers do not show up.
    private static func packedIndex(_ index: Int, of total: Int?) -> Data {
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes[2] = UInt8((index >> 8) & 0xFF)
        bytes[3] = UInt8(index & 0xFF)
        if let total {
            bytes[4] = UInt8((total >> 8) & 0xFF)
            bytes[5] = UInt8(total & 0xFF)
        }
        return Data(bytes)
    }
}
#endif
