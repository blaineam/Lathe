import AVFoundation
import Foundation
import LatheCore
import LatheFixtures
import Testing

@testable import LatheVideo

/// Chapters through a video transcode.
///
/// A film's scene markers and a lecture's sections are the same structure an
/// audiobook uses — a text track tied to the media by a track association — so
/// this exercises the same machinery against the video writer, where the
/// association goes on the video track rather than the audio one.
@Suite("Video chapters", .serialized)
struct VideoChapterTests {

    private let transcoder = VideoTranscoder()

    private static let size = PixelSize(width: 160, height: 120)
    private static let seconds: Double = 3

    /// **The headline: a chaptered film keeps its chapters through a transcode.**
    @Test("chapters survive a video transcode, on the video track")
    func chaptersSurvive() async throws {
        guard let source = await fixture("vchap-source.mov", {
            try await FixtureLibrary.shared.movie(
                named: "vchap-source.mov", size: Self.size, frameRate: 24,
                seconds: Self.seconds, audio: .none
            )
        }) else { return }

        let chaptered = await scratch("vchap-in.mov")
        let expected: [Chapter] = [
            Chapter(startSeconds: 0, durationSeconds: 1, title: "Cold Open"),
            Chapter(startSeconds: 1, durationSeconds: 1, title: "Acte Deux"),
            Chapter(startSeconds: 2, durationSeconds: 1, title: "Credits"),
        ]
        guard try await writeChapters(expected, from: source, to: chaptered) else {
            withKnownIssue("this machine could not build a chaptered video fixture") {
                Issue.record("fixture generation failed")
            }
            return
        }
        let before = await ChapterTrack.read(from: AVURLAsset(url: chaptered))
        let beforeCount = before.count
        #expect(beforeCount == 3, "the fixture has \(beforeCount) chapters, not 3")

        let destination = await scratch("vchap-out.mov")
        let result = try await transcoder.transcode(
            source: chaptered, to: destination, codec: .hevc, quality: .quality(0.5)
        )
        let why = result.chapterLossReason ?? "no reason given"
        #expect(result.preservedChapterCount == 3,
                "preserved \(result.preservedChapterCount) of 3 — \(why)")
        #expect(result.droppedChapterCount == 0)

        let after = await ChapterTrack.read(from: AVURLAsset(url: destination))
        #expect(after.map(\.title) == ["Cold Open", "Acte Deux", "Credits"],
                "titles came back as \(after.map(\.title))")
        for (got, want) in zip(after, expected) {
            #expect(abs(got.startSeconds - want.startSeconds) < 0.2,
                    "\"\(want.title)\" starts at \(got.startSeconds), expected \(want.startSeconds)")
        }
    }

    @Test("a film with no chapters gains none")
    func unchapteredIsUnaffected() async throws {
        guard let source = await fixture("vchap-none.mov", {
            try await FixtureLibrary.shared.movie(
                named: "vchap-none.mov", size: Self.size, frameRate: 24, seconds: 1, audio: .none
            )
        }) else { return }
        let destination = await scratch("vchap-none-out.mov")

        let result = try await transcoder.transcode(
            source: source, to: destination, codec: .hevc, quality: .quality(0.5)
        )
        #expect(result.preservedChapterCount == 0)
        #expect(result.droppedChapterCount == 0)
        #expect(result.chapterLossReason == nil, "nothing was lost, so nothing to explain")
    }

    // MARK: - Fixture plumbing

    private func writeChapters(
        _ chapters: [Chapter], from source: URL, to destination: URL
    ) async throws -> Bool {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return false }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video, outputSettings: nil,
            sourceFormatHint: try await track.load(.formatDescriptions).first
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { return false }
        writer.add(input)

        let attachment = ChapterTrack.makeInput(
            for: chapters, writer: writer, associatedWith: input
        )
        guard let chapterInput = attachment.input else {
            Issue.record("chapter input refused: \(attachment.reason ?? "unknown")")
            return false
        }

        guard reader.startReading(), writer.startWriting() else { return false }
        writer.startSession(atSourceTime: .zero)
        let chapterWrite = ChapterTrack.beginWriting(chapters, to: chapterInput)

        while let buffer = output.copyNextSampleBuffer() {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            if !input.append(buffer) { break }
        }
        input.markAsFinished()
        _ = await chapterWrite.value
        await writer.finishWriting()
        return writer.status == .completed
    }

    private func scratch(_ name: String) async -> URL {
        let url = await FixtureLibrary.shared.scratchURL(named: name)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    private func fixture(_ name: String, _ make: () async throws -> URL) async -> URL? {
        do {
            return try await make()
        } catch {
            withKnownIssue("could not generate the fixture \"\(name)\": \(error)") {
                Issue.record("fixture generation failed")
            }
            return nil
        }
    }
}
