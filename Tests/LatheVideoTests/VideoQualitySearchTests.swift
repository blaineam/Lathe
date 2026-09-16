@preconcurrency import AVFoundation
import Foundation
import LatheCore
import LatheFixtures
import LatheImage
import Testing

@testable import LatheVideo

@Suite("Video quality search")
struct VideoQualitySearchTests {

    @Test("clips are spread across a long video and cover a short one whole")
    func sampleRanges() {
        let long = VideoQualitySearch.sampleRanges(duration: 60, count: 3, seconds: 2)
        #expect(long.count == 3)
        #expect(long.map { $0.start.seconds } == [9, 29, 49])
        #expect(long.allSatisfy { $0.duration.seconds == 2 })

        let short = VideoQualitySearch.sampleRanges(duration: 4, count: 3, seconds: 2)
        #expect(short.count == 1)
        #expect(short[0].start == .zero)
        #expect(short[0].duration.seconds == 4)
    }

    @Test("a search over transcode quality finds a passing value, or reports none")
    func searchesTranscodeQuality() async throws {
        let source = try await FixtureLibrary.shared.movie(
            named: "search-split.mov", size: PixelSize(width: 320, height: 240), frameRate: 24,
            seconds: 3, colour: .black, rightHalf: .white)
        let asset = AVURLAsset(url: source)
        let encode: @Sendable (URL, Double, URL) async throws -> Void = { sample, value, output in
            try await VideoTranscoder().transcode(
                source: sample, to: output, codec: .hevc, quality: .quality(value))
        }

        let outcome = try await VideoQualitySearch(
            search: QualitySearch(range: 0.2...1, maximumAttempts: 4), sampleCount: 1, framesPerSample: 2
        ).run(asset: asset, outputExtension: "mov", encodeSample: encode)
        let value = try #require(outcome.value, "attempts: \(outcome.attempts)")
        #expect(value <= 1)
        #expect(outcome.similarity?.meets(.visuallyLossless) == true)

        let impossible = try await VideoQualitySearch(
            search: QualitySearch(
                threshold: VisualThreshold(minimumSimilarity: 1.01, minimumRegionSimilarity: 1),
                range: 0.2...1, maximumAttempts: 4),
            sampleCount: 1, framesPerSample: 1
        ).run(asset: asset, outputExtension: "mov", encodeSample: encode)
        #expect(!impossible.found)
        #expect(impossible.attempts.count == 1)
    }

    @Test("a file with no video is refused")
    func refusesAudioOnly() async throws {
        let audio = try await FixtureLibrary.shared.wav(named: "search-audio.wav", seconds: 1, audio: .silence)
        await #expect(throws: LatheError.self) {
            _ = try await VideoQualitySearch().run(
                asset: AVURLAsset(url: audio), outputExtension: "mov") { _, _, _ in }
        }
    }
}
