import CoreMedia
import Foundation
import Testing

@testable import LatheFetch

/// Reading the duration an MPEG-4 file declares about itself.
///
/// This exists because `AVFoundation` reads YouTube's fragmented MP4 video
/// streams at exactly twice their real length, and the movie header is the
/// file's own — correct — statement of how long it is. See ``MP4MovieHeader``
/// for the evidence.
@Suite("MP4 movie header")
struct MP4MovieHeaderTests {

    /// Builds a box: a big-endian size, a four-character name, a payload.
    private static func box(_ name: String, _ payload: [UInt8]) -> [UInt8] {
        let size = UInt32(8 + payload.count)
        return [UInt8(size >> 24 & 0xFF), UInt8(size >> 16 & 0xFF),
                UInt8(size >> 8 & 0xFF), UInt8(size & 0xFF)]
            + Array(name.utf8) + payload
    }

    private static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
         UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private static func be64(_ value: UInt64) -> [UInt8] {
        (0..<8).reversed().map { UInt8((value >> (UInt64($0) * 8)) & 0xFF) }
    }

    /// A version 0 header: 32-bit times, 32-bit duration.
    private static func mvhdV0(timescale: UInt32, duration: UInt32) -> [UInt8] {
        box("mvhd", [0, 0, 0, 0]                    // version 0, flags
            + be32(0) + be32(0)                     // creation, modification
            + be32(timescale) + be32(duration)
            + [UInt8](repeating: 0, count: 80))     // rate, volume, matrix, …
    }

    /// A version 1 header: 64-bit times, 64-bit duration.
    private static func mvhdV1(timescale: UInt32, duration: UInt64) -> [UInt8] {
        box("mvhd", [1, 0, 0, 0]
            + be64(0) + be64(0)
            + be32(timescale) + be64(duration)
            + [UInt8](repeating: 0, count: 80))
    }

    private static func write(_ bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lathe-mvhd-\(UUID().uuidString).mp4")
        try Data(bytes).write(to: url)
        return url
    }

    @Test("reads a version 0 header")
    func versionZero() throws {
        // The real figures from a YouTube DASH rendition: 290816 ticks at
        // 15360 per second is 18.933s, which is what the file that
        // AVFoundation reads as 37.867s actually contains.
        let file = try Self.write(
            Self.box("ftyp", Array("isom".utf8) + Self.be32(0))
                + Self.box("moov", Self.mvhdV0(timescale: 15360, duration: 290_816)))
        defer { try? FileManager.default.removeItem(at: file) }

        let duration = try #require(MP4MovieHeader.declaredDuration(of: file))
        #expect(abs(CMTimeGetSeconds(duration) - 18.9333) < 0.001)
    }

    @Test("reads a version 1 header")
    func versionOne() throws {
        let file = try Self.write(
            Self.box("ftyp", Array("isom".utf8))
                + Self.box("moov", Self.mvhdV1(timescale: 1000, duration: 5_000)))
        defer { try? FileManager.default.removeItem(at: file) }

        let duration = try #require(MP4MovieHeader.declaredDuration(of: file))
        #expect(abs(CMTimeGetSeconds(duration) - 5.0) < 0.001)
    }

    /// The regression test for the bug that made the first version of this
    /// return `nil` for every file: a box header is eight bytes, and reading
    /// the size from all eight folded the name into the number.
    @Test("a box whose size and name could be confused is still found")
    func boxSizeIsReadFromFourBytesNotEight() throws {
        let file = try Self.write(
            Self.box("ftyp", Array("isom".utf8))
                + Self.box("free", [UInt8](repeating: 0, count: 64))
                + Self.box("moov", Self.mvhdV0(timescale: 600, duration: 1_200)))
        defer { try? FileManager.default.removeItem(at: file) }

        let duration = try #require(MP4MovieHeader.declaredDuration(of: file))
        #expect(abs(CMTimeGetSeconds(duration) - 2.0) < 0.001)
    }

    @Test("walks past a 64-bit box to reach the movie header")
    func sixtyFourBitBoxSize() throws {
        // Size 1 means "the real size is the eight bytes after the name".
        let payload = [UInt8](repeating: 0, count: 32)
        let large = Self.be32(1) + Array("mdat".utf8)
            + Self.be64(UInt64(16 + payload.count)) + payload
        let file = try Self.write(
            Self.box("ftyp", Array("isom".utf8))
                + large
                + Self.box("moov", Self.mvhdV0(timescale: 90_000, duration: 180_000)))
        defer { try? FileManager.default.removeItem(at: file) }

        let duration = try #require(MP4MovieHeader.declaredDuration(of: file))
        #expect(abs(CMTimeGetSeconds(duration) - 2.0) < 0.001)
    }

    @Test("an unknown duration is not a length")
    func unknownDurationSentinel() throws {
        let file = try Self.write(
            Self.box("ftyp", Array("isom".utf8))
                + Self.box("moov", Self.mvhdV0(timescale: 600, duration: 0xFFFF_FFFF)))
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(MP4MovieHeader.declaredDuration(of: file) == nil)
    }

    @Test("a file with no movie header reports nothing")
    func noMovieHeader() throws {
        let file = try Self.write(Self.box("ftyp", Array("isom".utf8)))
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(MP4MovieHeader.declaredDuration(of: file) == nil)
    }

    @Test("a truncated box does not send the walk off the end")
    func truncatedBox() throws {
        // A size claiming far more than the file holds. Walking on from here
        // would read whatever followed as though it were a box.
        let file = try Self.write(Self.be32(9_999) + Array("moov".utf8) + [0, 0, 0, 0])
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(MP4MovieHeader.declaredDuration(of: file) == nil)
    }
}

/// The correction applied when a track's samples disagree with its container.
@Suite("Timing correction")
struct TimingCorrectionTests {

    @Test("the identity changes nothing")
    func identity() {
        #expect(!TimingCorrection.identity.isNeeded)
        let duration = CMTime(seconds: 12, preferredTimescale: 600)
        #expect(TimingCorrection.identity.corrected(duration) == duration)
    }

    @Test("halving a duration")
    func halves() {
        let correction = TimingCorrection(factor: 0.5, anchor: .zero)
        let corrected = correction.corrected(CMTime(seconds: 37.8667, preferredTimescale: 600))
        #expect(abs(CMTimeGetSeconds(corrected) - 18.933) < 0.01)
    }

    /// The measurements are the real ones from a two-minute YouTube AV1
    /// download: 4070 samples spaced for 60 fps against a header, and an
    /// audio track, that both say 30.
    @Test("samples spaced twice too close are stretched back out")
    func stretchesHalvedSamples() {
        let factor = TimingCorrection.factor(declared: 135.666667, observed: 67.816667)
        #expect(factor != nil)
        #expect(abs((factor ?? 0) - 2) < 0.01)
    }

    /// Measured 2026-09-21 on YouTube's AAC (format 140) for a 19.06s clip:
    /// the track claims 38.08s, but AVAssetReader's buffers each hold 129
    /// frames of 1024 samples and are spaced exactly that far apart. The
    /// samples are right; halving them is what broke a user's download.
    @Test("consistent samples call for no correction, whatever the track claims")
    func consistentSamplesMeasureOne() {
        let spans = (0..<10).map { (start: Double($0) * 132096 / 44100, duration: 132096.0 / 44100) }
        let factor = TimingCorrection.sampleFactor(spans: spans)
        #expect(abs((factor ?? 0) - 1) < 0.001)
    }

    /// The defect the correction exists for: 60 fps spacing, 1/30 durations.
    @Test("samples reporting twice their length measure one half")
    func doubledDurationsMeasureHalf() {
        let spans = (0..<10).map { (start: Double($0) / 60, duration: 1.0 / 30) }
        let factor = TimingCorrection.sampleFactor(spans: spans)
        #expect(abs((factor ?? 0) - 0.5) < 0.001)
    }

    @Test("zero durations and out-of-order starts do not skew the measurement")
    func zeroDurationsAndReorderingIgnored() {
        var spans = [(start: 0.0, duration: 0.0)]
        spans += [3, 1, 2, 5, 4, 6].map { (start: Double($0) / 15, duration: 1.0 / 15) }
        let factor = TimingCorrection.sampleFactor(spans: spans)
        #expect(abs((factor ?? 0) - 1) < 0.001)
    }

    @Test("too few samples cannot be measured")
    func tooFewSamples() {
        #expect(TimingCorrection.sampleFactor(spans: [(0, 1), (1, 1)]) == nil)
    }

    @Test("samples held twice too long are compressed")
    func compressesDoubledSamples() {
        let factor = TimingCorrection.factor(declared: 18.933, observed: 37.8667)
        #expect(abs((factor ?? 0) - 0.5) < 0.01)
    }

    /// The guard that keeps a half-finished download from being stretched to
    /// cover time it has no pictures for.
    @Test("an arbitrary shortfall is left alone")
    func ignoresTruncation() {
        #expect(TimingCorrection.factor(declared: 135.0, observed: 98.4) == nil)
        #expect(TimingCorrection.factor(declared: 135.0, observed: 135.0) == nil)
        #expect(TimingCorrection.factor(declared: 135.0, observed: 0) == nil)
    }

    /// The anchor is the reason an edit list that starts a track one frame in
    /// does not drag the whole track earlier relative to its audio.
    @Test("the anchor is held while the span is scaled")
    func anchorIsHeld() {
        let anchor = CMTime(value: 1024, timescale: 15360)   // one frame at 15fps
        let correction = TimingCorrection(factor: 0.5, anchor: anchor)
        // A sample at the anchor does not move at all.
        let atAnchor = correction.corrected(CMTime.zero)
        #expect(CMTimeGetSeconds(atAnchor) == 0)
        #expect(correction.isNeeded)
        #expect(correction.anchor == anchor)
    }
}
