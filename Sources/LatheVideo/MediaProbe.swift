import AVFoundation
import CoreMedia
import Foundation
import LatheCore

/// Reads a media file's container headers and reports what is in it.
///
/// ## What this replaces
///
/// The usual way to answer "how long is this, what codec, what size" is to spawn
/// a command-line prober and parse its JSON. That is unavailable on iOS — there
/// is no `fork`/`exec` — and unnecessary everywhere else, because AVFoundation
/// already reads the same headers. ``MediaProbe`` is the direct call, and
/// ``MediaInfo/ffprobeJSON(prettyPrinted:)`` is there for callers who still have
/// to hand the answer to something that expects the old shape.
///
/// ## No decoding
///
/// Everything reported comes from the container's track headers, so the cost is
/// independent of the file's length. Two consequences follow, and both are
/// visible in the API rather than hidden:
///
/// - ``MediaTrackInfo/nominalFrameRate`` is *declared*, not measured. A variable
///   frame rate recording reports its nominal rate and means it loosely.
/// - There is no frame count. Counting frames exactly requires walking the
///   sample tables or decoding, and quietly doing either would make a "cheap"
///   call expensive. `duration × nominalFrameRate` is available to any caller
///   that wants the estimate and should be the caller's decision.
///
/// ## Concurrency
///
/// Every accessor used here is the modern `load(_:)` form. The synchronous
/// `asset.duration` / `track.naturalSize` properties are deprecated *and* they
/// block: they perform I/O on the calling thread, which is precisely the thing
/// that must not happen on a cooperative-pool thread. `load(_:)` is asynchronous
/// all the way down, so the probe never blocks the pool and needs none of
/// `LatheWork`'s machinery.
///
/// ```swift
/// let info = try await MediaProbe().probe(url: url)
/// if info.hasVideoTrack, info.duration > 0 { … }
/// ```
public struct MediaProbe: Sendable {

    public init() {}

    /// Inspect a media file.
    ///
    /// - Throws: ``LatheError/readFailed(path:reason:)`` when the file is
    ///   missing or unreadable; ``LatheError/invalidInput(reason:)`` when
    ///   AVFoundation will not open it as an asset at all.
    ///
    ///   Note what is *not* an error: an asset that opens but holds nothing
    ///   playable. A zero-duration file, an image AVFoundation is willing to
    ///   open, a container with no tracks — those return a ``MediaInfo`` with
    ///   ``MediaInfo/isEmptyAsset`` set. They are facts about the file, and the
    ///   caller usually wants to branch on them rather than catch them.
    public func probe(url: URL) async throws -> MediaInfo {
        try Self.requireReadableFile(at: url)

        // `AVURLAssetPreferPreciseDurationAndTimingKey` makes the duration
        // exact rather than estimated from the container's headline value. It
        // can cost a small amount of extra I/O on formats with no index (MP3,
        // notably); for a probe whose entire job is to be accurate about
        // duration, that is the right trade.
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )

        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.load(.tracks)
        } catch {
            // This is the "not a media file" path, and it is worth converting
            // rather than rethrowing: AVFoundation's own error for it is
            // `AVFoundationErrorDomain -11828`, which tells a caller nothing.
            throw LatheError.invalidInput(
                reason: "\(url.lastPathComponent) is not a media file AVFoundation can open "
                    + "(\(LatheError.wrapping(error).errorDescription ?? "unknown reason"))"
            )
        }

        let rawDuration = (try? await asset.load(.duration)) ?? .invalid
        let isDeterminate = rawDuration.isValid && rawDuration.isNumeric
        let duration = isDeterminate ? max(0, rawDuration.seconds) : 0

        var infos: [MediaTrackInfo] = []
        infos.reserveCapacity(tracks.count)
        for (index, track) in tracks.enumerated() {
            infos.append(try await Self.describe(track, at: index))
        }

        LatheLog.video.debug(
            """
            probed \(LatheLog.publicPath(url), privacy: .public): \
            \(infos.count, privacy: .public) track(s), \
            \(duration, privacy: .public)s
            """
        )

        return MediaInfo(
            fileName: url.lastPathComponent,
            duration: duration,
            hasDeterminateDuration: isDeterminate,
            byteCount: Self.byteCount(of: url),
            tracks: infos,
            containerName: Self.containerName(for: url)
        )
    }

    // MARK: - One track

    private static func describe(_ track: AVAssetTrack, at index: Int) async throws -> MediaTrackInfo {
        // `mediaType` is one of the few track properties that is available
        // without loading — it is neither asynchronous nor deprecated, and there
        // is no `AVAsyncProperty` for it. Everything else is loaded, in small
        // groups because `load(_:_:_:)` tops out at three properties.
        let mediaType = track.mediaType
        let (formatDescriptions, timeRange) = try await track.load(
            .formatDescriptions, .timeRange
        )
        let (estimatedDataRate, nominalFrameRate) = try await track.load(
            .estimatedDataRate, .nominalFrameRate
        )

        let kind = MediaTrackKind(mediaType)
        let description = formatDescriptions.first

        let fourCC = description.map {
            MediaTrackInfo.fourCharacterCode(CMFormatDescriptionGetMediaSubType($0))
        } ?? ""

        var codedSize: PixelSize?
        var displaySize: PixelSize?
        var sampleRate: Double?
        var channelCount: Int?

        if kind == .video {
            // Prefer the format description's dimensions over `naturalSize`:
            // they are the coded dimensions in integers, where `naturalSize` is
            // a CGSize that has already had the track's display matrix partly
            // folded in on some containers.
            if let description {
                let dimensions = CMVideoFormatDescriptionGetDimensions(description)
                codedSize = PixelSize(width: Int(dimensions.width), height: Int(dimensions.height))
            }
            if codedSize == nil || codedSize?.isEmpty == true {
                let natural = try await track.load(.naturalSize)
                codedSize = PixelSize(width: Int(natural.width.rounded()),
                                      height: Int(natural.height.rounded()))
            }
            let transform = try await track.load(.preferredTransform)
            displaySize = codedSize.map { Self.applying(transform, to: $0) }
        }

        if kind == .audio, let description,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
            sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : nil
            channelCount = asbd.mChannelsPerFrame > 0 ? Int(asbd.mChannelsPerFrame) : nil
        }

        let trackDuration = timeRange.duration.isNumeric ? max(0, timeRange.duration.seconds) : 0

        return MediaTrackInfo(
            index: index,
            kind: kind,
            mediaTypeIdentifier: mediaType.rawValue,
            codecFourCC: fourCC,
            codecName: MediaTrackInfo.commonCodecName(forFourCharacterCode: fourCC),
            codedSize: codedSize,
            displaySize: displaySize,
            nominalFrameRate: kind == .video ? Double(nominalFrameRate) : nil,
            estimatedBitRate: estimatedDataRate > 0 ? Double(estimatedDataRate) : nil,
            duration: trackDuration,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
    }

    /// Applies a track's preferred transform to a size, i.e. swaps the axes for
    /// a 90°/270° rotation and leaves everything else alone.
    ///
    /// Only the rotation matters for a size — translation cannot change it, and
    /// a scale in the display matrix is vanishingly rare in capture formats.
    static func applying(_ transform: CGAffineTransform, to size: PixelSize) -> PixelSize {
        let quarterTurn = abs(transform.b) > 0.5 && abs(transform.c) > 0.5
            && abs(transform.a) < 0.5 && abs(transform.d) < 0.5
        return quarterTurn
            ? PixelSize(width: size.height, height: size.width)
            : size
    }

    // MARK: - Files

    static func requireReadableFile(at url: URL) throws {
        guard url.isFileURL else {
            // Deliberate: anything that ingests media from a network URL lives
            // outside this package. See the licence policy in the README.
            throw LatheError.invalidInput(reason: "MediaProbe reads local files only")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw LatheError.readFailed(path: url.lastPathComponent, reason: "no such file")
        }
        guard !isDirectory.boolValue else {
            throw LatheError.readFailed(path: url.lastPathComponent, reason: "is a directory")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw LatheError.readFailed(path: url.lastPathComponent, reason: "not readable")
        }
    }

    static func byteCount(of url: URL) -> UInt64? {
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return size.map(UInt64.init)
    }

    /// ffmpeg's name for the container, best-effort, from the file extension.
    ///
    /// AVFoundation does not expose a demuxer name, and the extension is the
    /// only thing available without sniffing. The QuickTime family shares one
    /// ffmpeg demuxer and therefore one name, which is why an `.mp4` reports the
    /// same string as a `.mov`.
    static func containerName(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mov", "mp4", "m4v", "m4a", "3gp", "3g2", "qt":
            "mov,mp4,m4a,3gp,3g2,mj2"
        case "wav", "wave": "wav"
        case "aif", "aiff", "aifc": "aiff"
        case "caf": "caf"
        case "mp3": "mp3"
        case "aac", "adts": "aac"
        case "flac": "flac"
        case "": "unknown"
        default: url.pathExtension.lowercased()
        }
    }
}
