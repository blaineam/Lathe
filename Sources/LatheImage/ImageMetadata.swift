import CoreGraphics
import Foundation
import ImageIO
import LatheCore

/// Turns a ``MetadataPolicy`` into an ImageIO properties dictionary.
///
/// ## Why this is a deny-list over a dictionary we own
///
/// ImageIO offers two ways to carry a source's metadata into a re-encode, and
/// they fail in opposite directions:
///
/// - `CGImageDestinationAddImageFromSource` carries **everything** across
///   implicitly and lets you override individual entries. Under that model a
///   strip policy is a list of things you remembered to delete, and anything the
///   source carried that nobody thought about — a maker note from a camera that
///   did not exist when the code was written — travels by default. For a feature
///   whose whole purpose is removing data, "by default it leaks" is the wrong
///   shape.
/// - `CGImageDestinationAddImage` writes **only** what is in the properties
///   dictionary you hand it. ``stripAll`` is then provable by construction: the
///   dictionary is nearly empty, so there is nothing to leak.
///
/// Lathe uses the second, which is why this type exists: `preserveAll` has to be
/// assembled rather than assumed.
///
/// ## What does not round-trip
///
/// `CGImageSourceCopyPropertiesAtIndex` returns EXIF, TIFF, IPTC, GPS, PNG and
/// the per-vendor maker-note dictionaries, and ImageIO will write those back.
/// It does **not** return the raw XMP packet — that is
/// `CGImageSourceCopyMetadataAtIndex`, a separate object model — so an XMP
/// sidecar embedded in the source is dropped on re-encode even under
/// ``MetadataPolicy/preserveAll``. That is a real gap and it is stated here
/// rather than discovered later; closing it belongs with the lossless metadata
/// rewriter, which can copy the packet without touching pixels.
enum ImageMetadata {

    // MARK: - Reading

    /// Everything ImageIO will tell us about image 0, or an empty dictionary.
    static func sourceProperties(of source: CGImageSource, at index: Int = 0) -> [CFString: Any] {
        guard let raw = CGImageSourceCopyPropertiesAtIndex(source, index, nil) else { return [:] }
        return (raw as NSDictionary) as? [CFString: Any] ?? [:]
    }

    // MARK: - Applying a policy

    /// The properties to hand to `CGImageDestinationAddImage`.
    ///
    /// - Parameters:
    ///   - policy: what to keep.
    ///   - source: the source's full property dictionary.
    ///   - forcePreserve: keys that are restored after stripping, because
    ///     removing them breaks the file rather than anonymising it.
    ///   - orientation: the tag to write, or `nil` to write none. **Never
    ///     governed by the policy** — see the note on ``strip(_:from:)``.
    static func properties(
        for policy: MetadataPolicy,
        from source: [CFString: Any],
        forcePreserve: MetadataForcePreserve,
        orientation: CGImagePropertyOrientation?
    ) -> [CFString: Any] {
        var result: [CFString: Any]

        switch policy {
        case .preserveAll:
            result = source

        case .stripAll:
            result = [:]

        case let .strip(classes):
            result = source
            for metadataClass in classes {
                result = strip(metadataClass, from: result)
            }

        case let .custom(allowList):
            // Start from nothing and copy in only what was named, so a key
            // nobody thought of stays out — the same by-construction guarantee
            // as `stripAll`.
            result = copy(allowList, from: source, into: [:])
        }

        // Structural entries ImageIO reports on the way in and computes again on
        // the way out. Carrying a stale pixel width into a resized encode is how
        // a file ends up describing dimensions it does not have.
        for key in structuralKeys { result.removeValue(forKey: key) }

        result = restore(forcePreserve.keys, from: source, into: result)

        // Orientation last, and outside the policy entirely. See below.
        if let orientation {
            result[kCGImagePropertyOrientation] = orientation.rawValue
            if var tiff = result[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = orientation.rawValue
                result[kCGImagePropertyTIFFDictionary] = tiff
            }
        } else {
            result.removeValue(forKey: kCGImagePropertyOrientation)
            if var tiff = result[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation)
                result[kCGImagePropertyTIFFDictionary] = tiff
            }
        }

        return result
    }

    /// Dimensions, colour model and depth. ImageIO derives these from the image
    /// it is actually given, so passing the source's copies through can only
    /// make them disagree.
    private static var structuralKeys: [CFString] { [
        kCGImagePropertyPixelWidth,
        kCGImagePropertyPixelHeight,
        kCGImagePropertyColorModel,
        kCGImagePropertyDepth,
        kCGImagePropertyIsFloat,
        kCGImagePropertyHasAlpha,
        kCGImagePropertyProfileName,
    ] }

    // MARK: - Classes

    /// Removes one class of metadata.
    ///
    /// **Orientation is deliberately not a class and cannot be stripped by any
    /// policy.** It is not a fact about the photographer, it is part of the
    /// image's geometry: dropping it does not anonymise the picture, it rotates
    /// it. A "strip everything" that silently turns every portrait photo on its
    /// side is a data-loss bug wearing a privacy feature's clothes, so the
    /// encoder writes the orientation after the policy has run.
    static func strip(_ metadataClass: MetadataClass, from properties: [CFString: Any]) -> [CFString: Any] {
        var result = properties
        for removal in removals(for: metadataClass) {
            switch removal {
            case let .wholeDictionary(key):
                result.removeValue(forKey: key)
            case let .entry(container, key):
                guard var dictionary = result[container] as? [CFString: Any] else { continue }
                dictionary.removeValue(forKey: key)
                result[container] = dictionary.isEmpty ? nil : dictionary
            }
        }
        return result
    }

    private enum Removal {
        case wholeDictionary(CFString)
        case entry(container: CFString, key: CFString)
    }

    /// The per-class key table.
    ///
    /// Necessarily incomplete and honest about it: metadata is an open
    /// vocabulary and every camera vendor extends it. The rule followed here is
    /// that a class removes the *containers* it can (which covers vendor keys
    /// nobody has seen yet) and named entries only where the container also
    /// holds things the class should keep.
    private static func removals(for metadataClass: MetadataClass) -> [Removal] {
        switch metadataClass {
        case .gps:
            // The GPS dictionary is the coordinates. The IPTC entries are the
            // place *written out*, which is the same disclosure in prose — a
            // "safe to share" policy that removes the numbers and leaves the
            // street name has not done its job.
            return [
                .wholeDictionary(kCGImagePropertyGPSDictionary),
                .entry(container: kCGImagePropertyIPTCDictionary, key: kCGImagePropertyIPTCSubLocation),
                .entry(container: kCGImagePropertyIPTCDictionary, key: kCGImagePropertyIPTCCity),
                .entry(container: kCGImagePropertyIPTCDictionary, key: kCGImagePropertyIPTCProvinceState),
                .entry(container: kCGImagePropertyIPTCDictionary, key: kCGImagePropertyIPTCCountryPrimaryLocationName),
                .entry(container: kCGImagePropertyIPTCDictionary, key: kCGImagePropertyIPTCCountryPrimaryLocationCode),
            ]

        case .deviceIdentity:
            return [
                .wholeDictionary(kCGImagePropertyExifAuxDictionary),
                .entry(container: kCGImagePropertyTIFFDictionary, key: kCGImagePropertyTIFFMake),
                .entry(container: kCGImagePropertyTIFFDictionary, key: kCGImagePropertyTIFFModel),
                .entry(container: kCGImagePropertyTIFFDictionary, key: kCGImagePropertyTIFFHostComputer),
                .entry(container: kCGImagePropertyExifDictionary, key: kCGImagePropertyExifBodySerialNumber),
                .entry(container: kCGImagePropertyExifDictionary, key: kCGImagePropertyExifCameraOwnerName),
                .entry(container: kCGImagePropertyExifDictionary, key: kCGImagePropertyExifLensMake),
                .entry(container: kCGImagePropertyExifDictionary, key: kCGImagePropertyExifLensModel),
                .entry(container: kCGImagePropertyExifDictionary, key: kCGImagePropertyExifLensSerialNumber),
            ]

        case .timestamps:
            return [
                .entry(container: kCGImagePropertyTIFFDictionary, key: kCGImagePropertyTIFFDateTime),
                .entry(container: kCGImagePropertyExifDictionary, key: kCGImagePropertyExifDateTimeOriginal),
                .entry(container: kCGImagePropertyExifDictionary, key: kCGImagePropertyExifDateTimeDigitized),
                .entry(container: kCGImagePropertyExifDictionary, key: kCGImagePropertyExifSubsecTime),
                .entry(container: kCGImagePropertyExifDictionary, key: kCGImagePropertyExifSubsecTimeOriginal),
                .entry(container: kCGImagePropertyExifDictionary, key: kCGImagePropertyExifSubsecTimeDigitized),
                .entry(container: kCGImagePropertyExifDictionary, key: kCGImagePropertyExifOffsetTime),
                .entry(container: kCGImagePropertyExifDictionary, key: kCGImagePropertyExifOffsetTimeOriginal),
                .entry(container: kCGImagePropertyExifDictionary, key: kCGImagePropertyExifOffsetTimeDigitized),
                .entry(container: kCGImagePropertyIPTCDictionary, key: kCGImagePropertyIPTCDateCreated),
                .entry(container: kCGImagePropertyIPTCDictionary, key: kCGImagePropertyIPTCTimeCreated),
                .entry(container: kCGImagePropertyIPTCDictionary, key: kCGImagePropertyIPTCDigitalCreationDate),
                .entry(container: kCGImagePropertyIPTCDictionary, key: kCGImagePropertyIPTCDigitalCreationTime),
            ]

        case .software:
            return [
                .entry(container: kCGImagePropertyTIFFDictionary, key: kCGImagePropertyTIFFSoftware),
                .entry(container: kCGImagePropertyPNGDictionary, key: kCGImagePropertyPNGSoftware),
                .entry(container: kCGImagePropertyExifDictionary, key: kCGImagePropertyExifVersion),
            ]

        case .makerNotes, .faces:
            // Face regions have no standard ImageIO key. Where they are carried
            // at all on Apple captures they live in the maker note, so the two
            // classes remove the same containers rather than `.faces` quietly
            // removing nothing at all. A `.faces` policy on a file whose regions
            // live in an XMP packet is a no-op, and cannot be otherwise until
            // XMP round-trips at all — see the note at the top of this file.
            return [
                .wholeDictionary(kCGImagePropertyMakerAppleDictionary),
                .wholeDictionary(kCGImagePropertyMakerCanonDictionary),
                .wholeDictionary(kCGImagePropertyMakerNikonDictionary),
                .wholeDictionary(kCGImagePropertyMakerMinoltaDictionary),
                .wholeDictionary(kCGImagePropertyMakerFujiDictionary),
                .wholeDictionary(kCGImagePropertyMakerOlympusDictionary),
                .wholeDictionary(kCGImagePropertyMakerPentaxDictionary),
            ]

        case .thumbnails:
            // Nothing to remove: `CGImageDestinationAddImage` embeds no
            // thumbnail unless `kCGImageDestinationEmbedThumbnail` asks for one,
            // and this encoder never does. The class is honoured by the encode
            // path's default rather than by a deletion here.
            return []
        }
    }

    // MARK: - Named keys

    /// Puts back the keys that no policy may remove.
    private static func restore(
        _ keys: Set<MetadataKey>,
        from source: [CFString: Any],
        into properties: [CFString: Any]
    ) -> [CFString: Any] {
        copy(keys, from: source, into: properties)
    }

    /// The ImageIO dictionary each still-image namespace lives in.
    ///
    /// The entry names inside those dictionaries are ImageIO's own, which are
    /// the tag names: `exif.DateTimeOriginal`, `gps.Latitude`, `iptc.City`,
    /// `tiff.Make`, `png.Software`. A maker-note entry is
    /// `exif.MakerApple.<tag>`.
    private static var containers: [String: CFString] { [
        "exif": kCGImagePropertyExifDictionary,
        "exifaux": kCGImagePropertyExifAuxDictionary,
        "gps": kCGImagePropertyGPSDictionary,
        "iptc": kCGImagePropertyIPTCDictionary,
        "tiff": kCGImagePropertyTIFFDictionary,
        "png": kCGImagePropertyPNGDictionary,
        "gif": kCGImagePropertyGIFDictionary,
        "heic": kCGImagePropertyHEICSDictionary,
        "webp": kCGImagePropertyWebPDictionary,
    ] }

    private static var makers: [String: CFString] { [
        "MakerApple": kCGImagePropertyMakerAppleDictionary,
        "MakerCanon": kCGImagePropertyMakerCanonDictionary,
        "MakerNikon": kCGImagePropertyMakerNikonDictionary,
        "MakerFuji": kCGImagePropertyMakerFujiDictionary,
        "MakerOlympus": kCGImagePropertyMakerOlympusDictionary,
        "MakerPentax": kCGImagePropertyMakerPentaxDictionary,
        "MakerMinolta": kCGImagePropertyMakerMinoltaDictionary,
    ] }

    /// Copies the named keys from `source` into `properties`.
    ///
    /// `namespace.*` names a whole dictionary. A key with no still-image
    /// meaning — `qt.*` belongs to the video writer, and `xmp.*` does not
    /// survive this encode path at all (see the note at the top) — is logged
    /// and skipped rather than ignored silently.
    static func copy(
        _ keys: Set<MetadataKey>,
        from source: [CFString: Any],
        into properties: [CFString: Any]
    ) -> [CFString: Any] {
        var result = properties
        for key in keys {
            let parts = key.rawValue.split(separator: ".", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { unmapped(key); continue }

            if parts[0] == "exif", let maker = makers[parts[1]] {
                if parts.count == 2 || parts[2] == "*" {
                    if let whole = source[maker] { result[maker] = whole }
                } else {
                    copyEntry(parts[2], in: maker, from: source, into: &result)
                }
                continue
            }
            guard let container = containers[parts[0]] else { unmapped(key); continue }
            let entry = parts.dropFirst().joined(separator: ".")
            if entry == "*" {
                if let whole = source[container] { result[container] = whole }
            } else {
                copyEntry(entry, in: container, from: source, into: &result)
            }
        }
        return result
    }

    private static func copyEntry(
        _ entry: String,
        in container: CFString,
        from source: [CFString: Any],
        into result: inout [CFString: Any]
    ) {
        guard let from = source[container] as? [CFString: Any],
              let value = from[entry as CFString]
        else { return }
        var into = result[container] as? [CFString: Any] ?? [:]
        into[entry as CFString] = value
        result[container] = into
    }

    private static func unmapped(_ key: MetadataKey) {
        if key.namespace != "qt" {
            LatheLog.image.debug(
                "metadata key \(key.rawValue, privacy: .public) has no still-image mapping"
            )
        }
    }
}
