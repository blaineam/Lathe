import CoreGraphics
import Foundation
import ImageIO
import LatheCore
import LatheImage
import LatheSWF

/// Where in a movie a thumbnail is taken from.
public enum SWFThumbnailPosition: Sendable, Equatable {
    /// This many seconds into the movie's performance.
    ///
    /// Capture is real time, so the cost of a thumbnail is this number: a
    /// batch of fifty movies at `.seconds(2)` takes a little under two
    /// minutes.
    case seconds(Double)

    /// The first frame Ruffle draws. The quickest thumbnail there is, and for
    /// a movie that opens on a preloader, a picture of the preloader.
    case start
}

/// What to do about the background of a movie that has none.
public enum SWFThumbnailBackground: Sendable, Equatable {
    /// Keep the alpha channel, for formats that have one. A format without
    /// one (JPEG) gets ``white`` instead of a black box.
    case transparent
    case white
    case black
}

/// What a batch of thumbnails should look like.
public struct SWFThumbnailOptions: Sendable {

    /// The output format. WebP by default: it is small, it keeps alpha, and
    /// every browser and most galleries read it.
    public var format: ImageFormat

    public var quality: QualityTarget

    /// The longest side of the picture in pixels, or `nil` for the movie's own
    /// stage size. Flash is vector art, so this is a rendering size rather
    /// than a resize — a larger value is sharper, not blurrier.
    public var longestSide: Int?

    public var position: SWFThumbnailPosition

    public var background: SWFThumbnailBackground

    /// When the frame at ``position`` is one flat colour — a movie that has
    /// not drawn anything yet — use the latest earlier frame that is not.
    public var skipBlankFrames: Bool

    /// How often the stage is sampled while waiting for ``position``. Only
    /// the last few samples can be used, so this stays low; it does not speed
    /// the movie up or slow it down.
    public var samplingRate: Double

    public var startupTimeout: Duration

    public init(
        format: ImageFormat = .webp,
        quality: QualityTarget = .quality(0.8),
        longestSide: Int? = 640,
        position: SWFThumbnailPosition = .seconds(1.5),
        background: SWFThumbnailBackground = .transparent,
        skipBlankFrames: Bool = true,
        samplingRate: Double = 8,
        startupTimeout: Duration = .seconds(60)
    ) {
        self.format = format
        self.quality = quality
        self.longestSide = longestSide
        self.position = position
        self.background = background
        self.skipBlankFrames = skipBlankFrames
        self.samplingRate = samplingRate
        self.startupTimeout = startupTimeout
    }
}

/// One finished thumbnail.
public struct SWFThumbnail: Sendable, Equatable {
    public let source: URL
    public let output: URL
    public let pixelSize: CGSize
    public let byteCount: Int
    /// Seconds into the movie that the picture was taken at.
    public let capturedAtSeconds: Double
    /// Every sampled frame was a single flat colour, so the picture is what
    /// the movie showed, which is nothing. Worth telling the person.
    public let isBlank: Bool
    /// Ruffle fell back to its canvas renderer, which is less faithful.
    public let usedFallbackRenderer: Bool
}

/// What happened to one movie in a batch.
public enum SWFThumbnailOutcome: Sendable {
    case made(SWFThumbnail)
    case failed(source: URL, reason: String)

    public var source: URL {
        switch self {
        case let .made(thumbnail): thumbnail.source
        case let .failed(source, _): source
        }
    }
}

/// A batch's progress, one event at a time.
public enum SWFThumbnailProgress: Sendable {
    /// Movie `index` of `count` (zero-based index) has begun.
    case started(index: Int, count: Int, source: URL)
    /// Movie `index` has finished, one way or the other.
    case finished(index: Int, count: Int, outcome: SWFThumbnailOutcome)
}

/// Cuts still thumbnails out of Flash movies with Ruffle, in bulk.
///
/// ```swift
/// let outcomes = try await SWFThumbnailer().thumbnails(
///     of: movies, into: folder,
///     options: SWFThumbnailOptions(format: .webp, longestSide: 480))
/// ```
///
/// This is ``SWFRenderer`` aimed at one picture per movie instead of all of
/// them: it plays each movie only as far as ``SWFThumbnailOptions/position``,
/// samples the stage coarsely on the way, keeps the last frame that has
/// something on it, and writes that through ``ImageEncoder`` in the format
/// asked for. It inherits every property of the renderer — real-time capture,
/// the bundled WebAssembly Ruffle, untrusted ActionScript interpreted inside a
/// `WKWebView` — and none of its cost beyond the time to reach the position.
///
/// A batch **never fails because one movie did.** A movie Ruffle cannot play,
/// or a file that is not a SWF, comes back as ``SWFThumbnailOutcome/failed``
/// with a sentence saying why, and the next movie runs. Cancelling the calling
/// task stops the batch at the next movie boundary, or sooner.
@MainActor
public final class SWFThumbnailer {

    private let renderer: SWFRenderer

    public init(renderer: SWFRenderer = SWFRenderer()) {
        self.renderer = renderer
    }

    // MARK: - One movie

    /// Writes one thumbnail of `swf` to `destination`, replacing a file that
    /// is already there.
    ///
    /// - Throws: whatever ``SWFRenderer/render(_:to:options:)`` throws, plus
    ///   ``LatheError/encodeUnavailable(format:)`` when this system cannot
    ///   write the format.
    @discardableResult
    public func thumbnail(
        of swf: URL, to destination: URL, options: SWFThumbnailOptions = SWFThumbnailOptions()
    ) async throws -> SWFThumbnail {
        try EncodeSupport.shared.requireEncodable(options.format)

        let header = try SWFCapture().header(of: swf)
        let rate = Self.clamp(options.samplingRate, 1, 30)
        let frameCount: Int
        let seconds: Double
        switch options.position {
        case .start:
            frameCount = 1
            seconds = 0
        case let .seconds(position):
            seconds = Self.clamp(position, 0, 120)
            frameCount = max(1, Int((seconds * rate).rounded(.up)))
        }

        var render = SWFRenderOptions(
            framesPerSecond: rate,
            pixelSize: Self.renderSize(for: header, longestSide: options.longestSide),
            limit: .frames(frameCount)
        )
        render.startupTimeout = options.startupTimeout

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("lathe-swf-thumbnail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let result = try await renderer.render(swf, to: work.appendingPathComponent("frames"), options: render)
        let frames = result.frames.frames
        guard !frames.isEmpty else {
            throw LatheError.invalidInput(reason: "\(swf.lastPathComponent) produced no frames")
        }

        // The last frame, or the latest one with something in it.
        var chosen = frames.count - 1
        var blank = Self.isFlat(frames[chosen])
        if blank, options.skipBlankFrames {
            if let found = frames.indices.reversed().first(where: { !Self.isFlat(frames[$0]) }) {
                chosen = found
                blank = false
            }
        }

        let flattened = work.appendingPathComponent("chosen.png")
        try Self.write(
            frames[chosen], to: flattened,
            flatteningOnto: Self.background(options.background, for: options.format))

        let encoded = try await ImageEncoder().encode(
            source: flattened, to: destination, format: options.format,
            quality: options.quality, metadata: .stripAll)

        return SWFThumbnail(
            source: swf, output: destination,
            pixelSize: result.pixelSize,
            byteCount: Int(encoded.outputByteCount),
            capturedAtSeconds: Double(chosen + 1) / rate,
            isBlank: blank,
            usedFallbackRenderer: result.renderer == "canvas")
    }

    // MARK: - A batch

    /// Cuts a thumbnail of each movie into `directory`, named after the
    /// movie, one after another.
    ///
    /// Two movies with the same name get `-2`, `-3` and so on rather than
    /// overwriting each other. `progress` is called on the main actor before
    /// and after each movie.
    ///
    /// - Returns: one outcome per movie, in order. Movies not reached because
    ///   the task was cancelled are absent.
    public func thumbnails(
        of movies: [URL], into directory: URL,
        options: SWFThumbnailOptions = SWFThumbnailOptions(),
        progress: ((SWFThumbnailProgress) -> Void)? = nil
    ) async throws -> [SWFThumbnailOutcome] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var outcomes: [SWFThumbnailOutcome] = []
        var used: Set<String> = []

        for (index, movie) in movies.enumerated() {
            try Task.checkCancellation()
            progress?(.started(index: index, count: movies.count, source: movie))

            let destination = Self.uniqueDestination(
                for: movie, in: directory, format: options.format, taken: &used)
            let outcome: SWFThumbnailOutcome
            do {
                outcome = .made(try await thumbnail(of: movie, to: destination, options: options))
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as LatheError where error.isCancellation {
                throw CancellationError()
            } catch {
                outcome = .failed(source: movie, reason: Self.reason(error))
            }
            outcomes.append(outcome)
            progress?(.finished(index: index, count: movies.count, outcome: outcome))
        }
        return outcomes
    }

    // MARK: - Helpers

    nonisolated static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        guard value.isFinite else { return low }
        return min(max(value, low), high)
    }

    /// The stage scaled so its longest side is `longestSide`, or the movie's
    /// own size when that is `nil`. Flash is vector, so it scales up as
    /// readily as down.
    nonisolated static func renderSize(for header: SWFHeader, longestSide: Int?) -> CGSize {
        let width = max(1, Int(header.stageWidthInPixels))
        let height = max(1, Int(header.stageHeightInPixels))
        guard let side = longestSide, side > 0 else {
            return CGSize(width: width, height: height)
        }
        let longest = Double(max(width, height))
        let scale = Double(min(side, 8192)) / longest
        return CGSize(
            width: max(1, (Double(width) * scale).rounded()),
            height: max(1, (Double(height) * scale).rounded()))
    }

    nonisolated static func background(
        _ choice: SWFThumbnailBackground, for format: ImageFormat
    ) -> CGColor? {
        switch choice {
        case .white: return CGColor(gray: 1, alpha: 1)
        case .black: return CGColor(gray: 0, alpha: 1)
        case .transparent: return format.supportsAlpha ? nil : CGColor(gray: 1, alpha: 1)
        }
    }

    /// `name.ext`, then `name-2.ext`, and so on, unique within the batch
    /// without regard to case. A file left by an earlier run is replaced,
    /// which is what running it again means.
    nonisolated static func uniqueDestination(
        for movie: URL, in directory: URL, format: ImageFormat, taken: inout Set<String>
    ) -> URL {
        let stem = movie.deletingPathExtension().lastPathComponent
        let ext = format.preferredFilenameExtension
        var name = "\(stem).\(ext)"
        var counter = 2
        while taken.contains(name.lowercased()) {
            name = "\(stem)-\(counter).\(ext)"
            counter += 1
        }
        taken.insert(name.lowercased())
        return directory.appendingPathComponent(name)
    }

    nonisolated static func reason(_ error: Error) -> String {
        if let lathe = error as? LatheError {
            switch lathe {
            case let .invalidInput(reason), let .invalidConfiguration(reason):
                return reason
            case let .unsupportedOnThisPlatform(feature):
                return feature
            default:
                break
            }
        }
        return error.localizedDescription
    }

    /// Whether every pixel is the same: a stage that has drawn nothing.
    nonisolated static func isFlat(_ url: URL) -> Bool {
        guard let image = decode(url) else { return false }
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return true }
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        let first = (data[0], data[1], data[2], data[3])
        var index = 4
        while index < data.count {
            if (data[index], data[index + 1], data[index + 2], data[index + 3]) != first {
                return false
            }
            index += 4
        }
        return true
    }

    nonisolated private static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Re-saves `frame` as a PNG, composited over `color` when there is one.
    nonisolated private static func write(_ frame: URL, to destination: URL, flatteningOnto color: CGColor?) throws {
        guard let image = decode(frame) else {
            throw LatheError.invalidInput(reason: "a captured frame could not be read back")
        }
        var output = image
        if let color {
            guard let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else {
                throw LatheError.invalidInput(reason: "a captured frame could not be flattened")
            }
            let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.setFillColor(color)
            context.fill(rect)
            context.draw(image, in: rect)
            guard let flat = context.makeImage() else {
                throw LatheError.invalidInput(reason: "a captured frame could not be flattened")
            }
            output = flat
        }
        guard let sink = CGImageDestinationCreateWithURL(
            destination as CFURL, "public.png" as CFString, 1, nil)
        else {
            throw LatheError.invalidInput(reason: "a captured frame could not be written")
        }
        CGImageDestinationAddImage(sink, output, nil)
        guard CGImageDestinationFinalize(sink) else {
            throw LatheError.invalidInput(reason: "a captured frame could not be written")
        }
    }
}
