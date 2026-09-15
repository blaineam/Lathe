import Foundation
import LatheCore

/// An ID3v2 tag: parsing what is there, and writing what should be.
///
/// ## Why this module has its own, rather than using AVFoundation
///
/// AVFoundation reads ID3 and cannot write it, so half of this had to be
/// written regardless. Once the writer exists, reading through it too is the
/// better arrangement: the two agree by construction, the module stops
/// depending on AVFoundation being willing to *open* a file whose audio frames
/// may be damaged in order to report its title, and an MP3 whose tag is
/// readable but whose audio is not is exactly the file someone is trying to fix.
///
/// ## What an ID3 tag is, and why writing one is not a container rewrite
///
/// It is a length-prefixed block bolted onto the front of the MPEG frames, not
/// a structure the audio lives inside. Writing one means: emit a new block, then
/// copy every audio byte across untouched. That is why an ID3 write cannot go
/// through the passthrough export the MP4 family uses, and why it is lossless
/// in an even stronger sense — the audio is not re-muxed, it is copied.
///
/// ## Versions
///
/// Parses v2.2, v2.3 and v2.4; writes v2.4. The differences that matter are
/// small and all of them bite: v2.3 frame sizes are plain integers where v2.4's
/// are syncsafe, so a parser that assumes one reads garbage lengths from the
/// other; v2.2 uses three-character frame IDs; and the whole-tag
/// unsynchronisation scheme inserts bytes that must be removed before anything
/// else is believed.
struct ID3Tag: Equatable {

    /// The frames, in file order. Kept as a list rather than a dictionary
    /// because ID3 legitimately repeats frames — several `APIC` pictures,
    /// several `TXXX` — and collapsing them would silently drop all but one.
    var frames: [Frame]

    /// How many bytes of the source file the tag occupied, header included.
    /// Everything after this offset is audio.
    var byteCount: Int

    struct Frame: Equatable {
        var id: String
        var payload: Payload
    }

    enum Payload: Equatable {
        /// A `T***` frame: one or more strings.
        case text([String])
        /// `COMM`: a language, a short description, and the comment itself.
        case comment(language: String, description: String, text: String)
        /// `APIC`: an embedded picture.
        case picture(mimeType: String, pictureType: UInt8, description: String, data: Data)
        /// `TXXX`: a user-defined key and value.
        case userText(description: String, value: String)
        /// Anything else, carried through byte for byte so a read-modify-write
        /// does not discard frames this module has no name for.
        case raw(Data)
    }

    // MARK: - Parsing

    /// The tag at the start of `data`, or `nil` if there is none.
    ///
    /// - Throws: ``LatheError/invalidInput(reason:)`` for a tag whose header is
    ///   present and self-contradictory, which is worth distinguishing from a
    ///   file that simply has no tag.
    static func parse(_ data: Data, name: String) throws -> ID3Tag? {
        let bytes = [UInt8](data)
        guard bytes.count >= 10,
              bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33   // "ID3"
        else { return nil }

        let major = bytes[3]
        guard (2...4).contains(major) else {
            throw LatheError.invalidInput(
                reason: "\(name) has an ID3v2.\(major) tag, which this reader does not know"
            )
        }
        let flags = bytes[5]
        guard let declared = syncsafe(Array(bytes[6..<10])) else {
            throw LatheError.invalidInput(reason: "\(name) has an ID3 header with an invalid size")
        }
        // A v2.4 footer adds ten bytes beyond the declared size.
        let footerBytes = (major == 4 && flags & 0x10 != 0) ? 10 : 0
        let total = 10 + declared + footerBytes
        guard total <= bytes.count else {
            throw LatheError.invalidInput(
                reason: "\(name) declares a \(total)-byte ID3 tag but is only \(bytes.count) bytes"
            )
        }

        var body = Array(bytes[10..<(10 + declared)])

        // Whole-tag unsynchronisation: every 0xFF was followed by an inserted
        // 0x00 so no byte pair could be mistaken for an MPEG frame sync. Undo it
        // before anything reads a length, or every length after the first
        // inserted byte is wrong.
        if flags & 0x80 != 0 {
            body = removeUnsynchronisation(body)
        }

        // An extended header, when present, sits at the front of the body and
        // declares its own length.
        var cursor = 0
        if flags & 0x40 != 0 {
            if major == 4, body.count >= 4, let size = syncsafe(Array(body[0..<4])) {
                cursor = size
            } else if body.count >= 4 {
                cursor = 4 + Int(bigEndian(Array(body[0..<4])))
            }
        }

        let idLength = major == 2 ? 3 : 4
        let headerLength = major == 2 ? 6 : 10
        var frames: [Frame] = []

        while cursor + headerLength <= body.count {
            let idBytes = Array(body[cursor..<(cursor + idLength)])
            // A run of zero bytes is the padding every tag is allowed to end
            // with, not a frame with an empty name.
            if idBytes.allSatisfy({ $0 == 0 }) { break }
            guard let id = String(bytes: idBytes, encoding: .isoLatin1) else { break }

            let sizeBytes = Array(body[(cursor + idLength)..<(cursor + headerLength - (major == 2 ? 0 : 2))])
            let size: Int
            if major == 4 {
                guard let value = syncsafe(sizeBytes) else { break }
                size = value
            } else {
                size = Int(bigEndian(sizeBytes))
            }
            guard size > 0, cursor + headerLength + size <= body.count else { break }

            let payload = Array(body[(cursor + headerLength)..<(cursor + headerLength + size)])
            frames.append(Frame(id: id, payload: decode(id: id, payload: payload)))
            cursor += headerLength + size
        }

        return ID3Tag(frames: frames, byteCount: total)
    }

    private static func decode(id: String, payload: [UInt8]) -> Payload {
        guard let first = payload.first else { return .raw(Data(payload)) }

        if id == "APIC" || id == "PIC" {
            return decodePicture(payload, threeCharacterMIME: id == "PIC") ?? .raw(Data(payload))
        }
        if id == "COMM" || id == "COM" {
            return decodeComment(payload) ?? .raw(Data(payload))
        }
        if id == "TXXX" || id == "TXX" {
            let rest = Array(payload.dropFirst())
            let parts = splitStrings(rest, encoding: first, limit: 2)
            guard parts.count >= 2 else { return .raw(Data(payload)) }
            return .userText(description: parts[0], value: parts[1])
        }
        if id.hasPrefix("T") {
            let rest = Array(payload.dropFirst())
            let values = splitStrings(rest, encoding: first, limit: nil)
                .filter { !$0.isEmpty }
            return .text(values)
        }
        return .raw(Data(payload))
    }

    private static func decodePicture(_ payload: [UInt8], threeCharacterMIME: Bool) -> Payload? {
        guard let encoding = payload.first else { return nil }
        var cursor = 1
        let mime: String
        if threeCharacterMIME {
            // v2.2 stores a bare three-character image format, not a MIME type.
            guard payload.count >= 4 else { return nil }
            let format = String(bytes: payload[1..<4], encoding: .isoLatin1) ?? "JPG"
            mime = format.uppercased() == "PNG" ? "image/png" : "image/jpeg"
            cursor = 4
        } else {
            guard let end = payload[cursor...].firstIndex(of: 0) else { return nil }
            mime = String(bytes: payload[cursor..<end], encoding: .isoLatin1) ?? "image/jpeg"
            cursor = end + 1
        }
        guard cursor < payload.count else { return nil }
        let pictureType = payload[cursor]
        cursor += 1
        guard cursor <= payload.count else { return nil }

        let remainder = Array(payload[cursor...])
        let (description, consumed) = readString(remainder, encoding: encoding)
        let data = Data(remainder.dropFirst(consumed))
        return .picture(mimeType: mime, pictureType: pictureType, description: description, data: data)
    }

    private static func decodeComment(_ payload: [UInt8]) -> Payload? {
        guard payload.count >= 4, let encoding = payload.first else { return nil }
        let language = String(bytes: payload[1..<4], encoding: .isoLatin1) ?? "und"
        let remainder = Array(payload[4...])
        let (description, consumed) = readString(remainder, encoding: encoding)
        let text = decodeString(Array(remainder.dropFirst(consumed)), encoding: encoding)
        return .comment(language: language, description: description, text: text)
    }

    // MARK: - Serialising

    /// The tag's bytes, as ID3v2.4 with no unsynchronisation and no padding.
    ///
    /// No unsynchronisation because v2.4 made it per-frame and optional, every
    /// reader in use handles its absence, and applying it means rewriting
    /// payload bytes — which is one more thing to get wrong on a path whose
    /// whole promise is that the audio comes across untouched.
    func serialise() -> Data {
        var body = Data()
        for frame in frames {
            guard let payload = Self.encode(frame) else { continue }
            // v2.2's three-character IDs are widened on write, since the output
            // is v2.4 and a three-character ID there is not a frame at all.
            let id = frame.id.count == 3 ? Self.widen(frame.id) : frame.id
            guard id.count == 4, let idBytes = id.data(using: .isoLatin1) else { continue }

            body.append(idBytes)
            body.append(contentsOf: Self.syncsafeBytes(payload.count))
            body.append(contentsOf: [0x00, 0x00])   // frame flags
            body.append(payload)
        }

        var out = Data("ID3".utf8)
        out.append(contentsOf: [0x04, 0x00])        // v2.4.0
        out.append(0x00)                            // no unsynchronisation, no extended header
        out.append(contentsOf: Self.syncsafeBytes(body.count))
        out.append(body)
        return out
    }

    private static func encode(_ frame: Frame) -> Data? {
        switch frame.payload {
        case .text(let values):
            guard !values.isEmpty else { return nil }
            var out = Data([0x03])                  // UTF-8
            // v2.4 separates multiple values with a null; earlier versions had
            // no way to express them at all, which is why a genre list arrives
            // from older files as one run-on string.
            out.append(Data(values.joined(separator: "\u{0}").utf8))
            return out

        case .userText(let description, let value):
            var out = Data([0x03])
            out.append(Data(description.utf8))
            out.append(0x00)
            out.append(Data(value.utf8))
            return out

        case .comment(let language, let description, let text):
            var out = Data([0x03])
            let code = language.count == 3 ? language : "und"
            out.append(Data(code.utf8))
            out.append(Data(description.utf8))
            out.append(0x00)
            out.append(Data(text.utf8))
            return out

        case .picture(let mimeType, let pictureType, let description, let data):
            guard !data.isEmpty else { return nil }
            var out = Data([0x03])
            out.append(Data((mimeType.data(using: .isoLatin1) ?? Data("image/jpeg".utf8))))
            out.append(0x00)
            out.append(pictureType)
            out.append(Data(description.utf8))
            out.append(0x00)
            out.append(data)
            return out

        case .raw(let data):
            return data.isEmpty ? nil : data
        }
    }

    /// The v2.4 spelling of a v2.2 frame ID, for the handful that survive a
    /// round trip through this module.
    private static func widen(_ id: String) -> String {
        [
            "TT2": "TIT2", "TT3": "TIT3", "TP1": "TPE1", "TP2": "TPE2",
            "TAL": "TALB", "TCO": "TCON", "TCR": "TCOP", "TCM": "TCOM",
            "TRK": "TRCK", "TPA": "TPOS", "TYE": "TDRC", "TCP": "TCMP",
            "COM": "COMM", "PIC": "APIC", "TXX": "TXXX",
        ][id] ?? id
    }

    // MARK: - Integers

    /// A syncsafe integer: four bytes of seven bits each, so no byte can look
    /// like the start of an MPEG frame sync.
    ///
    /// Returns `nil` when a high bit is set, which means the field is not
    /// syncsafe and the tag is not what its header claims.
    static func syncsafe(_ bytes: [UInt8]) -> Int? {
        guard bytes.count == 4 else { return nil }
        guard bytes.allSatisfy({ $0 & 0x80 == 0 }) else { return nil }
        return Int(bytes[0]) << 21 | Int(bytes[1]) << 14 | Int(bytes[2]) << 7 | Int(bytes[3])
    }

    static func syncsafeBytes(_ value: Int) -> [UInt8] {
        [
            UInt8((value >> 21) & 0x7F),
            UInt8((value >> 14) & 0x7F),
            UInt8((value >> 7) & 0x7F),
            UInt8(value & 0x7F),
        ]
    }

    private static func bigEndian(_ bytes: [UInt8]) -> UInt32 {
        bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    /// Removes the 0x00 inserted after every 0xFF by the unsynchronisation
    /// scheme.
    static func removeUnsynchronisation(_ bytes: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            out.append(bytes[index])
            if bytes[index] == 0xFF, index + 1 < bytes.count, bytes[index + 1] == 0x00 {
                index += 2
            } else {
                index += 1
            }
        }
        return out
    }

    // MARK: - Strings

    /// Reads one terminated string and reports how many bytes it consumed,
    /// terminator included.
    ///
    /// The terminator is two bytes wide for the UTF-16 encodings, which is the
    /// detail that makes a naive "find the first zero" search cut a UTF-16
    /// string in half at its first ASCII character.
    private static func readString(_ bytes: [UInt8], encoding: UInt8) -> (String, Int) {
        let wide = encoding == 1 || encoding == 2
        if wide {
            var index = 0
            while index + 1 < bytes.count {
                if bytes[index] == 0, bytes[index + 1] == 0 {
                    return (decodeString(Array(bytes[0..<index]), encoding: encoding), index + 2)
                }
                index += 2
            }
            return (decodeString(bytes, encoding: encoding), bytes.count)
        }
        guard let end = bytes.firstIndex(of: 0) else {
            return (decodeString(bytes, encoding: encoding), bytes.count)
        }
        return (decodeString(Array(bytes[0..<end]), encoding: encoding), end + 1)
    }

    private static func splitStrings(_ bytes: [UInt8], encoding: UInt8, limit: Int?) -> [String] {
        var out: [String] = []
        var rest = bytes
        while !rest.isEmpty {
            if let limit, out.count == limit - 1 {
                out.append(decodeString(rest, encoding: encoding))
                return out
            }
            let (value, consumed) = readString(rest, encoding: encoding)
            out.append(value)
            // consumed is always positive for a non-empty input, but the guard
            // is what makes that a fact rather than an assumption: a zero would
            // spin here forever on a malformed frame.
            guard consumed > 0 else { break }
            rest = Array(rest.dropFirst(consumed))
        }
        return out
    }

    private static func decodeString(_ bytes: [UInt8], encoding: UInt8) -> String {
        guard !bytes.isEmpty else { return "" }
        switch encoding {
        case 1:
            // UTF-16 with a byte-order mark, which String(bytes:encoding:)
            // honours when told the encoding is unicode.
            return String(bytes: bytes, encoding: .utf16) ?? ""
        case 2:
            return String(bytes: bytes, encoding: .utf16BigEndian) ?? ""
        case 3:
            return String(bytes: bytes, encoding: .utf8) ?? ""
        default:
            return String(bytes: bytes, encoding: .isoLatin1) ?? ""
        }
    }
}
