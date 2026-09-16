import CoreGraphics
import Foundation
import ImageIO
import LatheCore

import CWebP

/// The metadata chunks of an extended WebP, built from an ImageIO properties
/// dictionary.
///
/// ## Why ImageIO writes the EXIF block
///
/// A WebP `EXIF` chunk holds a TIFF-structured EXIF block — byte-order mark,
/// IFD0, sub-IFDs — exactly the payload of a JPEG's `APP1 Exif` segment minus
/// its six-byte `Exif\0\0` signature. (That is what `cwebp` stores when it
/// carries a JPEG's metadata across, so it is what every WebP reader expects.)
/// Serialising EXIF by hand would mean a second implementation of a
/// notoriously fiddly format, with its own tag tables, beside the one ImageIO
/// already has and the rest of this package already trusts.
///
/// So ImageIO writes it: the policy-filtered dictionary ``ImageEncoder`` has
/// already built is attached to a **1x1 JPEG** in memory, and the `APP1`
/// segments are lifted out of the result. The JPEG is a carrier and is thrown
/// away. That keeps one answer to "what does `.stripLocation` remove" for
/// every format, WebP included, instead of a WebP-shaped exception to it.
///
/// The one thing the carrier gets wrong is its own size: ImageIO stamps a
/// JPEG's EXIF `PixelXDimension`/`PixelYDimension` from the image it was given,
/// which is one pixel, whatever the dictionary says. Encoding a carrier at the
/// real size would cost a full JPEG encode per WebP, so instead the two values
/// are rewritten in place in the extracted block (``patchDimensions(in:to:)``) —
/// a fixed-width field, so nothing else moves. The tests read them back.
struct WebPMetadataChunks: Sendable, Equatable {

    /// A TIFF-structured EXIF block, without the JPEG `Exif\0\0` prefix.
    var exif: Data?
    /// An XMP packet.
    var xmp: Data?

    init(exif: Data? = nil, xmp: Data? = nil) {
        self.exif = exif
        self.xmp = xmp
    }

    var isEmpty: Bool { (exif?.isEmpty ?? true) && (xmp?.isEmpty ?? true) }

    /// The chunks that carry `properties`, or none when there is nothing worth
    /// an extended container.
    ///
    /// "Nothing worth it" is deliberate: an upright image with no EXIF, TIFF,
    /// GPS, IPTC or maker-note content gets a *simple* WebP, exactly as it did
    /// before the muxer existed. A `VP8X` header plus an EXIF block that says
    /// only "orientation 1" is bytes spent on saying nothing, and ``stripAll``
    /// in particular should produce a file with no metadata chunk at all.
    static func carrying(
        _ properties: [CFString: Any],
        pixelSize: PixelSize
    ) throws -> WebPMetadataChunks {
        guard carriesAnything(properties) else { return WebPMetadataChunks() }

        var properties = properties
        // Encode-time settings are not metadata, and a lossy-quality key would
        // make the carrier JPEG's quality the only thing it changed.
        properties.removeValue(forKey: kCGImageDestinationLossyCompressionQuality)

        guard let carrier = carrierImage() else {
            throw LatheError.encodingFailed(
                stage: "metadata", code: nil, reason: "could not build a 1x1 metadata carrier"
            )
        }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer as CFMutableData, "public.jpeg" as CFString, 1, nil
        ) else {
            throw LatheError.encodingFailed(
                stage: "metadata", code: nil,
                reason: "ImageIO would not open a JPEG destination to serialise WebP metadata"
            )
        }
        CGImageDestinationAddImage(destination, carrier, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw LatheError.encodingFailed(
                stage: "metadata", code: nil,
                reason: "ImageIO could not serialise the metadata for a WebP"
            )
        }
        var chunks = app1Segments(ofJPEG: buffer as Data)
        if var exif = chunks.exif {
            patchDimensions(in: &exif, to: pixelSize)
            chunks.exif = exif
        }
        return chunks
    }

    /// Whether `properties` says anything an EXIF or XMP chunk would keep.
    static func carriesAnything(_ properties: [CFString: Any]) -> Bool {
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value
        if let orientation, orientation != CGImagePropertyOrientation.up.rawValue { return true }

        let containers: [CFString] = [
            kCGImagePropertyExifAuxDictionary,
            kCGImagePropertyGPSDictionary,
            kCGImagePropertyIPTCDictionary,
            kCGImagePropertyMakerAppleDictionary,
            kCGImagePropertyMakerCanonDictionary,
            kCGImagePropertyMakerNikonDictionary,
            kCGImagePropertyMakerMinoltaDictionary,
            kCGImagePropertyMakerFujiDictionary,
            kCGImagePropertyMakerOlympusDictionary,
            kCGImagePropertyMakerPentaxDictionary,
        ]
        if containers.contains(where: { !((properties[$0] as? [CFString: Any])?.isEmpty ?? true) }) {
            return true
        }
        // EXIF and TIFF are special: ImageIO reports both for nearly every file,
        // PNGs included, holding nothing but facts about the pixels — which the
        // encoder states anyway — and the orientation already checked above.
        return hasContent(properties[kCGImagePropertyExifDictionary], ignoring: [
            kCGImagePropertyExifPixelXDimension,
            kCGImagePropertyExifPixelYDimension,
            kCGImagePropertyExifColorSpace,
        ]) || hasContent(properties[kCGImagePropertyTIFFDictionary], ignoring: [
            kCGImagePropertyTIFFOrientation,
            kCGImagePropertyTIFFXResolution,
            kCGImagePropertyTIFFYResolution,
            kCGImagePropertyTIFFResolutionUnit,
        ])
    }

    private static func hasContent(_ dictionary: Any?, ignoring structural: [CFString]) -> Bool {
        guard let dictionary = dictionary as? [CFString: Any] else { return false }
        return dictionary.keys.contains { !structural.contains($0) }
    }

    // MARK: - JPEG segments

    private static let exifSignature = Data("Exif\0\0".utf8)
    private static let xmpSignature = Data("http://ns.adobe.com/xap/1.0/\0".utf8)

    /// The EXIF and XMP payloads of a JPEG's `APP1` segments, signatures
    /// stripped. Stops at start-of-scan: metadata segments precede the image.
    static func app1Segments(ofJPEG jpeg: Data) -> WebPMetadataChunks {
        let bytes = [UInt8](jpeg)
        var result = WebPMetadataChunks()
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return result }

        var offset = 2
        while offset + 4 <= bytes.count, bytes[offset] == 0xFF {
            let marker = bytes[offset + 1]
            if marker == 0xDA || marker == 0xD9 { break }  // SOS / EOI
            let length = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let start = offset + 4
            let end = offset + 2 + length
            guard length >= 2, end <= bytes.count else { break }

            if marker == 0xE1 {
                let payload = Data(bytes[start..<end])
                if result.exif == nil, payload.starts(with: exifSignature) {
                    result.exif = Data(payload.dropFirst(exifSignature.count))
                } else if result.xmp == nil, payload.starts(with: xmpSignature) {
                    result.xmp = Data(payload.dropFirst(xmpSignature.count))
                }
            }
            offset = end
        }
        return result
    }

    // MARK: - EXIF dimensions

    /// Rewrites `PixelXDimension` and `PixelYDimension` in a TIFF-structured
    /// EXIF block, in place. Leaves the block untouched if it is not shaped as
    /// expected — a wrong dimension is a cosmetic fault, a corrupted block is
    /// not.
    ///
    /// Both tags are `SHORT` or `LONG` with a count of one, so the value lives in
    /// the entry itself and rewriting it moves nothing. WebP's own limit (16383
    /// a side) fits either type.
    static func patchDimensions(in exif: inout Data, to size: PixelSize) {
        var bytes = [UInt8](exif)
        guard bytes.count >= 8 else { return }
        let bigEndian: Bool
        switch (bytes[0], bytes[1]) {
        case (0x4D, 0x4D): bigEndian = true
        case (0x49, 0x49): bigEndian = false
        default: return
        }

        func read(_ offset: Int, _ width: Int) -> Int? {
            guard offset >= 0, offset + width <= bytes.count else { return nil }
            return (0..<width).reduce(0) { value, i in
                let byte = Int(bytes[offset + (bigEndian ? i : width - 1 - i)])
                return value << 8 | byte
            }
        }
        func write(_ value: Int, at offset: Int, _ width: Int) {
            for i in 0..<width {
                let shift = 8 * (bigEndian ? width - 1 - i : i)
                bytes[offset + i] = UInt8((value >> shift) & 0xFF)
            }
        }
        /// The entry offsets of the IFD at `offset`, bounds-checked.
        func entries(ofIFDAt offset: Int) -> [Int] {
            guard let count = read(offset, 2), offset + 2 + count * 12 <= bytes.count else { return [] }
            return (0..<count).map { offset + 2 + $0 * 12 }
        }

        guard let ifd0 = read(4, 4),
              let exifPointer = entries(ofIFDAt: ifd0).first(where: { read($0, 2) == 0x8769 }),
              let exifIFD = read(exifPointer + 8, 4)
        else { return }

        for entry in entries(ofIFDAt: exifIFD) {
            let value: Int
            switch read(entry, 2) {
            case 0xA002: value = size.width
            case 0xA003: value = size.height
            default: continue
            }
            guard read(entry + 4, 4) == 1 else { continue }
            switch read(entry + 2, 2) {
            case 3 where value <= Int(UInt16.max):  // SHORT, left-justified in the field
                write(value, at: entry + 8, 2)
                write(0, at: entry + 10, 2)
            case 4:                                 // LONG
                write(value, at: entry + 8, 4)
            default:
                continue
            }
        }
        exif = Data(bytes)
    }

    /// 1x1 opaque grey. The pixel is irrelevant; the JPEG is discarded.
    private static func carrierImage() -> CGImage? {
        let pixel: [UInt8] = [128, 128, 128, 255]
        guard let provider = CGDataProvider(data: Data(pixel) as CFData) else { return nil }
        return CGImage(
            width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

// MARK: - The muxer's error convention

/// `WebPMuxError` plumbing shared by the still and animation paths.
enum WebPMux {

    static func check(_ error: WebPMuxError, doing action: String) throws {
        guard error != WEBP_MUX_OK else { return }
        throw LatheError.encodingFailed(
            stage: "mux", code: error.rawValue, reason: "libwebp's muxer failed \(action): \(describe(error))"
        )
    }

    /// Runs an assemble-shaped call and copies its output out of libwebp's
    /// allocation before freeing it.
    static func assemble(
        doing action: String,
        _ body: (inout WebPData) -> WebPMuxError
    ) throws -> Data {
        var output = WebPData()
        WebPDataInit(&output)
        defer { WebPDataClear(&output) }
        try check(body(&output), doing: action)
        guard let bytes = output.bytes, output.size > 0 else {
            throw LatheError.encodingFailed(
                stage: "mux", code: nil, reason: "libwebp's muxer succeeded \(action) and wrote nothing"
            )
        }
        return Data(bytes: bytes, count: output.size)
    }

    static func describe(_ error: WebPMuxError) -> String {
        switch error {
        case WEBP_MUX_OK: "no error"
        case WEBP_MUX_NOT_FOUND: "not found"
        case WEBP_MUX_INVALID_ARGUMENT: "invalid argument"
        case WEBP_MUX_BAD_DATA: "bad data"
        case WEBP_MUX_MEMORY_ERROR: "out of memory"
        case WEBP_MUX_NOT_ENOUGH_DATA: "not enough data"
        default: "unknown mux error \(error.rawValue)"
        }
    }
}
