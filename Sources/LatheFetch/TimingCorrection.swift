import AVFoundation
import CoreMedia
import Foundation

/// Reconciles a track's sample timing with what its container says.
///
/// Normally there is nothing to reconcile and this is the identity. It exists
/// for one specific, reproducible disagreement: `AVFoundation` reads YouTube's
/// fragmented MP4 video streams with every sample durated at the wrong power
/// of two. Twice as long as the file declares, and a nineteen-second clip
/// arrives as thirty-eight seconds with its final frame held through the
/// second half; half as long, and a two-minute 30 fps AV1 video arrives with
/// its samples spaced for 60 fps, so the picture runs through at double speed
/// and freezes while the audio plays on. ``MP4MovieHeader`` documents the
/// evidence that the files themselves are right.
///
/// ## What the defect actually is, measured
///
/// On a 60 fps YouTube video whose header declares 40.03 seconds, the track
/// reports 80.07. Reading the samples shows why, and it is narrower than
/// "the timing is wrong": the presentation timestamps are spaced correctly at
/// 1/60 second and span the right 40 seconds, while each sample's *duration*
/// field reads 1/30 — twice what it should be. Those doubled durations are
/// what sum to the doubled track duration.
///
/// So the factor is right and scaling the durations is necessary; scaling the
/// positions as well is what produced a forty-second video playing out in
/// twenty against its own audio. The first sample reports a duration of zero,
/// which is ordinary and says nothing about the rest — a check that gave up
/// on seeing it would skip a correction the file needs.
///
/// ## Why scale rather than rebuild
///
/// The obvious alternative is to recompute every timestamp from the frame rate
/// — index times frame duration. That is wrong for anything variable-rate, and
/// a downloader receives plenty of variable-rate video.
///
/// Scaling the span between the first sample and the last is correct whatever
/// the sample spacing: it is the same proportional error applied to every
/// sample, which is exactly what the observed defect is. On the real files the
/// factor comes out at 0.5 to within floating-point noise.
///
/// ## Why the first sample is an anchor and not a scaled value
///
/// An edit list can legitimately start a track a fraction of a second in —
/// YouTube's do, by exactly one frame. Scaling that offset as well would move
/// the whole track earlier relative to the audio it is about to be muxed with.
/// Holding the first timestamp fixed and scaling only the span leaves the
/// tracks aligned where they were.
struct TimingCorrection: Sendable {

    /// How much to compress (or stretch) the span. 1 means do nothing.
    let factor: Double

    /// The timestamp everything is measured from, held fixed.
    let anchor: CMTime

    static let identity = TimingCorrection(factor: 1, anchor: .zero)

    var isNeeded: Bool { factor != 1 }

    /// A disagreement has to be bigger than this to be treated as real.
    ///
    /// A container's declared duration and the sum of its sample durations
    /// routinely differ by a frame or two — rounding, a trailing partial
    /// sample, an edit list trimming the head. Correcting for that would be
    /// noise. The defect this exists for is a factor of two.
    static let tolerance = 0.02

    init(factor: Double, anchor: CMTime) {
        self.factor = factor
        self.anchor = anchor
    }

    /// Works out whether `track`'s samples disagree with `file`'s movie header.
    init(for track: AVAssetTrack, file: URL) async {
        // Every path below says what it saw. A correction that silently does
        // nothing and a correction that silently does the wrong thing look
        // identical in the output, and telling them apart from the outside
        // means reading durations off a finished file and guessing backwards.
        let header = MP4MovieHeader.declaredDuration(of: file)
        let measured = try? await track.load(.timeRange)

        guard let declared = header, let range = measured else {
            DiagnosticLog.note("timing: no comparison possible — header \(header == nil ? "unreadable" : "ok"), track \(measured == nil ? "unreadable" : "ok")")
            LatheFetchLog.timing.log(
                """
                timing: no comparison possible — header \(header == nil ? "unreadable" : "ok",                 privacy: .public), track \(measured == nil ? "unreadable" : "ok", privacy: .public)
                """)
            self = .identity
            return
        }

        let declaredSeconds = CMTimeGetSeconds(declared)
        let observedSeconds = CMTimeGetSeconds(range.duration)
        guard declaredSeconds.isFinite, observedSeconds.isFinite,
              declaredSeconds > 0, observedSeconds > 0
        else {
            DiagnosticLog.note("timing: unusable durations declared=\(declaredSeconds) observed=\(observedSeconds)")
            LatheFetchLog.timing.log(
                "timing: unusable durations declared=\(declaredSeconds, privacy: .public) observed=\(observedSeconds, privacy: .public)")
            self = .identity
            return
        }

        guard let factor = Self.factor(declared: declaredSeconds, observed: observedSeconds) else {
            DiagnosticLog.note("timing: leaving alone — declared=\(declaredSeconds)s observed=\(observedSeconds)s ratio=\(declaredSeconds / observedSeconds)")
            LatheFetchLog.timing.log(
                """
                timing: leaving alone — declared=\(declaredSeconds, privacy: .public)s                 observed=\(observedSeconds, privacy: .public)s                 ratio=\(declaredSeconds / observedSeconds, privacy: .public)
                """)
            self = .identity
            return
        }

        // The header disagreeing with the TRACK is not proof the SAMPLES are
        // wrong. YouTube's AAC audio (format 140) reads exactly this way —
        // header 19.06s, track 38.08s — yet every sample AVAssetReader hands
        // back is timed correctly (buffers of 129 frames × 1024, spaced 129 ×
        // 1024 apart). Correcting on the header alone halved every audio
        // frame to 512 samples, squeezing a 3:45 song into 1:52 while the
        // video ran at full length: choppy, jumping playback. So the samples
        // are measured too, and only a disagreement they confirm is corrected.
        let measuredFactor = await Self.sampleFactor(of: track)
        guard let measuredFactor, abs(measuredFactor - factor) <= Self.tolerance else {
            DiagnosticLog.note("timing: header disagrees (ratio \(factor)) but samples measure \(measuredFactor.map { "\($0)" } ?? "unmeasurable") — leaving alone")
            LatheFetchLog.timing.log(
                """
                timing: header disagrees (ratio \(factor, privacy: .public)) but samples measure \(measuredFactor.map { "\($0)" } ?? "unmeasurable", privacy: .public) — leaving alone
                """)
            self = .identity
            return
        }

        DiagnosticLog.note("timing: correcting by \(factor) — declared=\(declaredSeconds)s observed=\(observedSeconds)s anchor=\(CMTimeGetSeconds(range.start))s")
        LatheFetchLog.timing.log(
            """
            timing: correcting by \(factor, privacy: .public) —             declared=\(declaredSeconds, privacy: .public)s             observed=\(observedSeconds, privacy: .public)s             anchor=\(CMTimeGetSeconds(range.start), privacy: .public)s
            """)
        self.init(factor: factor, anchor: range.start)
    }

    /// How much to scale a span that disagrees with its header, or nil to
    /// leave it alone.
    ///
    /// A factor of two either way, and nothing else. The defect is sample
    /// durations written at the wrong power of two — twice as long as they
    /// should be, which is the case this started with, or half, which is what
    /// YouTube's 30 fps AV1 arrives as: 4070 samples of 1/60 second each
    /// spanning 67 seconds against 135 seconds of audio, so the picture races
    /// through and freezes on its last frame while the sound plays on.
    ///
    /// Any other disagreement is not this defect and is left alone. A
    /// truncated download, or a file still being written, falls short of its
    /// header by an arbitrary amount, and stretching that to fit would invent
    /// time with no pictures in it.
    static func factor(declared: Double, observed: Double) -> Double? {
        guard declared > 0, observed > 0, declared.isFinite, observed.isFinite else { return nil }
        let ratio = declared / observed
        guard abs(ratio - 1) > tolerance else { return nil }
        guard abs(ratio - 0.5) <= tolerance || abs(ratio - 2) <= tolerance else { return nil }
        return ratio
    }

    /// How far apart the first samples actually are, relative to how long
    /// they say they last — the correction the samples themselves call for.
    ///
    /// 1 means the samples are consistent (whatever the track's duration
    /// claims); 0.5 means each sample reports twice its real length, the
    /// video defect this type exists for. nil when too few samples carry a
    /// usable duration to tell.
    static func sampleFactor(of track: AVAssetTrack, limit: Int = 48) async -> Double? {
        guard let asset = track.asset, let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }
        var spans: [(start: Double, duration: Double)] = []
        while spans.count < limit, let buffer = output.copyNextSampleBuffer() {
            let dts = CMSampleBufferGetDecodeTimeStamp(buffer)
            let start = dts.isNumeric ? dts : CMSampleBufferGetPresentationTimeStamp(buffer)
            let duration = CMSampleBufferGetDuration(buffer)
            guard start.isNumeric else { continue }
            spans.append((CMTimeGetSeconds(start),
                          duration.isNumeric ? CMTimeGetSeconds(duration) : 0))
        }
        return sampleFactor(spans: spans)
    }

    /// The pure half of ``sampleFactor(of:limit:)``: spacing over stated length.
    ///
    /// Starts are sorted first, so presentation times that arrive out of order
    /// (B-frames, when a buffer carries no decode time) still measure the span
    /// they cover. Zero durations — the first video sample reports one — are
    /// not evidence either way and are left out of the mean.
    static func sampleFactor(spans: [(start: Double, duration: Double)]) -> Double? {
        let starts = spans.map(\.start).sorted()
        let durations = spans.map(\.duration).filter { $0 > 0 && $0.isFinite }
        guard starts.count >= 3, durations.count >= 2,
              let first = starts.first, let last = starts.last, last > first
        else { return nil }
        let meanDuration = durations.reduce(0, +) / Double(durations.count)
        let meanSpacing = (last - first) / Double(starts.count - 1)
        guard meanDuration > 0 else { return nil }
        return meanSpacing / meanDuration
    }

    /// The same buffer with its timing scaled, or the buffer itself when
    /// there is nothing to correct.
    func apply(to sample: CMSampleBuffer) throws -> CMSampleBuffer {
        guard isNeeded else { return sample }

        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(
            sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return sample }

        var timings = [CMSampleTimingInfo](repeating: .invalid, count: Int(count))
        let status = CMSampleBufferGetSampleTimingInfoArray(
            sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: nil)
        guard status == noErr else { return sample }

        for index in timings.indices {
            // Durations only. The timestamps are already right.
            //
            // Measured on the file this was written for: the video track
            // reports an 80-second span against a 40-second header, so the
            // disagreement is real — but it is the per-sample *durations* that
            // read twice too long, not the presentation times. Scaling the
            // timestamps as well moved samples that were already in the right
            // place, and the output came out at 20 seconds: half of the
            // corrected span, a quarter of the observed one, with the audio
            // playing on for the other twenty. Leaving the positions alone and
            // fixing only the lengths is what the evidence actually supports.
            if timings[index].duration.isValid, timings[index].duration.isNumeric {
                timings[index].duration =
                    CMTimeMultiplyByFloat64(timings[index].duration, multiplier: factor)
            }
        }

        var corrected: CMSampleBuffer?
        let result = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timings,
            sampleBufferOut: &corrected)
        guard result == noErr, let corrected else {
            throw NSError(
                domain: "Lathe.TimingCorrection", code: Int(result),
                userInfo: [NSLocalizedDescriptionKey: "the sample's timing could not be rewritten"])
        }
        return corrected
    }

    private func scale(_ time: CMTime) -> CMTime {
        guard time.isValid, time.isNumeric else { return time }
        let offset = CMTimeSubtract(time, anchor)
        return CMTimeAdd(anchor, CMTimeMultiplyByFloat64(offset, multiplier: factor))
    }

    /// A duration measured under the old timing, restated under the new.
    func corrected(_ duration: CMTime) -> CMTime {
        guard isNeeded, duration.isValid, duration.isNumeric else { return duration }
        return CMTimeMultiplyByFloat64(duration, multiplier: factor)
    }
}
