import Foundation
import LatheCore

/// One tag, as found, with its body isolated.
struct SWFTagRecord {
    let code: SWFTagCode
    /// The tag's declared length, which has already been verified to fit.
    let length: Int
    /// A reader that can see this tag's bytes and no others.
    let body: SWFByteReader
    /// `0` at the top level; `1` inside a `DefineSprite`, and so on.
    let depth: Int
    /// The character IDs of the enclosing sprites, outermost first.
    ///
    /// Carried because a `SoundStreamBlock` means nothing on its own: the
    /// soundtrack it belongs to is the *timeline* it was found on, and a movie
    /// with six sprites has seven independent streams that must not be
    /// concatenated into one file.
    let spritePath: [UInt16]
}

/// Walks a SWF tag stream, and the nested streams inside `DefineSprite`.
///
/// ## The shape of the format, and the two ways a reader hangs
///
/// A tag is a `UI16` whose top ten bits are a code and whose bottom six are a
/// length; when that length is `0x3F` the real length follows as a `SI32`. That
/// is the entire structure, and it means a reader *never* has to understand a
/// tag in order to move past it — which is what makes extracting a few known
/// tags from an otherwise incomprehensible file tractable at all.
///
/// It also means the walk is a loop whose step size the file chooses, so both
/// ways a parser hangs are reachable from a crafted file:
///
/// - **A length that moves the cursor backwards.** The long form is signed, so a
///   file can write `-1`. ``SWFByteReader/skip(_:)`` refuses to move backwards,
///   and the length is range-checked before it is used, so this throws.
/// - **A step of zero, forever.** A short tag header is two bytes and a
///   zero-length tag is legal — `End` and `ShowFrame` are both zero-length — so
///   the guarantee cannot be "every tag advances the cursor". It is instead that
///   every *iteration* consumes the two-byte header, which is unconditional, so
///   the loop is bounded by the byte count regardless of what the tags say.
///   ``SWFLimits/maximumTagCount`` is the belt to that braces.
///
/// Sprite recursion is bounded separately by ``SWFLimits/maximumSpriteDepth``,
/// because deep nesting exhausts the *stack*, and stack exhaustion in Swift is
/// not an error a caller can catch — it is a crash in the host application.
enum SWFTagStream {

    /// The length value in a short tag header that means "a `SI32` follows".
    private static let longLengthSentinel = 0x3F

    /// Visits every tag in `reader`, descending into sprites.
    ///
    /// - Throws: ``LatheError/invalidInput(reason:)`` for any tag whose declared
    ///   length does not fit the bytes actually present, and for a stream that
    ///   exceeds the tag or depth ceilings. Nothing here recovers and continues:
    ///   a tag stream that has gone wrong has lost its framing, and every
    ///   "recovered" tag after that point is noise presented as data.
    static func walk(
        _ reader: inout SWFByteReader, limits: SWFLimits, name: String,
        visit: (SWFTagRecord) throws -> Void
    ) throws {
        var budget = limits.maximumTagCount
        try walk(&reader, limits: limits, name: name, depth: 0, spritePath: [], budget: &budget,
                 visit: visit)
    }

    private static func walk(
        _ reader: inout SWFByteReader, limits: SWFLimits, name: String, depth: Int,
        spritePath: [UInt16], budget: inout Int, visit: (SWFTagRecord) throws -> Void
    ) throws {
        while true {
            // A stream that simply runs out is treated as ended rather than as
            // malformed. A missing `End` tag at the very end of a file is common
            // in the wild — authoring tools truncated the last two bytes for
            // years — and refusing such a file would throw away every bitmap in
            // it to enforce a terminator nothing reads.
            guard reader.remaining >= 2 else { return }

            guard budget > 0 else {
                throw LatheError.invalidInput(
                    reason: "\(name) contains more than \(limits.maximumTagCount) tags; refusing "
                        + "to continue"
                )
            }
            budget -= 1

            let header = try reader.u16()
            let code = SWFTagCode(rawValue: header >> 6)
            var length = Int(header & 0x3F)

            if length == longLengthSentinel {
                let declared = try reader.i32()
                guard declared >= 0 else {
                    throw LatheError.invalidInput(
                        reason: "\(name): \(code) declares a negative length (\(declared))"
                    )
                }
                length = Int(declared)
            }

            guard length <= reader.remaining else {
                throw LatheError.invalidInput(
                    reason: "\(name): \(code) declares \(length) bytes but only "
                        + "\(reader.remaining) remain in the file"
                )
            }

            if code == .end { return }

            let body = try reader.slice(
                at: reader.offset, count: length, label: "\(name): \(code) body"
            )
            let record = SWFTagRecord(
                code: code, length: length, body: body, depth: depth, spritePath: spritePath
            )
            try visit(record)

            if code == .defineSprite {
                try walkSprite(
                    record, limits: limits, name: name, depth: depth, spritePath: spritePath,
                    budget: &budget, visit: visit
                )
            }

            try reader.skip(length)
        }
    }

    /// Descends into a `DefineSprite`.
    ///
    /// Sprites matter here for one reason: a *streaming* soundtrack is stored as
    /// `SoundStreamBlock` tags interleaved with the frames that play them, and
    /// in any movie assembled by a human those frames are inside a sprite. A
    /// walker that stayed at the top level would report "no audio" for a file
    /// whose entire point is its music.
    ///
    /// The nested reader is a slice of the sprite's own body, so the recursion
    /// is contained by construction: a sprite cannot describe tags outside
    /// itself, however its lengths are crafted.
    private static func walkSprite(
        _ record: SWFTagRecord, limits: SWFLimits, name: String, depth: Int,
        spritePath: [UInt16], budget: inout Int, visit: (SWFTagRecord) throws -> Void
    ) throws {
        guard depth < limits.maximumSpriteDepth else {
            throw LatheError.invalidInput(
                reason: "\(name) nests sprites more than \(limits.maximumSpriteDepth) deep; "
                    + "refusing to recurse further"
            )
        }
        var body = record.body
        // UI16 SpriteID, UI16 FrameCount, then an ordinary tag stream. A sprite
        // too short to hold even that is skipped rather than fatal: it defines
        // nothing, so there is nothing to lose by passing over it.
        guard let spriteID = try? body.u16(), (try? body.u16()) != nil else { return }
        try walk(
            &body, limits: limits, name: name, depth: depth + 1,
            spritePath: spritePath + [spriteID], budget: &budget, visit: visit
        )
    }
}
