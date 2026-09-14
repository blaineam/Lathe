import AVFoundation
import CoreMedia
import Foundation
import LatheCore

/// Applies a ``MetadataPolicy`` to an audio file's container metadata, and gets
/// the **cover art** across.
///
/// ## The problem this type exists for
///
/// Audio metadata is not one thing. An MP3 carries ID3 frames — `TIT2` for a
/// title, `APIC` for a picture. An M4A carries iTunes-style atoms — `©nam`,
/// `covr`. A WAV carries, in practice, nothing. They are different stores with
/// different spellings, and `AVAssetWriter` writes only what the **destination**
/// container understands: hand it an `id3/TIT2` item while writing an `.m4a` and
/// it is dropped without a word. That is how a library ends up transcoded,
/// smaller, and anonymous.
///
/// So this does not copy items; it **translates** them. Items already in the
/// destination's own keyspace are rebuilt and passed through, and every
/// remaining fact is reached through AVFoundation's *common* keyspace — the one
/// place where an ID3 title and an iTunes title are the same fact — and
/// re-emitted under the destination's native identifier.
///
/// The rule the video path states holds here too: **metadata is written, not
/// inherited.** `AVAssetWriter.metadata` starts empty and receives exactly what
/// this file decided to keep, so `.stripAll` is provable by construction.
///
/// ## Artwork is called out on purpose
///
/// Losing a title is annoying. Losing the cover art is the thing a user sees
/// instantly, on every screen, across a whole library — and it is the item most
/// likely to be lost, because it is the one that does not survive a naive
/// keyspace-blind copy. ``ArtworkFate`` is reported in the result so a caller
/// can check rather than hope.
///
/// ## What is not translated
///
/// Anything with no common-keyspace equivalent and no identifier in the
/// destination's keyspace — a vendor's private atom, an ID3 frame nobody
/// standardised — is dropped, and counted in the returned item count so the
/// loss is visible. Chapters are not metadata items at all; see
/// ``AudioTranscoder``.
enum AudioMetadata {

    /// The items to hand to `AVAssetWriter.metadata`, and whether the artwork is
    /// among them.
    struct Plan {
        var items: [AVMetadataItem] = []
        var carriedArtwork = false
    }

    static func plan(
        for policy: MetadataPolicy,
        from asset: AVAsset,
        container: AudioContainer,
        forcePreserve: MetadataForcePreserve
    ) async -> Plan {
        let source = await allItems(of: asset)
        let kept = filter(source, by: policy, forcePreserve: forcePreserve)

        guard container.carriesITunesMetadata else {
            // CAF has no tagging store AVFoundation will write. Saying so —
            // here, and in ``AudioContainer`` — is better than emitting items
            // that are silently discarded and reporting a count that is a lie.
            if !kept.isEmpty {
                LatheLog.audio.info(
                    """
                    \(kept.count, privacy: .public) metadata item(s) dropped: the \
                    \(container.rawValue, privacy: .public) container has nowhere to put them
                    """
                )
            }
            return Plan()
        }

        var plan = Plan()
        var emittedCommonKeys: Set<AVMetadataKey> = []

        // 1. Items already in a keyspace this container writes, rebuilt so their
        //    values are resolved rather than left to a lazy load the writer may
        //    not perform.
        for item in kept where writableKeyspace(of: item, in: container) {
            guard let rebuilt = await rebuild(item, identifier: item.identifier) else { continue }
            plan.items.append(rebuilt)
            if let common = item.commonKey { emittedCommonKeys.insert(common) }
            if isArtwork(item) { plan.carriedArtwork = true }
        }

        // 2. Everything else, reached through the common keyspace and re-emitted
        //    under the destination's own identifier. This is the MP3-to-M4A path,
        //    and the only reason an ID3 tag survives at all.
        for item in kept {
            guard let common = item.commonKey, !emittedCommonKeys.contains(common) else { continue }
            guard let identifier = iTunesIdentifier(forCommonKey: common) else { continue }
            guard let rebuilt = await rebuild(item, identifier: identifier) else { continue }
            plan.items.append(rebuilt)
            emittedCommonKeys.insert(common)
            if common == .commonKeyArtwork { plan.carriedArtwork = true }
        }

        return plan
    }

    // MARK: - Gathering

    /// Container metadata and the common-keyspace view of it, merged.
    ///
    /// Both are read because they are two *views* of one store, and which one a
    /// given file populates depends on how it was written. An MP3's title is
    /// reachable through either; a private atom only through the first; and for
    /// some containers AVFoundation synthesises the common view and nothing
    /// else.
    private static func allItems(of asset: AVAsset) async -> [AVMetadataItem] {
        var merged: [AVMetadataItem] = (try? await asset.load(.metadata)) ?? []
        let common = (try? await asset.load(.commonMetadata)) ?? []
        for item in common where !merged.contains(where: { $0.identifier == item.identifier }) {
            merged.append(item)
        }
        return merged
    }

    // MARK: - Policy

    private static func filter(
        _ source: [AVMetadataItem],
        by policy: MetadataPolicy,
        forcePreserve: MetadataForcePreserve
    ) -> [AVMetadataItem] {
        let kept: [AVMetadataItem]
        switch policy {
        case .preserveAll:
            kept = source
        case .stripAll:
            kept = []
        case let .strip(classes):
            kept = source.filter { item in
                guard let kind = metadataClass(of: item) else {
                    // Unclassified items survive a *targeted* strip, exactly as
                    // they do on the video path: `.strip([.gps])` says "remove
                    // the location", not "remove everything I could not name".
                    return true
                }
                return !classes.contains(kind)
            }
        case let .custom(allowList):
            kept = source.filter { item in
                guard let key = normalisedKey(for: item) else { return false }
                return allowList.contains(key)
            }
        }

        var result = kept
        for item in source {
            guard let key = normalisedKey(for: item), forcePreserve.keys.contains(key) else { continue }
            guard !result.contains(where: { $0.identifier == item.identifier }) else { continue }
            result.append(item)
        }
        return result
    }

    /// Lathe's normalised key for an audio metadata item.
    ///
    /// `AVMetadataIdentifier` is `"<keyspace>/<key>"` — `"itsk/%A9nam"`,
    /// `"id3/TIT2"`, `"common/title"` — and unlike the movie case, the keyspace
    /// here is **not** dropped. Two audio keyspaces spell the same fact
    /// differently and a third spells it in a way that is neither, so collapsing
    /// them would make `custom(allowList:)` match by accident. The prefix is
    /// mapped to a stable name so an allow-list written against one file's
    /// spelling keeps working: `itunes.*`, `id3.*`, `qt.*`, `common.*`.
    static func normalisedKey(for item: AVMetadataItem) -> MetadataKey? {
        guard let identifier = item.identifier?.rawValue, !identifier.isEmpty else { return nil }
        let parts = identifier.split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return MetadataKey(identifier) }
        return MetadataKey("\(namespace(forKeyspace: String(parts[0]))).\(parts[1])")
    }

    private static func namespace(forKeyspace keyspace: String) -> String {
        switch keyspace {
        case "itsk", "itlk": "itunes"
        case "id3": "id3"
        case "mdta", "udta", "uiso": "qt"
        case "common": "common"
        default: keyspace.lowercased()
        }
    }

    /// Which class of metadata an item belongs to.
    ///
    /// The common key is consulted first, because it is the one identification
    /// that does not depend on a spelling. Failing that, substring matching on
    /// the key — deliberately, and as a normalisation rather than an ontology:
    /// tagging software invents frames, and for a *strip* a false positive costs
    /// a metadata item while a false negative leaks the thing the caller asked
    /// to remove.
    ///
    /// > Important: **album artwork is classified as ``MetadataClass/thumbnails``**.
    /// > That is the closest class the shared vocabulary has, and it means
    /// > `.strip([.thumbnails])` removes the cover art from an audio file. It is
    /// > the only policy that does — `.preserveAll`, `.strip([.gps])` and
    /// > friends all keep it.
    static func metadataClass(of item: AVMetadataItem) -> MetadataClass? {
        if let common = item.commonKey {
            switch common {
            case .commonKeyArtwork: return .thumbnails
            case .commonKeyCreationDate, .commonKeyLastModifiedDate: return .timestamps
            case .commonKeySoftware, .commonKeyMake, .commonKeyModel: return .software
            case .commonKeyLocation: return .gps
            default: break
            }
        }

        guard let key = normalisedKey(for: item) else { return nil }
        let name = significantPart(of: key)
        if name.contains("location") || name.contains("gps") || name.contains("xyz") { return .gps }
        if name.contains("covr") || name.contains("apic") || name.contains("artwork")
            || name.contains("picture") { return .thumbnails }
        if name.contains("encoder") || name.contains("software") || name.contains("too")
            || name.contains("tsse") || name.contains("tenc") { return .software }
        if name.contains("date") || name.contains("year") || name.contains("day")
            || name.contains("tdrc") || name.contains("tyer") { return .timestamps }
        if name.contains("make") || name.contains("model") || name.contains("device") {
            return .deviceIdentity
        }
        return nil
    }

    /// The part of a key that carries the fact, with the namespace removed.
    ///
    /// The same trap the video path documents applies here in a different
    /// spelling: an unstripped namespace makes substring matching match the
    /// namespace. `itunes.` contains `"tune"`, `common.` contains `"comm"` —
    /// and a rule looking for a comment frame would file every common-keyspace
    /// item under the wrong class.
    private static func significantPart(of key: MetadataKey) -> String {
        var name = key.rawValue.lowercased()
        for prefix in ["itunes.", "id3.", "qt.", "common.", "com.apple.quicktime.", "com.apple."]
        where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        return name
    }

    // MARK: - Translation

    private static func writableKeyspace(of item: AVMetadataItem, in container: AudioContainer) -> Bool {
        guard let keyspace = item.keySpace else { return false }
        // The common keyspace is deliberately absent: its items are translated
        // in step 2 rather than handed to the writer, because what a writer does
        // with a common-keyspace item is container-dependent and, for the ones
        // that matter here, is "nothing".
        switch keyspace {
        case .iTunes, .quickTimeMetadata, .quickTimeUserData:
            return container.carriesITunesMetadata
        default:
            return false
        }
    }

    /// The iTunes atom that carries a given common fact.
    ///
    /// Short on purpose. Every entry is a fact a music or audiobook library
    /// actually shows a user; a mapping that guessed at the rest would put
    /// plausible-looking values in the wrong atoms, which is worse than dropping
    /// them, because it cannot be told apart from correct data afterwards.
    private static func iTunesIdentifier(forCommonKey key: AVMetadataKey) -> AVMetadataIdentifier? {
        switch key {
        case .commonKeyTitle: .iTunesMetadataSongName
        case .commonKeyArtist, .commonKeyCreator: .iTunesMetadataArtist
        case .commonKeyAlbumName: .iTunesMetadataAlbum
        case .commonKeyArtwork: .iTunesMetadataCoverArt
        case .commonKeyAuthor: .iTunesMetadataAuthor
        case .commonKeyPublisher: .iTunesMetadataPublisher
        case .commonKeyCopyrights: .iTunesMetadataCopyright
        case .commonKeyDescription: .iTunesMetadataDescription
        case .commonKeyType: .iTunesMetadataUserGenre
        case .commonKeyCreationDate: .iTunesMetadataReleaseDate
        default: nil
        }
    }

    /// Rebuilds an item under a (possibly different) identifier, with its value
    /// resolved.
    ///
    /// Resolving matters: `asset.load(.metadata)` hands back items whose values
    /// are loaded lazily, and an item whose value is still unresolved at
    /// `finishWriting` is written as nothing at all. Loading here turns that
    /// into a visible `nil` that this function skips, rather than into an atom
    /// that exists and is empty.
    private static func rebuild(
        _ item: AVMetadataItem,
        identifier: AVMetadataIdentifier?
    ) async -> AVMetadataItem? {
        guard let identifier else { return nil }
        let value = try? await item.load(.value)
        guard let value else { return nil }

        let rebuilt = AVMutableMetadataItem()
        rebuilt.identifier = identifier
        rebuilt.value = value
        rebuilt.extendedLanguageTag = item.extendedLanguageTag ?? "und"
        rebuilt.locale = item.locale
        rebuilt.time = item.time
        rebuilt.duration = item.duration

        // The data type is what tells the reader that a blob of bytes is a JPEG
        // rather than an opaque payload. Cover art written without one comes
        // back as `Data` that no player will draw.
        if let dataType = item.dataType {
            rebuilt.dataType = dataType
        } else if identifier == .iTunesMetadataCoverArt, let data = value as? Data {
            rebuilt.dataType = imageDataType(of: data)
        }
        return rebuilt
    }

    /// The `kCMMetadataBaseDataType_*` identifier for an image blob, sniffed
    /// from its magic number.
    ///
    /// Sniffed rather than assumed JPEG: PNG cover art is common — every screen
    /// grab of an album sleeve is one — and tagging it as JPEG produces artwork
    /// that some readers refuse to draw and others draw only by ignoring the
    /// tag.
    private static func imageDataType(of data: Data) -> String {
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        if data.count >= 4, Array(data.prefix(4)) == png {
            return kCMMetadataBaseDataType_PNG as String
        }
        return kCMMetadataBaseDataType_JPEG as String
    }

    // MARK: - Artwork

    /// Whether an item is album artwork, under any of the spellings.
    static func isArtwork(_ item: AVMetadataItem) -> Bool {
        if item.commonKey == .commonKeyArtwork { return true }
        switch item.identifier {
        case .some(.iTunesMetadataCoverArt), .some(.id3MetadataAttachedPicture):
            return true
        default: break
        }
        guard let key = normalisedKey(for: item) else { return false }
        let name = significantPart(of: key).lowercased()
        return name.contains("covr") || name.contains("apic") || name.contains("artwork")
    }
}
