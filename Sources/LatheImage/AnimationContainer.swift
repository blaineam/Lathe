import Foundation
import ImageIO

/// The four containers that can hold a *timed* sequence of frames, and where
/// each one keeps its timing, its loop count and its canvas.
///
/// There is no general "delay" key in ImageIO: every animated format keeps its
/// own, inside its own sub-dictionary. That table used to exist twice — once for
/// reading, in ``ImageInspector``, and it would have grown a second copy the
/// moment anything wrote one of these formats. Two copies of a key table is how
/// a reader and a writer end up disagreeing about where a delay lives, which
/// presents as an animation that round-trips through this package and comes out
/// a still.
///
/// All four dictionaries are older than this package's deployment floor, so no
/// availability check is needed or wanted — see ``EncodeSupport`` on why nothing
/// in this module branches on an OS version.
///
/// > Note: the keys are **computed rather than stored**. `CFString` is not
/// > `Sendable`, so under Swift 6 a stored static of one is shared mutable state
/// > whether or not anybody mutates it; rebuilding a `CFString` reference per
/// > call is cheaper than an `nonisolated(unsafe)` escape hatch is honest.
enum AnimationContainer: CaseIterable {
    case gif
    /// APNG. Its keys live in the **PNG** dictionary — there is no APNG
    /// dictionary — which is the single most common way this table is got wrong.
    case apng
    case webp
    /// HEIF image sequence, the animated sibling of HEIC.
    case heics

    /// The container that holds `format`'s frames, or `nil` for a format that
    /// has no notion of a timed sequence.
    ///
    /// Note that ``ImageFormat/avif`` is missing even though
    /// ``ImageFormat/isAnimatable`` admits it: AVIF sequences exist in the
    /// format, and ImageIO exposes no per-frame timing dictionary for one, so
    /// there is nowhere to put a delay. Claiming a container here that cannot
    /// carry timing would produce a file that is a burst rather than an
    /// animation — the ``ImageFrameInfo/isMultiPageStill`` case — while
    /// reporting success.
    static func holding(_ format: ImageFormat) -> AnimationContainer? {
        switch format {
        case .gif: .gif
        case .png: .apng
        case .webp: .webp
        case .heics: .heics
        case .heic, .avif, .jpeg, .tiff, .jpegXL, .jp2, .pdf: nil
        }
    }

    /// The sub-dictionary every other key here lives inside.
    var dictionaryKey: CFString {
        switch self {
        case .gif: kCGImagePropertyGIFDictionary
        case .apng: kCGImagePropertyPNGDictionary
        case .webp: kCGImagePropertyWebPDictionary
        case .heics: kCGImagePropertyHEICSDictionary
        }
    }

    /// The per-frame delay as the file stores it, before ImageIO's own floor.
    /// Preferred when reading; see ``ImageInspector/zeroDelayReplacement``.
    var unclampedDelayKey: CFString {
        switch self {
        case .gif: kCGImagePropertyGIFUnclampedDelayTime
        case .apng: kCGImagePropertyAPNGUnclampedDelayTime
        case .webp: kCGImagePropertyWebPUnclampedDelayTime
        case .heics: kCGImagePropertyHEICSUnclampedDelayTime
        }
    }

    /// The per-frame delay after ImageIO's per-format floor. **This is the one
    /// to write**: the unclamped variant is derived on read from what the file
    /// actually stores, so setting it on a destination changes nothing.
    var delayKey: CFString {
        switch self {
        case .gif: kCGImagePropertyGIFDelayTime
        case .apng: kCGImagePropertyAPNGDelayTime
        case .webp: kCGImagePropertyWebPDelayTime
        case .heics: kCGImagePropertyHEICSDelayTime
        }
    }

    /// File-level rather than frame-level. **`0` means forever** in all four.
    var loopKey: CFString {
        switch self {
        case .gif: kCGImagePropertyGIFLoopCount
        case .apng: kCGImagePropertyAPNGLoopCount
        case .webp: kCGImagePropertyWebPLoopCount
        case .heics: kCGImagePropertyHEICSLoopCount
        }
    }

    var canvasWidthKey: CFString {
        switch self {
        case .gif: kCGImagePropertyGIFCanvasPixelWidth
        case .apng: kCGImagePropertyAPNGCanvasPixelWidth
        case .webp: kCGImagePropertyWebPCanvasPixelWidth
        case .heics: kCGImagePropertyHEICSCanvasPixelWidth
        }
    }

    var canvasHeightKey: CFString {
        switch self {
        case .gif: kCGImagePropertyGIFCanvasPixelHeight
        case .apng: kCGImagePropertyAPNGCanvasPixelHeight
        case .webp: kCGImagePropertyWebPCanvasPixelHeight
        case .heics: kCGImagePropertyHEICSCanvasPixelHeight
        }
    }
}
