import Foundation

/// What a caller wants out of a listing, expressed as constraints rather than
/// as a `yt-dlp` format string.
///
/// ## Why not just pass `yt-dlp` a format expression
///
/// Because the expression is the wrong side of the boundary. `yt-dlp`'s
/// selector language can ask for `bestvideo+bestaudio`, and getting that answer
/// commits `yt-dlp` to **merging the two streams with `ffmpeg`** — which is a
/// `subprocess` call, which PEP 730 makes impossible on iOS. The merge decision
/// has to be made *here*, in Swift, because here is where there is an
/// `AVAssetWriter` to make it with.
///
/// So this package never hands `yt-dlp` a compound format expression. It asks
/// for the listing, chooses in Swift, and then asks for one concrete format id
/// at a time — which is the one shape of request that provably invokes no
/// post-processor.
public struct FormatPolicy: Sendable, Equatable {

    /// What the caller is downloading *for*.
    public enum Intent: Sendable, Equatable {
        /// Video with sound. Will mux when that is the only way to get it and
        /// ``allowsMuxing`` permits.
        case audioVisual
        /// Sound only. Never muxes, never downloads a video track.
        case audioOnly
        /// Picture only — a silent clip. Rare, but it is the cheap way to get
        /// the highest-resolution track when the audio is going to be replaced.
        case videoOnly
    }

    public var intent: Intent = .audioVisual

    /// The tallest video accepted, in pixels. `nil` means no ceiling.
    ///
    /// A ceiling is not only about bandwidth: an 8K AV1 rendition is a file
    /// most devices cannot decode in real time, and getting one is a worse
    /// outcome than getting 1080p.
    public var maximumHeight: Int?

    /// Refuse anything bigger than this, in bytes, when the size is known.
    ///
    /// Renditions whose size is *unknown* are not refused by this — refusing
    /// them would rule out every HLS stream on the internet, since a manifest
    /// publishes no total. A caller that wants a hard cap has to enforce it
    /// during the download too.
    public var maximumByteCount: Int64?

    /// Whether a video-plus-audio pair may be downloaded separately and joined
    /// with ``StreamMuxer``.
    ///
    /// `true` by default, because on the largest site in the extractor list it
    /// is the difference between 360p and 4K — see ``FormatSelector`` for the
    /// measurement. Set it to `false` for the conservative path: one file, one
    /// request, no `AVAssetWriter`, and whatever quality the site publishes
    /// pre-muxed.
    public var allowsMuxing: Bool = true

    /// Restrict to renditions a single HTTP GET fetches — no HLS, no DASH.
    ///
    /// `false` by default. Fragmented protocols work, but their progress is
    /// counted in fragments rather than bytes and the concatenated result is
    /// more likely to need a remux before `AVFoundation` will open it.
    public var requiresSingleRequestHTTP: Bool = false

    /// Container extensions to prefer, most-preferred first, when renditions
    /// are otherwise equal — `["mp4", "m4a"]` for a result that
    /// `AVFoundation` will certainly open.
    ///
    /// A *preference*, never a filter: a policy that turned this into a
    /// requirement would find nothing on a site that publishes only WebM.
    public var preferredContainers: [String] = ["mp4", "m4a"]

    /// Preferred audio language, when the item publishes several.
    public var preferredLanguage: String?

    public init(
        intent: Intent = .audioVisual,
        maximumHeight: Int? = nil,
        maximumByteCount: Int64? = nil,
        allowsMuxing: Bool = true,
        requiresSingleRequestHTTP: Bool = false,
        preferredContainers: [String] = ["mp4", "m4a"],
        preferredLanguage: String? = nil
    ) {
        self.intent = intent
        self.maximumHeight = maximumHeight
        self.maximumByteCount = maximumByteCount
        self.allowsMuxing = allowsMuxing
        self.requiresSingleRequestHTTP = requiresSingleRequestHTTP
        self.preferredContainers = preferredContainers
        self.preferredLanguage = preferredLanguage
    }

    /// The best audio-visual result the device can get, muxing when needed.
    public static let best = FormatPolicy()

    /// The best result obtainable **without** muxing: one file, one request.
    ///
    /// The floor this package promises. It is correct as a floor and wrong as a
    /// default — see ``FormatSelector`` for what it costs on YouTube.
    public static let preMuxedOnly = FormatPolicy(allowsMuxing: false)

    /// Sound only, best available.
    public static let audio = FormatPolicy(intent: .audioOnly)

    /// A ceiling that most devices decode comfortably and most networks carry.
    public static func upTo(height: Int) -> FormatPolicy {
        FormatPolicy(maximumHeight: height)
    }
}

// MARK: - The decision

/// Which rendition, or which pair of renditions, a download will fetch.
///
/// The muxing decision in one value: `.single` needs no `AVAssetWriter` and
/// `.pair` does. Everything downstream — how many requests, how progress is
/// apportioned, whether a temporary directory is needed — follows from which
/// case this is, which is why it is an enum and not a struct with a flag.
public enum FormatSelection: Sendable, Equatable {

    /// One rendition, downloaded and kept as it arrives.
    ///
    /// Covers three cases that behave identically: a pre-muxed file, an
    /// audio-only file the caller asked for, and a video-only file the caller
    /// asked for.
    case single(MediaFormat)

    /// Two renditions to fetch separately and join.
    case pair(video: MediaFormat, audio: MediaFormat)

    /// Whether ``StreamMuxer`` will be involved.
    public var needsMuxing: Bool {
        if case .pair = self { return true }
        return false
    }

    /// The format ids to hand back to `yt-dlp`, in download order.
    ///
    /// Video first: it is the larger of the two and the one most likely to
    /// fail, and finding that out before spending the audio download is worth
    /// the ordering.
    public var formatIDs: [String] {
        switch self {
        case let .single(format): [format.formatID]
        case let .pair(video, audio): [video.formatID, audio.formatID]
        }
    }

    /// Every rendition in the selection.
    public var formats: [MediaFormat] {
        switch self {
        case let .single(format): [format]
        case let .pair(video, audio): [video, audio]
        }
    }

    /// The tallest video in the selection, when there is video at all.
    public var height: Int? { formats.compactMap(\.height).max() }

    /// Total bytes, when every part published a size. `nil` when any did not —
    /// a partial total is worse than none, because a progress bar built on one
    /// runs past 100%.
    public var estimatedByteCount: Int64? {
        let counts = formats.map(\.estimatedByteCount)
        guard !counts.contains(where: { $0 == nil }) else { return nil }
        return counts.compactMap { $0 }.reduce(0, +)
    }

    /// The container the result should be written as.
    public var containerExtension: String {
        switch self {
        case let .single(format): format.ext ?? "mp4"
        case .pair: "mp4"
        }
    }

    public var summary: String {
        switch self {
        case let .single(format):
            "single format — \(format.summary)"
        case let .pair(video, audio):
            "mux two formats —\n    video: \(video.summary)\n    audio: \(audio.summary)"
        }
    }
}

// MARK: - The selector

/// Turns a listing and a policy into a ``FormatSelection``.
///
/// **Entirely pure.** No interpreter, no network, no file system — which is
/// what lets the whole of this package's format reasoning be tested against
/// fixture JSON captured from `yt-dlp --dump-json`.
///
/// ## The measurement that shaped the default
///
/// The tempting design is "prefer pre-muxed, fall back to muxing". It is
/// backwards, and the reason is worth recording because it will not be obvious
/// to whoever reads this next:
///
/// **YouTube has essentially stopped publishing pre-muxed renditions.** Against
/// `yt-dlp` 2026.8.19, a 4K test video returned 53 renditions from the default
/// client set and **not one of them carried both tracks**. Forcing an older
/// client shape does surface exactly one — format `18`, 360p H.264/AAC — and
/// that is the entire pre-muxed catalogue. The 720p pre-muxed format that this
/// fallback used to be worth having is gone.
///
/// So "pre-muxed only" is not a mild quality cap on YouTube. It is 360p, or
/// nothing at all depending on which client answered. Muxing is the normal path
/// and the pre-muxed path is the degraded one, which is the opposite of how it
/// reads — hence ``FormatPolicy/allowsMuxing`` defaulting to `true`.
public enum FormatSelector {

    /// Chooses what to download.
    ///
    /// - Throws: ``MediaFetchError/noUsableFormat(reason:)`` when the policy
    ///   rules everything out. The reason names the constraint that did it,
    ///   because "no formats available" against a listing that visibly has
    ///   fifty is the least useful error a downloader can produce.
    public static func select(from listing: MediaListing, policy: FormatPolicy = .best) throws -> FormatSelection {
        guard !listing.formats.isEmpty else {
            throw MediaFetchError.noUsableFormat(reason: "the extractor returned no formats at all")
        }

        let candidates = listing.formats.filter { admissible($0, under: policy) }
        guard !candidates.isEmpty else {
            throw MediaFetchError.noUsableFormat(reason: rejectionReason(listing, policy))
        }

        switch policy.intent {
        case .audioOnly:
            let audio = candidates.filter(\.isAudioOnly)
            if let best = bestAudio(from: audio.isEmpty ? candidates.filter(\.hasAudio) : audio, policy: policy) {
                return .single(best)
            }
            throw MediaFetchError.noUsableFormat(reason: "nothing in this listing carries audio")

        case .videoOnly:
            let video = candidates.filter(\.isVideoOnly)
            if let best = bestVideo(from: video.isEmpty ? candidates.filter(\.hasVideo) : video, policy: policy) {
                return .single(best)
            }
            throw MediaFetchError.noUsableFormat(reason: "nothing in this listing carries video")

        case .audioVisual:
            return try selectAudioVisual(from: candidates, in: listing, policy: policy)
        }
    }

    private static func selectAudioVisual(
        from candidates: [MediaFormat], in listing: MediaListing, policy: FormatPolicy
    ) throws -> FormatSelection {
        let preMuxed = bestVideo(from: candidates.filter(\.isPreMuxed), policy: policy)

        guard policy.allowsMuxing else {
            guard let preMuxed else {
                throw MediaFetchError.noUsableFormat(
                    reason: "no rendition carries both video and audio, and this policy does not allow muxing. "
                        + "Set FormatPolicy.allowsMuxing to true to download the tracks separately and join them.")
            }
            return .single(preMuxed)
        }

        // A pair is going to be joined into an MPEG-4 file, so the pair is
        // chosen from renditions an MPEG-4 file can hold. Without this filter
        // the tallest rendition wins on merit and then fails at the muxer,
        // which on the sites that publish VP9 beside AV1 is most of the time —
        // and the failure arrives after both streams have been downloaded,
        // which is the worst possible moment to discover it.
        //
        // Note this is a filter on the *pair* path only. A pre-muxed rendition
        // is kept exactly as it arrives and never opened by AVFoundation here,
        // so its codec is not this package's business.
        let videoPool = candidates.filter { $0.isVideoOnly && StreamMuxer.canMuxVideo($0) }
        let audioPool = candidates.filter { $0.isAudioOnly && StreamMuxer.canMuxAudio($0) }

        // A *vetted* half is one the muxer will actually be able to open.
        //
        // Two conditions, and both were learned the expensive way. The codec
        // has to be known, because `canMuxVideo`/`canMuxAudio` deliberately
        // pass a codec they cannot see — the right rule for them, since
        // refusing to judge is not the same as judging badly, but it means an
        // unknown codec reaches this point unexamined. And the rendition has
        // to arrive in one request, because a manifest is downloaded as
        // fragments and concatenated, and what comes out is not always
        // something `AVFoundation` will open.
        //
        // Both were true of YouTube's format 233, which is an HLS audio
        // manifest reporting no codec at all. It looked like the best audio
        // half available, passed every check, and failed in the muxer — after
        // the 4K video half had already been fetched.
        let vettedVideo = videoPool.filter { $0.videoCodec != nil && $0.isSingleRequestHTTP }
        let vettedAudio = audioPool.filter { $0.audioCodec != nil && $0.isSingleRequestHTTP }
        let hasVettedPair = !vettedVideo.isEmpty && !vettedAudio.isEmpty

        // Falling back to the unvetted pool rather than refusing: a site that
        // publishes nothing but manifests is common, and a fragmented download
        // that might need remuxing still beats no download at all.
        let video = bestVideo(from: vettedVideo.isEmpty ? videoPool : vettedVideo, policy: policy)
        let audio = bestAudio(from: vettedAudio.isEmpty ? audioPool : vettedAudio, policy: policy)

        // A pair is only worth the second request and the mux when it actually
        // beats the pre-muxed rendition. On a site that still publishes a
        // full-quality progressive file, it does not, and taking it anyway
        // would be paying for a re-container for nothing.
        if let video, let audio {
            // A pre-muxed rendition wins on a tie of height, and wins outright
            // when the pair could not be vetted. The second half of that is the
            // important one: an unvettable pair might fail in the muxer after
            // both halves have been downloaded, while a pre-muxed rendition is
            // copied through and never opened here at all. Taking a smaller
            // file that certainly works over a larger one that might not is the
            // right trade at the point where the alternative costs a gigabyte
            // to discover.
            if let preMuxed, !hasVettedPair || (preMuxed.height ?? 0) >= (video.height ?? 0) {
                return .single(preMuxed)
            }
            return .pair(video: video, audio: audio)
        }

        if let preMuxed { return .single(preMuxed) }

        // Nothing pre-muxed and no usable pair. Which half was missing is the
        // whole of the diagnostic, and "no formats available" against a listing
        // with fifty of them is the least useful thing a downloader can say.
        let anyVideo = candidates.contains(where: \.isVideoOnly)
        let anyAudio = candidates.contains(where: \.isAudioOnly)
        if anyVideo && video == nil {
            let codecs = Set(candidates.filter(\.isVideoOnly).compactMap(\.videoCodec)).sorted()
            throw MediaFetchError.noUsableFormat(
                reason: "every video rendition here is in a codec an MPEG-4 file cannot hold"
                    + (codecs.isEmpty ? "" : " (\(codecs.joined(separator: ", ")))")
                    + ", so none of them can be joined to an audio track")
        }
        if anyAudio && audio == nil {
            let codecs = Set(candidates.filter(\.isAudioOnly).compactMap(\.audioCodec)).sorted()
            throw MediaFetchError.noUsableFormat(
                reason: "every audio rendition here is in a codec an MPEG-4 file cannot hold"
                    + (codecs.isEmpty ? "" : " (\(codecs.joined(separator: ", ")))"))
        }
        if anyVideo {
            throw MediaFetchError.noUsableFormat(
                reason: "this listing has video renditions but no separate audio rendition to pair with one, "
                    + "and nothing pre-muxed")
        }

        // No video among the *candidates*. When the listing had video and the
        // policy took it away, say which constraint did it — the caller set
        // that constraint and can change it, which is not true of anything else
        // that could be reported here.
        if let ceiling = policy.maximumHeight, listing.formats.contains(where: \.hasVideo) {
            let shortest = listing.formats.filter(\.hasVideo).compactMap(\.height).min()
            throw MediaFetchError.noUsableFormat(
                reason: "the policy caps height at \(ceiling)px"
                    + (shortest.map { " and the shortest video rendition here is \($0)px" } ?? "")
                    + ", so no video rendition qualifies")
        }
        throw MediaFetchError.noUsableFormat(
            reason: "this listing has no rendition carrying video")
    }

    // MARK: Admission

    /// Whether a rendition survives the policy's hard constraints.
    ///
    /// Hard constraints only. Preferences — container, language — are applied
    /// in the ordering, not here, so that a preference can never be the reason
    /// nothing is found.
    static func admissible(_ format: MediaFormat, under policy: FormatPolicy) -> Bool {
        if format.hasDRM { return false }
        if format.url == nil { return false }
        if policy.requiresSingleRequestHTTP && !format.isSingleRequestHTTP { return false }
        if let ceiling = policy.maximumHeight, let height = format.height, height > ceiling { return false }
        if let cap = policy.maximumByteCount, let bytes = format.byteCount, bytes > cap { return false }
        return true
    }

    /// Why nothing survived, named as specifically as the evidence allows.
    private static func rejectionReason(_ listing: MediaListing, _ policy: FormatPolicy) -> String {
        if listing.formats.allSatisfy(\.hasDRM) {
            return "every rendition is DRM-protected, so none of them can be played once downloaded"
        }
        if policy.requiresSingleRequestHTTP,
            listing.formats.allSatisfy({ !$0.isSingleRequestHTTP })
        {
            let protocols = Set(listing.formats.compactMap(\.transferProtocol)).sorted()
            return "the policy requires a single-request HTTP rendition and this item publishes only "
                + protocols.joined(separator: ", ")
        }
        if let ceiling = policy.maximumHeight, let shortest = listing.formats.compactMap(\.height).min(),
            shortest > ceiling
        {
            return "the policy caps height at \(ceiling)px and the shortest rendition here is \(shortest)px"
        }
        if let cap = policy.maximumByteCount {
            return "every rendition with a published size is larger than the \(cap)-byte cap"
        }
        return "no rendition satisfies the policy"
    }

    // MARK: Ordering
    //
    // Sorting rather than a fold, because the tie-breaks matter and a chain of
    // `max(by:)` comparisons is where they go wrong. Ordering is
    // *descending by desirability*, so `first` is the answer.

    static func bestVideo(from formats: [MediaFormat], policy: FormatPolicy) -> MediaFormat? {
        formats.max { left, right in
            videoRank(left, policy).lexicographicallyPrecedes(videoRank(right, policy))
        }
    }

    static func bestAudio(from formats: [MediaFormat], policy: FormatPolicy) -> MediaFormat? {
        formats.max { left, right in
            audioRank(left, policy).lexicographicallyPrecedes(audioRank(right, policy))
        }
    }

    /// A lexicographic rank, most significant first. Tuples of `Double` so that
    /// a missing figure sorts below a present one without a special case.
    private static func videoRank(_ format: MediaFormat, _ policy: FormatPolicy) -> [Double] {
        [
            Double(format.height ?? 0),
            Double(format.pixelCount ?? 0),
            format.frameRate ?? 0,
            containerScore(format, policy),
            format.videoBitrate ?? format.totalBitrate ?? 0,
            format.isSingleRequestHTTP ? 1 : 0,
        ]
    }

    private static func audioRank(_ format: MediaFormat, _ policy: FormatPolicy) -> [Double] {
        [
            languageScore(format, policy),
            containerScore(format, policy),
            format.audioBitrate ?? format.totalBitrate ?? 0,
            format.audioSampleRate ?? 0,
            Double(format.audioChannelCount ?? 0),
            format.isSingleRequestHTTP ? 1 : 0,
        ]
    }

    /// Higher is better; `0` for a container the policy did not name, so an
    /// unlisted container is never *worse* than being absent from the list.
    private static func containerScore(_ format: MediaFormat, _ policy: FormatPolicy) -> Double {
        guard let ext = format.ext,
            let index = policy.preferredContainers.firstIndex(of: ext)
        else { return 0 }
        return Double(policy.preferredContainers.count - index)
    }

    private static func languageScore(_ format: MediaFormat, _ policy: FormatPolicy) -> Double {
        guard let wanted = policy.preferredLanguage else { return 0 }
        guard let language = format.language else { return 0 }
        if language == wanted { return 2 }
        // `en-US` should still beat `ja` when `en` was asked for.
        if language.hasPrefix(wanted) || wanted.hasPrefix(language) { return 1 }
        return -1
    }
}
