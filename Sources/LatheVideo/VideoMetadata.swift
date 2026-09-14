import AVFoundation
import CoreMedia
import Foundation
import LatheCore

/// Applies a ``MetadataPolicy`` to a movie's container metadata.
///
/// The still-image path's rule holds here too: **metadata is written, not
/// inherited.** `AVAssetWriter.metadata` starts empty and receives exactly the
/// items this file decided to keep, so `.stripAll` is provable by construction
/// rather than by remembering to delete each thing somebody once thought of.
///
/// Two limits, stated rather than discovered later:
///
/// - This is **container-level** metadata. Per-track metadata and timed metadata
///   *tracks* — the ones carrying, say, gyroscope samples — are not copied, and
///   copying them needs a writer input per track rather than a dictionary.
/// - The QuickTime creation date is metadata, but the track's rotation is not:
///   `preferredTransform` travels on the writer input, not here, and no policy
///   may drop it. Dropping an orientation does not anonymise a video, it turns
///   it on its side — the same rule the image encoder states about EXIF
///   orientation.
enum VideoMetadata {

    /// The items to hand to `AVAssetWriter.metadata`.
    static func items(
        for policy: MetadataPolicy,
        from asset: AVAsset,
        forcePreserve: MetadataForcePreserve
    ) async -> [AVMetadataItem] {
        let source = await allItems(of: asset)

        let kept: [AVMetadataItem]
        switch policy {
        case .preserveAll:
            kept = source
        case .stripAll:
            kept = []
        case let .strip(classes):
            kept = source.filter { item in
                guard let key = normalisedKey(for: item), let kind = metadataClass(of: key) else {
                    // Unclassified items survive a *targeted* strip. `.strip([.gps])`
                    // says "remove the location", not "remove everything I could
                    // not name"; a caller who meant the latter has `.stripAll`.
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

        // The floor. Removing these breaks the file rather than anonymising it —
        // the motivating case is a still and a video captured as one item, which
        // stop being recognised as a pair the moment the content identifier
        // goes. See ``MetadataForcePreserve``.
        var result = kept
        for item in source {
            guard let key = normalisedKey(for: item), forcePreserve.keys.contains(key) else { continue }
            guard !result.contains(where: { $0.identifier == item.identifier }) else { continue }
            result.append(item)
        }
        return result
    }

    /// Container metadata, the common-keyspace view of it, and the creation date,
    /// merged by identifier.
    ///
    /// All three are read because they are three *views*, not three stores, and
    /// which one a given file populates depends on how it was written. A file
    /// whose creation date is only reachable through `AVAsset.creationDate`
    /// would otherwise lose it on every transcode.
    private static func allItems(of asset: AVAsset) async -> [AVMetadataItem] {
        var merged: [AVMetadataItem] = (try? await asset.load(.metadata)) ?? []
        let common = (try? await asset.load(.commonMetadata)) ?? []
        let creationDate = ((try? await asset.load(.creationDate)) ?? nil).map { [$0] } ?? []

        for item in common + creationDate
        where !merged.contains(where: { $0.identifier == item.identifier }) {
            merged.append(item)
        }
        return merged
    }

    // MARK: - Normalisation

    /// Lathe's normalised key for a metadata item.
    ///
    /// `AVMetadataIdentifier` is `"<keyspace>/<key>"` — `"mdta/com.apple.quicktime.location.ISO6709"`,
    /// `"common/creationDate"` — and every keyspace here belongs to a movie
    /// container, so they all normalise into the `qt.*` namespace that
    /// ``MetadataKey`` documents for QuickTime. The keyspace is dropped rather
    /// than encoded because the same fact reaches us under two of them depending
    /// on the file, and two spellings of one key is how an allow-list ends up
    /// half-working.
    static func normalisedKey(for item: AVMetadataItem) -> MetadataKey? {
        guard let identifier = item.identifier?.rawValue, !identifier.isEmpty else { return nil }
        let key = identifier.split(separator: "/", maxSplits: 1).last.map(String.init) ?? identifier
        return MetadataKey("qt.\(key)")
    }

    /// Which class of metadata a normalised key belongs to.
    ///
    /// Substring matching, deliberately, and it is a normalisation rather than an
    /// ontology: QuickTime keys are dotted reverse-DNS names whose last component
    /// is the fact, and vendors add new ones. A rule that catches
    /// `com.apple.quicktime.location.ISO6709` and a camera vendor's own
    /// `…location.something` is more useful for a privacy strip than an exact
    /// list that catches only the keys that existed when it was written —
    /// **for a strip, a false positive costs a metadata item and a false
    /// negative leaks a location.**
    static func metadataClass(of key: MetadataKey) -> MetadataClass? {
        let name = significantPart(of: key)
        if name.contains("location") || name.contains("gps") { return .gps }
        if name.contains("date") || name.contains("time") { return .timestamps }
        if name.contains("make") || name.contains("model") || name.contains("camera")
            || name.contains("device") { return .deviceIdentity }
        if name.contains("software") || name.contains("encoder") { return .software }
        if name.contains("thumbnail") || name.contains("artwork") { return .thumbnails }
        return nil
    }

    /// The part of a key that carries the fact, with the namespaces removed.
    ///
    /// The namespaces have to go before any substring matching, and the reason
    /// is a real bug this caught rather than a tidiness argument:
    /// `com.apple.quicktime.make` **contains the substring "time"**, so a rule
    /// that searched the whole identifier filed the camera make under
    /// `.timestamps` — and `.strip([.timestamps])` would then have removed every
    /// QuickTime key there is, silently, while a test on location keys still
    /// passed. Vendor prefixes name a *namespace*; only what follows one names a
    /// fact.
    private static func significantPart(of key: MetadataKey) -> String {
        var name = key.rawValue.lowercased()
        for prefix in ["qt.", "com.apple.quicktime.", "com.apple.", "udta.", "mdta."]
        where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
        }
        return name
    }
}
