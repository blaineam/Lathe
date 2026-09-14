import Foundation
import LatheCore

// The audio transcode *vocabulary*: what a caller asks for, what it is told
// about the source, and what it is told happened. The engine that honours it is
// ``AudioTranscoder``; the read-only half is ``AudioInspector``.

// MARK: - Target codecs

/// Audio codecs Lathe can **write**.
///
/// Two members, and the absences are the interesting part.
///
/// **There is no `.opus`.** AVFoundation decodes Opus and cannot encode it —
/// there is no `kAudioFormatOpus` encoder on any Apple platform, and
/// `AVAssetWriter` refuses an input configured for one. A case here would be a
/// promise nothing can keep, and the alternative habit — accepting `.opus` and
/// quietly writing AAC instead — is worse than refusing, because the caller
/// asked for Opus for a reason and would never learn it did not get it. Naming
/// an Opus destination is therefore refused by name; see
/// ``AudioTranscoder`` and ``AudioContainer``.
///
/// **There is no `.mp3` either**, for the same reason and with less excuse: MP3
/// is read everywhere on these platforms and written nowhere. If the goal is a
/// file that plays on hardware from 2004, this package cannot produce it.
///
/// **There is no `.flac`.** AVFoundation decodes FLAC (so a FLAC source is a
/// perfectly good input, and a *lossless* one), but `AVFileType` has no FLAC
/// member and the writer cannot mux it. ``appleLossless`` is the lossless
/// target that exists here.
public enum AudioCodec: String, Sendable, Hashable, CaseIterable {
    /// MPEG-4 AAC-LC. The primary target: universally playable, and the only
    /// codec here that makes a file meaningfully smaller.
    case aac

    /// Apple Lossless. Bit-exact, typically 40–60% of PCM, and only worth
    /// asking for when the **source is itself lossless** — see
    /// ``LossySourceRule``, which refuses the alternative by default.
    case appleLossless

    /// Whether this codec reproduces its input exactly.
    public var isLossless: Bool { self == .appleLossless }

    /// The name this codec is reported under in ``AudioStreamInfo/codecName``.
    public var codecName: String {
        switch self {
        case .aac: "aac"
        case .appleLossless: "alac"
        }
    }
}

/// The containers this package will write, named by the destination's
/// extension.
///
/// Named rather than sniffed, and refused rather than guessed — the same rule
/// the video path uses. A container that cannot hold the requested codec is a
/// file that plays nowhere, and finding that out at `finishWriting` is far too
/// late.
public enum AudioContainer: String, Sendable, Hashable, CaseIterable {
    /// MPEG-4 audio. The default and the right answer for both codecs: AAC and
    /// ALAC both live here, and iTunes-style metadata atoms — including cover
    /// art — come with it.
    case m4a
    /// MPEG-4. Identical machinery to ``m4a``; some consumers insist on the
    /// extension.
    case mp4
    /// Core Audio Format. Takes both codecs, carries no iTunes atoms, and is
    /// useful mainly for very long files: CAF's offset table is 64-bit where
    /// MPEG-4's is not.
    case caf

    /// The container an extension names, or `nil` when it names none this
    /// package writes.
    public init?(fileExtension: String) {
        switch fileExtension.lowercased() {
        case "m4a", "m4b": self = .m4a
        case "mp4": self = .mp4
        case "caf": self = .caf
        default: return nil
        }
    }

    /// Whether this container carries iTunes-style metadata atoms — which is
    /// where a title, an artist and, critically, the cover art live.
    public var carriesITunesMetadata: Bool { self != .caf }
}

// MARK: - Channels

/// What happens to the source's channels.
///
/// The default is ``preserve`` because the alternative is the failure mode this
/// enum exists to prevent: **a transcoder that silently turns 5.1 into stereo**
/// (or, worse, into the front two channels with the dialogue centre discarded)
/// looks like it worked, produces a plausibly smaller file, and cannot be
/// undone. Whatever happens here is reported as
/// ``AudioTranscodeResult/channels``, so a caller can check rather than trust.
///
/// Note what none of these can do: **add** channels. A mono source stays mono
/// under every policy, because upmixing grows the file by exactly the size of
/// the information it does not add.
public enum ChannelPolicy: Sendable, Equatable {
    /// Keep the source's channel count and its channel layout. The default.
    ///
    /// Preserving more than two channels requires the source's
    /// `AudioChannelLayout`, because an AAC encoder cannot be configured for 6
    /// channels without being told *which* six. Where a multi-channel source
    /// carries no readable layout, this degrades to a stereo downmix rather
    /// than failing, and says so in
    /// ``AudioTranscodeResult/channels``.
    case preserve

    /// Mix down to at most two channels. A mono source stays mono.
    case downmixToStereo

    /// Mix down to at most `count` channels. Never upmixes.
    case atMost(Int)

    /// The channel count this policy asks for, given the source's.
    func resolve(sourceChannels: Int) -> Int {
        let source = max(1, sourceChannels)
        switch self {
        case .preserve: return source
        // `min` is the whole no-upmix rule, in both remaining cases.
        case .downmixToStereo: return min(source, 2)
        case let .atMost(count): return min(source, max(1, count))
        }
    }
}

/// What actually happened to the channels. Reported, not assumed.
public enum AppliedChannelPolicy: Sendable, Equatable {
    /// The output has the source's channel count.
    case preserved(channels: Int)
    /// The output has fewer channels than the source, because the caller asked.
    case downmixed(from: Int, to: Int)
    /// The output has fewer channels than the source **although
    /// ``ChannelPolicy/preserve`` was asked for**, because the source's channel
    /// layout could not be read and a multi-channel encoder cannot be
    /// configured without one.
    ///
    /// A distinct case rather than a flag on ``downmixed(from:to:)`` because it
    /// is the one outcome the caller did not ask for, and a batch that hits it
    /// on an audiobook or a concert film should be able to notice.
    case downmixedForWantOfALayout(from: Int, to: Int)

    public var outputChannelCount: Int {
        switch self {
        case let .preserved(channels): channels
        case let .downmixed(_, to): to
        case let .downmixedForWantOfALayout(_, to): to
        }
    }
}

// MARK: - The lossy-source rule

/// When an **already-lossy** source may be re-encoded.
///
/// This is the rule the whole module is built around, so it is worth stating
/// plainly: *transcoding a 128 kbps MP3 to 128 kbps AAC makes the file sound
/// worse and does not reliably make it smaller.* Lossy codecs throw away what
/// the psychoacoustic model says will not be missed; run a second one over the
/// result and it throws away a second helping, from material whose artefacts it
/// now has to spend bits encoding. Two generations of loss, sometimes for a
/// *larger* file. An optimiser that does that across a library is worse than
/// one that does nothing, because doing nothing is at least reversible.
///
/// So the default is ``requireSavings(fraction:)`` at 0.75: a lossy source is
/// re-encoded only when the target bitrate is at most three-quarters of the
/// source's — enough of a drop that the size win pays for the generation loss.
/// Anything else is **skipped, not failed**: ``AudioTranscodeResult/outcome``
/// comes back as ``AudioTranscodeOutcome/skipped(_:)``, the destination is not
/// written at all, and the caller keeps its original. A lossless source is not
/// governed by this rule; see ``AudioSkipReason``.
public enum LossySourceRule: Sendable, Equatable {
    /// Re-encode a lossy source only when the target bitrate is at most
    /// `fraction` of the source's.
    ///
    /// `fraction` is clamped to `0...1`. At `1.0` any reduction at all counts,
    /// which is not the same as ``allow`` — it still refuses a *bitrate
    /// increase*, which is the single most common way a "compression" batch
    /// grows a library.
    ///
    /// **A source whose bitrate cannot be determined is skipped under this
    /// rule**, rather than re-encoded on the assumption that it was probably
    /// big. There is no way to prove a saving against an unknown number, and
    /// guessing here is how the generation-loss trap is sprung.
    case requireSavings(fraction: Double)

    /// Re-encode regardless. For a caller that has decided, for its own
    /// reasons, that a second generation of loss is acceptable.
    case allow

    /// Never re-encode a lossy source. The setting for a library where lossy
    /// material is considered already-final.
    case never

    /// The default: a target bitrate at or below three-quarters of the
    /// source's.
    public static let `default` = LossySourceRule.requireSavings(fraction: 0.75)
}

// MARK: - Outcomes

/// Why a transcode was not performed.
///
/// Every case carries the numbers behind the decision, because "skipped" with no
/// explanation is indistinguishable from a bug, and a caller that disagrees
/// needs to know what to override.
public enum AudioSkipReason: Sendable, Equatable {
    /// The source is already lossy and the requested target bitrate is not
    /// meaningfully below its own. See ``LossySourceRule``.
    case lossySourceWithoutMeaningfulSavings(
        sourceBitsPerSecond: Int,
        targetBitsPerSecond: Int,
        requiredFraction: Double
    )

    /// The source is already lossy and its bitrate could not be determined, so
    /// no saving can be proved. See ``LossySourceRule/requireSavings(fraction:)``.
    case lossySourceWithUnknownBitrate

    /// The source is already lossy and ``LossySourceRule/never`` was in force.
    case lossySourceRefusedByRule

    /// A lossy source was asked to be re-encoded to a **lossless** target.
    ///
    /// Always a mistake, and an expensive one: ALAC cannot restore what the
    /// lossy encoder discarded, so this buys a file three to five times larger
    /// that sounds exactly the same. Overridable with ``LossySourceRule/allow``
    /// for the one legitimate case — an archival pipeline that wants everything
    /// in one container.
    case losslessTargetForLossySource(sourceCodec: String)

    /// The transcode ran and produced a file **larger** than the source, so it
    /// was discarded and the destination left alone.
    ///
    /// The last line of defence: the bitrate arithmetic above is a prediction,
    /// and an encoder is entitled to disagree with it. Disable with
    /// `keepLargerOutput`.
    case outputWouldBeLarger(inputByteCount: UInt64, outputByteCount: UInt64)
}

/// What the transcoder did.
public enum AudioTranscodeOutcome: Sendable, Equatable {
    /// A file was written to the destination.
    case transcoded
    /// Nothing was written, and the destination is exactly as it was.
    case skipped(AudioSkipReason)

    public var wasTranscoded: Bool {
        if case .transcoded = self { return true }
        return false
    }

    public var skipReason: AudioSkipReason? {
        if case let .skipped(reason) = self { return reason }
        return nil
    }
}

// MARK: - Request

/// One audio transcode.
public struct AudioTranscodeRequest: Sendable {
    public var source: URL

    /// Where to write. The extension picks the container — see
    /// ``AudioContainer`` — and the file is left untouched unless the transcode
    /// completes.
    public var destination: URL

    public var codec: AudioCodec

    /// ``QualityTarget/quality(_:)`` and ``QualityTarget/averageBitrate(_:)``
    /// are honoured for ``AudioCodec/aac``; ``QualityTarget/lossless`` is the
    /// only value accepted for ``AudioCodec/appleLossless``, which has no
    /// quality knob to turn. ``QualityTarget/constantQualityFactor(_:)`` is a
    /// VideoToolbox concept and is refused rather than reinterpreted.
    ///
    /// See ``AudioTranscoder/bitrate(for:channels:)`` for the exact mapping from
    /// a normalised quality to a bitrate — it is arithmetic rather than a mood,
    /// precisely so that ``LossySourceRule`` has a number to compare against.
    public var quality: QualityTarget

    /// Output sample rate in hertz, or `nil` to keep the source's.
    ///
    /// **Clamped to the source's rate**: asking for 48 kHz from a 22 kHz source
    /// resamples nothing into existence and costs a little over twice the bytes.
    /// This is the audio spelling of the no-upscale rule the image and video
    /// paths already enforce.
    public var sampleRate: Int?

    public var channels: ChannelPolicy
    public var metadata: MetadataPolicy
    public var forcePreserve: MetadataForcePreserve

    /// When a lossy source may be re-encoded. See ``LossySourceRule``.
    public var lossySources: LossySourceRule

    /// Keep an output that came out larger than the source.
    ///
    /// `false` by default: a compression pass that grows a file has failed at
    /// the only thing it was asked to do, and the default is to throw the
    /// result away and report
    /// ``AudioSkipReason/outputWouldBeLarger(inputByteCount:outputByteCount:)``
    /// rather than to replace a good file with a worse, bigger one.
    public var keepLargerOutput: Bool

    public init(
        source: URL,
        destination: URL,
        codec: AudioCodec = .aac,
        quality: QualityTarget = .quality(0.5),
        sampleRate: Int? = nil,
        channels: ChannelPolicy = .preserve,
        metadata: MetadataPolicy = .preserveAll,
        forcePreserve: MetadataForcePreserve = .default,
        lossySources: LossySourceRule = .default,
        keepLargerOutput: Bool = false
    ) {
        self.source = source
        self.destination = destination
        self.codec = codec
        self.quality = quality
        self.sampleRate = sampleRate
        self.channels = channels
        self.metadata = metadata
        self.forcePreserve = forcePreserve
        self.lossySources = lossySources
        self.keepLargerOutput = keepLargerOutput
    }
}

// MARK: - Result

/// What the transcode did — measured from the written file, not assumed from
/// the settings handed to the encoder.
///
/// ``source`` and ``destination`` are the same type, so "what did this cost me"
/// is a comparison rather than an exercise in matching up loose fields.
public struct AudioTranscodeResult: Sendable, Equatable {

    /// The file written, or `nil` when ``outcome`` is
    /// ``AudioTranscodeOutcome/skipped(_:)``.
    ///
    /// Optional on purpose: a skip leaves *nothing* at the destination, and a
    /// non-optional URL pointing at a file that may not exist is how a batch
    /// ends up deleting originals it never replaced.
    public var output: URL?

    public var outcome: AudioTranscodeOutcome

    /// The source's codec, bitrate, sample rate, channel count and duration.
    public var source: AudioStreamInfo

    /// The same facts about what was written, read back from the file. `nil`
    /// when skipped.
    public var destination: AudioStreamInfo?

    public var inputByteCount: UInt64
    /// `0` when skipped.
    public var outputByteCount: UInt64
    public var wallTime: TimeInterval

    /// What happened to the channels. See ``AppliedChannelPolicy``.
    public var channels: AppliedChannelPolicy

    /// Container-level metadata items written to the output.
    public var metadataItemsWritten: Int

    /// Whether album artwork made it across.
    ///
    /// Called out separately from ``metadataItemsWritten`` because it is the one
    /// metadata loss a user sees immediately, across a whole library, in a grid
    /// of grey squares.
    public var carriedArtwork: Bool

    /// Chapters found in the source and **not** carried across.
    ///
    /// Non-zero means the output lost them. See ``AudioTranscoder`` on why they
    /// are not written, and ``AudioInspector`` for how to detect them before
    /// starting.
    public var droppedChapterCount: Int

    /// The size difference as a fraction of the source, negative when the file
    /// shrank. `nil` when skipped or when the source's size is unknown.
    public var sizeDelta: Double? {
        guard outcome.wasTranscoded, inputByteCount > 0 else { return nil }
        return (Double(outputByteCount) - Double(inputByteCount)) / Double(inputByteCount)
    }

    public init(
        output: URL?,
        outcome: AudioTranscodeOutcome,
        source: AudioStreamInfo,
        destination: AudioStreamInfo?,
        inputByteCount: UInt64,
        outputByteCount: UInt64,
        wallTime: TimeInterval,
        channels: AppliedChannelPolicy,
        metadataItemsWritten: Int,
        carriedArtwork: Bool,
        droppedChapterCount: Int
    ) {
        self.output = output
        self.outcome = outcome
        self.source = source
        self.destination = destination
        self.inputByteCount = inputByteCount
        self.outputByteCount = outputByteCount
        self.wallTime = wallTime
        self.channels = channels
        self.metadataItemsWritten = metadataItemsWritten
        self.carriedArtwork = carriedArtwork
        self.droppedChapterCount = droppedChapterCount
    }
}

// MARK: - Plan

/// What ``AudioTranscoder`` *would* do, without doing it.
///
/// The "inspect and decide" seam. A library pass that wants to show a user what
/// it is about to change — or that wants to sort by predicted saving before
/// spending an hour of battery — asks for this first.
public struct AudioTranscodePlan: Sendable, Equatable {
    public var source: AudioStreamInfo

    /// `nil` when the plan is not to transcode at all.
    public var skipReason: AudioSkipReason?

    public var targetCodec: AudioCodec
    /// The bitrate that would be requested of the encoder. `nil` for a lossless
    /// target, which has none.
    public var targetBitsPerSecond: Int?
    public var targetSampleRate: Double
    public var targetChannelCount: Int

    /// Whether this would re-encode already-lossy material — a second
    /// generation of loss.
    public var isSecondGenerationLossy: Bool

    public var wouldTranscode: Bool { skipReason == nil }

    public init(
        source: AudioStreamInfo,
        skipReason: AudioSkipReason?,
        targetCodec: AudioCodec,
        targetBitsPerSecond: Int?,
        targetSampleRate: Double,
        targetChannelCount: Int,
        isSecondGenerationLossy: Bool
    ) {
        self.source = source
        self.skipReason = skipReason
        self.targetCodec = targetCodec
        self.targetBitsPerSecond = targetBitsPerSecond
        self.targetSampleRate = targetSampleRate
        self.targetChannelCount = targetChannelCount
        self.isSecondGenerationLossy = isSecondGenerationLossy
    }
}
