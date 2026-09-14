import Foundation

/// One downloadable rendition of a media item, as the extractor described it.
///
/// This is a decode of one entry of `yt-dlp`'s `formats` list — the same shape
/// `yt-dlp --dump-json` prints, which is why every test that reasons about
/// format selection in this package is a pure function of fixture JSON and
/// needs neither an interpreter nor a network.
///
/// ## Why the codec fields are `String?` and not `String`
///
/// `yt-dlp` uses the **string** `"none"` to mean "this rendition carries no
/// video" (or no audio), and uses a *missing* or `null` field to mean "unknown,
/// assume it is present". Those are different facts and collapsing them is the
/// classic way to get this wrong: a format with no `acodec` key is not a silent
/// format, and treating it as one throws away the best rendition on half the
/// sites in the extractor list.
///
/// So the decode maps `"none"` to `nil` and leaves genuinely absent fields as
/// `nil` too — and then ``hasAudio`` deliberately does *not* read
/// `acodec != nil`. It reads a separate flag that remembers which of the two
/// happened. See ``videoIsAbsent`` and ``audioIsAbsent``.
public struct MediaFormat: Sendable, Equatable, Codable {

    /// The extractor's own id — `"137"`, `"hls-1080"`, `"http-mp4"`. Opaque,
    /// and the only thing that should ever be handed back to `yt-dlp` to ask
    /// for this rendition again.
    public let formatID: String

    /// The container extension the extractor expects — `"mp4"`, `"webm"`,
    /// `"m4a"`. Advisory: it is what the *file* should be called, not a promise
    /// about what is inside it.
    public let ext: String?

    /// `yt-dlp`'s transfer protocol name — `"https"`, `"m3u8_native"`,
    /// `"dash"`, `"http_dash_segments"`. The distinction that matters here is
    /// whether the rendition is a single HTTP body or a manifest of fragments;
    /// see ``isSingleRequestHTTP``.
    public let transferProtocol: String?

    /// The media URL. Frequently signed and short-lived — minutes, not hours —
    /// which is why a listing is not a durable thing to persist.
    public let url: URL?

    public let width: Int?
    public let height: Int?
    public let frameRate: Double?

    /// `vcodec`, with `"none"` normalised to `nil`. See the type documentation.
    public let videoCodec: String?

    /// `acodec`, with `"none"` normalised to `nil`.
    public let audioCodec: String?

    /// `true` when the extractor said `vcodec: "none"` — an *assertion* that
    /// there is no video track, as opposed to simply not knowing.
    public let videoIsAbsent: Bool

    /// `true` when the extractor said `acodec: "none"`.
    public let audioIsAbsent: Bool

    /// Total bitrate, kbit/s.
    public let totalBitrate: Double?
    /// Video bitrate, kbit/s.
    public let videoBitrate: Double?
    /// Audio bitrate, kbit/s.
    public let audioBitrate: Double?

    /// Audio sample rate, Hz.
    public let audioSampleRate: Double?
    public let audioChannelCount: Int?

    /// Exact size in bytes, when the server told the extractor.
    public let byteCount: Int64?
    /// An estimate, when it did not. Usually bitrate × duration.
    public let approximateByteCount: Int64?

    /// The extractor's human note — `"1080p60"`, `"DASH audio"`, `"tiny"`.
    public let note: String?

    /// `"en"`, `"ja"`. Present on sites that publish alternate audio tracks,
    /// and the reason audio selection cannot always be "highest bitrate".
    public let language: String?

    /// `true` when the extractor knows the rendition is encrypted. A download
    /// of one produces a file nothing on the device can play, so this is a
    /// refusal and not a warning.
    public let hasDRM: Bool

    /// The extractor's own ordering hint, where it publishes one.
    public let quality: Double?

    // MARK: Derived

    /// Whether this rendition carries video, using `yt-dlp`'s own convention:
    /// *not* asserted absent. An unknown codec counts as present.
    public var hasVideo: Bool { !videoIsAbsent }

    /// Whether this rendition carries audio, on the same rule.
    public var hasAudio: Bool { !audioIsAbsent }

    /// A single file with both tracks already interleaved. Downloading one is
    /// the whole job — no second request, no muxing, no `AVAssetWriter`.
    public var isPreMuxed: Bool { hasVideo && hasAudio }

    /// Video with no audio. Half of a pair.
    public var isVideoOnly: Bool { hasVideo && audioIsAbsent }

    /// Audio with no video. The other half — and, on its own, the right answer
    /// for a caller that only wants the sound.
    public var isAudioOnly: Bool { hasAudio && videoIsAbsent }

    /// Whether one HTTP GET fetches the whole thing.
    ///
    /// The alternative is a manifest — HLS or DASH — which `yt-dlp` downloads
    /// as hundreds of fragments and concatenates. That works here, but it is
    /// slower, its progress reporting is fragment-counted rather than
    /// byte-counted, and the result is a stream that may need remuxing before
    /// `AVFoundation` will read it. A caller that cares can ask for only these.
    public var isSingleRequestHTTP: Bool {
        guard let transferProtocol else { return false }
        return transferProtocol == "https" || transferProtocol == "http"
    }

    /// The best size figure available, exact preferred over estimated.
    public var estimatedByteCount: Int64? { byteCount ?? approximateByteCount }

    /// Pixels, for ordering renditions whose `height` ties.
    public var pixelCount: Int? {
        guard let width, let height else { return nil }
        return width * height
    }

    /// A one-line description in the shape `yt-dlp -F` prints, for logs and for
    /// a picker.
    public var summary: String {
        var parts: [String] = [formatID]
        if let ext { parts.append(ext) }
        if let height { parts.append("\(height)p" + (frameRate.map { $0 > 30 ? String(Int($0.rounded())) : "" } ?? "")) }
        else if isAudioOnly { parts.append("audio only") }
        if let videoCodec { parts.append(videoCodec) }
        if let audioCodec { parts.append(audioCodec) }
        if let bytes = estimatedByteCount {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        if let note { parts.append("(\(note))") }
        return parts.joined(separator: " · ")
    }

    // MARK: Decoding

    private enum CodingKeys: String, CodingKey {
        case formatID = "format_id"
        case ext
        case transferProtocol = "protocol"
        case url, width, height
        case frameRate = "fps"
        case videoCodec = "vcodec"
        case audioCodec = "acodec"
        case totalBitrate = "tbr"
        case videoBitrate = "vbr"
        case audioBitrate = "abr"
        case audioSampleRate = "asr"
        case audioChannelCount = "audio_channels"
        case byteCount = "filesize"
        case approximateByteCount = "filesize_approx"
        case note = "format_note"
        case language
        case hasDRM = "has_drm"
        case quality
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // `format_id` is the one field this package treats as mandatory,
        // because it is the handle everything else is expressed in terms of. It
        // is documented as mandatory upstream too, but a few extractors emit it
        // as an integer, so it is read leniently rather than as a `String`.
        guard let identifier = try Self.decodeLenientString(container, .formatID) else {
            throw DecodingError.dataCorruptedError(
                forKey: .formatID, in: container, debugDescription: "a format has no format_id")
        }
        formatID = identifier

        ext = try Self.decodeLenientString(container, .ext)
        transferProtocol = try Self.decodeLenientString(container, .transferProtocol)
        url = try Self.decodeLenientString(container, .url).flatMap(URL.init(string:))

        width = try Self.decodeInt(container, .width)
        height = try Self.decodeInt(container, .height)
        frameRate = try Self.decodeDouble(container, .frameRate)

        let rawVideoCodec = try Self.decodeLenientString(container, .videoCodec)
        let rawAudioCodec = try Self.decodeLenientString(container, .audioCodec)
        videoIsAbsent = rawVideoCodec == "none"
        audioIsAbsent = rawAudioCodec == "none"
        videoCodec = videoIsAbsent ? nil : rawVideoCodec
        audioCodec = audioIsAbsent ? nil : rawAudioCodec

        totalBitrate = try Self.decodeDouble(container, .totalBitrate)
        videoBitrate = try Self.decodeDouble(container, .videoBitrate)
        audioBitrate = try Self.decodeDouble(container, .audioBitrate)
        audioSampleRate = try Self.decodeDouble(container, .audioSampleRate)
        audioChannelCount = try Self.decodeInt(container, .audioChannelCount)

        byteCount = try Self.decodeInt64(container, .byteCount)
        approximateByteCount = try Self.decodeInt64(container, .approximateByteCount)

        note = try Self.decodeLenientString(container, .note)
        language = try Self.decodeLenientString(container, .language)
        hasDRM = (try? container.decodeIfPresent(Bool.self, forKey: .hasDRM)) as? Bool ?? false
        quality = try Self.decodeDouble(container, .quality)
    }

    /// The memberwise initialiser, for tests and for callers constructing a
    /// selection by hand.
    public init(
        formatID: String,
        ext: String? = nil,
        transferProtocol: String? = nil,
        url: URL? = nil,
        width: Int? = nil,
        height: Int? = nil,
        frameRate: Double? = nil,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        videoIsAbsent: Bool = false,
        audioIsAbsent: Bool = false,
        totalBitrate: Double? = nil,
        videoBitrate: Double? = nil,
        audioBitrate: Double? = nil,
        audioSampleRate: Double? = nil,
        audioChannelCount: Int? = nil,
        byteCount: Int64? = nil,
        approximateByteCount: Int64? = nil,
        note: String? = nil,
        language: String? = nil,
        hasDRM: Bool = false,
        quality: Double? = nil
    ) {
        self.formatID = formatID
        self.ext = ext
        self.transferProtocol = transferProtocol
        self.url = url
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.videoIsAbsent = videoIsAbsent
        self.audioIsAbsent = audioIsAbsent
        self.totalBitrate = totalBitrate
        self.videoBitrate = videoBitrate
        self.audioBitrate = audioBitrate
        self.audioSampleRate = audioSampleRate
        self.audioChannelCount = audioChannelCount
        self.byteCount = byteCount
        self.approximateByteCount = approximateByteCount
        self.note = note
        self.language = language
        self.hasDRM = hasDRM
        self.quality = quality
    }

    // MARK: Lenient scalars
    //
    // `yt-dlp` is a thousand extractors written by a thousand people, and the
    // JSON they produce is only as consistent as the sites they scrape. `height`
    // arrives as `1080`, `"1080"` and `1080.0`; `filesize` overflows `Int` on
    // nothing but is `null` far more often than not. Decoding strictly here
    // would mean one badly-behaved extractor failing the whole listing, which is
    // a much worse outcome than a `nil` field.

    private static func decodeLenientString(
        _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) throws -> String? {
        if let text = try? container.decodeIfPresent(String.self, forKey: key) { return text }
        if let number = try? container.decodeIfPresent(Int.self, forKey: key) { return String(number) }
        return nil
    }

    private static func decodeInt(
        _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) throws -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key), value.isFinite {
            return Int(value)
        }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) { return Int(text) }
        return nil
    }

    private static func decodeInt64(
        _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) throws -> Int64? {
        if let value = try? container.decodeIfPresent(Int64.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key), value.isFinite {
            return Int64(value)
        }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) { return Int64(text) }
        return nil
    }

    private static func decodeDouble(
        _ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) throws -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key), value.isFinite {
            return value
        }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) { return Double(text) }
        return nil
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatID, forKey: .formatID)
        try container.encodeIfPresent(ext, forKey: .ext)
        try container.encodeIfPresent(transferProtocol, forKey: .transferProtocol)
        try container.encodeIfPresent(url?.absoluteString, forKey: .url)
        try container.encodeIfPresent(width, forKey: .width)
        try container.encodeIfPresent(height, forKey: .height)
        try container.encodeIfPresent(frameRate, forKey: .frameRate)
        try container.encode(videoIsAbsent ? "none" : videoCodec, forKey: .videoCodec)
        try container.encode(audioIsAbsent ? "none" : audioCodec, forKey: .audioCodec)
        try container.encodeIfPresent(totalBitrate, forKey: .totalBitrate)
        try container.encodeIfPresent(videoBitrate, forKey: .videoBitrate)
        try container.encodeIfPresent(audioBitrate, forKey: .audioBitrate)
        try container.encodeIfPresent(audioSampleRate, forKey: .audioSampleRate)
        try container.encodeIfPresent(audioChannelCount, forKey: .audioChannelCount)
        try container.encodeIfPresent(byteCount, forKey: .byteCount)
        try container.encodeIfPresent(approximateByteCount, forKey: .approximateByteCount)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encode(hasDRM, forKey: .hasDRM)
        try container.encodeIfPresent(quality, forKey: .quality)
    }
}

// MARK: - The listing

/// What an extractor knows about one media item, before anything is downloaded.
///
/// Decoded from `yt-dlp`'s info dictionary. Only the fields this package acts on
/// are modelled; the rest is deliberately dropped rather than carried as an
/// `[String: Any]`, because a typed surface that also has an untyped escape
/// hatch is one that every caller eventually reaches through.
public struct MediaListing: Sendable, Equatable, Codable {

    /// The extractor's id for the item — a YouTube video id, say.
    public let id: String

    public let title: String?

    /// `"youtube"`, `"twitter"`, `"generic"`. Which extractor claimed the URL,
    /// which is the single most useful thing in a bug report.
    public let extractor: String?

    /// The page the item was extracted from, canonicalised by the extractor.
    public let webpageURL: URL?

    /// Seconds. `nil` for a live stream and for extractors that do not publish
    /// one.
    public let duration: TimeInterval?

    /// `true` for a stream with no end. Downloading one never finishes on its
    /// own, which is a fact a caller has to be told before it starts rather
    /// than after.
    public let isLive: Bool

    public let uploader: String?

    /// Every rendition the extractor found, in its own order.
    public let formats: [MediaFormat]

    /// The extractor's own recommended container for a merged result, when it
    /// publishes one.
    public let preferredContainer: String?

    private enum CodingKeys: String, CodingKey {
        case id, title, extractor, duration, uploader, formats
        case webpageURL = "webpage_url"
        case isLive = "is_live"
        case preferredContainer = "ext"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(String.self, forKey: .id)) as? String ?? ""
        title = try? container.decodeIfPresent(String.self, forKey: .title)
        extractor = try? container.decodeIfPresent(String.self, forKey: .extractor)
        webpageURL = (try? container.decodeIfPresent(String.self, forKey: .webpageURL))
            .flatMap { $0 }.flatMap(URL.init(string:))
        duration = {
            if let value = try? container.decodeIfPresent(Double.self, forKey: .duration) { return value }
            return nil
        }()
        isLive = ((try? container.decodeIfPresent(Bool.self, forKey: .isLive)) as? Bool) ?? false
        uploader = try? container.decodeIfPresent(String.self, forKey: .uploader)

        // Per-element leniency, and it has to be per-element.
        //
        // `yt-dlp` is a thousand extractors written by a thousand people, and
        // one of them emitting a rendition this decoder cannot read must not
        // take the other forty with it — which is exactly what decoding the
        // array as a whole does, whether it throws or is swallowed by a `try?`.
        // A rendition with no `format_id` is unusable on its own terms, since
        // the id is the handle every later request is expressed in, so it is
        // dropped rather than repaired.
        let wrapped = try? container.decodeIfPresent([FailableFormat].self, forKey: .formats)
        formats = (wrapped ?? [])?.compactMap(\.format) ?? []
        preferredContainer = try? container.decodeIfPresent(String.self, forKey: .preferredContainer)
    }

    public init(
        id: String,
        title: String? = nil,
        extractor: String? = nil,
        webpageURL: URL? = nil,
        duration: TimeInterval? = nil,
        isLive: Bool = false,
        uploader: String? = nil,
        formats: [MediaFormat],
        preferredContainer: String? = nil
    ) {
        self.id = id
        self.title = title
        self.extractor = extractor
        self.webpageURL = webpageURL
        self.duration = duration
        self.isLive = isLive
        self.uploader = uploader
        self.formats = formats
        self.preferredContainer = preferredContainer
    }

    /// Renditions that are a complete file on their own.
    public var preMuxedFormats: [MediaFormat] { formats.filter(\.isPreMuxed) }
    /// Renditions carrying only video.
    public var videoOnlyFormats: [MediaFormat] { formats.filter(\.isVideoOnly) }
    /// Renditions carrying only audio.
    public var audioOnlyFormats: [MediaFormat] { formats.filter(\.isAudioOnly) }

    /// The tallest rendition of any kind, which is the ceiling a caller can
    /// reach *if* muxing is allowed.
    public var maximumHeight: Int? { formats.compactMap(\.height).max() }

    /// The tallest rendition that needs no muxing — the ceiling with muxing
    /// switched off.
    public var maximumPreMuxedHeight: Int? { preMuxedFormats.compactMap(\.height).max() }

    /// `yt-dlp -F`, more or less.
    public var formatTable: String {
        ([title ?? id] + formats.map { "  " + $0.summary }).joined(separator: "\n")
    }
}

/// A `MediaFormat` that decodes to `nil` instead of throwing.
///
/// The mechanism behind the per-element leniency above. Written as a wrapper
/// type rather than as a `try?` inside an unkeyed-container loop because a
/// failed `decode` on an unkeyed container is not specified to advance its
/// index — a loop built that way either spins forever or skips an element,
/// depending on the decoder, and which one it does is not something this
/// package should be relying on.
private struct FailableFormat: Decodable {
    let format: MediaFormat?

    init(from decoder: any Decoder) throws {
        format = try? MediaFormat(from: decoder)
    }
}
