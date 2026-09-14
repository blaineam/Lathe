import Foundation
import LatheCore
import Testing

@testable import LatheAudio

@Suite("Audio API surface")
struct AudioSurfaceTests {

    private let source = URL(fileURLWithPath: "/tmp/lathe-test-in.mp4")

    @Test("the cheap audibility check reports as not implemented")
    func audibilityIsNotImplemented() async {
        await #expect(throws: LatheError.self) {
            _ = try await UnimplementedAudioAnalyzer().hasAudibleAudio(source, thresholds: .default)
        }
    }

    @Test("the full analysis reports as not implemented")
    func analysisIsNotImplemented() async {
        await #expect(throws: LatheError.self) {
            _ = try await UnimplementedAudioAnalyzer()
                .analyzeAudio(source, thresholds: .default, progress: .ignoring())
        }
    }

    /// Both thresholds sit above a realistic room-noise floor and below anything
    /// a listener would call audible. Pinning them means a careless edit shows up
    /// as a failure rather than as a silent change in classification.
    @Test("default thresholds are in the sane range")
    func thresholdsAreSane() {
        let thresholds = AudibilityThresholds.default
        #expect(thresholds.peakDBFS == -60)
        #expect(thresholds.shortTermRMSDBFS == -70)
        // The secondary RMS guard must be the more permissive of the two, or it
        // would never guard anything.
        #expect(thresholds.shortTermRMSDBFS < thresholds.peakDBFS)
        #expect(thresholds.peakDBFS < 0)
    }

    /// The result type keeps a whole-file mean alongside the peak-based boolean
    /// purely for migration. The point of the separation is that
    /// `isEffectivelySilent` must never be derived from the mean — a clip with
    /// two seconds of speech in ten minutes averages far below any sane
    /// threshold while being plainly audible.
    @Test("a sparse-audio clip is not silent, even with a very low mean volume")
    func sparseAudioIsNotSilent() {
        let sparse = AudioAnalysis(
            hasAudioTrack: true,
            channelCount: 2,
            sampleRate: 48_000,
            duration: 600,
            peakDBFS: -3,             // loud speech, briefly
            truePeakDBTP: -2.4,
            meanVolumeDBFS: -45,      // and 598 seconds of near-silence
            integratedLUFS: -38,
            loudnessRangeLU: 12,
            silentRanges: [],
            isEffectivelySilent: false
        )
        #expect(!sparse.isEffectivelySilent)
        // The peak says "obviously audible"...
        #expect(sparse.peakDBFS > AudibilityThresholds.default.peakDBFS)
        // ...while the whole-file mean sits more than 40 dB lower, which is the
        // divergence that makes mean volume the wrong statistic for this
        // question. The two numbers must stay independent fields; deriving one
        // from the other would reintroduce the misclassification.
        #expect(sparse.meanVolumeDBFS < sparse.peakDBFS - 40)
    }
}
