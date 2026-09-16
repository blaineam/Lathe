@preconcurrency import AVFoundation
import Foundation
import LatheCore

/// How an AV1 encode should come out.
public struct AV1EncodeOptions: Sendable, Equatable {

    /// The largest the picture may be *as displayed*, in pixels. The video is
    /// scaled down to fit, keeping its shape; it is never enlarged. `nil`
    /// keeps the source's size.
    public var maxWidth: Int?
    public var maxHeight: Int?

    /// Frames per second to tell the encoder. `nil` uses the source's
    /// nominal rate. The frames keep the source's own timestamps either way;
    /// this informs rate control and key-frame spacing.
    public var frameRate: Double?

    /// Target bits per second. SVT-AV1 runs in VBR mode, so this is an
    /// average, not a ceiling.
    public var bitrate: Int

    /// SVT-AV1's speed preset, 0 (slowest, smallest) to 13 (fastest).
    /// ``AV1Encoder/defaultPreset`` is 8 on a Mac and 10 on a phone.
    public var preset: Int

    public init(
        maxWidth: Int? = nil,
        maxHeight: Int? = nil,
        frameRate: Double? = nil,
        bitrate: Int,
        preset: Int = AV1Encoder.defaultPreset
    ) {
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.frameRate = frameRate
        self.bitrate = bitrate
        self.preset = preset
    }
}

/// What an AV1 encode produced.
public struct AV1EncodeResult: Sendable, Equatable {
    public var output: URL
    /// The coded size — the track's natural size, before any rotation.
    public var pixelSize: PixelSize
    public var frameCount: Int
    /// Whether the encode was 10-bit: HDR and high-bit-depth sources are
    /// kept at 10 bits rather than truncated.
    public var isTenBit: Bool
    /// Whether the source's audio was carried into the output.
    public var hasAudio: Bool
    public var outputByteCount: UInt64
    public var wallTime: TimeInterval
}

/// AV1 encoding, in process, through SVT-AV1.
///
/// ## Why a software encoder
///
/// No Apple device encodes AV1 in hardware. VideoToolbox decodes it on newer
/// chips and lists no AV1 encoder anywhere, so every frame is computed on the
/// CPU. Expect several times real time on a Mac and considerably slower on a
/// phone — against the media engine's many times faster than real time for
/// HEVC. That cost is the reason this is its own product: an app that does not
/// offer AV1 should not link a CPU encoder it never calls.
///
/// ## What comes out
///
/// An MP4 with one AV1 video track and the source's audio passed through (or
/// re-encoded to AAC when the MP4 container will not take it as it is). Colour
/// primaries, transfer and matrix are carried from the source, and HDR sources
/// stay 10-bit.
///
/// ## Licence
///
/// SVT-AV1 is BSD-3-Clause-Clear, with the Alliance for Open Media Patent
/// License 1.0. An app that ships this must reproduce both notices; they are
/// in the xcframework as `LICENSE.md` and `PATENTS.md`.
public struct AV1Encoder: Sendable {

    public static var defaultPreset: Int { AV1Engine.defaultPreset }

    public init() {}

    /// Encodes the video of `source` to AV1 at `destination`.
    ///
    /// Atomic: the encode goes to a scratch file beside `destination`, which
    /// replaces it only once the MP4 is finished, so a failure or a
    /// cancellation leaves whatever was there before.
    ///
    /// - Parameters:
    ///   - destination: must end in `.mp4` — AV1 has a standard home in MP4
    ///     and none in QuickTime.
    ///   - progress: reported per frame under the stage name `"av1"`.
    /// - Throws: ``LatheError/invalidInput(reason:)`` for a source with no
    ///   video; ``LatheError/invalidConfiguration(reason:)`` for a destination
    ///   that is not `.mp4` or a non-positive bitrate;
    ///   ``LatheError/encodingFailed(stage:code:reason:)`` when SVT-AV1 or the
    ///   writer fails; ``LatheError/cancelled(atUnit:)`` when progress says stop.
    @discardableResult
    public func encode(
        source: URL,
        to destination: URL,
        options: AV1EncodeOptions,
        progress: ProgressHandle = .ignoring()
    ) async throws -> AV1EncodeResult {
        guard FileManager.default.isReadableFile(atPath: source.path) else {
            throw LatheError.readFailed(path: source.lastPathComponent, reason: "no such file")
        }
        return try await encode(
            asset: AVURLAsset(url: source), to: destination, options: options, progress: progress)
    }

    /// The same, from an asset that is already open — a Photos library video,
    /// say, which would otherwise be exported only to be read back.
    @discardableResult
    public func encode(
        asset: AVAsset,
        to destination: URL,
        options: AV1EncodeOptions,
        progress: ProgressHandle = .ignoring()
    ) async throws -> AV1EncodeResult {
        let started = Date()
        guard destination.pathExtension.lowercased() == "mp4" else {
            throw LatheError.invalidConfiguration(
                reason: "AV1 is written into MP4; \(destination.lastPathComponent) is not a .mp4")
        }
        guard options.bitrate > 0 else {
            throw LatheError.invalidConfiguration(
                reason: "the bitrate must be positive, got \(options.bitrate)")
        }

        let directory = destination.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scratch = directory.appendingPathComponent(".lathe-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let config = AV1Engine.Configuration(
            width: options.maxWidth ?? Int.max / 4,
            height: options.maxHeight ?? Int.max / 4,
            frameRate: Float(options.frameRate ?? 0),
            bitrate: options.bitrate,
            preset: min(max(options.preset, 0), 13))

        let summary: AV1Engine.Summary
        do {
            summary = try await AV1Engine().encode(
                asset: asset, to: scratch, config: config, progress: progress)
        } catch is CancellationError {
            throw LatheError.cancelled(atUnit: progress.currentUnitIndex)
        }

        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: scratch)
            } else {
                try FileManager.default.moveItem(at: scratch, to: destination)
            }
        } catch {
            throw LatheError.writeFailed(
                path: destination.lastPathComponent, reason: (error as NSError).localizedDescription)
        }

        let bytes = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .flatMap { $0.map(UInt64.init) } ?? 0
        return AV1EncodeResult(
            output: destination,
            pixelSize: PixelSize(width: summary.width, height: summary.height),
            frameCount: summary.frameCount,
            isTenBit: summary.tenBit,
            hasAudio: summary.hasAudio,
            outputByteCount: bytes,
            wallTime: Date().timeIntervalSince(started))
    }
}
