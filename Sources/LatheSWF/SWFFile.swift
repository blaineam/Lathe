import Compression
import Foundation
import LatheCore

// MARK: - Geometry

/// A SWF rectangle, in twips — twentieths of a pixel, which is the only unit
/// the format stores coordinates in.
///
/// Kept in twips rather than converted on the way in, because the stage size is
/// most often wanted as the integer pixel size a caller will name a file after,
/// and rounding twice (to a `Double` here, to an `Int` there) is how a 550-pixel
/// stage becomes 549.
public struct SWFRect: Sendable, Equatable, Codable {
    public let xMin: Int32
    public let xMax: Int32
    public let yMin: Int32
    public let yMax: Int32

    public init(xMin: Int32, xMax: Int32, yMin: Int32, yMax: Int32) {
        self.xMin = xMin
        self.xMax = xMax
        self.yMin = yMin
        self.yMax = yMax
    }

    /// Width in pixels, rounded to nearest. Negative extents cannot happen in a
    /// well-formed file and clamp to zero rather than throwing: a nonsensical
    /// stage size is not a reason to refuse to extract the bitmaps.
    public var widthInPixels: Int { Self.pixels(from: xMin, to: xMax) }
    public var heightInPixels: Int { Self.pixels(from: yMin, to: yMax) }

    private static func pixels(from low: Int32, to high: Int32) -> Int {
        max(0, Int(((Double(high) - Double(low)) / 20.0).rounded()))
    }
}

// MARK: - Compression

/// How a SWF's body is stored, as declared by its three-byte signature.
public enum SWFCompression: String, Sendable, Equatable, Codable, CustomStringConvertible {
    /// `FWS` — the body follows the header verbatim.
    case none
    /// `CWS` — the body is a zlib stream (RFC 1950). SWF 6 and later.
    case zlib
    /// `ZWS` — the body is a raw LZMA1 stream. SWF 13 and later, and the one
    /// this module cannot read. See ``SWFReader`` for why.
    case lzma

    public var signature: String {
        switch self {
        case .none: "FWS"
        case .zlib: "CWS"
        case .lzma: "ZWS"
        }
    }

    public var description: String {
        switch self {
        case .none: "uncompressed (FWS)"
        case .zlib: "zlib (CWS)"
        case .lzma: "LZMA (ZWS)"
        }
    }
}

// MARK: - Header

/// A SWF's header: everything the file says about itself before its first tag.
public struct SWFHeader: Sendable, Equatable, Codable {
    public let compression: SWFCompression
    /// The SWF version the file declares. Advisory: files routinely claim a
    /// version older than the tags they actually contain.
    public let version: UInt8

    /// The total uncompressed length the header claims, header included.
    ///
    /// **A claim, not a fact.** It is used as a starting size for the
    /// decompression buffer and nothing else; a file that lies about it
    /// decompresses correctly anyway, and a file that lies *enormously* about it
    /// is capped by ``SWFLimits/maximumDecompressedBytes`` rather than being
    /// allowed to name its own allocation.
    public let declaredFileLength: UInt32

    /// The stage, in twips.
    public let frameSize: SWFRect
    /// Frames per second. Stored as an 8.8 fixed-point value.
    public let frameRate: Double
    /// The main timeline's frame count, as declared.
    public let frameCount: UInt16

    public var stageWidthInPixels: Int { frameSize.widthInPixels }
    public var stageHeightInPixels: Int { frameSize.heightInPixels }
}

// MARK: - Limits

/// Ceilings applied to a file that is, by assumption, hostile.
///
/// Every one of these exists because some field in a SWF is a number the *file*
/// chooses and this module would otherwise act on: a decompressed size, a
/// bitmap's dimensions, how many tags there are, how deep sprites nest. Left
/// unbounded, each is a way for a few hundred bytes on disk to become a few
/// gigabytes in memory — which on iOS is not a slow program, it is a jetsam
/// kill, and the crash log blames the host application.
///
/// They are a `struct` with defaults rather than constants so that a caller
/// processing a trusted archive of its own files can raise them deliberately,
/// in one visible place, instead of discovering the limit as a mysterious
/// failure and patching the module.
public struct SWFLimits: Sendable, Equatable {

    /// The largest body this module will decompress. Default 256 MiB.
    public var maximumDecompressedBytes: Int

    /// The largest bitmap, in pixels, this module will rasterise. Default
    /// 16,777,216 — a 4096×4096 image, comfortably beyond anything Flash ever
    /// shipped, and 64 MiB as RGBA.
    ///
    /// The field it guards is two `UInt16`s, so a malformed tag can ask for
    /// 65535×65535: four billion pixels, sixteen gigabytes.
    public var maximumBitmapPixels: Int

    /// How many tags a single tag stream may contain before the walk gives up.
    /// Default 1,000,000.
    public var maximumTagCount: Int

    /// How deeply `DefineSprite` may nest. Default 16.
    ///
    /// Sprites contain tag streams that contain sprites, so the walk is
    /// recursive and a crafted file could otherwise recurse until the *stack*
    /// runs out — which is not a catchable error in Swift, it is a crash.
    public var maximumSpriteDepth: Int

    public init(
        maximumDecompressedBytes: Int = 256 * 1024 * 1024,
        maximumBitmapPixels: Int = 16_777_216,
        maximumTagCount: Int = 1_000_000,
        maximumSpriteDepth: Int = 16
    ) {
        self.maximumDecompressedBytes = maximumDecompressedBytes
        self.maximumBitmapPixels = maximumBitmapPixels
        self.maximumTagCount = maximumTagCount
        self.maximumSpriteDepth = maximumSpriteDepth
    }

    public static let `default` = SWFLimits()
}

// MARK: - Reading the container

/// Opens a `.swf`: reads the header, decompresses the body, and hands back a
/// cursor positioned at the first tag.
///
/// ## The three signatures, and the one that cannot be read
///
/// A SWF begins with `FWS`, `CWS` or `ZWS` — uncompressed, zlib, LZMA. The first
/// eight bytes are *always* plain, whichever it is: signature, version byte, and
/// a `UI32` length. Compression begins at byte 8.
///
/// `CWS` is a zlib stream and the system's Compression framework handles it.
/// `ZWS` is not readable here, and the reason is specific enough to be worth
/// stating rather than waving at:
///
/// - SWF's LZMA body is a **raw LZMA1 stream**: a five-byte properties header,
///   then compressed data, with the uncompressed size known from the SWF header
///   rather than carried inline.
/// - Apple's `COMPRESSION_LZMA` is not that. It is the **xz container** — a
///   compressed buffer produced by it begins `FD 37 7A 58 5A 00`, the xz magic —
///   which frames LZMA2 chunks inside blocks with their own index and checksums.
///   There is no way to present a raw LZMA1 stream to it, because the framing it
///   requires is not framing SWF's payload has.
/// - Decoding it would therefore mean either a third-party LZMA library or an
///   LZMA range decoder written here. Lathe takes no third-party runtime
///   dependencies, and a hand-written LZMA decoder is a substantial piece of
///   code whose failure mode on hostile input is exactly the class of bug this
///   module is otherwise arranged to avoid.
///
/// So `ZWS` is **detected and refused by name**, with an error that says which
/// compression was found and why it was not attempted. A caller can then
/// decompress the file elsewhere and hand back an `FWS` — the useful answer —
/// rather than being told "invalid SWF" about a perfectly valid one.
enum SWFReader {

    /// The eight bytes every SWF begins with, compressed or not.
    static let plainHeaderLength = 8

    /// Reads the file and returns its header together with a reader over the
    /// *decompressed* body, positioned immediately after the frame rate and
    /// frame count — that is, at the first tag.
    static func open(_ url: URL, name: String, limits: SWFLimits) throws -> (
        header: SWFHeader, tags: SWFByteReader
    ) {
        let data: Data
        do {
            // `.mappedIfSafe` rather than a plain read: an uncompressed SWF can
            // be large, and mapping keeps the untouched majority of a file whose
            // tags we skip out of resident memory.
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw LatheError.readFailed(path: name, reason: (error as NSError).localizedDescription)
        }
        return try open(data, name: name, limits: limits)
    }

    /// The same, for bytes already in hand. Split out so tests can synthesise a
    /// file without touching the filesystem.
    static func open(_ data: Data, name: String, limits: SWFLimits) throws -> (
        header: SWFHeader, tags: SWFByteReader
    ) {
        guard data.count >= plainHeaderLength else {
            throw LatheError.invalidInput(
                reason: "\(name) is \(data.count) bytes; a SWF header is at least "
                    + "\(plainHeaderLength)"
            )
        }

        var head = SWFByteReader(data, label: "\(name) header")
        let signature = try head.bytes(3)
        let compression = try compressionKind(forSignature: signature, name: name)
        let version = try head.u8()
        let declaredFileLength = try head.u32()

        let body = try body(
            of: data, compression: compression, declaredFileLength: declaredFileLength,
            name: name, limits: limits
        )

        var reader = SWFByteReader(body, label: "\(name) body")
        let frameSize = try reader.rect()
        // 8.8 fixed point in a little-endian UI16: the low byte is the
        // fraction. Reading it as an integer frame rate — the obvious mistake —
        // turns 24 fps into 6144.
        let frameRate = Double(try reader.u16()) / 256.0
        let frameCount = try reader.u16()

        let header = SWFHeader(
            compression: compression,
            version: version,
            declaredFileLength: declaredFileLength,
            frameSize: frameSize,
            frameRate: frameRate,
            frameCount: frameCount
        )
        return (header, reader)
    }

    /// Just the signature and version, without decompressing anything.
    ///
    /// Exists so a caller can tell an LZMA SWF from a corrupt file cheaply, and
    /// so ``SWFCapture/compression(of:)`` can answer for a file it will then
    /// refuse.
    static func signature(of data: Data, name: String) throws -> (SWFCompression, UInt8) {
        guard data.count >= 4 else {
            throw LatheError.invalidInput(reason: "\(name) is too short to hold a SWF signature")
        }
        var head = SWFByteReader(data, label: "\(name) signature")
        let compression = try compressionKind(forSignature: try head.bytes(3), name: name)
        return (compression, try head.u8())
    }

    private static func compressionKind(forSignature bytes: Data, name: String) throws
        -> SWFCompression
    {
        switch Array(bytes) {
        case Array("FWS".utf8): return .none
        case Array("CWS".utf8): return .zlib
        case Array("ZWS".utf8): return .lzma
        default:
            let printable = String(decoding: bytes, as: UTF8.self)
                .map { $0.isLetter || $0.isNumber ? $0 : "?" }
            throw LatheError.invalidInput(
                reason: "\(name) does not begin with a SWF signature: found "
                    + "'\(String(printable))', expected FWS, CWS or ZWS"
            )
        }
    }

    private static func body(
        of data: Data, compression: SWFCompression, declaredFileLength: UInt32,
        name: String, limits: SWFLimits
    ) throws -> Data {
        let compressedBody = data[(data.startIndex + plainHeaderLength)...]
        guard !compressedBody.isEmpty else {
            throw LatheError.invalidInput(reason: "\(name) has a header and no body")
        }

        switch compression {
        case .none:
            return Data(compressedBody)

        case .zlib:
            // The header's length counts itself, so the body inflates to eight
            // bytes fewer. Treated as a hint: it sizes the first attempt, and
            // the inflater grows if the file undercounted.
            let hint = Int(declaredFileLength) - plainHeaderLength
            return try inflateZlib(
                Data(compressedBody),
                expectedCount: hint > 0 ? hint : nil,
                limit: limits.maximumDecompressedBytes,
                what: "\(name)'s compressed body"
            )

        case .lzma:
            throw LatheError.decodeUnavailable(
                format: "LZMA-compressed SWF (ZWS). Apple's Compression framework implements "
                    + "LZMA only as the xz container format, and a SWF's body is a raw LZMA1 "
                    + "stream with a 5-byte properties header, which xz cannot frame. Lathe "
                    + "adds no third-party dependency to read it. Decompress \(name) to an "
                    + "uncompressed (FWS) SWF elsewhere and pass that."
            )
        }
    }

    // MARK: - zlib

    /// Inflates an RFC 1950 zlib stream — header, deflate data, Adler-32.
    ///
    /// **The trap is the framework's naming, and it is the exact inverse of the
    /// one `LatheDoc`'s ZIP reader documents.** `COMPRESSION_ZLIB` is Apple's
    /// name for *raw* DEFLATE (RFC 1951) with no wrapper. ZIP stores raw
    /// deflate, so the ZIP reader passes its bytes through untouched. SWF stores
    /// the wrapped form, so **the two-byte zlib header must be removed here**
    /// before the same function is called. Get it backwards in either direction
    /// and the first block decodes to garbage while everything after it looks
    /// plausible — a corruption that survives a glance at the output.
    ///
    /// The trailing Adler-32 needs no handling: raw inflate stops at the final
    /// block and simply never reads it. It is therefore also never *checked*,
    /// which is the right trade — a SWF with one bad checksum and twelve good
    /// bitmaps should yield twelve bitmaps.
    static func inflateZlib(
        _ data: Data, expectedCount: Int?, limit: Int, what: String
    ) throws -> Data {
        guard data.count > 2 else {
            throw LatheError.invalidInput(reason: "\(what) is too short to be a zlib stream")
        }
        let cmf = data[data.startIndex]
        let flg = data[data.startIndex + 1]
        // Low nibble 8 is "deflate"; the two bytes together must be a multiple
        // of 31. Checked so that a tag whose payload is not zlib at all fails
        // here, naming itself, rather than inflating to zero bytes and being
        // reported as an empty image.
        guard cmf & 0x0F == 8, (UInt16(cmf) << 8 | UInt16(flg)) % 31 == 0 else {
            throw LatheError.invalidInput(
                reason: "\(what) is not a zlib stream (header bytes "
                    + String(format: "%02X %02X", cmf, flg) + ")"
            )
        }
        // FDICT — a preset dictionary the stream does not carry. Nothing writes
        // one here, and inflating without it would silently produce wrong bytes.
        guard flg & 0x20 == 0 else {
            throw LatheError.invalidInput(
                reason: "\(what) needs a preset zlib dictionary, which a SWF never supplies"
            )
        }

        let deflate = Data(data[(data.startIndex + 2)...])

        var capacity = min(max(expectedCount ?? (deflate.count * 4), 64 * 1024), limit)
        while true {
            var destination = Data(count: capacity)
            let written: Int = destination.withUnsafeMutableBytes { destinationBuffer in
                deflate.withUnsafeBytes { sourceBuffer in
                    guard
                        let destinationBase = destinationBuffer.bindMemory(to: UInt8.self)
                            .baseAddress,
                        let sourceBase = sourceBuffer.bindMemory(to: UInt8.self).baseAddress
                    else { return 0 }
                    return compression_decode_buffer(
                        destinationBase, capacity, sourceBase, deflate.count, nil, COMPRESSION_ZLIB
                    )
                }
            }
            guard written > 0 else {
                throw LatheError.invalidInput(
                    reason: "\(what) did not inflate; it is truncated or not deflate data"
                )
            }
            // `compression_decode_buffer` fills the buffer and returns its size
            // whether it finished or merely ran out of room, so a full buffer is
            // ambiguous and has to be retried larger. Only a short result proves
            // the stream ended.
            if written < capacity {
                destination.removeSubrange(written...)
                return destination
            }
            guard capacity < limit else {
                throw LatheError.invalidInput(
                    reason: "\(what) inflates to more than the \(limit)-byte ceiling; refusing "
                        + "to continue (raise SWFLimits.maximumDecompressedBytes if this file "
                        + "is trusted)"
                )
            }
            capacity = min(capacity * 4, limit)
        }
    }
}
