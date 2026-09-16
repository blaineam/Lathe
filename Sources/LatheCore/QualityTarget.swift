import Foundation

/// The quality knob, in the one form every backend can honour.
///
/// Shared by stills and video because the *mapping* differs per backend but the
/// user's intent does not. Translating between a backend that takes a CRF and
/// one that takes a 0...1 quality factor is this type's job, and keeping it in
/// one place is what stops two call sites disagreeing about what "high quality"
/// means.
public enum QualityTarget: Sendable, Equatable {
    /// Normalised `0...1`, higher is better. Maps to
    /// `kCGImageDestinationLossyCompressionQuality` for stills and to
    /// `kVTCompressionPropertyKey_Quality` for video.
    ///
    /// Note the trap: **HEIC at quality 1.0 is still lossy, and larger than
    /// PNG.** 1.0 is not "lossless"; it is "wasteful".
    case quality(Double)

    /// True CRF semantics via `kVTCompressionPropertyKey_ConstantQualityFactor`.
    ///
    /// Opt-in only, and **probed at runtime, never version-gated** — the key is
    /// newer than this package's deployment floor, and asking the system whether
    /// it works is both simpler and more durable than a version check.
    case constantQualityFactor(Double)

    /// Average bitrate in bits per second. The fallback wherever constant
    /// quality is unavailable.
    case averageBitrate(Int)

    /// Re-encode nothing; rewrite the container or metadata only.
    ///
    /// For stills this is `CGImageDestinationCopyImageSource`, which is how
    /// "strip GPS" gets done without touching a DCT coefficient.
    case lossless

    /// Clamped `0...1` where the case carries a normalised quality, else `nil`.
    public var normalizedQuality: Double? {
        if case let .quality(q) = self { return min(max(q, 0), 1) }
        return nil
    }
}
