import Foundation

// MARK: - Pixel layouts

/// The pixel layout inside a `DefineBitsLossless` or `DefineBitsLossless2` tag.
public enum SWFLosslessFormat: String, Sendable, Equatable, Codable, CustomStringConvertible {
    /// Format 3 in `DefineBitsLossless`: one byte per pixel into an RGB palette.
    case palette8
    /// Format 4: `PIX15`, one unused bit and three five-bit channels.
    case rgb15
    /// Format 5 in `DefineBitsLossless`: `PIX24`, a padding **byte** then RGB.
    case rgb24
    /// Format 3 in `DefineBitsLossless2`: one byte per pixel into an RGBA palette.
    case paletteRGBA8
    /// Format 5 in `DefineBitsLossless2`: `PIX32`, premultiplied ARGB.
    case argb32

    /// The layout a format byte names, or `nil` if that value is not defined for
    /// the tag that carried it.
    ///
    /// The mapping is not one table but two — format `3` means a different
    /// palette entry size in each tag, and format `4` exists in only one of them
    /// — so the tag has to be part of the question.
    init?(formatByte: UInt8, hasAlpha: Bool) {
        switch (formatByte, hasAlpha) {
        case (3, false): self = .palette8
        case (4, false): self = .rgb15
        case (5, false): self = .rgb24
        case (3, true): self = .paletteRGBA8
        case (5, true): self = .argb32
        default: return nil
        }
    }

    var isPaletted: Bool { self == .palette8 || self == .paletteRGBA8 }

    /// Bytes per palette entry, or `0` when there is no palette.
    var paletteEntryByteCount: Int {
        switch self {
        case .palette8: 3
        case .paletteRGBA8: 4
        default: 0
        }
    }

    /// Bytes each pixel occupies in the stored raster — **not** how many
    /// channels it has. `rgb24` is the trap: three channels, four bytes.
    var bytesPerPixel: Int {
        switch self {
        case .palette8, .paletteRGBA8: 1
        case .rgb15: 2
        case .rgb24, .argb32: 4
        }
    }

    var hasAlpha: Bool { self == .paletteRGBA8 || self == .argb32 }

    var imageSource: SWFImageSource {
        switch self {
        case .palette8: .losslessPalette
        case .rgb15: .lossless15Bit
        case .rgb24: .lossless24Bit
        case .paletteRGBA8: .losslessPaletteWithAlpha
        case .argb32: .lossless32Bit
        }
    }

    public var description: String {
        switch self {
        case .palette8: "8-bit palette"
        case .rgb15: "15-bit RGB"
        case .rgb24: "24-bit RGB"
        case .paletteRGBA8: "8-bit palette with alpha"
        case .argb32: "32-bit ARGB"
        }
    }
}

/// Where an extracted image came from, and therefore what happened to it.
public enum SWFImageSource: String, Sendable, Equatable, Codable, CustomStringConvertible {
    /// A complete JPEG, copied out byte for byte.
    case jpeg
    /// A `DefineBits` payload reunited with its shared `JPEGTables`.
    case jpegSharingTables
    /// A JPEG and its separate alpha channel, composed into a PNG.
    case jpegWithAlpha
    /// A PNG stored inside a tag whose name still says JPEG.
    case png
    /// A GIF, likewise.
    case gif
    case losslessPalette
    case lossless15Bit
    case lossless24Bit
    case losslessPaletteWithAlpha
    case lossless32Bit

    /// Whether the bytes written are the bytes the SWF held.
    ///
    /// Worth stating because it is the difference between a faithful copy and a
    /// re-encode: the three JPEG-family cases that are not `jpegWithAlpha` come
    /// out untouched, and everything else was decoded here and written as PNG.
    public var isVerbatimCopy: Bool {
        switch self {
        case .jpeg, .png, .gif: true
        default: false
        }
    }

    public var description: String {
        switch self {
        case .jpeg: "JPEG"
        case .jpegSharingTables: "JPEG with shared tables"
        case .jpegWithAlpha: "JPEG with alpha, composed to PNG"
        case .png: "PNG"
        case .gif: "GIF"
        case .losslessPalette: "lossless 8-bit palette"
        case .lossless15Bit: "lossless 15-bit"
        case .lossless24Bit: "lossless 24-bit"
        case .losslessPaletteWithAlpha: "lossless 8-bit palette with alpha"
        case .lossless32Bit: "lossless 32-bit"
        }
    }
}

// MARK: - Sound

/// The codec a SWF sound tag declares, by the four-bit `SoundFormat` field.
public enum SWFSoundFormat: Sendable, Equatable, Codable, CustomStringConvertible {
    /// `0` — uncompressed PCM in the *authoring machine's* byte order, which is
    /// why format `3` exists.
    case uncompressedNativeEndian
    /// `1` — Adobe's own ADPCM. Related to IMA ADPCM, and not compatible with it.
    case adpcm
    /// `2` — MP3.
    case mp3
    /// `3` — uncompressed PCM, explicitly little-endian.
    case uncompressedLittleEndian
    /// `4`, `5`, `6` — Nellymoser, a speech codec with no public specification.
    case nellymoser16kHz
    case nellymoser8kHz
    case nellymoser
    /// `11` — Speex.
    case speex
    /// A value the specification does not assign, kept as found.
    case unassigned(UInt8)

    init(code: UInt8) {
        switch code {
        case 0: self = .uncompressedNativeEndian
        case 1: self = .adpcm
        case 2: self = .mp3
        case 3: self = .uncompressedLittleEndian
        case 4: self = .nellymoser16kHz
        case 5: self = .nellymoser8kHz
        case 6: self = .nellymoser
        case 11: self = .speex
        default: self = .unassigned(code)
        }
    }

    /// Whether the samples are plain PCM this module can wrap in a WAV header.
    public var isLinearPCM: Bool {
        self == .uncompressedNativeEndian || self == .uncompressedLittleEndian
    }

    public var description: String {
        switch self {
        case .uncompressedNativeEndian: "uncompressed PCM (native-endian)"
        case .adpcm: "Adobe ADPCM"
        case .mp3: "MP3"
        case .uncompressedLittleEndian: "uncompressed PCM (little-endian)"
        case .nellymoser16kHz: "Nellymoser 16 kHz"
        case .nellymoser8kHz: "Nellymoser 8 kHz"
        case .nellymoser: "Nellymoser"
        case .speex: "Speex"
        case let .unassigned(code): "unassigned sound format \(code)"
        }
    }
}

/// What a sound tag said about itself.
public struct SWFSoundInfo: Sendable, Equatable, Codable {
    public let format: SWFSoundFormat
    /// 5512, 11025, 22050 or 44100 — the only four rates the format can express.
    public let sampleRateHz: Int
    public let bitsPerSample: Int
    public let channelCount: Int
    /// The declared sample count, per channel. `nil` for a streaming soundtrack,
    /// which has no single count.
    public let declaredSampleCount: UInt32?
    /// Whether this is a timeline soundtrack assembled from `SoundStreamBlock`
    /// tags rather than a single `DefineSound`.
    public let isStreamingSoundtrack: Bool
}

// MARK: - Assets

/// Something recovered from a SWF.
public struct SWFAsset: Sendable, Equatable, Codable {

    /// What the asset turned out to be.
    public enum Content: Sendable, Equatable, Codable {
        case image(width: Int?, height: Int?, source: SWFImageSource, hasAlpha: Bool)
        case sound(SWFSoundInfo)
        /// An `[Embed]`-ed payload from `DefineBinaryData`, named by what its
        /// first bytes actually are.
        case binaryData(sniffedAs: String)
    }

    /// The name of the file written, relative to the extraction directory.
    ///
    /// `nil` when the report came from ``SWFCapture/inspect(_:)``, which finds
    /// everything and writes nothing.
    ///
    /// Always generated here — `character-00042.png` — and never taken from the
    /// file's own bytes. A SWF has no filenames in it to be tempted by, and
    /// keeping the generation on this side means no payload can reach a path.
    public let fileName: String?

    /// The SWF character this came from, or `nil` for a streaming soundtrack,
    /// which belongs to a timeline rather than to a character.
    public let characterID: UInt16?

    /// The tag it was found in, by name where there is one.
    public let sourceTag: String
    public let sourceTagCode: UInt16

    /// How many bytes were written, or would be.
    public let byteCount: Int

    public let content: Content

    /// The enclosing sprite IDs, outermost first. Empty for the main timeline.
    public let spritePath: [UInt16]
}

// MARK: - What was left behind

/// Something found and not recovered, and why.
///
/// The existence of this type is the point of the module's honesty: a report
/// listing four images is useless if the file also contained ninety seconds of
/// Nellymoser audio and a VP6 video that were silently dropped.
public struct SWFOmission: Sendable, Equatable, Codable {

    public enum Reason: String, Sendable, Equatable, Codable {
        /// A recognised media tag whose codec cannot be decoded without a
        /// decoder this package does not have and will not add.
        case codecNotDecodable
        /// A recognised media tag whose contents were malformed. The rest of the
        /// file was still read.
        case malformed
        /// Vector artwork, text, fonts, morph shapes — content that only exists
        /// once something renders it.
        case vectorArtwork
        /// ActionScript bytecode, in either virtual machine. Never executed.
        case script
        /// A tag code outside the published specification.
        case unrecognisedTag
    }

    public let what: String
    public let reason: Reason
    /// How many tags this line accounts for.
    public let count: Int
    /// The total size of those tags' bodies, which is how a caller judges
    /// whether what was left behind was the bulk of the file.
    public let byteCount: Int
    public let detail: String?
}

/// One line of the tag census: every tag code seen, with counts.
public struct SWFTagCensus: Sendable, Equatable, Codable {
    public let code: UInt16
    /// The specification's name, or `nil` for a code this reader does not know.
    public let name: String?
    public let count: Int
    public let byteCount: Int
}

// MARK: - The verdict

/// The one-line answer to "what is this file, and did I get anything out of it".
///
/// This exists because the alternative — a caller inferring the answer from an
/// empty asset list — collapses three completely different situations into one.
/// "This SWF had no bitmaps", "this SWF is a cartoon drawn in vectors that
/// nothing here can render", and "this file is full of tags nobody recognises"
/// lead to three different next steps, and only the first is a dead end.
public enum SWFVerdict: String, Sendable, Equatable, Codable, CustomStringConvertible {
    /// Media was found and written out.
    case mediaRecovered
    /// Media tags were present, and none of them could be turned into a file —
    /// a movie whose only audio is ADPCM, or whose only video is VP6.
    case mediaFoundButUnrecoverable
    /// No media tags at all. The file is vector artwork, a timeline, and/or
    /// script — the case this module is honest about rather than attempting.
    case vectorOrScriptOnly
    /// Neither media nor recognisable content: mostly or entirely tag codes
    /// outside the specification.
    case unrecognisedContent
    /// A structurally valid SWF with essentially nothing in it.
    case empty

    public var description: String {
        switch self {
        case .mediaRecovered: "media recovered"
        case .mediaFoundButUnrecoverable: "media found, none recoverable"
        case .vectorOrScriptOnly: "vector art and script only"
        case .unrecognisedContent: "unrecognised content"
        case .empty: "empty"
        }
    }
}

// MARK: - The report

/// Everything a capture found, everything it skipped, and what it makes of the
/// file as a whole.
///
/// `Codable`, and written to `manifest.json` beside the extracted files, so the
/// output directory is self-describing: six months later the folder still says
/// which tag each file came from, whether it is a verbatim copy or a re-encode,
/// and what was in the SWF that is not in the folder.
public struct SWFCaptureReport: Sendable, Equatable, Codable {

    /// The file this report is about, by name only. Never a full path: Lathe
    /// treats paths as private, and a manifest that travels with its folder
    /// should not carry the directory layout of the machine that made it.
    public let source: String

    public let header: SWFHeader

    /// What was recovered, in the order found.
    public let assets: [SWFAsset]

    /// What was not, and why.
    public let omissions: [SWFOmission]

    /// Every tag code seen, most frequent first.
    public let tagCensus: [SWFTagCensus]

    public let verdict: SWFVerdict

    public var imageCount: Int {
        assets.filter { if case .image = $0.content { return true } else { return false } }.count
    }

    public var soundCount: Int {
        assets.filter { if case .sound = $0.content { return true } else { return false } }.count
    }

    public var binaryDataCount: Int {
        assets.filter { if case .binaryData = $0.content { return true } else { return false } }
            .count
    }

    /// A sentence a caller can show a person without interpreting anything.
    public var summary: String {
        var parts: [String] = []
        if imageCount > 0 { parts.append("\(imageCount) image\(imageCount == 1 ? "" : "s")") }
        if soundCount > 0 { parts.append("\(soundCount) sound\(soundCount == 1 ? "" : "s")") }
        if binaryDataCount > 0 { parts.append("\(binaryDataCount) embedded file(s)") }

        let found = parts.isEmpty ? "nothing" : parts.joined(separator: ", ")
        let stage = "\(header.stageWidthInPixels)×\(header.stageHeightInPixels)"
        let opening =
            "\(source): SWF \(header.version), \(header.compression), \(stage), "
            + "\(header.frameCount) frames at \(String(format: "%.2f", header.frameRate)) fps — "
            + "recovered \(found)."

        switch verdict {
        case .mediaRecovered:
            guard !omissions.isEmpty else { return opening }
            let left = omissions.reduce(0) { $0 + $1.count }
            return opening + " \(left) tag(s) were left behind; see omissions."
        case .mediaFoundButUnrecoverable:
            return opening
                + " It does contain media, in formats nothing here can decode; see omissions."
        case .vectorOrScriptOnly:
            return opening
                + " There are no bitmap, sound or video tags in this file at all: it is vector "
                + "artwork and/or ActionScript, which needs a Flash renderer, not an extractor."
        case .unrecognisedContent:
            return opening + " Most of its tags are outside the published specification."
        case .empty:
            return opening + " The file is structurally valid and contains almost nothing."
        }
    }
}
