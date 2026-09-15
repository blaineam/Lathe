#if canImport(ImageIO)
import Foundation
import ImageIO

/// Writes a ``MediaMetadata`` into the EXIF, TIFF, IPTC and GPS dictionaries
/// ImageIO expects.
///
/// Four dictionaries rather than one because a still's metadata genuinely is
/// four overlapping standards, and readers disagree about which to consult:
/// a title is `IPTC/ObjectName` to a photo library and `TIFF/DocumentName` to
/// other tools, so the ones that overlap are written to every place that holds
/// them. Writing a title to only one of them produces a file that looks
/// untitled in half the software that opens it.
enum ImagePropertyBuilder {

    static func apply(_ metadata: MediaMetadata, to properties: inout [CFString: Any]) {
        var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        var iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]

        set(&iptc, kCGImagePropertyIPTCObjectName, metadata.title)
        set(&tiff, kCGImagePropertyTIFFDocumentName, metadata.title)

        set(&iptc, kCGImagePropertyIPTCCaptionAbstract, metadata.summary)
        set(&tiff, kCGImagePropertyTIFFImageDescription, metadata.summary)

        set(&tiff, kCGImagePropertyTIFFArtist, metadata.creators.first)
        set(&iptc, kCGImagePropertyIPTCByline, metadata.creators.first)

        set(&tiff, kCGImagePropertyTIFFCopyright, metadata.copyrightNotice)
        set(&iptc, kCGImagePropertyIPTCCopyrightNotice, metadata.copyrightNotice)
        set(&exif, kCGImagePropertyExifUserComment, metadata.comment)

        let stamp = metadata.date.map { MetadataReader.exifFormatter.string(from: $0) }
        set(&exif, kCGImagePropertyExifDateTimeOriginal, stamp)
        set(&exif, kCGImagePropertyExifDateTimeDigitized, stamp)
        set(&tiff, kCGImagePropertyTIFFDateTime, stamp)

        properties[kCGImagePropertyExifDictionary] = exif
        properties[kCGImagePropertyTIFFDictionary] = tiff
        properties[kCGImagePropertyIPTCDictionary] = iptc

        // GPS is written whole or removed whole. EXIF splits a coordinate into a
        // magnitude and a hemisphere, so a half-updated dictionary — a new
        // latitude beside the old reference — places the photo on the wrong side
        // of the equator, which is worse than having no location at all.
        if let location = metadata.location {
            var gps: [CFString: Any] = [:]
            gps[kCGImagePropertyGPSLatitude] = abs(location.latitude)
            gps[kCGImagePropertyGPSLatitudeRef] = location.latitude < 0 ? "S" : "N"
            gps[kCGImagePropertyGPSLongitude] = abs(location.longitude)
            gps[kCGImagePropertyGPSLongitudeRef] = location.longitude < 0 ? "W" : "E"
            if let altitude = location.altitude {
                gps[kCGImagePropertyGPSAltitude] = abs(altitude)
                gps[kCGImagePropertyGPSAltitudeRef] = altitude < 0 ? 1 : 0
            }
            properties[kCGImagePropertyGPSDictionary] = gps
        } else {
            properties[kCGImagePropertyGPSDictionary] = kCFNull
        }
    }

    /// Sets a key, or asks ImageIO to delete it when the value is absent.
    ///
    /// `kCFNull`, not `nil`, and the difference is the whole reason this helper
    /// exists. ImageIO **merges** the properties it is handed with the ones
    /// already in the file, so a key simply left out keeps its old value — which
    /// makes clearing a field impossible and, worse, silently impossible: the
    /// write succeeds, reports success, and the stale title is still there.
    /// `kCFNull` is the documented "remove this" marker.
    private static func set(_ dictionary: inout [CFString: Any], _ key: CFString, _ value: String?) {
        dictionary[key] = value ?? kCFNull
    }
}
#endif
