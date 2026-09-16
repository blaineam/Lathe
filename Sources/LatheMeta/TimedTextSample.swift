#if canImport(AVFoundation)
import AVFoundation
import CoreMedia
import Foundation

/// The bytes of a subtitle track: `tx3g` written and read, WebVTT-in-MP4 read.
///
/// ## Why `tx3g`, and not WebVTT, is what gets written
///
/// Both are creatable: `CMFormatDescriptionCreate` accepts
/// `kCMSubtitleFormatType_WebVTT` as readily as a `tx3g` description, and the
/// spike that preceded this file confirmed it. The choice is made on who plays
/// the result.
///
/// - **`tx3g` in an `sbtl` track is what Apple's own files contain.** It is the
///   format of subtitles in iTunes Store downloads and what HandBrake and
///   Subler write for Apple devices, which is the long record behind trusting
///   it in QuickTime Player, the TV app and AVKit on iOS. What this package's
///   tests prove is the part those players share: AVFoundation reads the
///   written track back as an option in the asset's legible selection group,
///   with its language — the data an AVKit subtitle menu is built from. No
///   player's menu has been driven from this repository's tests.
/// - **WebVTT in MP4 (`wvtt`, ISO/IEC 14496-30)** is what Apple's HLS stack
///   uses in fragmented segments. In a progressive file its support outside
///   Apple's streaming path is thinner — older Apple TV software and many
///   third-party players ignore it — and every WebVTT feature beyond plain text
///   (regions, positioning, classes) would be lost at the `tx3g`-equivalent
///   level anyway.
///
/// So `tx3g` is written, and both are read: a file produced by another tool can
/// carry `wvtt`, and extraction should not care.
///
/// ## The chapter description is not a subtitle description
///
/// ``ChapterTrack`` builds a `tx3g` description with a zero text box, top-left
/// justification and a 12-point font, which is right for a track nobody sees.
/// A subtitle track is seen: the box is the video frame, text is centred at the
/// bottom, and the font scales with the picture. Apple's players substitute the
/// user's caption style for most of this, but QuickTime's legacy renderer and
/// several third-party players take the description literally.
enum TimedTextSample {

    /// `tx3g` display flag: every sample in the track is forced — shown even
    /// when the viewer has subtitles off. Apple's players read this into
    /// `AVMediaCharacteristic.containsOnlyForcedSubtitles`.
    static let allSamplesForced: UInt32 = 0x8000_0000

    // MARK: - Description

    static func formatDescription(videoSize: CGSize, forced: Bool) -> CMFormatDescription? {
        let description = sampleDescription(videoSize: videoSize, forced: forced)
        var format: CMFormatDescription?
        let status = description.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return -1 }
            return CMTextFormatDescriptionCreateFromBigEndianTextDescriptionData(
                allocator: kCFAllocatorDefault,
                bigEndianTextDescriptionData: base,
                size: description.count,
                flavor: nil,
                // `.subtitle`, not `.text`: the media type is what puts the
                // track in the asset's legible selection group, which is what a
                // player's subtitle menu is built from. The same bytes under
                // `.text` make a track no menu lists.
                mediaType: kCMMediaType_Subtitle,
                formatDescriptionOut: &format
            )
        }
        return status == noErr ? format : nil
    }

    /// The font size a description declares: about a twentieth of the picture
    /// height, within what the one-byte field can hold.
    static func fontSize(forHeight height: CGFloat) -> UInt8 {
        UInt8(max(12, min(255, (height * 0.05).rounded())))
    }

    static func sampleDescription(videoSize: CGSize, forced: Bool) -> Data {
        var out = BigEndianWriter()
        let width = UInt16(clamping: Int(videoSize.width.rounded()))
        let height = UInt16(clamping: Int(videoSize.height.rounded()))
        let fontName = "Sans-Serif"
        let fontTableSize = UInt32(8 + 2 + 2 + 1 + fontName.utf8.count)
        let totalSize = UInt32(38 + 8 + 12 + 6) + fontTableSize

        out.u32(totalSize)
        out.fourCC("tx3g")
        out.zeros(6)                             // reserved
        out.u16(1)                               // data reference index

        out.u32(forced ? allSamplesForced : 0)   // display flags
        out.u8(1)                                // horizontal justification: centre
        out.u8(0xFF)                             // vertical justification: bottom (-1)
        out.zeros(4)                             // background: transparent

        // BoxRecord: top, left, bottom, right — the whole frame.
        out.u16(0); out.u16(0); out.u16(height); out.u16(width)

        // StyleRecord: the default style.
        out.u16(0); out.u16(0)                   // start and end character
        out.u16(1)                               // font ID
        out.u8(0)                                // face style: plain
        out.u8(fontSize(forHeight: CGFloat(height)))
        out.u8(255); out.u8(255); out.u8(255); out.u8(255)   // opaque white

        // FontTableBox — required; a description without one is rejected.
        out.u32(fontTableSize)
        out.fourCC("ftab")
        out.u16(1)
        out.u16(1)
        out.u8(UInt8(fontName.utf8.count))
        out.fourCC(fontName)
        return out.data
    }

    // MARK: - Samples

    /// One cue as a `tx3g` sample: a 16-bit byte count, the UTF-8 text, and —
    /// when the cue has any styling — a `styl` box.
    ///
    /// The text is cut at a scalar boundary if it would overflow the count.
    /// Cutting at a byte leaves a broken UTF-8 sequence, which some players
    /// render as nothing at all for the whole cue.
    static func payload(text: String, styles: [SubtitleStyleRun], fontSize: UInt8) -> Data {
        var scalars = Array(text.unicodeScalars)
        var byteCount = 0
        var kept = 0
        for scalar in scalars {
            let length = UTF8.width(scalar)
            if byteCount + length > Int(UInt16.max) { break }
            byteCount += length
            kept += 1
        }
        scalars.removeSubrange(kept...)
        let utf8 = Array(String(String.UnicodeScalarView(scalars)).utf8)

        var out = BigEndianWriter()
        out.u16(UInt16(utf8.count))
        out.bytes(utf8)

        let limit = min(scalars.count, Int(UInt16.max))
        let records = styles.compactMap { run -> (UInt16, UInt16, UInt8)? in
            let lower = min(run.range.lowerBound, limit)
            let upper = min(run.range.upperBound, limit)
            guard upper > lower, !run.style.isEmpty else { return nil }
            return (UInt16(lower), UInt16(upper), run.style.rawValue)
        }
        .sorted { $0.0 < $1.0 }
        if !records.isEmpty, records.count <= Int(UInt16.max) {
            out.u32(UInt32(8 + 2 + records.count * 12))
            out.fourCC("styl")
            out.u16(UInt16(records.count))
            for (start, end, face) in records {
                out.u16(start); out.u16(end)
                out.u16(1)                        // font ID
                out.u8(face)
                out.u8(fontSize)
                out.u8(255); out.u8(255); out.u8(255); out.u8(255)
            }
        }
        return out.data
    }

    /// The empty sample that fills a gap between cues.
    ///
    /// An MP4 track's samples are contiguous — the sample table stores
    /// durations, not start times — so "nothing on screen from 4s to 9s" has to
    /// be a sample that says nothing. Leaving the gap to the writer is how a cue
    /// ends up stretched until the next one begins.
    static let emptyPayload = Data([0, 0])

    static func sampleBuffer(
        payload: Data, start: CMTime, duration: CMTime, format: CMFormatDescription
    ) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: payload.count, flags: 0, blockBufferOut: &block
        ) == noErr, let block else { return nil }

        let copied = payload.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count
            )
        }
        guard copied == noErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: duration, presentationTimeStamp: start, decodeTimeStamp: .invalid
        )
        var size = payload.count
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer
        ) == noErr else { return nil }
        return buffer
    }

    // MARK: - Reading

    /// The text and styling in one `tx3g` sample, or `nil` for an empty one.
    ///
    /// Read defensively: the length is checked against the bytes present, and
    /// box sizes against what remains, so a truncated or hostile sample yields
    /// what it can rather than reading past its end.
    static func decodeTx3g(_ bytes: [UInt8]) -> (String, [SubtitleStyleRun])? {
        guard bytes.count >= 2 else { return nil }
        let length = Int(bytes[0]) << 8 | Int(bytes[1])
        guard length > 0 else { return nil }
        let end = min(bytes.count, 2 + length)
        let textBytes = bytes[2..<end]

        let text: String
        if textBytes.starts(with: [0xFE, 0xFF]) {
            // The format allows UTF-16 text, marked by a byte-order mark.
            text = String(data: Data(textBytes.dropFirst(2)), encoding: .utf16BigEndian) ?? ""
        } else {
            text = String(decoding: textBytes, as: UTF8.self)
        }
        guard !text.isEmpty else { return nil }
        let scalarCount = text.unicodeScalars.count

        var styles: [SubtitleStyleRun] = []
        var cursor = end
        while cursor + 8 <= bytes.count {
            let size = Int(readU32(bytes, cursor))
            let type = String(decoding: bytes[(cursor + 4)..<(cursor + 8)], as: UTF8.self)
            guard size >= 8, cursor + size <= bytes.count else { break }
            if type == "styl", size >= 10 {
                let count = Int(readU16(bytes, cursor + 8))
                var entry = cursor + 10
                for _ in 0..<count where entry + 12 <= cursor + size {
                    let start = min(Int(readU16(bytes, entry)), scalarCount)
                    let stop = min(Int(readU16(bytes, entry + 2)), scalarCount)
                    let style = SubtitleStyle(rawValue: bytes[entry + 6])
                        .intersection([.bold, .italic, .underline])
                    if stop > start, !style.isEmpty {
                        styles.append(SubtitleStyleRun(range: start..<stop, style: style))
                    }
                    entry += 12
                }
            }
            cursor += size
        }
        return (text, SubtitleMarkup.merge(styles))
    }

    /// The text in one WebVTT-in-MP4 sample: a run of `vttc` boxes, each with a
    /// `payl` holding cue text, or a `vtte` for "nothing now". Several `vttc`s
    /// in one sample are cues on screen together, and become one line each.
    static func decodeWebVTT(_ bytes: [UInt8]) -> (String, [SubtitleStyleRun])? {
        var parts: [(String, [SubtitleStyleRun])] = []
        var cursor = 0
        while cursor + 8 <= bytes.count {
            let size = Int(readU32(bytes, cursor))
            let type = String(decoding: bytes[(cursor + 4)..<(cursor + 8)], as: UTF8.self)
            guard size >= 8, cursor + size <= bytes.count else { break }
            if type == "vttc" {
                var inner = cursor + 8
                while inner + 8 <= cursor + size {
                    let innerSize = Int(readU32(bytes, inner))
                    let innerType = String(decoding: bytes[(inner + 4)..<(inner + 8)], as: UTF8.self)
                    guard innerSize >= 8, inner + innerSize <= cursor + size else { break }
                    if innerType == "payl" {
                        let raw = String(decoding: bytes[(inner + 8)..<(inner + innerSize)], as: UTF8.self)
                        let stripped = SubtitleMarkup.strip(raw)
                        if !stripped.0.isEmpty { parts.append(stripped) }
                    }
                    inner += innerSize
                }
            }
            cursor += size
        }
        guard !parts.isEmpty else { return nil }

        var text = ""
        var styles: [SubtitleStyleRun] = []
        for (part, partStyles) in parts {
            if !text.isEmpty { text += "\n" }
            let offset = text.unicodeScalars.count
            text += part
            styles += partStyles.map {
                SubtitleStyleRun(range: ($0.range.lowerBound + offset)..<($0.range.upperBound + offset), style: $0.style)
            }
        }
        return (text, styles)
    }

    private static func readU16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
    }

    private static func readU32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
    }
}

/// Big-endian field writer, so the layouts above read as the specification
/// does.
struct BigEndianWriter {
    var data = Data()
    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: UInt16) { data.append(UInt8(value >> 8)); data.append(UInt8(value & 0xFF)) }
    mutating func u32(_ value: UInt32) {
        u16(UInt16(value >> 16)); u16(UInt16(value & 0xFFFF))
    }
    mutating func fourCC(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
    mutating func bytes(_ bytes: [UInt8]) { data.append(contentsOf: bytes) }
    mutating func zeros(_ count: Int) { data.append(contentsOf: [UInt8](repeating: 0, count: count)) }
}
#endif
