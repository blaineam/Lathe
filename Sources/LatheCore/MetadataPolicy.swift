import Foundation

/// A class of metadata, in Lathe's normalised namespace.
///
/// Do *not* build per-format policies. Build one normalised intermediate and one
/// policy, so `.strip([.gps])` means the same thing for JPEG, HEIC, MP4 and PDF.
public enum MetadataClass: String, Sendable, Hashable, CaseIterable {
    case gps
    case deviceIdentity
    case timestamps
    case faces
    case software
    case thumbnails
    case makerNotes
}

/// A single normalised metadata key — `exif.DateTimeOriginal`, `gps.Latitude`,
/// `pdf.info.Title`, and so on.
///
/// Namespaces: `exif.*`, `gps.*`, `iptc.*`, `tiff.*`, `png.*` and the other
/// ImageIO dictionaries for stills; `qt.*` and the other AVFoundation
/// keyspaces for video and audio.
public struct MetadataKey: Sendable, Hashable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    /// The namespace prefix — `"exif"`, `"gps"`, and so on.
    public var namespace: String {
        String(rawValue.prefix(while: { $0 != "." }))
    }
}

/// What to do with the source's metadata when a file is re-encoded.
///
/// Honoured by ``ImageEncoder``, ``AnimatedImageWriter``, ``VideoTranscoder``
/// and ``AudioTranscoder``. Orientation is never governed by a policy: dropping
/// it rotates the picture rather than anonymising it.
public enum MetadataPolicy: Sendable, Equatable {
    /// Copy everything through. The right default for a compression tool — the
    /// user asked for smaller, not anonymous.
    case preserveAll

    /// Remove everything the format allows to be removed.
    case stripAll

    /// Remove the named classes, keep the rest. `.strip([.gps])` is the common
    /// "safe to share" case.
    case strip(Set<MetadataClass>)

    /// Keep only the named keys.
    ///
    /// For stills a key is `namespace.Entry` using ImageIO's entry names —
    /// `exif.DateTimeOriginal`, `gps.Latitude`, `tiff.Make` — or
    /// `namespace.*` for a whole dictionary. For video and audio it is the
    /// metadata item's identifier, as ``MetadataKey`` documents.
    case custom(allowList: Set<MetadataKey>)

    /// Shorthand for the most-requested policy.
    public static let stripLocation = MetadataPolicy.strip([.gps])
}

/// Keys whose removal *breaks the file* rather than merely anonymising it, and
/// which no ``MetadataPolicy`` may override.
///
/// The motivating case is paired still/video capture: strip the maker-note
/// content identifier and the two halves stop being recognised as one item. This
/// is why the policy model has a floor at all.
public struct MetadataForcePreserve: Sendable, Equatable {
    public var keys: Set<MetadataKey>

    public init(keys: Set<MetadataKey> = []) { self.keys = keys }

    /// The built-in floor.
    public static let `default` = MetadataForcePreserve(keys: [
        MetadataKey("exif.MakerApple.17"),
        MetadataKey("qt.com.apple.quicktime.content.identifier"),
    ])
}
