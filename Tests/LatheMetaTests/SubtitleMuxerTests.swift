import AVFoundation
import CoreMedia
import Foundation
import LatheCore
import LatheFixtures
import Testing

@testable import LatheMeta

/// Subtitle tracks written into a film and read back out, asserted on the file
/// that was written — the way a player would open it — rather than on what the
/// writer was told.
///
/// These replace the muxing spike that preceded ``SubtitleMuxer``. Its
/// findings live on in the muxer's documentation; its questions are asked here
/// of the shipped code.
@Suite("Subtitle muxing", .serialized)
struct SubtitleMuxerTests {

    private let muxer = SubtitleMuxer()
    private static let seconds: Double = 4
    private static let frame = 1.0 / 24

    private static let english = """
    1
    00:00:00,500 --> 00:00:01,250
    Hello, <i>world</i>.

    2
    00:00:02,000 --> 00:00:03,000
    Second line
    across two

    """

    private static let french = """
    WEBVTT

    00:00.250 --> 00:01.000
    Bonjour à tous

    00:01.500 --> 00:03.750
    Deuxième réplique — «ça va»
    """

    // MARK: - The headline

    /// **The question the spike existed to answer, asked of the real thing.**
    /// Two languages in one MP4, each an option in the legible selection group
    /// a player's subtitle menu is built from, each with the right language —
    /// and each extracting back to exactly what went in.
    @Test("two languages written into an MP4 are selectable, labelled, and round-trip")
    func twoLanguagesRoundTrip() async throws {
        guard let source = await movie("subs-source.mov") else { return }
        let output = await scratch("subs-two.mp4")

        let english = try SubtitleParser.parse(Self.english).cues
        let french = try SubtitleParser.parse(Self.french).cues
        let result = try await muxer.inject([
            SubtitleTrackSource(cues: english, language: "en", title: "English"),
            SubtitleTrackSource(cues: french, language: "fr-CA", title: "Français"),
        ], into: source, writingTo: output)

        #expect(result.cuesWritten == [2, 2])
        #expect(result.cuesOutsideFilm == [0, 0])
        #expect(result.droppedTracks.isEmpty, "\(result.droppedTracks)")

        // What a player sees.
        let asset = AVURLAsset(url: output)
        let tracks = try await asset.loadTracks(withMediaType: .subtitle)
        #expect(tracks.count == 2)
        let group = try #require(try await asset.loadMediaSelectionGroup(for: .legible),
                                 "no legible group: a player would show no subtitle menu")
        // AVFoundation adds a forced-only option beside every full track, so
        // the tracks written are the options that are not forced-only.
        let options = group.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
        #expect(options.count == 2)
        // What a viewer reads, including the region from the BCP 47 tag, which
        // the three-letter code cannot carry.
        #expect(options.map { $0.displayName(with: Locale(identifier: "en")) }
                    == ["English", "French (Canada)"])
        #expect(Set(options.compactMap { $0.locale?.language.languageCode?.identifier }) == ["en", "fr"])
        #expect(group.allowsEmptySelection, "subtitles must be switchable off")
        #expect(group.defaultOption == nil, "subtitles should start off unless asked")

        let codes = try await tracks.asyncMap { try await $0.load(.languageCode) }
        let tags = try await tracks.asyncMap { try await $0.load(.extendedLanguageTag) }
        #expect(codes == ["eng", "fra"])
        #expect(tags == ["en", "fr-CA"])

        let listed = try await muxer.subtitleTracks(in: output)
        #expect(listed.map(\.title) == ["English", "Français"])
        #expect(listed == result.addedTracks)
        #expect(listed.allSatisfy { $0.codec == "tx3g" && $0.isExtractable })

        // Extraction reproduces the cues, within a frame.
        let backEnglish = try await muxer.extractCues(from: output, trackID: listed[0].trackID)
        let backFrench = try await muxer.extractCues(from: output, trackID: listed[1].trackID)
        expectSame(backEnglish, english)
        expectSame(backFrench, french)
        #expect(backEnglish[0].styles == [SubtitleStyleRun(range: 7..<12, style: .italic)],
                "italics were lost in the sample")

        // And to SubRip text a person could open.
        let srt = try await muxer.extractSubRip(from: output)
        #expect(srt.contains("00:00:00,500 --> 00:00:01,250\nHello, <i>world</i>."))
        expectSame(try SubtitleParser.parse(srt).cues, english)
    }

    /// **A remux, not a transcode.** Every compressed video and audio sample
    /// in the output is the one in the source, byte for byte.
    @Test("video and audio samples are copied, not re-encoded")
    func mediaIsNotReencoded() async throws {
        guard let source = await movie("subs-lossless.mov") else { return }
        let output = await scratch("subs-lossless-out.mov")

        _ = try await muxer.inject(
            [SubtitleTrackSource(cues: try SubtitleParser.parse(Self.english).cues, language: "en")],
            into: source, writingTo: output
        )

        for type in [AVMediaType.video, .audio] {
            let before = try await sampleBytes(of: source, type: type)
            let after = try await sampleBytes(of: output, type: type)
            #expect(!before.isEmpty, "the fixture has no \(type.rawValue) samples")
            #expect(before == after, "\(type.rawValue) was re-encoded; adding subtitles must be a remux")
        }
        let inDuration = try await AVURLAsset(url: source).load(.duration).seconds
        let outDuration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(inDuration - outDuration) < Self.frame)
    }

    @Test("M4V and MOV take subtitle tracks too; MKV is refused before anything is written")
    func containers() async throws {
        guard let source = await movie("subs-containers.mov") else { return }
        let cues = try SubtitleParser.parse(Self.english).cues
        for ext in ["m4v", "mov"] {
            let output = await scratch("subs-container.\(ext)")
            _ = try await muxer.inject([SubtitleTrackSource(cues: cues, language: "en")],
                                       into: source, writingTo: output)
            let options = try await AVURLAsset(url: output).loadMediaSelectionGroup(for: .legible)?.options
                .filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
            #expect(options?.count == 1, ".\(ext) output has no selectable subtitle")
            expectSame(try await muxer.extractCues(from: output), cues)
        }

        let mkv = await scratch("subs-container.mkv")
        await #expect(throws: SubtitleError.unsupportedContainer(".mkv")) {
            try await muxer.inject([SubtitleTrackSource(cues: cues, language: "en")],
                                   into: source, writingTo: mkv)
        }
        #expect(!FileManager.default.fileExists(atPath: mkv.path))
    }

    // MARK: - Existing tracks

    @Test("existing subtitles are kept, replaced by language, or removed, as asked")
    func existingTracks() async throws {
        guard let source = await movie("subs-existing.mov") else { return }
        let first = await scratch("subs-existing-1.mp4")
        let english = try SubtitleParser.parse(Self.english).cues
        let french = try SubtitleParser.parse(Self.french).cues
        _ = try await muxer.inject([
            SubtitleTrackSource(cues: english, language: "en"),
            SubtitleTrackSource(cues: french, language: "fr"),
        ], into: source, writingTo: first)

        // Keep: a third track joins the other two, in the same menu.
        let kept = await scratch("subs-existing-keep.mp4")
        let keep = try await muxer.inject(
            [SubtitleTrackSource(cues: french, language: "de", isDefault: true)],
            into: first, writingTo: kept
        )
        #expect(keep.keptSubtitleTrackCount == 2)
        let keptAsset = AVURLAsset(url: kept)
        let group = try await keptAsset.loadMediaSelectionGroup(for: .legible)
        let full = group?.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
        #expect(full?.count == 3, "kept and new tracks must share one menu")
        #expect(group?.defaultOption?.extendedLanguageTag == "de", "the new default was not the default")
        // The copied English track still reads back as it was written.
        let listing = try await muxer.subtitleTracks(in: kept)
        #expect(listing.map(\.languageCode) == ["eng", "fra", "deu"])
        expectSame(try await muxer.extractCues(from: kept, trackID: listing[0].trackID), english)

        // Replace: the English track goes, its replacement arrives.
        let replaced = await scratch("subs-existing-replace.mp4")
        let fixed = english.map { SubtitleCue(startSeconds: $0.startSeconds + 0.5,
                                              endSeconds: $0.endSeconds + 0.5, text: $0.text) }
        let replace = try await muxer.inject(
            [SubtitleTrackSource(cues: fixed, language: "en-GB")],
            into: first, writingTo: replaced, existing: .replaceSameLanguage
        )
        #expect(replace.removedSubtitleTrackCount == 1)
        let afterReplace = try await muxer.subtitleTracks(in: replaced)
        #expect(afterReplace.map(\.languageCode) == ["fra", "eng"])
        expectSame(try await muxer.extractCues(from: replaced, trackID: afterReplace[1].trackID), fixed)

        // Remove, with nothing to add: a file with no subtitles at all.
        let stripped = await scratch("subs-existing-strip.mp4")
        let strip = try await muxer.inject([], into: first, writingTo: stripped, existing: .removeAll)
        #expect(strip.removedSubtitleTrackCount == 2)
        #expect(try await muxer.subtitleTracks(in: stripped).isEmpty)
        #expect(try await AVURLAsset(url: stripped).loadTracks(withMediaType: .video).count == 1)
    }

    // MARK: - Characteristics

    @Test("forced and SDH tracks say so, where a player looks")
    func forcedAndSDH() async throws {
        guard let source = await movie("subs-flags.mov") else { return }
        let output = await scratch("subs-flags-out.mp4")
        let cues = try SubtitleParser.parse(Self.english).cues
        _ = try await muxer.inject([
            SubtitleTrackSource(cues: cues, language: "en", isForced: true),
            SubtitleTrackSource(cues: cues, language: "en", isHearingImpaired: true),
        ], into: source, writingTo: output)

        let listed = try await muxer.subtitleTracks(in: output)
        #expect(listed.map(\.isForced) == [true, false])
        #expect(listed.map(\.isHearingImpaired) == [false, true])

        let options = try await AVURLAsset(url: output).loadMediaSelectionGroup(for: .legible)?.options ?? []
        #expect(options.contains { $0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) },
                "no option is marked forced")
        #expect(options.contains { $0.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility) },
                "no option is marked SDH")
    }

    // MARK: - Timing at the edges

    @Test("overlaps are merged, gaps stay empty, and cues past the end are clipped or dropped")
    func timingEdges() async throws {
        guard let source = await movie("subs-edges.mov") else { return }
        let output = await scratch("subs-edges-out.mp4")
        let cues = [
            SubtitleCue(startSeconds: 0.5, endSeconds: 2, text: "A"),
            SubtitleCue(startSeconds: 1, endSeconds: 1.5, text: "B"),
            SubtitleCue(startSeconds: 3.5, endSeconds: 9, text: "Runs long"),
            SubtitleCue(startSeconds: 12, endSeconds: 13, text: "After the end"),
        ]
        let result = try await muxer.inject([SubtitleTrackSource(cues: cues, language: "en")],
                                            into: source, writingTo: output)
        #expect(result.cuesOutsideFilm == [1])

        let back = try await muxer.extractCues(from: output)
        #expect(back.map(\.text) == ["A", "A\nB", "A", "Runs long"])
        let last = try #require(back.last)
        #expect(abs(last.endSeconds - Self.seconds) < Self.frame, "clipped at the film's end")

        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .subtitle).first)
        let range = try await track.load(.timeRange)
        #expect(abs(range.duration.seconds - Self.seconds) < Self.frame,
                "the subtitle track should span the film, not stop at its last cue")

        await #expect(throws: SubtitleError.cuesOutsideFilm(language: "en")) {
            try await muxer.inject(
                [SubtitleTrackSource(cues: [SubtitleCue(startSeconds: 60, endSeconds: 61, text: "x")],
                                     language: "en")],
                into: source, writingTo: await scratch("subs-edges-none.mp4")
            )
        }
    }

    // MARK: - Refusals

    @Test("bad requests fail before writing, with an error that says what to do")
    func refusals() async throws {
        guard let source = await movie("subs-refusals.mov") else { return }
        let cues = [SubtitleCue(startSeconds: 0, endSeconds: 1, text: "x")]
        let output = await scratch("subs-refusals-out.mp4")

        await #expect(throws: SubtitleError.invalidLanguage("english please")) {
            try await muxer.inject([SubtitleTrackSource(cues: cues, language: "english please")],
                                   into: source, writingTo: output)
        }
        await #expect(throws: SubtitleError.destinationIsSource("subs-refusals.mov")) {
            try await muxer.inject([SubtitleTrackSource(cues: cues, language: "en")],
                                   into: source, writingTo: source)
        }
        await #expect(throws: SubtitleError.noCues) {
            try await muxer.inject([SubtitleTrackSource(cues: [], language: "en")],
                                   into: source, writingTo: output)
        }
        await #expect(throws: LatheError.self) {
            try await muxer.inject([], into: source, writingTo: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path), "a refused write left a file")

        let audioOnly = try await FixtureLibrary.shared.aacFile(named: "subs-audio-only.m4a", seconds: 1)
        await #expect(throws: SubtitleError.noVideoTrack("subs-audio-only.m4a")) {
            try await muxer.inject([SubtitleTrackSource(cues: cues, language: "en")],
                                   into: audioOnly, writingTo: await scratch("subs-audio-out.mp4"))
        }

        await #expect(throws: SubtitleError.trackNotFound(trackID: 99)) {
            try await muxer.extractCues(from: source, trackID: 99)
        }
        await #expect(throws: SubtitleError.trackNotFound(trackID: 1)) {
            try await muxer.extractCues(from: source, trackID: 1)   // the video track
        }
        await #expect(throws: SubtitleError.trackNotFound(trackID: 0)) {
            try await muxer.extractCues(from: source)   // no subtitles at all
        }
    }

    @Test("cancellation stops the write and leaves no file behind")
    func cancellation() async throws {
        guard let source = await movie("subs-cancel.mov") else { return }
        let output = await scratch("subs-cancel-out.mp4")
        let progress = ProgressHandle(sink: ClosureProgressSink { _ in false }, throttle: .unthrottled)
        await #expect(throws: LatheError.self) {
            try await muxer.inject(
                [SubtitleTrackSource(cues: [SubtitleCue(startSeconds: 0, endSeconds: 1, text: "x")],
                                     language: "en")],
                into: source, writingTo: output, progress: progress
            )
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: output.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".lathe-subtitles-") }
        #expect(leftovers.isEmpty, "scratch files were left: \(leftovers)")
    }

    // MARK: - Chapters

    @Test("a chaptered film keeps its chapters through a subtitle injection")
    func chaptersSurvive() async throws {
        guard let source = await movie("subs-chapters-src.mov") else { return }
        let chaptered = await scratch("subs-chapters-in.mp4")
        let chapters = [
            Chapter(startSeconds: 0, durationSeconds: 2, title: "One"),
            Chapter(startSeconds: 2, durationSeconds: 2, title: "Two"),
        ]
        try await writeChapters(chapters, from: source, to: chaptered)
        #expect(await ChapterTrack.read(from: AVURLAsset(url: chaptered)).count == 2,
                "the chaptered fixture has no chapters")

        let output = await scratch("subs-chapters-out.mp4")
        let result = try await muxer.inject(
            [SubtitleTrackSource(cues: try SubtitleParser.parse(Self.english).cues, language: "en")],
            into: chaptered, writingTo: output
        )
        #expect(result.preservedChapterCount == 2)
        #expect(await ChapterTrack.read(from: AVURLAsset(url: output)).map(\.title) == ["One", "Two"])
        #expect(try await muxer.subtitleTracks(in: output).count == 1,
                "the chapter track must not be mistaken for a subtitle track")
    }

    // MARK: - Helpers

    private func expectSame(
        _ actual: [SubtitleCue], _ expected: [SubtitleCue], sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(actual.map(\.text) == expected.map(\.text), sourceLocation: sourceLocation)
        guard actual.count == expected.count else { return }
        for (a, e) in zip(actual, expected) {
            #expect(abs(a.startSeconds - e.startSeconds) < Self.frame,
                    "\"\(e.text)\" starts at \(a.startSeconds), not \(e.startSeconds)",
                    sourceLocation: sourceLocation)
            #expect(abs(a.endSeconds - e.endSeconds) < Self.frame,
                    "\"\(e.text)\" ends at \(a.endSeconds), not \(e.endSeconds)",
                    sourceLocation: sourceLocation)
        }
    }

    private func movie(_ name: String) async -> URL? {
        do {
            return try await FixtureLibrary.shared.movie(
                named: name, size: PixelSize(width: 160, height: 120), frameRate: 24,
                seconds: Self.seconds, audio: .tone(hertz: 440, amplitude: 0.2)
            )
        } catch {
            withKnownIssue("could not generate the fixture \"\(name)\" on this machine: \(error)") {
                Issue.record("fixture generation failed")
            }
            return nil
        }
    }

    private func scratch(_ name: String) async -> URL {
        let url = await FixtureLibrary.shared.scratchURL(named: name)
        try? FileManager.default.removeItem(at: url)
        return url
    }

    private func sampleBytes(of url: URL, type: AVMediaType) async throws -> [Data] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: type).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var samples: [Data] = []
        while let buffer = output.copyNextSampleBuffer() {
            for sample in SubtitleMuxer.samples(in: buffer) {
                samples.append(Data(sample.bytes))
            }
        }
        return samples
    }

    /// A copy of `source` with a chapter list, written the way the video
    /// transcoder's chapter tests do.
    private func writeChapters(_ chapters: [Chapter], from source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        let video = AVAssetWriterInput(
            mediaType: .video, outputSettings: nil,
            sourceFormatHint: try await track.load(.formatDescriptions).first
        )
        video.expectsMediaDataInRealTime = false
        writer.add(video)
        let chapterInput = try #require(
            ChapterTrack.makeInput(for: chapters, writer: writer, associatedWith: video).input
        )

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let chapterWrite = ChapterTrack.beginWriting(chapters, to: chapterInput)
        let pump = MetaWriterPump(input: video, label: "fixture") {
            guard let sample = output.copyNextSampleBuffer() else { return false }
            return video.append(sample)
        }
        try await pump.run()
        _ = await chapterWrite.value
        await writer.finishWriting()
        #expect(writer.status == .completed, "\(String(describing: writer.error))")
    }
}

extension Array {
    fileprivate func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for element in self { out.append(try await transform(element)) }
        return out
    }
}
