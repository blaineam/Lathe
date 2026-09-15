import AVFoundation
import CoreMedia
import Foundation

/// Reconciles a track's sample timing with what its container says.
///
/// Normally there is nothing to reconcile and this is the identity. It exists
/// for one specific, reproducible disagreement: `AVFoundation` reads YouTube's
/// fragmented MP4 video streams with every sample twice as long as the file
/// declares, so a nineteen-second clip arrives as thirty-eight seconds with
/// its final frame held through the second half, and a ten-minute video as
/// twenty-one minutes. ``MP4MovieHeader`` documents the evidence that the
/// files themselves are right.
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
    private static let tolerance = 0.02

    init(factor: Double, anchor: CMTime) {
        self.factor = factor
        self.anchor = anchor
    }

    /// Works out whether `track`'s samples disagree with `file`'s movie header.
    init(for track: AVAssetTrack, file: URL) async {
        guard let declared = MP4MovieHeader.declaredDuration(of: file),
              let range = try? await track.load(.timeRange)
        else {
            self = .identity
            return
        }

        let declaredSeconds = CMTimeGetSeconds(declared)
        let observedSeconds = CMTimeGetSeconds(range.duration)
        guard declaredSeconds.isFinite, observedSeconds.isFinite,
              declaredSeconds > 0, observedSeconds > 0
        else {
            self = .identity
            return
        }

        let ratio = declaredSeconds / observedSeconds
        guard abs(ratio - 1) > Self.tolerance else {
            self = .identity
            return
        }

        // Only ever shorten. If the samples span *less* than the header
        // claims, the header is describing something that is not there —
        // a truncated download, or a file still being written — and
        // stretching the samples to cover it would invent time that has no
        // pictures in it.
        guard ratio < 1 else {
            self = .identity
            return
        }

        self.init(factor: ratio, anchor: range.start)
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
            timings[index].presentationTimeStamp = scale(timings[index].presentationTimeStamp)
            timings[index].decodeTimeStamp = scale(timings[index].decodeTimeStamp)
            // A duration is a length, not a position, so it scales directly
            // rather than about the anchor.
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
