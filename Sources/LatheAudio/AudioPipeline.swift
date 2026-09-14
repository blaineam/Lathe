import CoreMedia
import Foundation
import LatheCore

/// Everything one `AVAssetReader` pass can produce.
///
/// Decoding is the expensive part, so it happens **once** and every statistic
/// below falls out of the same Float32 buffers via Accelerate/vDSP and
/// libebur128 (MIT).
public struct AudioAnalysis: Sendable, Equatable {
    public var hasAudioTrack: Bool
    public var channelCount: Int
    public var sampleRate: Double
    public var duration: TimeInterval

    /// `vDSP_maxmgv` sample peak.
    public var peakDBFS: Float
    /// True peak. Sample peak under-reports inter-sample peaks by up to ~3 dB,
    /// and lossy re-encoding *moves* peaks — material sitting at 0 dBFS
    /// routinely lands above 0 dBTP after transcode and clips on playback. Above
    /// about **−1 dBTP**, warn or reduce gain.
    public var truePeakDBTP: Float
    /// `10·log₁₀(Σ(s²)/N)` in dBFS — the same statistic the common
    /// command-line volume detector reports, kept **only** so existing
    /// thresholds keep working while a caller migrates off it. Do not build new
    /// logic on it; see ``isEffectivelySilent``.
    public var meanVolumeDBFS: Float
    /// libebur128 mode I.
    public var integratedLUFS: Double
    /// EBU Tech 3342 loudness range.
    public var loudnessRangeLU: Double
    /// 400 ms window, 100 ms hop, ≥0.5 s minimum run. Free from the same pass.
    public var silentRanges: [CMTimeRange]
    /// The product-level boolean. Peak-based, **not** mean-based.
    public var isEffectivelySilent: Bool

    public init(
        hasAudioTrack: Bool,
        channelCount: Int,
        sampleRate: Double,
        duration: TimeInterval,
        peakDBFS: Float,
        truePeakDBTP: Float,
        meanVolumeDBFS: Float,
        integratedLUFS: Double,
        loudnessRangeLU: Double,
        silentRanges: [CMTimeRange],
        isEffectivelySilent: Bool
    ) {
        self.hasAudioTrack = hasAudioTrack
        self.channelCount = channelCount
        self.sampleRate = sampleRate
        self.duration = duration
        self.peakDBFS = peakDBFS
        self.truePeakDBTP = truePeakDBTP
        self.meanVolumeDBFS = meanVolumeDBFS
        self.integratedLUFS = integratedLUFS
        self.loudnessRangeLU = loudnessRangeLU
        self.silentRanges = silentRanges
        self.isEffectivelySilent = isEffectivelySilent
    }
}

/// Thresholds for the cheap "does this have sound" question.
public struct AudibilityThresholds: Sendable, Equatable {
    /// Peak above this counts as audible.
    public var peakDBFS: Float
    /// Secondary guard so a single-sample click does not register as audio:
    /// the 99th-percentile 400 ms short-term RMS must also clear this.
    public var shortTermRMSDBFS: Float

    public init(peakDBFS: Float = -60, shortTermRMSDBFS: Float = -70) {
        self.peakDBFS = peakDBFS
        self.shortTermRMSDBFS = shortTermRMSDBFS
    }

    /// A reasonable starting point. **Tune on a real corpus** before trusting
    /// these numbers.
    public static let `default` = AudibilityThresholds()
}

/// The loudness probe.
///
/// Not yet implemented; `AVAssetReader` + vDSP, with libebur128 (MIT) for true
/// LUFS and true peak, is the intended backing.
///
/// Worth stating why this is not merely a reimplementation of the usual
/// command-line approach. Mean volume computed over the **entire file** is the
/// wrong statistic for "does this have sound": a ten-minute clip with two
/// seconds of speech averages around −45 dBFS and gets misclassified as silent.
/// That false-negative cliff is exactly the shape of a phone video with one
/// spoken sentence in it.
///
/// The design is an escalating ladder, cheapest first:
///
/// 1. No audio track → done, in microseconds.
/// 2. Zero channels or zero duration → done.
/// 3. Decode with **early exit** the moment peak clears the threshold. Any video
///    that actually has sound terminates within a fraction of a second. Only
///    genuinely silent files pay the full-scan cost — and those *must* be
///    scanned fully, because sound can start at 9:58.
/// 4. Track "all samples exactly zero" separately from "quiet": synthesised
///    silence is genuinely −∞ dBFS, a real capture in a quiet room has a noise
///    floor around −60 to −80 dBFS.
public protocol AudioAnalyzer: Sendable {
    /// The cheap boolean, with early exit.
    func hasAudibleAudio(
        _ url: URL,
        thresholds: AudibilityThresholds
    ) async throws -> Bool

    /// The full pass. Same code path, different early-exit flag.
    func analyzeAudio(
        _ url: URL,
        thresholds: AudibilityThresholds,
        progress: ProgressHandle
    ) async throws -> AudioAnalysis
}

// MARK: - Scaffold implementation

/// Throws ``LatheError/notImplemented(feature:)`` for everything.
public struct UnimplementedAudioAnalyzer: AudioAnalyzer {

    public init() {}

    public func hasAudibleAudio(
        _ url: URL,
        thresholds: AudibilityThresholds = .default
    ) async throws -> Bool {
        throw LatheError.todo("AudioAnalyzer.hasAudibleAudio(_:thresholds:)")
    }

    public func analyzeAudio(
        _ url: URL,
        thresholds: AudibilityThresholds = .default,
        progress: ProgressHandle
    ) async throws -> AudioAnalysis {
        throw LatheError.todo("AudioAnalyzer.analyzeAudio(_:thresholds:progress:)")
    }
}
