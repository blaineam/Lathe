import Foundation
import LatheCore

/// A bounds-checked cursor over SWF bytes, with the bit-level reads the format
/// needs.
///
/// ## Why this is not `LatheDoc`'s `ByteReader`
///
/// SWF is little-endian across bytes, exactly like ZIP, so the integer reads
/// look identical and the reflex is to share one type. Two things rule it out,
/// and the second is the one that matters.
///
/// The first is the linking contract: `LatheSWF` depends on `LatheCore` alone,
/// and reusing forty lines is not a reason to link a PDF module.
///
/// The second is that **SWF reads bits in the opposite order from which it
/// reads bytes.** Integers are least-significant-byte-first; bit fields are
/// most-significant-*bit*-first, packed continuously across byte boundaries
/// with no alignment — a `RECT` is a five-bit width followed by four signed
/// values of that width, so a frame size can be 37 bits long and the next field
/// begins mid-byte. A reader that grew both orders would have to be read very
/// carefully every time, which is precisely the property a shared utility must
/// not have.
///
/// ## Everything here is hostile input
///
/// A `.swf` is a file somebody found on the internet fifteen years ago. Every
/// read is bounds-checked against an explicit limit, and **no declared length
/// is ever trusted** — a length is a claim by the file about itself, checked
/// against the bytes actually present before it is used to advance anything.
/// The reader has no failure mode that is not a thrown error: it cannot read
/// past its limit, and it cannot move its cursor backwards.
struct SWFByteReader {

    /// The bytes being read. Sliced `Data` is common here (a tag body is a
    /// slice of the decompressed file), so every access is relative to
    /// `startIndex` rather than to zero — indexing a slice from zero is the
    /// classic `Data` trap, and it does not crash, it reads the wrong bytes.
    private let data: Data
    private let base: Int

    /// Cursor and end, both as offsets from `base`.
    private(set) var offset: Int
    private let limit: Int

    /// What to call this run of bytes when a read fails. Carried so an error
    /// says "DefineBitsLossless body" rather than "record".
    private let label: String

    /// The partially-consumed byte for bit reads, and how many of its low bits
    /// remain. Zero means the cursor is byte-aligned.
    private var partialBits: UInt8 = 0
    private var partialBitCount: Int = 0

    init(_ data: Data, label: String) {
        self.data = data
        self.base = data.startIndex
        self.offset = 0
        self.limit = data.count
        self.label = label
    }

    /// A reader over a sub-range of this one's bytes, without copying.
    ///
    /// Used for tag bodies and for the tag stream nested inside a `DefineSprite`:
    /// a nested walk gets a reader that **cannot see past its parent's body**,
    /// so a sprite whose contents claim to run off the end of the sprite cannot
    /// reach the rest of the file. Containment is structural rather than
    /// checked, which is the only kind that stays true as the code grows.
    func slice(at start: Int, count: Int, label: String) throws -> SWFByteReader {
        guard start >= 0, count >= 0, start <= limit, count <= limit - start else {
            throw LatheError.invalidInput(
                reason: "\(self.label) declares a \(count)-byte range at \(start) "
                    + "that runs past its own \(limit) bytes"
            )
        }
        return SWFByteReader(data[(base + start)..<(base + start + count)], label: label)
    }

    // MARK: - Position

    var remaining: Int { max(0, limit - offset) }
    var isAtEnd: Bool { remaining == 0 }
    var count: Int { limit }

    /// Advance, refusing to move backwards.
    ///
    /// The refusal is the loop guarantee: the tag walker advances by a
    /// file-declared length, and a negative or wrapping length that moved the
    /// cursor back would spin forever on a crafted file rather than fail.
    mutating func skip(_ byteCount: Int) throws {
        guard byteCount >= 0 else {
            throw LatheError.invalidInput(reason: "\(label) declares a negative length")
        }
        guard byteCount <= remaining else {
            throw LatheError.invalidInput(
                reason: "\(label) skips \(byteCount) bytes with only \(remaining) left"
            )
        }
        offset += byteCount
        alignToByte()
    }

    /// Discard a partially consumed byte, which SWF does after every bit field.
    mutating func alignToByte() {
        partialBits = 0
        partialBitCount = 0
    }

    // MARK: - Bytes

    mutating func bytes(_ byteCount: Int) throws -> Data {
        alignToByte()
        guard byteCount >= 0 else {
            throw LatheError.invalidInput(reason: "\(label) declares a negative length")
        }
        guard byteCount <= remaining else {
            throw LatheError.invalidInput(
                reason: "\(label) wants \(byteCount) bytes with only \(remaining) left"
            )
        }
        defer { offset += byteCount }
        return data[(base + offset)..<(base + offset + byteCount)]
    }

    /// Everything from the cursor to the limit.
    mutating func rest() throws -> Data { try bytes(remaining) }

    mutating func u8() throws -> UInt8 {
        alignToByte()
        guard remaining >= 1 else {
            throw LatheError.invalidInput(reason: "\(label) is truncated")
        }
        defer { offset += 1 }
        return data[base + offset]
    }

    mutating func u16() throws -> UInt16 {
        let low = UInt16(try u8())
        let high = UInt16(try u8())
        return low | (high << 8)
    }

    mutating func u32() throws -> UInt32 {
        let low = UInt32(try u16())
        let high = UInt32(try u16())
        return low | (high << 16)
    }

    /// A signed 32-bit value, two's complement.
    ///
    /// `Int32(bitPattern:)` rather than a cast, because the long tag header's
    /// length field is nominally `SI32` and a file that writes `-1` there must
    /// arrive as a negative number the caller can reject — not as 4294967295,
    /// which would sail through an upper-bound check and then allocate.
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    // MARK: - Bits
    //
    // MSB-first within each byte, continuing across byte boundaries with no
    // padding, which is how SWF packs `UB[n]` / `SB[n]` / `FB[n]` fields.

    mutating func unsignedBits(_ bitCount: Int) throws -> UInt32 {
        guard (0...32).contains(bitCount) else {
            throw LatheError.invalidInput(
                reason: "\(label) declares a \(bitCount)-bit field, which cannot exist"
            )
        }
        var value: UInt32 = 0
        for _ in 0..<bitCount {
            if partialBitCount == 0 {
                guard remaining >= 1 else {
                    throw LatheError.invalidInput(reason: "\(label) ran out of bits")
                }
                partialBits = data[base + offset]
                partialBitCount = 8
                offset += 1
            }
            let bit = (partialBits >> 7) & 1
            partialBits <<= 1
            partialBitCount -= 1
            value = (value << 1) | UInt32(bit)
        }
        return value
    }

    /// A signed bit field, sign-extended from its own width.
    mutating func signedBits(_ bitCount: Int) throws -> Int32 {
        guard bitCount > 0 else { _ = try unsignedBits(bitCount); return 0 }
        let raw = try unsignedBits(bitCount)
        guard bitCount < 32 else { return Int32(bitPattern: raw) }
        let signBit = UInt32(1) << (bitCount - 1)
        if raw & signBit != 0 {
            // Sign-extend by filling the bits above the field's width.
            return Int32(bitPattern: raw | ~((UInt32(1) << bitCount) - 1))
        }
        return Int32(bitPattern: raw)
    }

    /// A `RECT`: five bits of width, then four signed values of that width, in
    /// twips. Leaves the cursor byte-aligned, as the format requires.
    mutating func rect() throws -> SWFRect {
        let width = Int(try unsignedBits(5))
        let xMin = try signedBits(width)
        let xMax = try signedBits(width)
        let yMin = try signedBits(width)
        let yMax = try signedBits(width)
        alignToByte()
        return SWFRect(xMin: xMin, xMax: xMax, yMin: yMin, yMax: yMax)
    }
}
