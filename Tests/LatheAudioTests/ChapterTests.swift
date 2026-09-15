import AVFoundation
import Foundation
import LatheCore
import LatheFixtures
import Testing

@testable import LatheAudio

/// Chapters through a transcode.
///
/// The round trip is the test that matters: write a chaptered file, transcode
/// it, and ask AVFoundation to read the chapters back out of the result. A test
/// that only checked a count would pass against a chapter track with the right
/// number of entries and no titles in it, which is the failure the sample format
/// actually produces when it is wrong.
@Suite("Chapters", .serialized)
struct ChapterTests {

    private let transcoder = AudioTranscoder()

    // MARK: - The model

    /// Overlaps are resolved by truncating the EARLIER chapter. A chapter's
    /// start is what a listener navigates to and what a producer chose; its
    /// duration is usually implied.
    @Test("overlapping chapters are truncated, not moved")
    func overlapsTruncateTheEarlierChapter() {
        let chapters: [Chapter] = [
            Chapter(startSeconds: 0, durationSeconds: 100, title: "One"),
            Chapter(startSeconds: 60, durationSeconds: 60, title: "Two"),
        ]
        let normalised = chapters.normalisedChapters()

        #expect(normalised.count == 2)
        #expect(normalised[0].startSeconds == 0)
        #expect(normalised[0].durationSeconds == 60, "the earlier chapter should have been trimmed")
        #expect(normalised[1].startSeconds == 60, "the later chapter's start must not move")
    }

    @Test("chapters come back in order, and zero-length ones are dropped")
    func normalisationOrdersAndPrunes() {
        let chapters: [Chapter] = [
            Chapter(startSeconds: 30, durationSeconds: 30, title: "Second"),
            Chapter(startSeconds: 0, durationSeconds: 30, title: "First"),
            Chapter(startSeconds: 90, durationSeconds: 0, title: "Empty"),
            Chapter(startSeconds: -5, durationSeconds: 10, title: "Impossible"),
        ]
        let normalised = chapters.normalisedChapters()
        #expect(normalised.map(\.title) == ["First", "Second"])
    }

    /// The last chapter's length is not knowable from the list alone, so the
    /// file's duration is what closes it.
    @Test("the last chapter is closed by the file's duration")
    func lastChapterIsClosedByDuration() {
        let chapters = [Chapter(startSeconds: 10, durationSeconds: 0, title: "Only")]
        let normalised = chapters.normalisedChapters(totalDuration: 40)
        #expect(normalised.count == 1)
        #expect(normalised[0].durationSeconds == 30)
    }

    // MARK: - The sample format

    /// **A 3GPP text sample is a 16-bit big-endian BYTE count then UTF-8.**
    ///
    /// Asserted against the format rather than against the reader, because a
    /// writer and reader that share a misunderstanding round-trip perfectly and
    /// produce a file whose chapter titles are empty in every other player.
    @Test("a chapter title is encoded as a big-endian byte count then UTF-8")
    func samplePayloadMatchesTheFormat() {
        let ascii = ChapterTrack.samplePayload(for: "Hi")
        #expect(Array(ascii) == [0x00, 0x02, 0x48, 0x69])

        // The count is of BYTES, not characters: "Café" is four characters and
        // five bytes, and counting characters truncates the last one.
        let accented = ChapterTrack.samplePayload(for: "Café")
        #expect(accented[0] == 0x00)
        #expect(accented[1] == 0x05, "the length must count UTF-8 bytes, not characters")
        #expect(Array(accented.dropFirst(2)) == Array("Café".utf8))

        let empty = ChapterTrack.samplePayload(for: "")
        #expect(Array(empty) == [0x00, 0x00])
    }

    // MARK: - The round trip

    /// **The headline: a chaptered file survives a transcode with its chapters.**
    @Test("chapters survive a transcode, with their titles and their times")
    func chaptersSurviveATranscode() async throws {
        guard let source = await fixture("chapters-source.m4a", {
            try await FixtureLibrary.shared.aacFile(named: "chapters-source.m4a", seconds: 6)
        }) else { return }

        let chaptered = await scratch("chapters-in.m4a")
        let expected: [Chapter] = [
            Chapter(startSeconds: 0, durationSeconds: 2, title: "Opening"),
            Chapter(startSeconds: 2, durationSeconds: 2, title: "Café Scene"),
            Chapter(startSeconds: 4, durationSeconds: 2, title: "Closing"),
        ]
        guard try await writeChapters(expected, from: source, to: chaptered) else {
            withKnownIssue("this machine could not write a chapter track to build the fixture") {
                Issue.record("fixture generation failed")
            }
            return
        }

        // The fixture itself has to be right, or the transcode test proves
        // nothing about the transcode.
        let before = await ChapterTrack.read(from: AVURLAsset(url: chaptered))
        let beforeCount = before.count
        #expect(beforeCount == 3, "the fixture has \(beforeCount) chapters, not 3")

        let destination = await scratch("chapters-out.m4a")
        // The source is already AAC, so the default lossy-source rule and the
        // grew-larger check would both legitimately SKIP this transcode — and a
        // skipped transcode writes nothing, which would make every assertion
        // below about a file that does not exist. Both are overridden here on
        // purpose, and the outcome is asserted first so that a future change to
        // either rule fails loudly rather than silently emptying this test.
        let result = try await transcoder.transcode(
            source: chaptered, to: destination, codec: .aac, quality: .quality(0.5),
            lossySources: .allow, keepLargerOutput: true
        )
        #expect(result.outcome.wasTranscoded,
                "nothing was transcoded (\(result.outcome)), so the rest proves nothing")

        let why = result.chapterLossReason ?? "no reason given"
        #expect(result.preservedChapterCount == 3,
                "preserved \(result.preservedChapterCount) of 3 chapters — \(why)")
        #expect(result.droppedChapterCount == 0)

        let after = await ChapterTrack.read(from: AVURLAsset(url: destination))
        #expect(after.map(\.title) == ["Opening", "Café Scene", "Closing"],
                "titles came back as \(after.map(\.title))")
        for (got, want) in zip(after, expected) {
            #expect(abs(got.startSeconds - want.startSeconds) < 0.2,
                    "\"\(want.title)\" starts at \(got.startSeconds), expected \(want.startSeconds)")
        }
    }

    /// A file with no chapters must not grow an empty chapter track, and must
    /// not report having preserved anything.
    @Test("a file with no chapters gains none")
    func unchapteredFilesAreUnaffected() async throws {
        guard let source = await fixture("chapters-none.m4a", {
            try await FixtureLibrary.shared.aacFile(named: "chapters-none.m4a", seconds: 2)
        }) else { return }
        let destination = await scratch("chapters-none-out.m4a")

        let result = try await transcoder.transcode(
            source: source, to: destination, codec: .aac, quality: .quality(0.5),
            lossySources: .allow, keepLargerOutput: true
        )
        #expect(result.outcome.wasTranscoded)
        #expect(result.preservedChapterCount == 0)
        #expect(result.droppedChapterCount == 0)
        #expect(await ChapterTrack.read(from: AVURLAsset(url: destination)).isEmpty)
    }

    // MARK: - Fixture plumbing

    /// Writes `chapters` into a copy of `source`, using the same machinery under
    /// test — which is acceptable here only because the round-trip test reads
    /// the result back with AVFoundation rather than with our own reader, and
    /// because the sample format is pinned independently above.
    private func writeChapters(
        _ chapters: [Chapter], from source: URL, to destination: URL
    ) async throws -> Bool {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return false }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)

        try? FileManager.default.removeItem(at: destination)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        let input = AVAssetWriterInput(
            mediaType: .audio, outputSettings: nil,
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
