import Foundation
import LatheCore

/// One box of an ISO base media file: its type, where it is, and how big.
///
/// "Box" and "atom" are the same thing; the ISO specification says box and
/// QuickTime says atom, and this module says whichever reads better in the
/// sentence. Offsets are absolute file offsets even for a box nested inside
/// another, so a box found while walking a parent's payload in memory can be
/// patched on disk without arithmetic at the call site.
struct ISOBox: Equatable, Sendable {
    /// The four-character type, decoded as Latin-1 so `©nam` keeps its `©`.
    var type: String
    /// Absolute offset of the box's first byte.
    var offset: UInt64
    /// 8 for a plain box, 16 when the size is 64-bit, and 16 more for `uuid`.
    var headerSize: UInt64
    /// The whole box, header included.
    var size: UInt64
    /// Whether the size field was zero — "to the end of the file" — which only
    /// the last box may say and which nothing can be appended after.
    var extendsToEnd: Bool = false

    var payloadOffset: UInt64 { offset + headerSize }
    var payloadSize: UInt64 { size - headerSize }
    var end: UInt64 { offset + size }
}

/// Reading and writing the box structure of an ISO base media file.
///
/// ## Why this exists beside AVFoundation
///
/// AVFoundation reads the structure fine and will not edit it: every write it
/// offers is a new file with every sample copied. A metadata change touches a
/// few kilobytes inside `moov`, and the only way to write those few kilobytes
/// — and nothing else — is to know where they are. This is the smallest
/// parser that does: the top-level table, the children of a box, and the
/// headers to write one back. It decodes nothing inside a sample table, and
/// it never needs to, because the samples never move.
enum ISOBMFF {

    /// What a header reads as, before the box is known to fit.
    struct Header {
        var type: String
        var headerSize: UInt64
        var size: UInt64
        var extendsToEnd: Bool
    }

    /// Decodes the header at the start of `bytes`, which must hold at least 8
    /// bytes. `available` is how many bytes the box may occupy, for resolving
    /// a zero size.
    static func header(_ bytes: Data, available: UInt64) -> Header? {
        guard bytes.count >= 8 else { return nil }
        var size = UInt64(uint32(bytes, at: 0))
        let type = fourCC(bytes, at: 4)
        var headerSize: UInt64 = 8
        var extendsToEnd = false
        if size == 1 {
            guard bytes.count >= 16 else { return nil }
            size = uint64(bytes, at: 8)
            headerSize = 16
        } else if size == 0 {
            size = available
            extendsToEnd = true
        }
        if type == "uuid" { headerSize += 16 }
        guard size >= headerSize else { return nil }
        return Header(type: type, headerSize: headerSize, size: size, extendsToEnd: extendsToEnd)
    }

    /// The boxes that tile `payload`, whose first byte sits at `base` in the
    /// file.
    ///
    /// - Throws: ``LatheError/invalidInput(reason:)`` when a box runs past
    ///   the end, or the bytes do not tile exactly — a parent whose children
    ///   do not add up is a parent this module must not rebuild, because it
    ///   could not put back what it did not understand.
    static func children(of payload: Data, base: UInt64, in parent: String) throws -> [ISOBox] {
        var boxes: [ISOBox] = []
        var cursor = 0
        let count = payload.count
        while cursor < count {
            guard count - cursor >= 8 else {
                throw LatheError.invalidInput(
                    reason: "\(parent) has \(count - cursor) trailing bytes that are not a box"
                )
            }
            let slice = payload.subdata(in: cursor..<min(cursor + 24, count))
            guard let header = header(slice, available: UInt64(count - cursor)) else {
                throw LatheError.invalidInput(reason: "\(parent) holds a box with an impossible size")
            }
            guard UInt64(cursor) + header.size <= UInt64(count) else {
                throw LatheError.invalidInput(
                    reason: "a \(header.type) box inside \(parent) runs past the end of \(parent)"
                )
            }
            boxes.append(ISOBox(
                type: header.type, offset: base + UInt64(cursor),
                headerSize: header.headerSize, size: header.size, extendsToEnd: header.extendsToEnd
            ))
            cursor += Int(header.size)
        }
        return boxes
    }

    /// The top-level table of a file, read header by header.
    ///
    /// Every box has to fit, and the last one has to end exactly at the end of
    /// the file, with one tolerated exception: a final box whose declared
    /// size runs past the end is reported through `trailingPartial` rather
    /// than refused, because that is what an interrupted append looks like
    /// and the next write heals it by cutting it off.
    static func topLevel(of file: ISOFileReader) throws -> (boxes: [ISOBox], trailingPartial: UInt64?) {
        var boxes: [ISOBox] = []
        var cursor: UInt64 = 0
        let length = file.length
        while cursor < length {
            guard length - cursor >= 8 else {
                return (boxes, cursor)
            }
            let bytes = try file.read(at: cursor, count: 24)
            guard let header = header(bytes, available: length - cursor) else {
                throw LatheError.invalidInput(
                    reason: "the box at offset \(cursor) has an impossible size"
                )
            }
            guard cursor + header.size <= length else {
                return (boxes, cursor)
            }
            boxes.append(ISOBox(
                type: header.type, offset: cursor,
                headerSize: header.headerSize, size: header.size, extendsToEnd: header.extendsToEnd
            ))
            cursor += header.size
        }
        return (boxes, nil)
    }

    // MARK: - Encoding

    /// A box header for `size` bytes in all, 64-bit when it has to be.
    static func header(type: String, size: UInt64) -> Data {
        var data = Data()
        if size > UInt64(UInt32.max) {
            data.append(contentsOf: bytes(UInt32(1)))
            data.append(fourCC(type))
            data.append(contentsOf: bytes(size))
        } else {
            data.append(contentsOf: bytes(UInt32(size)))
            data.append(fourCC(type))
        }
        return data
    }

    /// A whole box around `payload`.
    static func box(_ type: String, _ payload: Data) -> Data {
        header(type: type, size: UInt64(payload.count) + 8) + payload
    }

    static func fourCC(_ type: String) -> Data {
        // Latin-1, so `©` is the single byte 0xA9 the atom names use.
        var data = type.data(using: .isoLatin1) ?? Data("????".utf8)
        if data.count != 4 { data = Data(data.prefix(4)) + Data(repeating: 0x20, count: max(0, 4 - data.count)) }
        return data
    }

    static func fourCC(_ data: Data, at offset: Int) -> String {
        let start = data.startIndex + offset
        // Latin-1 maps every byte to the scalar of the same value, which is
        // what keeps `©nam` spelled with its `©` rather than a replacement
        // character.
        return String(String.UnicodeScalarView(data[start..<start + 4].map { Unicode.Scalar($0) }))
    }

    static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        let start = data.startIndex + offset
        return data[start..<start + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    static func uint64(_ data: Data, at offset: Int) -> UInt64 {
        let start = data.startIndex + offset
        return data[start..<start + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }

    static func bytes(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    static func bytes(_ value: UInt64) -> [UInt8] {
        bytes(UInt32(value >> 32)) + bytes(UInt32(value & 0xFFFF_FFFF))
    }
}

/// Positioned reads from one open file.
///
/// A `FileHandle` with the length remembered, so a caller can ask for the
/// bytes at an offset without the seek-then-read dance at every site, and so
/// a read that comes back short is an error rather than a shorter `Data`.
final class ISOFileReader {
    private let handle: FileHandle
    let length: UInt64
    let name: String

    init(url: URL) throws {
        name = url.lastPathComponent
        do {
            handle = try FileHandle(forReadingFrom: url)
            length = try handle.seekToEnd()
        } catch {
            throw LatheError.readFailed(
                path: url.lastPathComponent, reason: (error as NSError).localizedDescription
            )
        }
    }

    deinit { try? handle.close() }

    /// Up to `count` bytes at `offset`; fewer only at the end of the file.
    func read(at offset: UInt64, count: Int) throws -> Data {
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count) ?? Data()
        } catch {
            throw LatheError.readFailed(path: name, reason: (error as NSError).localizedDescription)
        }
    }

    /// Exactly `count` bytes at `offset`.
    func readExactly(at offset: UInt64, count: Int) throws -> Data {
        let data = try read(at: offset, count: count)
        guard data.count == count else {
            throw LatheError.readFailed(
                path: name, reason: "wanted \(count) bytes at offset \(offset) and got \(data.count)"
            )
        }
        return data
    }
}
