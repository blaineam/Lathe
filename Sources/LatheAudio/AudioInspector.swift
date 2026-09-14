import AVFoundation
import CoreMedia
import Foundation
import LatheCore

// MARK: - One audio stream

/// One audio track's facts, as the container reports them.
///
/// No decoding happens to produce this, so inspecting a nine-hour audiobook
/// costs what inspecting a ringtone costs. (``LoudnessProbe`` is the one that
/// decodes; the two are separate for that reason.)
///
/// The field that earns this type its keep is ``isLossless``. Everything
/// ``AudioTranscoder`` refuses to do badly turns on the difference between a
/// source that has already been through a psychoacoustic model and one that has
/// not, and that difference is not visible in a bitrate, a sample rate or a file
/// extension.
public struct AudioStreamInfo: Sendable, Equatable {

    /// The CoreAudio format ID as a four-character code — `"aac "`, `"lpcm"`,
    /// `"alac"`, `".mp3"`.
    ///
    /// Unmapped, exactly as `CMFormatDescriptionGetMediaSubType` returned it.
    /// Note that for audio this is the **CoreAudio** format ID and not the
    /// container's sample-description tag: AAC in an MPEG-4 file reports
    /// `"aac "` — with the padding space — and never the `"mp4a"` a container
    /// inspector would print.
    public var codecFourCC: String

    /// The codec's common name — `"aac"`, `"alac"`, `"pcm"`, `"mp3"`,
    /// `"flac"`, `"opus"`.
    ///
    /// Spelled the way the familiar command-line tools spell it, so a caller
    /// migrating off one keeps comparing against the same strings. An
    /// unrecognised code passes through trimmed and lowercased rather than
    /// becoming `"unknown"`: a new codec should look unfamiliar, not look like
    /// an error.
    public var codecName: String

    /// Whether the codec reproduces its input exactly.
    ///
    /// `true` for linear PCM, Apple Lossless and FLAC. **The decision the whole
    /// module hangs off** — a lossless source is where re-encoding wins, and a
    /// lossy one is where it compounds. See ``LossySourceRule``.
    public var isLossless: Bool

    /// Bits per second, as AVFoundation estimates it from the track's size and
    /// duration. `nil` only when neither the track nor the file offers enough to
    /// estimate one.
    ///
    /// An estimate, labelled as one, and an honest one: it is bytes over
    /// seconds, which is exact for a constant-bitrate file and, for a
    /// variable-bitrate file, is the average that actually matters when
    /// predicting a saving.
    ///
    /// ``AudioInspector/inspect(_:)`` falls back to the *file's* size over its
    /// duration for a single-track file whose track declines to estimate — an
    /// MP3 with no Xing header, typically. That number is a few tenths of a
    /// percent high because it counts the container's own bytes, which is the
    /// safe direction: it can only make ``LossySourceRule`` more willing to
    /// believe a re-encode saves something, never less.
    public var bitsPerSecond: Int?

    public var sampleRate: Double

    public var channelCount: Int

    /// Bits per sample for uncompressed audio; `nil` for a compressed stream,
    /// which does not have one.
    public var bitDepth: Int?

    /// The track's duration in seconds.
    public var duration: TimeInterval

    /// The track's `AudioChannelLayout`, as the bytes the format description
    /// carries, or `nil` when it declares none.
    ///
    /// Opaque here on purpose — nothing in this package interprets it. It is
    /// exposed because it is *load-bearing* rather than decorative: an AAC or
    /// ALAC encoder cannot be configured for more than two channels without
    /// one, since "six channels" does not say which six. A 5.1 source whose
    /// layout is missing therefore cannot be re-encoded as 5.1 by anything,
    /// and ``ChannelPolicy`` says what happens instead.
    public var channelLayout: Data?

    public init(
        codecFourCC: String,
        codecName: String,
        isLossless: Bool,
        bitsPerSecond: Int?,
        sampleRate: Double,
        channelCount: Int,
        bitDepth: Int?,
        duration: TimeInterval,
        channelLayout: Data? = nil
    ) {
        self.codecFourCC = codecFourCC
        self.codecName = codecName
        self.isLossless = isLossless
        self.bitsPerSecond = bitsPerSecond
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitDepth = bitDepth
        self.duration = duration
        self.channelLayout = channelLayout
    }

    public var isLossy: Bool { !isLossless }

    /// `true` for more than two channels.
    public var isMultichannel: Bool { channelCount > 2 }
}

// MARK: - One file

/// Everything ``AudioInspector`` learned about a file.
public struct AudioFileInfo: Sendable, Equatable {

    /// The file's name — **the last path component only**.
    ///
    /// Not the full path, deliberately, and for the same reason ``MediaInfo``
    /// does the same: this ends up in logs and in bug reports, and a full path
    /// to somebody's music library is exactly the kind of thing that should not
    /// travel.
    public var fileName: String

    /// The container's duration in seconds.
    ///
    /// `0` both for a genuinely empty file and for one whose duration is not a
    /// number at all; ``hasDeterminateDuration`` tells them apart.
    public var duration: TimeInterval

    /// `false` when the asset reported an indefinite duration, which a
    /// `TimeInterval` cannot represent.
    public var hasDeterminateDuration: Bool

    public var byteCount: UInt64?

    /// The first audio track, which is the one a player would play. `nil` for a
    /// file with no audio at all — which is a fact, not an error.
    public var stream: AudioStreamInfo?

    /// Chapters the container declares.
    ///
    /// Present on audiobooks and on long podcast episodes, and **not carried
    /// across by ``AudioTranscoder``** — see its documentation. Non-zero here
    /// is the signal to leave a file alone, or to accept the loss knowingly.
    public var chapterCount: Int

    /// Whether the file carries album artwork.
    public var hasArtwork: Bool

    /// Container-level metadata items, before any policy is applied.
    public var metadataItemCount: Int

    public init(
        fileName: String,
        duration: TimeInterval,
        hasDeterminateDuration: Bool,
        byteCount: UInt64?,
        stream: AudioStreamInfo?,
        chapterCount: Int,
        hasArtwork: Bool,
        metadataItemCount: Int
    ) {
        self.fileName = fileName
        self.duration = duration
        self.hasDeterminateDuration = hasDeterminateDuration
        self.byteCount = byteCount
        self.stream = stream
        self.chapterCount = chapterCount
        self.hasArtwork = hasArtwork
        self.metadataItemCount = metadataItemCount
    }

    public var hasAudioTrack: Bool { stream != nil }
}

// MARK: - The inspector

/// Reads an audio file's headers and reports what is in it — including **how
/// long it is**.
///
/// ```swift
/// let info = try await AudioInspector().inspect(url)
/// print(info.duration, info.stream?.codecName ?? "no audio")
///
/// let seconds = try await AudioInspector().duration(of: url)
/// ```
///
/// ## Why this is in `LatheAudio` and not in the video module's prober
///
/// `MediaProbe` already answers "how long is this" for anything AVFoundation
/// opens, an audio file included. It lives in `LatheVideo`, though, and the
/// package's linking contract is that a consumer which only handles audio links
/// no video code. Answering "how long is this MP3" should not pull in a
/// VideoToolbox transcoder, so the small amount that overlaps is written twice
/// — the same trade the package already makes between the still-image and video
/// modules. `MediaProbe` remains the right call for a file that may contain
/// video, and reports strictly more.
///
/// ## Duration, and why the option is not optional
///
/// `AVURLAssetPreferPreciseDurationAndTimingKey` costs a little extra I/O on
/// formats with no index — MP3 above all, where the headline duration in the
/// first frame's header is a guess extrapolated from one bitrate and is wrong
/// by seconds on any VBR file. For a type whose entire job is to be right about
/// duration, paying that is the only defensible choice, so it is not a
/// parameter.
public struct AudioInspector: Sendable {

    public init() {}

    /// Inspect an audio file.
    ///
    /// - Throws: ``LatheError/readFailed(path:reason:)`` when the file is
    ///   missing or unreadable, ``LatheError/invalidInput(reason:)`` when
    ///   AVFoundation will not open it as an asset at all.
    ///
    ///   Note what is *not* an error: a file that opens and holds no audio. It
    ///   comes back with a `nil` ``AudioFileInfo/stream``, because a caller
    ///   almost always wants to branch on that rather than catch it.
    public func inspect(_ url: URL) async throws -> AudioFileInfo {
        try AudioFiles.requireReadableFile(at: url)
        let asset = try await AudioFiles.asset(at: url)

        let rawDuration = (try? await asset.load(.duration)) ?? .invalid
        let isDeterminate = rawDuration.isValid && rawDuration.isNumeric
        let duration = isDeterminate ? max(0, rawDuration.seconds) : 0

        let track = try await AudioFiles.firstAudioTrack(of: asset)
        var stream: AudioStreamInfo?
        if let track { stream = try await Self.describe(track) }

        // The fallback described on `AudioStreamInfo.bitsPerSecond`. Only for a
        // file that is *only* this track — dividing a movie's bytes by its
        // duration would attribute the video's bitrate to the audio, which is
        // the one way this estimate can be catastrophically wrong.
        let byteCount = AudioFiles.byteCount(of: url)
        if stream?.bitsPerSecond == nil,
           let byteCount, byteCount > 0, duration > 0,
           (try? await AudioFiles.loadTracks(of: asset, url: url))?.count == 1 {
            stream?.bitsPerSecond = Int((Double(byteCount) * 8 / duration).rounded())
        }

        let metadata = (try? await asset.load(.metadata)) ?? []
        let common = (try? await asset.load(.commonMetadata)) ?? []
        let hasArtwork = (metadata + common).contains { AudioMetadata.isArtwork($0) }

        let chapters = await Self.chapterCount(of: asset)

        LatheLog.audio.debug(
            """
            inspected \(LatheLog.publicPath(url), privacy: .public): \
            \(stream?.codecName ?? "no audio", privacy: .public), \
            \(duration, privacy: .public)s, \
            \(chapters, privacy: .public) chapter(s)
            """
        )

        return AudioFileInfo(
            fileName: url.lastPathComponent,
            duration: duration,
            hasDeterminateDuration: isDeterminate,
            byteCount: byteCount,
            stream: stream,
            chapterCount: chapters,
            hasArtwork: hasArtwork,
            metadataItemCount: metadata.count
        )
    }

    /// How long an audio file is, in seconds.
    ///
    /// The answer to the question the image module answers with
    /// `ImageFrameInfo.totalPlaybackDuration` and the video module with
    /// `MediaInfo.duration`, so "how long is this?" has an answer for every kind
    /// of media this package handles.
    ///
    /// - Returns: `0` for a file whose duration is indefinite rather than long.
    ///   Use ``inspect(_:)`` and check
    ///   ``AudioFileInfo/hasDeterminateDuration`` where the difference matters.
    public func duration(of url: URL) async throws -> TimeInterval {
        try AudioFiles.requireReadableFile(at: url)
        let asset = try await AudioFiles.asset(at: url)
        let raw = (try? await asset.load(.duration)) ?? .invalid
        guard raw.isValid, raw.isNumeric else { return 0 }
        return max(0, raw.seconds)
    }

    // MARK: - One track

    static func describe(_ track: AVAssetTrack) async throws -> AudioStreamInfo {
        let (formatDescriptions, timeRange) = try await track.load(.formatDescriptions, .timeRange)
        let estimatedDataRate = try await track.load(.estimatedDataRate)
        let description = formatDescriptions.first

        let subtype = description.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
        let fourCC = AudioStreamInfo.fourCharacterCode(subtype)
        let asbd = description.flatMap {
            CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
        }

        let bitDepth = asbd.map { Int($0.mBitsPerChannel) }.flatMap { $0 > 0 ? $0 : nil }
        let duration = timeRange.duration.isNumeric ? max(0, timeRange.duration.seconds) : 0

        return AudioStreamInfo(
            codecFourCC: fourCC,
            codecName: AudioStreamInfo.commonCodecName(forFormatID: subtype, fourCC: fourCC),
            isLossless: AudioStreamInfo.isLosslessFormat(subtype),
            bitsPerSecond: estimatedDataRate > 0 ? Int(estimatedDataRate.rounded()) : nil,
            sampleRate: asbd.map(\.mSampleRate).flatMap { $0 > 0 ? $0 : nil } ?? 0,
            channelCount: asbd.map { max(1, Int($0.mChannelsPerFrame)) } ?? 1,
            bitDepth: bitDepth,
            duration: duration,
            channelLayout: description.flatMap(channelLayoutData(of:))
        )
    }

    /// The track's `AudioChannelLayout` as bytes.
    ///
    /// `CMAudioFormatDescriptionGetChannelLayout` hands back a pointer into the
    /// format description and a size, and the size is **not**
    /// `MemoryLayout<AudioChannelLayout>.size`: the struct ends in a
    /// variable-length array of channel descriptions, so a fixed-size copy
    /// truncates every layout that actually describes its channels individually.
    /// The returned size is the one to copy.
    static func channelLayoutData(of description: CMAudioFormatDescription) -> Data? {
        var size = 0
        guard let pointer = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &size),
              size > 0
        else { return nil }
        return Data(bytes: pointer, count: size)
    }

    /// How many chapters the container declares.
    ///
    /// `chapterMetadataGroups` needs a locale to match against, and an
    /// audiobook's chapter track carries whatever locale its producer chose. The
    /// available locales are asked for first and *all* of them offered, so a
    /// German audiobook inspected on an English device does not report zero
    /// chapters — which it does if the device's preferred language is passed in
    /// alone.
    static func chapterCount(of asset: AVAsset) async -> Int {
        let locales = (try? await asset.load(.availableChapterLocales)) ?? []
        if locales.isEmpty {
            // No locale is declared; the nil-locale overload returns every group
            // regardless of language, which is what "how many chapters" means.
            let groups = (try? await asset.loadChapterMetadataGroups(
                bestMatchingPreferredLanguages: Locale.preferredLanguages
            )) ?? []
            return groups.count
        }
        var total = 0
        for locale in locales {
            let groups = (try? await asset.loadChapterMetadataGroups(
                withTitleLocale: locale, containingItemsWithCommonKeys: []
            )) ?? []
            total = max(total, groups.count)
        }
        return total
    }
}

// MARK: - Codec names

extension AudioStreamInfo {

    /// Renders a `FourCharCode` the way container tools print it, hex-escaping
    /// anything unprintable rather than dropping it — two different codecs must
    /// not compare equal because one of them had a high byte.
    ///
    /// (Duplicated from the video module's identical helper. The linking
    /// contract is that an audio-only consumer links no video code, and one
    /// twelve-line function is a cheaper price for that than a dependency.)
    static func fourCharacterCode(_ code: FourCharCode) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF),
        ]
        return bytes.map { byte in
            (0x20...0x7E).contains(byte)
                ? String(UnicodeScalar(byte))
                : String(format: "\\x%02x", byte)
        }.joined()
    }

    /// Whether a CoreAudio format ID names a codec that reproduces its input
    /// exactly.
    ///
    /// Matched against the CoreAudio constants rather than against a list of
    /// strings, so it cannot drift from what the decoder actually reports.
    /// Everything not named here is treated as **lossy**, which is the safe
    /// direction to be wrong in: mistaking a lossless format for a lossy one
    /// makes the transcoder more cautious, while the opposite mistake is
    /// precisely the generation-loss trap.
    static func isLosslessFormat(_ formatID: AudioFormatID) -> Bool {
        switch formatID {
        case kAudioFormatLinearPCM,
             kAudioFormatAppleLossless,
             kAudioFormatFLAC:
            true
        default:
            false
        }
    }

    static func commonCodecName(forFormatID formatID: AudioFormatID, fourCC: String) -> String {
        switch formatID {
        case kAudioFormatLinearPCM: "pcm"
        case kAudioFormatAppleLossless: "alac"
        case kAudioFormatFLAC: "flac"
        case kAudioFormatMPEG4AAC,
             kAudioFormatMPEG4AAC_HE,
             kAudioFormatMPEG4AAC_HE_V2,
             kAudioFormatMPEG4AAC_LD,
             kAudioFormatMPEG4AAC_ELD:
            "aac"
        case kAudioFormatMPEGLayer3: "mp3"
        case kAudioFormatMPEGLayer1: "mp1"
        case kAudioFormatMPEGLayer2: "mp2"
        case kAudioFormatOpus: "opus"
        case kAudioFormatAC3: "ac3"
        case kAudioFormatEnhancedAC3: "eac3"
        case kAudioFormatAppleIMA4: "adpcm_ima_qt"
        case kAudioFormatAMR: "amr_nb"
        case kAudioFormatiLBC: "ilbc"
        case kAudioFormatULaw: "pcm_mulaw"
        case kAudioFormatALaw: "pcm_alaw"
        default: fourCC.lowercased().trimmingCharacters(in: .whitespaces)
        }
    }
}

// MARK: - Files

/// The small amount of file and asset handling every entry point in this module
/// needs, in one place.
enum AudioFiles {

    static func requireReadableFile(at url: URL) throws {
        guard url.isFileURL else {
            // Deliberate: anything that ingests media from the network lives
            // outside this package. See the licence policy in the README.
            throw LatheError.invalidInput(reason: "LatheAudio reads local files only")
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

    /// An asset whose duration is exact rather than extrapolated. See
    /// ``AudioInspector``.
    static func asset(at url: URL) async throws -> AVURLAsset {
        let asset = AVURLAsset(
            url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        // Loading the tracks is what converts "not a media file" from a lazy
        // failure somewhere later into an error at the call the caller made.
        _ = try await loadTracks(of: asset, url: url)
        return asset
    }

    static func loadTracks(of asset: AVURLAsset, url: URL) async throws -> [AVAssetTrack] {
        do {
            return try await asset.load(.tracks)
        } catch {
            // AVFoundation's own error here is `AVFoundationErrorDomain -11828`,
            // which tells a caller nothing.
            throw LatheError.invalidInput(
                reason: "\(url.lastPathComponent) is not a media file AVFoundation can open "
                    + "(\(LatheError.wrapping(error).errorDescription ?? "unknown reason"))"
            )
        }
    }

    static func firstAudioTrack(of asset: AVURLAsset) async throws -> AVAssetTrack? {
        (try? await asset.loadTracks(withMediaType: .audio))?.first
    }

    static func byteCount(of url: URL) -> UInt64? {
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        return size.map(UInt64.init)
    }
}
