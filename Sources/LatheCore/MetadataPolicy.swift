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
/// Namespaces: `exif.*`, `iptc.*`, `xmp.*`, `gps.*`, `qt.*`, `png.*`,
/// `pdf.info.*`, `pdf.xmp.*`.
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

/// What to do with the source's metadata.
///
/// Not yet implemented. Stills will use `CGImageDestinationCopyImageSource`,
/// which rewrites metadata **without re-encoding a single DCT coefficient**;
/// video will use `AVAssetWriter.metadata`; PDF needs a third-party writer for
/// the XMP `/Metadata` stream, which PDFKit cannot reach.
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
///
/// TODO: populate from real-world capture formats as each encoder lands.
public struct MetadataForcePreserve: Sendable, Equatable {
    public var keys: Set<MetadataKey>

    public init(keys: Set<MetadataKey> = []) { self.keys = keys }

    /// The built-in floor.
    public static let `default` = MetadataForcePreserve(keys: [
        MetadataKey("exif.MakerApple.17"),
        MetadataKey("qt.com.apple.quicktime.content.identifier"),
    ])
}
