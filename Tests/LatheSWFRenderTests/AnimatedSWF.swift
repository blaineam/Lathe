import Foundation

/// A tiny, valid, *animated* Flash movie, assembled from the file format rather
/// than committed.
///
/// One solid red square on a dark background, moved across the stage by the
/// main timeline — no ActionScript, no bitmaps, nothing but a vector shape and a
/// `PlaceObject2` per frame. That is the smallest thing that can only look right
/// if a real Flash player drew it: there is no embedded image for anything to
/// have extracted, and the square is in a different place on every frame, so a
/// capture that froze, or that recorded a click-to-play overlay, cannot pass.
///
/// It duplicates the bit writer in `LatheSWFTests` on purpose. SwiftPM test
/// targets cannot depend on one another, and this is thirty lines.
enum AnimatedSWF {

    static let background: (UInt8, UInt8, UInt8) = (0x10, 0x18, 0x20)
    static let square: (UInt8, UInt8, UInt8) = (0xFF, 0x00, 0x00)

    /// The movie: `width` × `height` pixels, `frameCount` frames at
    /// `frameRate`, with a `side`-pixel square advancing `step` pixels a frame.
    static func movie(
        width: Int = 160, height: Int = 120, frameRate: Double = 8, frameCount: Int = 4,
        side: Int = 30, step: Int = 36
    ) -> Data {
        var tags = Data()
        tags += tag(9, Data([background.0, background.1, background.2]))  // SetBackgroundColor
        tags += defineSquare(id: 1, side: side)
        for frame in 0..<frameCount {
            let x = 10 + frame * step
            let y = (height - side) / 2
            tags += placeObject2(id: 1, depth: 1, x: x, y: y, isMove: frame > 0)
            tags += tag(1)  // ShowFrame
        }
        tags += tag(0)  // End

        var body = rect(width: width * 20, height: height * 20)
        body += u16(UInt16((frameRate * 256).rounded()))
        body += u16(UInt16(frameCount))
        body += tags
        // Version 8: old enough to need nothing modern, new enough that Ruffle
        // treats it as ordinary AVM1 content.
        return Data("FWS".utf8) + Data([8]) + u32(UInt32(8 + body.count)) + body
    }

    // MARK: - Tags

    private static func tag(_ code: UInt16, _ body: Data = Data()) -> Data {
        if body.count < 0x3F {
            return u16(code << 6 | UInt16(body.count)) + body
        }
        return u16(code << 6 | 0x3F) + u32(UInt32(body.count)) + body
    }

    /// `DefineShape`: one solid fill, four straight edges, a closed square.
    private static func defineSquare(id: UInt16, side: Int) -> Data {
        let twips = Int32(side * 20)
        var body = u16(id) + rect(width: Int(twips), height: Int(twips))
        body += Data([1, 0x00, square.0, square.1, square.2])  // one solid fill style
        body += Data([0])  // no line styles
        body += Data([0x10])  // NumFillBits 1, NumLineBits 0

        var bits = BitWriter()
        // StyleChangeRecord: select fill style 0 = 1, move to the origin.
        bits.write(0, bits: 1)  // TypeFlag: non-edge
        bits.write(0, bits: 1)  // StateNewStyles
        bits.write(0, bits: 1)  // StateLineStyle
        bits.write(0, bits: 1)  // StateFillStyle1
        bits.write(1, bits: 1)  // StateFillStyle0
        bits.write(1, bits: 1)  // StateMoveTo
        bits.write(16, bits: 5)
        bits.writeSigned(0, bits: 16)
        bits.writeSigned(0, bits: 16)
        bits.write(1, bits: 1)  // FillStyle0 = 1
        // Four general straight edges, 16-bit deltas.
        for (dx, dy) in [(twips, 0), (0, twips), (-twips, 0), (0, -twips)] {
            bits.write(1, bits: 1)  // TypeFlag: edge
            bits.write(1, bits: 1)  // StraightFlag
            bits.write(16 - 2, bits: 4)
            bits.write(1, bits: 1)  // GeneralLineFlag
            bits.writeSigned(dx, bits: 16)
            bits.writeSigned(dy, bits: 16)
        }
        bits.write(0, bits: 6)  // EndShapeRecord
        body += bits.finish()
        return tag(2, body)
    }

    /// `PlaceObject2` with a translate-only matrix; a move after the first frame.
    private static func placeObject2(id: UInt16, depth: UInt16, x: Int, y: Int, isMove: Bool)
        -> Data
    {
        // HasMatrix, plus HasCharacter to place or Move to move.
        var body = Data([isMove ? 0x05 : 0x06]) + u16(depth)
        if !isMove { body += u16(id) }
        var bits = BitWriter()
        bits.write(0, bits: 1)  // HasScale
        bits.write(0, bits: 1)  // HasRotate
        bits.write(16, bits: 5)
        bits.writeSigned(Int32(x * 20), bits: 16)
        bits.writeSigned(Int32(y * 20), bits: 16)
        body += bits.finish()
        return tag(26, body)
    }

    // MARK: - Primitives

    /// A `RECT` from the origin, in twips.
    private static func rect(width: Int, height: Int) -> Data {
        var bits = BitWriter()
        bits.write(20, bits: 5)
        bits.writeSigned(0, bits: 20)
        bits.writeSigned(Int32(width), bits: 20)
        bits.writeSigned(0, bits: 20)
        bits.writeSigned(Int32(height), bits: 20)
        return bits.finish()
    }

    private static func u16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }

    private static func u32(_ value: UInt32) -> Data {
        Data((0..<4).map { UInt8((value >> ($0 * 8)) & 0xFF) })
    }

    /// Bit fields, most significant bit first, the way SWF packs them.
    private struct BitWriter {
        private var bytes: [UInt8] = []
        private var current: UInt8 = 0
        private var filled = 0

        mutating func write(_ value: UInt32, bits: Int) {
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
            write(UInt32(bitPattern: value) & ((UInt32(1) << bits) - 1), bits: bits)
        }

        mutating func finish() -> Data {
            if filled > 0 { bytes.append(current << (8 - filled)) }
            return Data(bytes)
        }
    }
}
