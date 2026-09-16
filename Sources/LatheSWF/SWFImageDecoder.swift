import CoreGraphics
import Foundation
import ImageIO
import LatheCore

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

/// Turns SWF bitmap tags into files something written after 2010 can open.
///
/// ## What "extracting an image" actually involves
///
/// Two of the five bitmap tags hold a file you can write straight to disk. The
/// other three do not, and the difference is the reason this type exists rather
/// than a `write(tagBody)` one-liner:
///
/// - **`DefineBitsJPEG2`** is a whole JPEG (or, from SWF 8, a whole PNG or GIF —
///   the tag name kept its 1998 spelling long after it stopped being true). Copy
///   it out.
/// - **`DefineBits`** is a JPEG with **no Huffman or quantisation tables**. They
///   live once in a separate `JPEGTables` tag so that a movie with forty
///   photographs stores one copy of them. Written out alone, the payload is a
///   JPEG no decoder on earth will open. It has to be reassembled.
/// - **`DefineBitsJPEG3` / `JPEG4`** append a zlib-compressed alpha channel to
///   the JPEG. Write the JPEG alone and you get a correct-looking rectangle
///   where a cut-out sprite should be — the worst failure available, because it
///   *is* an image and nothing about it looks broken.
/// - **`DefineBitsLossless` / `Lossless2`** are not files at all. They are
///   zlib-compressed rasters in one of five pixel layouts, two of which are
///   palettes and one of which is premultiplied. They have to be decoded and
///   re-encoded, and a PNG is the only sensible destination.
enum SWFImageDecoder {

    // MARK: - Sniffing

    /// What a run of bytes actually is, by magic number.
    ///
    /// Needed because several SWF tags declare a type they do not keep:
    /// `DefineBitsJPEG2` may hold a PNG, and `DefineBinaryData` holds whatever
    /// the author embedded. The extension on an extracted file has to come from
    /// the bytes, not from the tag's name, or the output is a folder of `.jpg`
    /// files half of which are PNGs.
    enum Payload: String, Sendable, Equatable {
        case jpeg, png, gif, mp3, wav, aiff, flac, mp4, ogg, zip, xml, swf
        case unknown

        var filenameExtension: String {
            switch self {
            case .jpeg: "jpg"
            case .unknown: "bin"
            default: rawValue
            }
        }
    }

    static func sniff(_ data: Data) -> Payload {
        func matches(_ bytes: [UInt8], at index: Int = 0) -> Bool {
            guard data.count >= index + bytes.count else { return false }
            let start = data.startIndex + index
            return Array(data[start..<(start + bytes.count)]) == bytes
        }
        if matches([0xFF, 0xD8, 0xFF]) { return .jpeg }
        if matches([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if matches(Array("GIF87a".utf8)) || matches(Array("GIF89a".utf8)) { return .gif }
        if matches(Array("ID3".utf8)) { return .mp3 }
        // An MP3 frame sync: eleven set bits. Checked after ID3 so a tagged file
        // is still recognised by its tag, and after the container magics so a
        // coincidence cannot outrank them.
        if data.count >= 2 {
            let first = data[data.startIndex]
            let second = data[data.startIndex + 1]
            if first == 0xFF, second & 0xE0 == 0xE0 { return .mp3 }
        }
        if matches(Array("RIFF".utf8)), matches(Array("WAVE".utf8), at: 8) { return .wav }
        if matches(Array("FORM".utf8)), matches(Array("AIFF".utf8), at: 8) { return .aiff }
        if matches(Array("fLaC".utf8)) { return .flac }
        if matches(Array("ftyp".utf8), at: 4) { return .mp4 }
        if matches(Array("OggS".utf8)) { return .ogg }
        if matches([0x50, 0x4B, 0x03, 0x04]) { return .zip }
        if matches(Array("FWS".utf8)) || matches(Array("CWS".utf8)) || matches(Array("ZWS".utf8)) {
            return .swf
        }
        if matches(Array("<?xml".utf8)) { return .xml }
        return .unknown
    }

    // MARK: - JPEG repair

    /// Removes the bogus `FFD9 FFD8` that Flash's own authoring tool wrote at
    /// the *front* of JPEG payloads.
    ///
    /// That is an end-of-image marker followed by a start-of-image marker, at
    /// offset zero, before the real start-of-image — so the file begins by
    /// declaring an empty image and then starting a second one. It is not a
    /// corruption to be repaired defensively; it is what Macromedia shipped, it
    /// is in a great many real files, and every Flash implementation strips it.
    /// ImageIO does not: it reads the first (empty) image and reports failure.
    static func strippingErroneousJPEGPrefix(_ data: Data) -> Data {
        guard data.count >= 4 else { return data }
        let start = data.startIndex
        guard data[start] == 0xFF, data[start + 1] == 0xD9,
              data[start + 2] == 0xFF, data[start + 3] == 0xD8
        else { return data }
        return Data(data[(start + 4)...])
    }

    /// Rebuilds a complete JPEG from a `JPEGTables` tag and a `DefineBits` one.
    ///
    /// Both halves are *themselves* framed as JPEG streams: the tables block is
    /// `SOI … tables … EOI`, and the image block is `SOI … frame … EOI`.
    /// Concatenating them verbatim produces a stream containing two images, the
    /// first of which has no frame — which some decoders forgive and ImageIO
    /// does not. The join that works is to drop the tables' trailing `EOI` and
    /// the image's leading `SOI`, giving one image whose tables precede its
    /// frame, exactly as an ordinary JPEG has.
    static func mergingJPEGTables(_ tables: Data, into imageData: Data) -> Data {
        var head = strippingErroneousJPEGPrefix(tables)
        var tail = strippingErroneousJPEGPrefix(imageData)

        if head.count >= 2, head[head.index(head.endIndex, offsetBy: -2)] == 0xFF,
           head[head.index(head.endIndex, offsetBy: -1)] == 0xD9 {
            head = Data(head.dropLast(2))
        }
        if tail.count >= 2, tail[tail.startIndex] == 0xFF, tail[tail.startIndex + 1] == 0xD8 {
            tail = Data(tail.dropFirst(2))
        }
        return head + tail
    }

    // MARK: - Dimensions

    /// The pixel size of an encoded image, read from its header.
    ///
    /// `CGImageSourceCopyPropertiesAtIndex` parses the header and stops; it does
    /// not decode pixels. So a manifest can state the size of every extracted
    /// JPEG without the extraction ever holding a decoded bitmap, which is what
    /// keeps a movie full of large photographs from being a memory problem.
    static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    // MARK: - Lossless rasters

    /// A decoded `DefineBitsLossless` raster: 8-bit RGBA, premultiplied, tightly
    /// packed.
    struct Raster {
        let width: Int
        let height: Int
        /// `width * height * 4` bytes, RGBA, alpha premultiplied.
        let pixels: Data
    }

    /// Decodes a `DefineBitsLossless` or `DefineBitsLossless2` body.
    ///
    /// ## The five layouts, and the padding that ruins four of them
    ///
    /// The `BitmapFormat` byte selects the pixel layout, and which values are
    /// legal depends on which of the two tags carried it:
    ///
    /// | Format | `DefineBitsLossless` | `DefineBitsLossless2` |
    /// |---|---|---|
    /// | 3 | palette of RGB triples, one byte per pixel | palette of RGBA quads |
    /// | 4 | `PIX15` — 1 unused bit + 5/5/5 | not used |
    /// | 5 | `PIX24` — 1 unused *byte* + R + G + B | `PIX32` — A + R + G + B |
    ///
    /// Two details in that table are where a plausible implementation goes
    /// wrong. `PIX24` is **four** bytes per pixel, not three — the leading byte
    /// is padding — so reading it as a packed RGB triple produces the famous
    /// diagonal-smear image. And **every row is padded to a four-byte
    /// boundary**, which is invisible at widths that are already multiples of
    /// four and shears the image at every other width. Formats 4 and 3 are where
    /// that bites; 5 is naturally aligned and hides the bug.
    ///
    /// ## Premultiplication
    ///
    /// `PIX32`'s alpha is premultiplied, and this decoder keeps it that way and
    /// declares it, rather than dividing it back out. Un-premultiplying is lossy
    /// where alpha is small, and the PNG encoder will do the division once,
    /// correctly, on its way out. The palette form of `Lossless2` is treated the
    /// same way; where a file turns out to have stored straight alpha there, the
    /// difference appears only in the colour of pixels that are nearly
    /// transparent.
    static func decodeLossless(
        tag: SWFTagCode, body: SWFByteReader, limits: SWFLimits, name: String
    ) throws -> (characterID: UInt16, raster: Raster, format: SWFLosslessFormat) {
        var reader = body
        let characterID = try reader.u16()
        let formatByte = try reader.u8()
        let width = Int(try reader.u16())
        let height = Int(try reader.u16())

        let hasAlpha = tag == .defineBitsLossless2
        guard let format = SWFLosslessFormat(formatByte: formatByte, hasAlpha: hasAlpha) else {
            throw LatheError.invalidInput(
                reason: "\(name): character \(characterID) declares bitmap format \(formatByte), "
                    + "which \(tag) does not define"
            )
        }

        guard width > 0, height > 0 else {
            throw LatheError.invalidInput(
                reason: "\(name): character \(characterID) is \(width)×\(height)"
            )
        }
        guard width * height <= limits.maximumBitmapPixels else {
            throw LatheError.invalidInput(
                reason: "\(name): character \(characterID) is \(width)×\(height) — "
                    + "\(width * height) pixels, past the \(limits.maximumBitmapPixels) ceiling"
            )
        }

        // Only format 3 carries a palette, and its size byte is a *maximum
        // index*, so the entry count is one more. Off by one here shifts every
        // colour in the image by one palette slot.
        var paletteEntryCount = 0
        if format.isPaletted { paletteEntryCount = Int(try reader.u8()) + 1 }

        let bytesPerEntry = format.paletteEntryByteCount
        let paletteBytes = paletteEntryCount * bytesPerEntry
        let rowStride = ((width * format.bytesPerPixel) + 3) & ~3
        let expected = paletteBytes + rowStride * height

        let inflated = try SWFReader.inflateZlib(
            try reader.rest(),
            expectedCount: expected,
            limit: min(limits.maximumDecompressedBytes, expected + 4096),
            what: "\(name): character \(characterID)'s bitmap"
        )
        guard inflated.count >= expected else {
            throw LatheError.invalidInput(
                reason: "\(name): character \(characterID) inflates to \(inflated.count) bytes, "
                    + "but a \(width)×\(height) \(format) raster needs \(expected)"
            )
        }

        let pixels = rasterise(
            inflated, width: width, height: height, rowStride: rowStride,
            paletteBytes: paletteBytes, paletteEntryCount: paletteEntryCount, format: format
        )
        return (characterID, Raster(width: width, height: height, pixels: pixels), format)
    }

    private static func rasterise(
        _ source: Data, width: Int, height: Int, rowStride: Int, paletteBytes: Int,
        paletteEntryCount: Int, format: SWFLosslessFormat
    ) -> Data {
        var output = Data(count: width * height * 4)

        // Both buffers are walked through raw pointers rather than copied into
        // `[UInt8]`. The copy is the obvious spelling and it doubles the peak
        // memory of every extraction: a 4096-square raster is 64 MB, and paying
        // it twice to make the indexing read nicely is not a trade worth making
        // on a phone.
        source.withUnsafeBytes { sourceBuffer in
            guard let bytes = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            output.withUnsafeMutableBytes { raw in
                guard let out = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                let rows = paletteBytes

                for y in 0..<height {
                    let rowStart = rows + y * rowStride
                    var destination = y * width * 4
                    for x in 0..<width {
                        var r: UInt8 = 0
                        var g: UInt8 = 0
                        var b: UInt8 = 0
                        var a: UInt8 = 255
                        switch format {
                        case .palette8, .paletteRGBA8:
                            let index = Int(bytes[rowStart + x])
                            let entry = index * format.paletteEntryByteCount
                            // A palette index past the end of the table is a
                            // malformed file, not a reason to abandon the image:
                            // it becomes transparent black, which is visibly wrong
                            // in the one place it occurs rather than fatal
                            // everywhere.
                            if index < paletteEntryCount {
                                r = bytes[entry]
                                g = bytes[entry + 1]
                                b = bytes[entry + 2]
                                if format == .paletteRGBA8 { a = bytes[entry + 3] }
                            } else {
                                a = 0
                            }
                        case .rgb15:
                            // MSB-first within the 16-bit record, so the two bytes
                            // read big-endian even though every integer elsewhere
                            // in the format is little-endian.
                            let offset = rowStart + x * 2
                            let value = (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
                            r = expand5((value >> 10) & 0x1F)
                            g = expand5((value >> 5) & 0x1F)
                            b = expand5(value & 0x1F)
                        case .rgb24:
                            // Four bytes: a padding byte, then R, G, B.
                            let offset = rowStart + x * 4
                            r = bytes[offset + 1]
                            g = bytes[offset + 2]
                            b = bytes[offset + 3]
                        case .argb32:
                            let offset = rowStart + x * 4
                            a = bytes[offset]
                            r = bytes[offset + 1]
                            g = bytes[offset + 2]
                            b = bytes[offset + 3]
                        }
                        out[destination] = r
                        out[destination + 1] = g
                        out[destination + 2] = b
                        out[destination + 3] = a
                        destination += 4
                    }
                }
            }
        }
        return output
    }

    /// Widens a 5-bit channel to 8 bits by replication, so 31 becomes 255 rather
    /// than 248. Scaling by shifting alone leaves every image slightly dark and
    /// white never quite white.
    private static func expand5(_ value: UInt16) -> UInt8 {
        let v = UInt8(value & 0x1F)
        return (v << 3) | (v >> 2)
    }

    // MARK: - Alpha

    /// Composes a `DefineBitsJPEG3`/`JPEG4` payload — a JPEG plus a separately
    /// compressed alpha plane — into a single PNG.
    ///
    /// The alpha plane is one byte per pixel, zlib-compressed, in the same row
    /// order as the image and with **no row padding**, which is the one place
    /// this format does not pad. It is straight alpha, not premultiplied, so it
    /// is multiplied in here on the way to a premultiplied buffer.
    ///
    /// - Returns: PNG bytes, or `nil` when the JPEG cannot be decoded or the
    ///   alpha does not match its size. `nil` is a signal to fall back to
    ///   writing the bare JPEG: an image without its transparency is a poor
    ///   result, and no image at all is a worse one.
    static func composingAlpha(
        jpeg: Data, alphaZlib: Data, limits: SWFLimits, name: String
    ) -> Data? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width * height <= limits.maximumBitmapPixels else {
            return nil
        }

        let alphaCount = width * height
        guard let alpha = try? SWFReader.inflateZlib(
            alphaZlib, expectedCount: alphaCount,
            limit: min(limits.maximumDecompressedBytes, alphaCount + 4096),
            what: "\(name)'s alpha channel"
        ), alpha.count >= alphaCount else { return nil }

        // Draw into an opaque RGBX buffer first. Drawing straight into a
        // premultiplied buffer would be one step shorter and wrong: Core
        // Graphics would set every alpha byte to 255 and the multiply below
        // would then be applied to values that already claim to be
        // premultiplied at full opacity — correct only by coincidence, and only
        // because 255 is the identity. Keeping the two steps separate keeps the
        // colour values straight until the exact point they are premultiplied.
        var pixels = Data(count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }

        alpha.withUnsafeBytes { alphaBuffer in
            guard let alphaBytes = alphaBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return
            }
            pixels.withUnsafeMutableBytes { raw in
                guard let out = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                for index in 0..<alphaCount {
                    let a = alphaBytes[index]
                    let offset = index * 4
                    out[offset] = premultiply(out[offset], a)
                    out[offset + 1] = premultiply(out[offset + 1], a)
                    out[offset + 2] = premultiply(out[offset + 2], a)
                    out[offset + 3] = a
                }
            }
        }

        return pngData(Raster(width: width, height: height, pixels: pixels))
    }

    private static func premultiply(_ channel: UInt8, _ alpha: UInt8) -> UInt8 {
        UInt8((Int(channel) * Int(alpha) + 127) / 255)
    }

    // MARK: - PNG

    /// Encodes a premultiplied RGBA raster as PNG.
    ///
    /// PNG is the destination for every raster this module produces, and the
    /// choice is not about quality: it is that these rasters are palettes,
    /// 15-bit gradients and cut-out sprites, and re-encoding one lossily would
    /// make Lathe the thing that damaged the only surviving copy. A PNG is a
    /// faithful record of what the SWF held; a caller wanting a smaller file can
    /// recompress it with `LatheImage`, knowing what it started from.
    static func pngData(_ raster: Raster) -> Data? {
        let bytesPerRow = raster.width * 4
        guard raster.pixels.count >= bytesPerRow * raster.height,
              let provider = CGDataProvider(data: raster.pixels as CFData),
              let image = CGImage(
                width: raster.width, height: raster.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, pngTypeIdentifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static var pngTypeIdentifier: String {
        #if canImport(UniformTypeIdentifiers)
        return UTType.png.identifier
        #else
        return "public.png"
        #endif
    }
}
