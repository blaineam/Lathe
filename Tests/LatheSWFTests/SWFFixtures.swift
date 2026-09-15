import Compression
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Builds SWF byte streams, valid and otherwise.
///
/// **Nothing binary is committed for this suite, and nothing needs to be.** A
/// SWF is a header and a list of length-prefixed tags, so a file exercising a
/// specific tag is a few lines of bytes — which is better than a captured
/// fixture in every way that matters here: the test says exactly what is in the
/// file, a malformed case can be built by changing one number, and there is no
/// file of unknown provenance in the repository whose licence somebody has to
/// explain.
enum SWFFixtures {

    // MARK: - Primitives

    static func u16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    static func u32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ])
    }

    /// Writes bit fields most-significant-bit first, the way SWF packs them.
    struct BitWriter {
        private var bytes: [UInt8] = []
        private var current: UInt8 = 0
        private var filled = 0

        mutating func write(_ value: UInt32, bits: Int) {
            guard bits > 0 else { return }
            for shift in stride(from: bits - 1, through: 0, by: -1) {
                current = (current << 1) | UInt8((value >> UInt32(shift)) & 1)
                filled += 1
                if filled == 8 {
                    bytes.append(current)
                    current = 0
                    filled = 0
                }
            }
        }

        mutating func writeSigned(_ value: Int32, bits: Int) {
            let mask: UInt32 = bits >= 32 ? .max : (UInt32(1) << bits) - 1
            write(UInt32(bitPattern: value) & mask, bits: bits)
        }

        mutating func finish() -> Data {
            if filled > 0 {
                bytes.append(current << (8 - filled))
                current = 0
                filled = 0
            }
            return Data(bytes)
        }
    }

    /// A `RECT` covering `width` × `height` pixels, in twips.
    static func rect(width: Int, height: Int, bits: Int = 20) -> Data {
        var writer = BitWriter()
        writer.write(UInt32(bits), bits: 5)
        writer.writeSigned(0, bits: bits)
        writer.writeSigned(Int32(width * 20), bits: bits)
        writer.writeSigned(0, bits: bits)
        writer.writeSigned(Int32(height * 20), bits: bits)
        return writer.finish()
    }

    // MARK: - Tags

    /// A tag with a correct header, short or long as the body requires.
    static func tag(_ code: UInt16, _ body: Data = Data(), forceLongHeader: Bool = false) -> Data {
        var out = Data()
        if body.count >= 0x3F || forceLongHeader {
            out += u16((code << 6) | 0x3F)
            out += u32(UInt32(body.count))
        } else {
            out += u16((code << 6) | UInt16(body.count))
        }
        return out + body
    }

    /// A tag whose header *lies* about its length. The point of the suite's
    /// malformed half.
    static func lyingTag(_ code: UInt16, declaredLength: Int32, body: Data) -> Data {
        u16((code << 6) | 0x3F) + u32(UInt32(bitPattern: declaredLength)) + body
    }

    static let endTag = tag(0)

    // MARK: - Files

    /// An uncompressed SWF wrapping the given tags.
    static func swf(
        tags: [Data], version: UInt8 = 6, width: Int = 550, height: Int = 400,
        frameRate: Double = 12, frameCount: UInt16 = 1, includeEndTag: Bool = true
    ) -> Data {
        var body = rect(width: width, height: height)
        body += u16(UInt16((frameRate * 256).rounded()))
        body += u16(frameCount)
        for item in tags { body += item }
        if includeEndTag { body += endTag }
        return Data("FWS".utf8) + Data([version]) + u32(UInt32(8 + body.count)) + body
    }

    /// The same file, zlib-compressed and signed `CWS`.
    static func compressed(_ uncompressed: Data) -> Data {
        let body = uncompressed[(uncompressed.startIndex + 8)...]
        return Data("CWS".utf8) + uncompressed[(uncompressed.startIndex + 3)..<(uncompressed
            .startIndex + 8)] + zlib(Data(body))
    }

    /// An `FWS` file whose declared tag stream is replaced wholesale, so a test
    /// can put arbitrary bytes where the tags belong.
    static func swfWithRawBody(_ body: Data, signature: String = "FWS", version: UInt8 = 6) -> Data
    {
        var full = rect(width: 100, height: 100)
        full += u16(UInt16(12 * 256))
        full += u16(1)
        full += body
        return Data(signature.utf8) + Data([version]) + u32(UInt32(8 + full.count)) + full
    }

    // MARK: - zlib

    /// A real RFC 1950 zlib stream: two header bytes, deflate data, Adler-32.
    ///
    /// Falls back to *stored* deflate blocks when the framework declines to
    /// compress, so the builder cannot fail on incompressible input — a fixture
    /// that sometimes does not build is worse than a large one.
    static func zlib(_ data: Data) -> Data {
        var stream = Data([0x78, 0x01])
        stream += deflate(data) ?? storedDeflate(data)
        stream += bigEndian(adler32(data))
        return stream
    }

    private static func deflate(_ data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        let capacity = data.count + 64 * 1024
        var destination = Data(count: capacity)
        let written: Int = destination.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                guard let outBase = out.bindMemory(to: UInt8.self).baseAddress,
                      let inBase = input.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_encode_buffer(
                    outBase, capacity, inBase, data.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        destination.removeSubrange(written...)
        return destination
    }

    /// Deflate's "stored" encoding: a three-bit header padded to a byte, then a
    /// length, its complement, and the bytes verbatim.
    private static func storedDeflate(_ data: Data) -> Data {
        var out = Data()
        var index = data.startIndex
        repeat {
            let chunk = min(65_535, data.endIndex - index)
            let isFinal = index + chunk >= data.endIndex
            out.append(isFinal ? 0x01 : 0x00)
            out += u16(UInt16(chunk))
            out += u16(UInt16(chunk) ^ 0xFFFF)
            out += data[index..<(index + chunk)]
            index += chunk
        } while index < data.endIndex
        return out
    }

    private static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        return (b << 16) | a
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ])
    }

    // MARK: - Real encoded images, generated at run time

    /// A JPEG of a solid colour, made by ImageIO so it is a genuine one.
    static func jpeg(width: Int = 16, height: Int = 12, gray: CGFloat = 0.5) -> Data {
        encoded(width: width, height: height, gray: gray, type: UTType.jpeg)
    }

    static func png(width: Int = 8, height: Int = 8, gray: CGFloat = 0.25) -> Data {
        encoded(width: width, height: height, gray: gray, type: UTType.png)
    }

    private static func encoded(width: Int, height: Int, gray: CGFloat, type: UTType) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(CGColor(red: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            output as CFMutableData, type.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(destination, image, nil)
        _ = CGImageDestinationFinalize(destination)
        return output as Data
    }

    // MARK: - Media tag bodies

    /// `DefineBitsJPEG2`: a character ID and a whole image file.
    static func defineBitsJPEG2(characterID: UInt16, imageData: Data) -> Data {
        tag(21, u16(characterID) + imageData)
    }

    /// `DefineBitsJPEG3`: character, image length, image, zlib alpha.
    static func defineBitsJPEG3(characterID: UInt16, jpeg: Data, alpha: Data) -> Data {
        tag(35, u16(characterID) + u32(UInt32(jpeg.count)) + jpeg + zlib(alpha))
    }

    /// `DefineBitsLossless` / `2`.
    static func defineBitsLossless(
        characterID: UInt16, format: UInt8, width: Int, height: Int, colorTableSize: UInt8? = nil,
        raster: Data, withAlpha: Bool = false
    ) -> Data {
        var body = u16(characterID) + Data([format]) + u16(UInt16(width)) + u16(UInt16(height))
        if let colorTableSize { body += Data([colorTableSize]) }
        body += zlib(raster)
        return tag(withAlpha ? 36 : 20, body)
    }

    /// `DefineSound`. The four fields share one byte, most significant first.
    static func defineSound(
        characterID: UInt16, format: UInt8, rateIndex: UInt8, is16Bit: Bool, isStereo: Bool,
        sampleCount: UInt32, data: Data
    ) -> Data {
        var writer = BitWriter()
        writer.write(UInt32(format), bits: 4)
        writer.write(UInt32(rateIndex), bits: 2)
        writer.write(is16Bit ? 1 : 0, bits: 1)
        writer.write(isStereo ? 1 : 0, bits: 1)
        return tag(14, u16(characterID) + writer.finish() + u32(sampleCount) + data)
    }

    /// `SoundStreamHead2`, whose playback and stream descriptions are separate.
    static func soundStreamHead(
        streamFormat: UInt8, rateIndex: UInt8, is16Bit: Bool = true, isStereo: Bool = false,
        sampleCount: UInt16 = 1152
    ) -> Data {
        var writer = BitWriter()
        writer.write(0, bits: 4)  // reserved
        writer.write(UInt32(rateIndex), bits: 2)  // playback rate
        writer.write(1, bits: 1)  // playback size
        writer.write(isStereo ? 1 : 0, bits: 1)  // playback type
        writer.write(UInt32(streamFormat), bits: 4)
        writer.write(UInt32(rateIndex), bits: 2)
        writer.write(is16Bit ? 1 : 0, bits: 1)
        writer.write(isStereo ? 1 : 0, bits: 1)
        var body = writer.finish() + u16(sampleCount)
        if streamFormat == 2 { body += u16(0) }  // LatencySeek, MP3 only
        return tag(45, body)
    }

    /// `SoundStreamBlock`. MP3 blocks carry a four-byte preamble before frames.
    static func soundStreamBlock(mp3Frames: Data) -> Data {
        tag(19, u16(1152) + u16(0) + mp3Frames)
    }

    /// `DefineSprite`, wrapping a nested tag stream.
    static func defineSprite(characterID: UInt16, frameCount: UInt16, tags: [Data]) -> Data {
        var body = u16(characterID) + u16(frameCount)
        for item in tags { body += item }
        body += endTag
        return tag(39, body)
    }

    /// `DefineVideoStream`.
    static func defineVideoStream(
        characterID: UInt16, frameCount: UInt16, width: UInt16, height: UInt16, codecID: UInt8
    ) -> Data {
        tag(
            60,
            u16(characterID) + u16(frameCount) + u16(width) + u16(height) + Data([0])
                + Data([codecID])
        )
    }

    /// `DefineBinaryData`: an identifier, a reserved word, and the payload.
    static func defineBinaryData(characterID: UInt16, payload: Data) -> Data {
        tag(87, u16(characterID) + u32(0) + payload)
    }

    /// `JPEGTables`, and a `DefineBits` that needs it.
    static func jpegTables(_ data: Data) -> Data { tag(8, data) }
    static func defineBits(characterID: UInt16, scanData: Data) -> Data {
        tag(6, u16(characterID) + scanData)
    }
}
