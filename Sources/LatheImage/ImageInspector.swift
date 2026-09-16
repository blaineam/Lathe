import CoreGraphics
import Foundation
import ImageIO
import LatheCore

/// What a still-image file turns out to be: how many frames, whether they play,
/// and for how long.
///
/// ``ImageInspector/inspect(_:)`` builds one. Nothing here is decoded — see that
/// method for why that matters.
public struct ImageFrameInfo: Sendable, Equatable {

    /// The format, where the file's type identifier names one Lathe knows.
    ///
    /// `nil` for an image ImageIO can read and this package has no name for,
    /// which is not an error: the frame arithmetic is format-independent.
    public let format: ImageFormat?

    /// Every frame in the file, animated or not. Always `>= 1`.
    public let frameCount: Int

    /// Whether the frames are **timed** — i.e. whether this plays.
    ///
    /// See ``ImageInspector/inspect(_:)`` for why this is not `frameCount > 1`.
    public let isAnimated: Bool

    /// One pass, in seconds — the sum of the per-frame delays, after the
    /// zero-delay clamp. `nil` for a still.
    ///
    /// **One pass, not total playtime.** A caller who wants "how long will this
    /// run on screen" multiplies by ``loopCount``; a caller who wants "how long
    /// is this clip" — which is the far more common question, and the one that
    /// matches what `MediaProbe` means by a duration for video and audio — wants
    /// this. ``totalPlaybackDuration`` does the multiplication.
    public let duration: TimeInterval?

    /// The per-frame delays, in order, after the clamp. Empty for a still.
    ///
    /// Exposed because the delays are genuinely per-frame: a caller resampling an
    /// animation to a fixed frame rate needs each one, and deriving them from
    /// ``duration`` by dividing is the mistake this property exists to prevent.
    public let frameDelays: [TimeInterval]

    /// How many times the container says to repeat, or `nil` if it does not say.
    ///
    /// **`0` means forever** — that is the GIF/APNG/WebP convention, carried
    /// through unchanged rather than translated into a sentinel of Lathe's own.
    /// ``repeatsForever`` reads it without having to remember.
    public let loopCount: Int?

    /// The canvas, in pixels — the size a player draws into.
    ///
    /// Not necessarily the size of frame 0. An optimised animation stores each
    /// frame as the sub-rectangle that changed, so frame 0 of a 480x270 GIF can
    /// legitimately be 32x11.
    public let pixelSize: PixelSize

    public init(
        format: ImageFormat?,
        frameCount: Int,
        isAnimated: Bool,
        duration: TimeInterval?,
        frameDelays: [TimeInterval],
        loopCount: Int?,
        pixelSize: PixelSize
    ) {
        self.format = format
        self.frameCount = frameCount
        self.isAnimated = isAnimated
        self.duration = duration
        self.frameDelays = frameDelays
        self.loopCount = loopCount
        self.pixelSize = pixelSize
    }

    /// `true` when the container asks to loop indefinitely.
    public var repeatsForever: Bool { loopCount == 0 }

    /// Total time on screen, or `nil` when that is unbounded or unknown.
    ///
    /// `nil` for a still, and `nil` for an animation that loops forever —
    /// because the honest answer there is "it does not end", and returning one
    /// pass would be a plausible number that is wrong.
    public var totalPlaybackDuration: TimeInterval? {
        guard let duration, let loopCount, loopCount > 0 else { return nil }
        return duration * Double(loopCount)
    }

    /// Multi-frame but not timed: a multi-page TIFF, a HEIC burst or image
    /// sequence, a multi-page fax.
    ///
    /// Worth naming because it is the case a caller most often wants to treat
    /// differently from both a still and an animation — "pages", not "frames".
    ///
    /// > Note: **PDF is not among them**, for a duller reason than it looks.
    /// > ImageIO *writes* PDF and does not list it as a source type, so a PDF
    /// > never reaches this type at all — `ImageInspector` refuses it as not an
    /// > image. Page counting for PDFs is PDFKit's job, and `LatheDoc`'s.
    public var isMultiPageStill: Bool { frameCount > 1 && !isAnimated }
}

/// Reads what a file *is* without decoding what it contains.
///
/// ```swift
/// let info = try ImageInspector().inspect(url)
/// if info.isAnimated { print("\(info.frameCount) frames, \(info.duration ?? 0)s") }
/// ```
public struct ImageInspector: Sendable {

    public init() {}

    // MARK: - Timing

    /// The delay floor, and the value a zero is replaced with.
    ///
    /// **A zero delay is not zero time.** GIFs in the wild routinely store a
    /// delay of 0 or 1 hundredths, meaning "as fast as you can", and summing
    /// those literally reports 0.0 seconds for a file that visibly plays for two.
    /// Every renderer clamps instead; this one uses the classic browser rule —
    /// **anything under 11 ms becomes 100 ms** — which is also what ImageIO's own
    /// `kCGImagePropertyGIFDelayTime` does.
    ///
    /// The clamp is applied here rather than taken from ImageIO because ImageIO's
    /// clamp is *not uniform across formats*: its GIF and WebP floors are 100 ms
    /// and its APNG floor is 50 ms. Reading the pre-clamp
    /// (`…UnclampedDelayTime`) value and applying one rule means the same
    /// animation, transcoded between those formats, does not change duration.
    public static let zeroDelayReplacement: TimeInterval = 0.1

    /// Delays at or below this are treated as zero. One centisecond is the
    /// finest a GIF can express, so this is "the smallest nonzero the format
    /// has", with a hair of floating-point slack.
    public static let zeroDelayThreshold: TimeInterval = 0.011

    /// Where per-frame timing lives, per container.
    ///
    /// Animated WebP is read here like the others — by ImageIO, through
    /// `kCGImagePropertyWebPDictionary`, whether libwebp's `WebPAnimEncoder` or
    /// something else wrote the file; the WebP-specific part of this package is
    /// on the write side only.
    ///
    /// One table, shared with the write side — see ``AnimationContainer`` for
    /// the whole argument, including why the keys are computed rather than
    /// stored. The unclamped key is preferred here and the clamped one is the
    /// fallback, so a format whose unclamped variant is missing still reports
    /// timing rather than reading as a still.
    private static var timingKeys: [(container: CFString, unclamped: CFString, clamped: CFString)] {
        AnimationContainer.allCases.map { ($0.dictionaryKey, $0.unclampedDelayKey, $0.delayKey) }
    }

    /// Where the loop count lives, per container. Same table, file level rather
    /// than frame level.
    private static var loopKeys: [(container: CFString, loop: CFString)] {
        AnimationContainer.allCases.map { ($0.dictionaryKey, $0.loopKey) }
    }

    /// Where the canvas size lives, per container.
    private static var canvasKeys: [(container: CFString, width: CFString, height: CFString)] {
        AnimationContainer.allCases.map { ($0.dictionaryKey, $0.canvasWidthKey, $0.canvasHeightKey) }
    }

    // MARK: - Inspecting

    /// Reads a file's frame structure.
    ///
    /// ## "Is this animated?" is not "does it have more than one frame"
    ///
    /// `CGImageSourceGetCount(source) > 1` is the obvious implementation and it
    /// is wrong in both directions:
    ///
    /// - **A multi-page TIFF is not animated.** Nor is a scanned multi-page fax,
    ///   nor a HEIC burst or image sequence — all of them report a count above
    ///   one, and none of them plays. Treating a 300-page scanned TIFF as an
    ///   animation is how a "recompress animations differently" branch ends up
    ///   producing a 300-frame GIF of somebody's tax return.
    /// - **A one-frame GIF is not animated.** GIF is an animated container and
    ///   plenty of GIFs in the wild hold a single image; anything keying off the
    ///   *format* rather than the *content* gets this backwards.
    ///
    /// So the test is **more than one frame _and_ the frames carry timing**.
    /// Timing means a per-frame delay key — each animated format has its own, and
    /// a container with none is a container with no notion of when to show the
    /// next frame, which is exactly what "not animated" means. Note that the
    /// delay must merely be *present*, not nonzero: a zero delay is a real GIF
    /// idiom meaning "as fast as possible", and reading it as absent would call a
    /// fast animation a still.
    ///
    /// ## Nothing is decoded
    ///
    /// This is a header read. `CGImageSourceCreateWithURL` parses structure,
    /// `CGImageSourceCopyPropertiesAtIndex` reads a frame's metadata, and neither
    /// materialises a bitmap — `kCGImageSourceShouldCache: false` is passed to
    /// both so ImageIO does not speculatively hold one either. Asking "is this
    /// animated?" about a 200 MB file should cost the price of reading its
    /// headers, and on iOS the difference between that and a decode is the
    /// difference between a pass that runs and one that is jetsammed.
    ///
    /// - Throws: ``LatheError/readFailed(path:reason:)`` if the file cannot be
    ///   opened, or ``LatheError/invalidInput(reason:)`` if it is not an image.
    ///   **"Not an image" and "not animated" are different answers** and this
    ///   never conflates them by returning `false` for a text file.
    public func inspect(_ url: URL) throws -> ImageFrameInfo {
        try ImageEncoder.requireReadableFile(at: url)

        guard let source = CGImageSourceCreateWithURL(
            url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary
        ) else {
            throw LatheError.invalidInput(
                reason: "\(url.lastPathComponent) is not an image ImageIO can read"
            )
        }

        let frameCount = CGImageSourceGetCount(source)
        // A source object is handed back for almost anything; the count and the
        // type are what actually say whether a decoder recognised the bytes.
        // `statusUnknownType` is the one a text file lands on.
        let typeIdentifier = CGImageSourceGetType(source) as String?
        guard frameCount > 0, typeIdentifier != nil else {
            throw LatheError.invalidInput(
                reason: "\(url.lastPathComponent) is not an image ImageIO can read "
                    + "(\(Self.describe(CGImageSourceGetStatus(source))))"
            )
        }

        let containerProperties = Self.containerProperties(of: source)
        let format = typeIdentifier.flatMap(ImageFormat.named(byTypeIdentifier:))

        var rawDelays: [TimeInterval] = []
        var carriesTiming = false
        for index in 0..<frameCount {
            let frame = Self.frameProperties(of: source, at: index)
            if let delay = Self.delay(in: frame) {
                carriesTiming = true
                rawDelays.append(delay)
            } else {
                // A frame with no delay inside an animation that has them — the
                // renderer would show it for the container's default. Recorded as
                // zero so the clamp below gives it the same treatment.
                rawDelays.append(0)
            }
        }

        let isAnimated = frameCount > 1 && carriesTiming
        let frameDelays = isAnimated ? rawDelays.map(Self.clamping) : []

        return ImageFrameInfo(
            format: format,
            frameCount: frameCount,
            isAnimated: isAnimated,
            duration: isAnimated ? frameDelays.reduce(0, +) : nil,
            frameDelays: frameDelays,
            loopCount: Self.loopCount(in: containerProperties),
            pixelSize: try Self.canvasSize(
                of: source, containerProperties: containerProperties, name: url.lastPathComponent
            )
        )
    }

    // MARK: - Reading properties

    private static func containerProperties(of source: CGImageSource) -> [CFString: Any] {
        guard let raw = CGImageSourceCopyProperties(
            source, [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return [:] }
        return (raw as NSDictionary) as? [CFString: Any] ?? [:]
    }

    private static func frameProperties(of source: CGImageSource, at index: Int) -> [CFString: Any] {
        guard let raw = CGImageSourceCopyPropertiesAtIndex(
            source, index, [kCGImageSourceShouldCache: false] as CFDictionary
        ) else { return [:] }
        return (raw as NSDictionary) as? [CFString: Any] ?? [:]
    }

    /// The frame's delay in seconds, or `nil` when the frame carries no timing at
    /// all — which is the distinction `isAnimated` turns on, so a present-but-zero
    /// delay must come back as `0`, never as `nil`.
    private static func delay(in frame: [CFString: Any]) -> TimeInterval? {
        for keys in timingKeys {
            guard let container = frame[keys.container] as? [CFString: Any] else { continue }
            if let value = (container[keys.unclamped] as? NSNumber)?.doubleValue {
                return value
            }
            if let value = (container[keys.clamped] as? NSNumber)?.doubleValue {
                return value
            }
        }
        return nil
    }

    private static func clamping(_ delay: TimeInterval) -> TimeInterval {
        delay <= zeroDelayThreshold ? zeroDelayReplacement : delay
    }

    private static func loopCount(in container: [CFString: Any]) -> Int? {
        for keys in loopKeys {
            guard let dictionary = container[keys.container] as? [CFString: Any] else { continue }
            if let value = (dictionary[keys.loop] as? NSNumber)?.intValue { return value }
        }
        return nil
    }

    /// The canvas, preferring the container's own canvas keys over frame 0's
    /// size. See ``ImageFrameInfo/pixelSize``.
    private static func canvasSize(
        of source: CGImageSource,
        containerProperties: [CFString: Any],
        name: String
    ) throws -> PixelSize {
        for keys in canvasKeys {
            guard let dictionary = containerProperties[keys.container] as? [CFString: Any],
                  let width = (dictionary[keys.width] as? NSNumber)?.intValue,
                  let height = (dictionary[keys.height] as? NSNumber)?.intValue
            else { continue }
            let size = PixelSize(width: width, height: height)
            if !size.isEmpty { return size }
        }

        let frame = frameProperties(of: source, at: 0)
        let size = PixelSize(
            width: (frame[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0,
            height: (frame[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        )
        guard !size.isEmpty else {
            throw LatheError.invalidInput(reason: "\(name) reports no pixel dimensions")
        }
        return size
    }

    private static func describe(_ status: CGImageSourceStatus) -> String {
        switch status {
        case .statusUnexpectedEOF: "truncated"
        case .statusInvalidData: "invalid data"
        case .statusUnknownType: "unknown type"
        case .statusReadingHeader: "incomplete header"
        case .statusIncomplete: "incomplete"
        case .statusComplete: "complete"
        @unknown default: "status \(status.rawValue)"
        }
    }
}

// MARK: - Naming a format from a type identifier

extension ImageFormat {
    /// The format a Uniform Type Identifier names, or `nil` for one this package
    /// has no name for.
    ///
    /// The counterpart to ``named(byFilenameExtension:)``, and it matches against
    /// ``allTypeIdentifiers`` so an alias resolves too — ImageIO reports
    /// `public.heif` for some files that `public.heic` names here.
    ///
    /// Like that method, this answers *what the file is*, not *what the system
    /// can write*: ask ``EncodeSupport`` for the second question.
    public static func named(byTypeIdentifier identifier: String) -> ImageFormat? {
        allCases.first { format in
            format.allTypeIdentifiers.contains { $0.caseInsensitiveCompare(identifier) == .orderedSame }
        }
    }
}
