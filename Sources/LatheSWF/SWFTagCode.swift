import Foundation

/// A SWF tag code, and what this reader believes it means.
///
/// ## Only the codes this reader is sure of are named
///
/// The SWF specification's tag table has gaps, and the gaps are not empty — they
/// hold codes Macromedia used and withdrew, codes the Flash authoring tool
/// emitted and never documented, and codes different third-party references
/// disagree about. Naming one of those on a guess would be worse than leaving it
/// unnamed, because the name would then appear in a report a caller trusts.
///
/// So: the table below is the set of codes taken from the published SWF File
/// Format Specification, and **an unlisted code is reported by number**, counted
/// and passed over, never interpreted. A reader that meets tag 68 says "tag 68",
/// which is the true statement.
///
/// The one place this is flagged rather than silent is ``SWFTagCode/doABC`` and
/// ``SWFTagCode/doABCDefine``: both carry ActionScript 3 bytecode, both are
/// real, and published references swap the two names. They are classified
/// identically — as script, which this module does not execute — so the
/// ambiguity cannot change any decision made here.
public struct SWFTagCode: RawRepresentable, Sendable, Hashable, CustomStringConvertible {

    public let rawValue: UInt16

    public init(rawValue: UInt16) { self.rawValue = rawValue }

    // MARK: - Structure

    /// Ends a tag stream — the file's, or a sprite's. Always zero-length.
    public static let end = SWFTagCode(rawValue: 0)
    public static let showFrame = SWFTagCode(rawValue: 1)
    public static let setBackgroundColor = SWFTagCode(rawValue: 9)
    public static let protect = SWFTagCode(rawValue: 24)
    public static let frameLabel = SWFTagCode(rawValue: 43)
    public static let exportAssets = SWFTagCode(rawValue: 56)
    public static let importAssets = SWFTagCode(rawValue: 57)
    public static let enableDebugger = SWFTagCode(rawValue: 58)
    public static let enableDebugger2 = SWFTagCode(rawValue: 64)
    public static let scriptLimits = SWFTagCode(rawValue: 65)
    public static let setTabIndex = SWFTagCode(rawValue: 66)
    public static let fileAttributes = SWFTagCode(rawValue: 69)
    public static let importAssets2 = SWFTagCode(rawValue: 71)
    public static let symbolClass = SWFTagCode(rawValue: 76)
    public static let metadata = SWFTagCode(rawValue: 77)
    public static let defineScalingGrid = SWFTagCode(rawValue: 78)
    public static let defineSceneAndFrameLabelData = SWFTagCode(rawValue: 86)

    /// A nested tag stream with its own timeline. Walked recursively, because a
    /// streaming soundtrack almost always lives inside one.
    public static let defineSprite = SWFTagCode(rawValue: 39)

    // MARK: - Display list

    public static let placeObject = SWFTagCode(rawValue: 4)
    public static let removeObject = SWFTagCode(rawValue: 5)
    public static let placeObject2 = SWFTagCode(rawValue: 26)
    public static let removeObject2 = SWFTagCode(rawValue: 28)
    public static let placeObject3 = SWFTagCode(rawValue: 70)

    // MARK: - Vector art, text and buttons

    public static let defineShape = SWFTagCode(rawValue: 2)
    public static let defineShape2 = SWFTagCode(rawValue: 22)
    public static let defineShape3 = SWFTagCode(rawValue: 32)
    public static let defineShape4 = SWFTagCode(rawValue: 83)
    public static let defineMorphShape = SWFTagCode(rawValue: 46)
    public static let defineMorphShape2 = SWFTagCode(rawValue: 84)
    public static let defineButton = SWFTagCode(rawValue: 7)
    public static let defineButtonSound = SWFTagCode(rawValue: 17)
    public static let defineButtonCxform = SWFTagCode(rawValue: 23)
    public static let defineButton2 = SWFTagCode(rawValue: 34)
    public static let defineText = SWFTagCode(rawValue: 11)
    public static let defineText2 = SWFTagCode(rawValue: 33)
    public static let defineEditText = SWFTagCode(rawValue: 37)
    public static let defineFont = SWFTagCode(rawValue: 10)
    public static let defineFontInfo = SWFTagCode(rawValue: 13)
    public static let defineFont2 = SWFTagCode(rawValue: 48)
    public static let defineFontInfo2 = SWFTagCode(rawValue: 62)
    public static let defineFontAlignZones = SWFTagCode(rawValue: 73)
    public static let csmTextSettings = SWFTagCode(rawValue: 74)
    public static let defineFont3 = SWFTagCode(rawValue: 75)
    public static let defineFontName = SWFTagCode(rawValue: 88)
    public static let defineFont4 = SWFTagCode(rawValue: 91)

    // MARK: - Script

    public static let doAction = SWFTagCode(rawValue: 12)
    public static let doInitAction = SWFTagCode(rawValue: 59)
    /// ActionScript 3 bytecode. See the note on name ambiguity above.
    public static let doABC = SWFTagCode(rawValue: 72)
    /// ActionScript 3 bytecode, the form carrying a name. See the note above.
    public static let doABCDefine = SWFTagCode(rawValue: 82)

    // MARK: - Media: the tags this module exists for

    /// JPEG pixel data *without* its Huffman and quantisation tables, which live
    /// in a separate ``jpegTables`` tag. Not a usable JPEG on its own.
    public static let defineBits = SWFTagCode(rawValue: 6)
    public static let jpegTables = SWFTagCode(rawValue: 8)
    /// A self-contained JPEG — or, from SWF 8, a PNG or a GIF89a.
    public static let defineBitsJPEG2 = SWFTagCode(rawValue: 21)
    /// As `DefineBitsJPEG2`, plus a zlib-compressed alpha channel.
    public static let defineBitsJPEG3 = SWFTagCode(rawValue: 35)
    /// As `DefineBitsJPEG3`, plus a deblocking parameter.
    public static let defineBitsJPEG4 = SWFTagCode(rawValue: 90)
    /// A zlib-compressed raster: palette, 15-bit, or 24-bit. Opaque.
    public static let defineBitsLossless = SWFTagCode(rawValue: 20)
    /// A zlib-compressed raster with alpha: palette+RGBA, or 32-bit ARGB.
    public static let defineBitsLossless2 = SWFTagCode(rawValue: 36)

    public static let defineSound = SWFTagCode(rawValue: 14)
    public static let startSound = SWFTagCode(rawValue: 15)
    public static let startSound2 = SWFTagCode(rawValue: 89)
    public static let soundStreamHead = SWFTagCode(rawValue: 18)
    public static let soundStreamHead2 = SWFTagCode(rawValue: 45)
    public static let soundStreamBlock = SWFTagCode(rawValue: 19)

    public static let defineVideoStream = SWFTagCode(rawValue: 60)
    public static let videoFrame = SWFTagCode(rawValue: 61)

    /// An arbitrary byte payload an ActionScript 3 movie embedded with
    /// `[Embed]`. Frequently a whole image or sound file.
    public static let defineBinaryData = SWFTagCode(rawValue: 87)

    // MARK: - Naming

    /// The specification's name for this code, or `nil` when the code is not one
    /// of the published ones.
    ///
    /// `nil` is a deliberate answer rather than a fallback string: a caller that
    /// wants to say "12 tags this reader does not recognise" needs to be able to
    /// tell a named tag from an unnamed one, and a `"tag 68"` placeholder would
    /// have hidden that.
    public var specificationName: String? {
        switch rawValue {
        case 0: "End"
        case 1: "ShowFrame"
        case 2: "DefineShape"
        case 4: "PlaceObject"
        case 5: "RemoveObject"
        case 6: "DefineBits"
        case 7: "DefineButton"
        case 8: "JPEGTables"
        case 9: "SetBackgroundColor"
        case 10: "DefineFont"
        case 11: "DefineText"
        case 12: "DoAction"
        case 13: "DefineFontInfo"
        case 14: "DefineSound"
        case 15: "StartSound"
        case 17: "DefineButtonSound"
        case 18: "SoundStreamHead"
        case 19: "SoundStreamBlock"
        case 20: "DefineBitsLossless"
        case 21: "DefineBitsJPEG2"
        case 22: "DefineShape2"
        case 23: "DefineButtonCxform"
        case 24: "Protect"
        case 26: "PlaceObject2"
        case 28: "RemoveObject2"
        case 32: "DefineShape3"
        case 33: "DefineText2"
        case 34: "DefineButton2"
        case 35: "DefineBitsJPEG3"
        case 36: "DefineBitsLossless2"
        case 37: "DefineEditText"
        case 39: "DefineSprite"
        case 43: "FrameLabel"
        case 45: "SoundStreamHead2"
        case 46: "DefineMorphShape"
        case 48: "DefineFont2"
        case 56: "ExportAssets"
        case 57: "ImportAssets"
        case 58: "EnableDebugger"
        case 59: "DoInitAction"
        case 60: "DefineVideoStream"
        case 61: "VideoFrame"
        case 62: "DefineFontInfo2"
        case 64: "EnableDebugger2"
        case 65: "ScriptLimits"
        case 66: "SetTabIndex"
        case 69: "FileAttributes"
        case 70: "PlaceObject3"
        case 71: "ImportAssets2"
        case 72: "DoABC"
        case 73: "DefineFontAlignZones"
        case 74: "CSMTextSettings"
        case 75: "DefineFont3"
        case 76: "SymbolClass"
        case 77: "Metadata"
        case 78: "DefineScalingGrid"
        case 82: "DoABCDefine"
        case 83: "DefineShape4"
        case 84: "DefineMorphShape2"
        case 86: "DefineSceneAndFrameLabelData"
        case 87: "DefineBinaryData"
        case 88: "DefineFontName"
        case 89: "StartSound2"
        case 90: "DefineBitsJPEG4"
        case 91: "DefineFont4"
        default: nil
        }
    }

    public var description: String { specificationName ?? "tag \(rawValue)" }

    // MARK: - Classification

    /// What kind of content a tag carries, which is the whole basis of the
    /// verdict in ``SWFInventory/verdict``.
    ///
    /// The distinction that earns its keep is ``vectorOrTimeline`` versus
    /// ``unrecognised``. A file made entirely of shapes and a display list is
    /// one this module can say something definite about — *there is nothing here
    /// but vector art, and rendering it is a different project*. A file made of
    /// codes nobody recognises is one this module knows nothing about, and
    /// saying "no media found" for both would collapse a confident answer and an
    /// ignorant one into the same sentence.
    public enum Kind: Sendable, Hashable {
        /// Carries bitmap, sound or video data this module may be able to recover.
        case media
        /// Vector art, text, fonts, buttons, the display list, the timeline.
        case vectorOrTimeline
        /// ActionScript, in either virtual machine. Never executed.
        case script
        /// File structure, attributes, export tables, debugging.
        case structural
        /// A code outside the published specification table.
        case unrecognized
    }

    public var kind: Kind {
        switch rawValue {
        case 6, 8, 14, 15, 18, 19, 20, 21, 35, 36, 45, 60, 61, 87, 89, 90:
            .media
        case 2, 4, 5, 7, 10, 11, 13, 17, 22, 23, 26, 28, 32, 33, 34, 37, 39, 46, 48, 62, 70, 73, 74,
             75, 83, 84, 88, 91:
            .vectorOrTimeline
        case 12, 59, 72, 82:
            .script
        case 0, 1, 9, 24, 43, 56, 57, 58, 64, 65, 66, 69, 71, 76, 77, 78, 86:
            .structural
        default:
            .unrecognized
        }
    }
}
