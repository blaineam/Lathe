import AVFoundation
import CoreMedia
import Foundation
import LatheCore
import LatheFixtures
import Testing

@testable import LatheMeta

/// Chapters written into a file, and chapters surviving a tag edit — both
/// asserted on the file that was written, read back the way a player reads it.
@Suite("Chapter writing", .serialized)
struct ChapterWriterTests {

    private static let seconds: Double = 4
    private static let frame = 1.0 / 24

    private static let chapters = [
        Chapter(startSeconds: 0, durationSeconds: 1.5, title: "Opening"),
        Chapter(startSeconds: 1.5, durationSeconds: 1.5, title: "Café — middle"),
        Chapter(startSeconds: 3, durationSeconds: 1, title: "End"),
    ]

    // MARK: - The regression

    /// **A tag edit must not delete a file's chapters.** The passthrough export
    /// behind ``MetadataWriter`` drops the chapter track for some output types;
    /// every container that can hold chapters is asked here, with a chapter
    /// list written independently of the code under test.
    @Test("chapters survive a tag write", arguments: ["mp4", "m4v", "mov", "m4a"])
    func chaptersSurviveTagWrite(ext: String) async throws {
        guard let source = await chaptered(ext) else { return }
        #expect(await titles(in: source) == Self.chapters.map(\.title),
                "the chaptered fixture has no chapters")

        let output = await scratch("tagged-chapters-out.\(ext)")
        var meta = try await MetadataReader().read(source)
        meta.title = "A new title"
        meta.creators = ["Someone"]
        let result = try await MetadataWriter().write(meta, to: source, writingTo: output)

        let back = try await MetadataReader().read(output)
        #expect(back.title == "A new title")
        #expect(back.creators == ["Someone"])
        expectSame(await ChapterTrack.read(from: AVURLAsset(url: output)), Self.chapters)
        #expect(result.droppedTracks.isEmpty, "\(result.droppedTracks)")
        // Recorded rather than asserted per container: which exports drop the
        // track is the system's business, and the write must work either way.
        #expect([0, Self.chapters.count].contains(result.restoredChapterCount))
    }

    /// **The fallback for an `.mp4` that loses its tags.**
    ///
    /// On macOS 26 the MPEG-4 file type keeps a title and drops the artist, the
    /// artwork, the track and the episode, so `ChapterWriter` writes such a file
    /// again with the M4V brand. The machine this was written on does not lose
    /// the tags, so the fallback never runs by itself here; the writer is told
    /// to go straight to it, and the output is checked the same way the normal
    /// path's is. A `.mp4` name and M4V contents is what ships on those systems.
    @Test("an .mp4 written through the M4V fallback keeps every tag and chapter")
    func mp4FallbackKeepsTags() async throws {
        guard let source = await chaptered("mp4") else { return }
        let png = try DocumentFixtures.solidPNG(gray: 0.4)
        let art = try #require(Artwork(sniffing: png))

        var meta = MediaMetadata()
        meta.title = "Through the fallback"
        meta.creators = ["Someone"]
        meta.kind = .tvShow
        meta.show = ShowInfo(seriesName: "A Series", seasonNumber: 1, episodeNumber: 4)
        meta.track = TrackInfo(trackNumber: 3, trackCount: 9)
        meta.artwork = [art]

        var writer = ChapterWriter()
        writer.mp4FileTypes = [.m4v]
        let output = await scratch("fallback-out.mp4")
        let result = try await writer.write(
            Self.chapters, into: source, writingTo: output,
            metadata: MetadataItemBuilder.items(for: meta), progress: .ignoring())

        #expect(output.pathExtension == "mp4", "the fallback renamed the user's file")
        let back = try await MetadataReader().read(output)
        #expect(back.title == "Through the fallback")
        #expect(back.creators == ["Someone"])
        #expect(back.artwork.first?.data == png)
        #expect(back.track?.trackNumber == 3)
        #expect(back.show?.episodeNumber == 4)
        expectSame(await ChapterTrack.read(from: AVURLAsset(url: output)), Self.chapters)
        #expect(result.chapters.count == Self.chapters.count)
    }

    /// **The same fallback on the tag-only path.** A tag edit of an `.mp4`
    /// with no chapters goes through the passthrough export rather than
    /// ``ChapterWriter``, and loses the same tags on the same systems, so it
    /// retries with the same brand. Forced here for the same reason as above.
    @Test("an .mp4 tag write through the M4V fallback keeps every tag")
    func mp4TagWriteFallbackKeepsTags() async throws {
        guard let plain = await chaptered("mp4", chapters: [], name: "fallback-plain.mp4") else { return }
        let png = try DocumentFixtures.solidPNG(gray: 0.6)
        let art = try #require(Artwork(sniffing: png))

        var meta = MediaMetadata()
        meta.title = "Plain fallback"
        meta.creators = ["Someone"]
        meta.genre = "Drama"
        meta.kind = .tvShow
        meta.show = ShowInfo(seriesName: "A Series", seasonNumber: 1, episodeNumber: 4)
        meta.artwork = [art]

        var writer = MetadataWriter()
        writer.mp4FileTypes = [.m4v]
        // Its own folder: other suites write scratch files into the shared one
        // while this runs, and the leftover check below must see only this write.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("lathe-fallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("fallback-plain-out.mp4")
        try await writer.write(meta, to: plain, writingTo: output)

        #expect(output.pathExtension == "mp4")
        let back = try await MetadataReader().read(output)
        #expect(back.title == "Plain fallback")
        #expect(back.creators == ["Someone"])
        #expect(back.genre == "Drama")
        #expect(back.show?.episodeNumber == 4)
        #expect(back.artwork.first?.data == png)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: output.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".lathe-") }
        #expect(leftovers.isEmpty, "scratch files were left: \(leftovers)")
    }

    /// **3GPP tags read as the fields they are.** What macOS 26 writes for a
    /// plain MPEG-4 export, and what other tools write, reads the same as the
    /// iTunes spelling. The survival check does not accept it as kept.
    @Test("an .mp4 tagged in the 3GPP keyspace reads its title and artist")
    func isoUserDataTags() async throws {
        guard let source = await movie("chapters-base-movie.mov") else { return }
        let output = await scratch("iso-tags.mp4")
        func item(_ identifier: String, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = AVMetadataIdentifier(identifier)
            item.value = value as NSString
            item.extendedLanguageTag = "und"
            return item
        }
        let tags = [item("uiso/titl", "A Title"), item("uiso/perf", "A Performer")]
        try await ChapterWriter().write([], into: source, writingTo: output, metadata: tags, progress: .ignoring())

        let found = try await AVURLAsset(url: output).load(.metadata).compactMap { $0.identifier?.rawValue }
        try #require(found.contains("uiso/perf"), "this system did not write 3GPP tags: \(found)")
        let back = try await MetadataReader().read(output)
        #expect(back.title == "A Title")
        #expect(back.creators == ["A Performer"])

        let itunes = MetadataItemBuilder.items(for: MediaMetadata(title: "A Title", creators: ["A Performer"]))
        #expect(await TagSurvival.allKept(itunes, in: output) == false)
    }

    /// The fast path stays fast: a file with no chapters is exported once and
    /// never remuxed.
    @Test("a file with no chapters is not remuxed by a tag write")
    func unchapteredTagWriteIsPassthrough() async throws {
        guard let source = await movie("chapters-plain.mov") else { return }
        let output = await scratch("chapters-plain-out.mp4")
        let result = try await MetadataWriter().write(
            MediaMetadata(title: "Plain"), to: source, writingTo: output
        )
        #expect(result.restoredChapterCount == 0)
        #expect(try await MetadataReader().read(output).title == "Plain")
        #expect(await titles(in: output).isEmpty)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: output.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(".lathe-") }
        #expect(leftovers.isEmpty, "scratch files were left: \(leftovers)")
    }

    /// **Tags written through the chapter-restoring path are the tags the
    /// passthrough writes.** Every field the round-trip suite checks, written
    /// once into a chaptered file and once into the same file without
    /// chapters, must read back the same.
    @Test("a rich tag write reads back the same with or without chapters", arguments: ["mp4", "m4a", "m4v", "mov"])
    func richTagsWithChapters(ext: String) async throws {
        guard let withChapters = await chaptered(ext),
              let plain = await chaptered(ext, chapters: [], name: "chapters-fixture-plain-\(ext).\(ext)")
        else { return }
        let png = try DocumentFixtures.solidPNG(gray: 0.25)
        let art = try #require(Artwork(sniffing: png))

        var meta = MediaMetadata()
        meta.title = "Everything"
        meta.summary = "Short."
        meta.longDescription = "A longer description."
        meta.creators = ["An Author", "A Narrator"]
        meta.genre = "Drama"
        meta.comment = "A comment"
        meta.copyrightNotice = "© Someone"
        meta.kind = ext == "m4a" ? .audiobook : .tvShow
        meta.show = ShowInfo(seriesName: "A Series", seasonNumber: 2, episodeNumber: 4, episodeID: "204",
                             network: "A Network")
        meta.track = TrackInfo(albumName: "An Album", albumArtist: "Various", trackNumber: 3, trackCount: 9,
                               discNumber: 1, discCount: 2, composer: "A Composer", isCompilation: false)
        meta.artwork = [art]

        let withOut = await scratch("rich-with-\(ext).\(ext)")
        let plainOut = await scratch("rich-plain-\(ext).\(ext)")
        try await MetadataWriter().write(meta, to: withChapters, writingTo: withOut)
        try await MetadataWriter().write(meta, to: plain, writingTo: plainOut)

        let withTags = try await MetadataReader().read(withOut)
        let plainTags = try await MetadataReader().read(plainOut)
        #expect(withTags == plainTags)
        #expect(withTags.title == "Everything")
        #expect(withTags.artwork.first?.data == png, "the artwork bytes changed")
        #expect(withTags.track?.trackNumber == 3)
        #expect(withTags.show?.episodeNumber == 4)
        expectSame(await ChapterTrack.read(from: AVURLAsset(url: withOut)), Self.chapters)
        #expect(await titles(in: plainOut).isEmpty)
    }

    // MARK: - Writing, replacing, removing

    @Test("chapters are written into, replaced in, and removed from a film", arguments: ["mp4", "m4v", "mov"])
    func writeReplaceRemove(ext: String) async throws {
        guard let source = await movie("chapters-base-movie.mov") else { return }
        let writer = ChapterWriter()
        #expect(try await writer.read(from: source).isEmpty)

        let written = await scratch("chapters-written.\(ext)")
        let result = try await writer.write(Self.chapters, into: source, writingTo: written)
        #expect(result.chapters.map(\.title) == Self.chapters.map(\.title))
        #expect(result.droppedTracks.isEmpty, "\(result.droppedTracks)")
        expectSame(try await writer.read(from: written), Self.chapters)
        // The chapter track hangs off the picture, which is where a player looks.
        // The asset is held: a track does not keep its asset alive, and one
        // whose asset has gone reports no associations at all.
        let writtenAsset = AVURLAsset(url: written)
        let video = try #require(try await writtenAsset.loadTracks(withMediaType: .video).first)
        let associated = try await video.loadAssociatedTracks(ofType: .chapterList)
        #expect(associated.count == 1)

        let replacement = [
            Chapter(startSeconds: 0, durationSeconds: 2, title: "First half"),
            Chapter(startSeconds: 2, durationSeconds: 2, title: "Second half"),
        ]
        let replaced = await scratch("chapters-replaced.\(ext)")
        try await writer.write(replacement, into: written, writingTo: replaced)
        expectSame(try await writer.read(from: replaced), replacement)
        #expect(try await AVURLAsset(url: replaced).loadTracks(withMediaType: .text).count == 1,
                "the old chapter track was carried beside the new one")

        let removed = await scratch("chapters-removed.\(ext)")
        let removal = try await writer.write([], into: replaced, writingTo: removed)
        #expect(removal.chapters.isEmpty)
        #expect(try await writer.read(from: removed).isEmpty)
        #expect(try await AVURLAsset(url: removed).loadTracks(withMediaType: .text).isEmpty)
        #expect(try await AVURLAsset(url: removed).loadTracks(withMediaType: .video).count == 1)
        #expect(try await AVURLAsset(url: removed).loadTracks(withMediaType: .audio).count == 1)
    }

    /// An audiobook has no picture, so its chapters hang off the sound.
    @Test("an audio-only M4A takes chapters, and gives them up")
    func audioOnly() async throws {
        guard let source = await audio("chapters-base-audio.m4a") else { return }
        let writer = ChapterWriter()

        let written = await scratch("chapters-audio.m4a")
        try await writer.write(Self.chapters, into: source, writingTo: written)
        expectSame(try await writer.read(from: written), Self.chapters)
        let writtenAsset = AVURLAsset(url: written)
        let sound = try #require(try await writtenAsset.loadTracks(withMediaType: .audio).first)
        #expect(try await sound.loadAssociatedTracks(ofType: .chapterList).count == 1)

        let replacement = [Chapter(startSeconds: 0, durationSeconds: 4, title: "Only")]
        let replaced = await scratch("chapters-audio-replaced.m4a")
        try await writer.write(replacement, into: written, writingTo: replaced)
        expectSame(try await writer.read(from: replaced), replacement)

        let removed = await scratch("chapters-audio-removed.m4a")
        try await writer.write([], into: replaced, writingTo: removed)
        #expect(try await writer.read(from: removed).isEmpty)

        // The tags the fixture was made with come across every time.
        let tags = try await MetadataReader().read(removed)
        #expect(tags.title == "Tone")
        #expect(tags.creators == ["Lathe"])
    }

    /// **A remux, not a transcode.**
    @Test("video and audio samples are copied, not re-encoded")
    func mediaIsNotReencoded() async throws {
        guard let movie = await movie("chapters-base-movie.mov"),
              let sound = await audio("chapters-base-audio.m4a")
        else { return }

        let movieOut = await scratch("chapters-lossless.mp4")
        try await ChapterWriter().write(Self.chapters, into: movie, writingTo: movieOut)
        for type in [AVMediaType.video, .audio] {
            let before = try await sampleBytes(of: movie, type: type)
            let after = try await sampleBytes(of: movieOut, type: type)
            #expect(!before.isEmpty, "the fixture has no \(type.rawValue) samples")
            #expect(before == after, "\(type.rawValue) was re-encoded; writing chapters must be a remux")
        }
        let inDuration = try await AVURLAsset(url: movie).load(.duration).seconds
        let outDuration = try await AVURLAsset(url: movieOut).load(.duration).seconds
        #expect(abs(inDuration - outDuration) < Self.frame)

        let soundOut = await scratch("chapters-lossless.m4a")
        try await ChapterWriter().write(Self.chapters, into: sound, writingTo: soundOut)
        let before = try await sampleBytes(of: sound, type: .audio)
        #expect(!before.isEmpty)
        #expect(before == (try await sampleBytes(of: soundOut, type: .audio)), "the audio was re-encoded")
    }

    /// The chapter writer carries subtitles the same way the subtitle muxer
    /// does — they are the same remux — so a chapter edit does not take a
    /// film's subtitle menu away.
    @Test("subtitle tracks and tags survive a chapter write")
    func subtitlesAndTagsSurvive() async throws {
        guard let source = await movie("chapters-base-movie.mov") else { return }
        let subtitled = await scratch("chapters-subs-in.mp4")
        let cues = [SubtitleCue(startSeconds: 0.5, endSeconds: 1.5, text: "Hello")]
        _ = try await SubtitleMuxer().inject(
            [SubtitleTrackSource(cues: cues, language: "en"),
             SubtitleTrackSource(cues: cues, language: "fr", isDefault: true)],
            into: source, writingTo: subtitled
        )
        let tagged = await scratch("chapters-subs-tagged.mp4")
        try await MetadataWriter().write(MediaMetadata(title: "Subtitled", creators: ["Someone"]),
                                         to: subtitled, writingTo: tagged)

        let output = await scratch("chapters-subs-out.mp4")
        try await ChapterWriter().write(Self.chapters, into: tagged, writingTo: output)

        expectSame(try await ChapterWriter().read(from: output), Self.chapters)
        let tags = try await MetadataReader().read(output)
        #expect(tags.title == "Subtitled")
        #expect(tags.creators == ["Someone"])
        let listed = try await SubtitleMuxer().subtitleTracks(in: output)
        #expect(listed.map(\.languageCode) == ["eng", "fra"])
        let group = try await AVURLAsset(url: output).loadMediaSelectionGroup(for: .legible)
        let options = group?.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
        #expect(options?.count == 2, "the subtitles lost their shared menu")
        #expect(group?.defaultOption?.extendedLanguageTag == "fr", "the default subtitle changed")
        #expect(try await SubtitleMuxer().extractCues(from: output, trackID: listed[0].trackID).map(\.text)
                    == ["Hello"])
    }

    @Test("overlapping and out-of-order chapters are normalised, and the result says how")
    func normalisation() async throws {
        guard let source = await movie("chapters-base-movie.mov") else { return }
        let output = await scratch("chapters-normalised.mp4")
        let messy = [
            Chapter(startSeconds: 2, durationSeconds: 10, title: "Late"),
            Chapter(startSeconds: 0, durationSeconds: 3, title: "Early"),
        ]
        let result = try await ChapterWriter().write(messy, into: source, writingTo: output)
        let expected = [
            Chapter(startSeconds: 0, durationSeconds: 2, title: "Early"),
            Chapter(startSeconds: 2, durationSeconds: 2, title: "Late"),
        ]
        expectSame(result.chapters, expected)
        expectSame(try await ChapterWriter().read(from: output), expected)
    }

    // MARK: - Refusals

    @Test("a container that cannot hold chapters is refused with the reason, before anything is written")
    func unsupportedContainers() async throws {
        guard let source = await audio("chapters-base-audio.m4a") else { return }
        let writer = ChapterWriter()

        for (name, phrase) in [("book.m4b", "no file type for .m4b"), ("song.mp3", "ID3 CHAP"),
                               ("film.mkv", "Matroska"), ("still.jpg", "no timeline"),
                               ("sound.wav", "nowhere to put"), ("noextension", "no extension")] {
            let url = await scratch(name)
            let support = ChapterWriter.support(for: url)
            #expect(!support.isSupported)
            #expect(support.reason?.contains(phrase) == true, "\(name): \(support.reason ?? "no reason")")
            do {
                try await writer.write(Self.chapters, into: source, writingTo: url)
                Issue.record("\(name) was written")
            } catch let error as ChapterError {
                guard case let .unsupportedContainer(_, reason) = error else {
                    Issue.record("\(name): \(error)")
                    continue
                }
                #expect(reason == support.reason)
                #expect(error.localizedDescription.contains(phrase))
                #expect(error.recoverySuggestion != nil)
            }
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        for name in ["a.mp4", "a.M4V", "a.mov", "a.m4a"] {
            #expect(ChapterWriter.support(for: URL(fileURLWithPath: name)) == .supported)
        }

        await #expect(throws: ChapterError.destinationIsSource("chapters-base-audio.m4a")) {
            try await writer.write(Self.chapters, into: source, writingTo: source)
        }
    }

    @Test("cancellation stops the write and leaves no file behind", .timeLimit(.minutes(1)))
    func cancellation() async throws {
        for ext in ["mp4", "m4a"] {
            guard let source = await chaptered(ext) else { return }
            let output = await scratch("chapters-cancel-out.\(ext)")
            let progress = ProgressHandle(sink: ClosureProgressSink { _ in false }, throttle: .unthrottled)
            await #expect(throws: LatheError.self) {
                try await ChapterWriter().write(
                    [Chapter(startSeconds: 0, durationSeconds: 1, title: "x")],
                    into: source, writingTo: output, progress: progress
                )
            }
            #expect(!FileManager.default.fileExists(atPath: output.path))
            let leftovers = try FileManager.default.contentsOfDirectory(
                atPath: output.deletingLastPathComponent().path
            ).filter { $0.hasPrefix(".lathe-chapters-") }
            #expect(leftovers.isEmpty, "scratch files were left: \(leftovers)")
        }
    }

    // MARK: - Helpers

    private func expectSame(
        _ actual: [Chapter], _ expected: [Chapter], sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(actual.map(\.title) == expected.map(\.title), sourceLocation: sourceLocation)
        guard actual.count == expected.count else { return }
        for (a, e) in zip(actual, expected) {
            #expect(abs(a.startSeconds - e.startSeconds) < Self.frame,
                    "\"\(e.title)\" starts at \(a.startSeconds), not \(e.startSeconds)",
                    sourceLocation: sourceLocation)
            #expect(abs(a.durationSeconds - e.durationSeconds) < Self.frame,
                    "\"\(e.title)\" lasts \(a.durationSeconds), not \(e.durationSeconds)",
                    sourceLocation: sourceLocation)
        }
    }

    private func titles(in url: URL) async -> [String] {
        await ChapterTrack.read(from: AVURLAsset(url: url)).map(\.title)
    }

    private func movie(_ name: String) async -> URL? {
        await fixture(name) {
            try await FixtureLibrary.shared.movie(
                named: name, size: PixelSize(width: 160, height: 120), frameRate: 24,
                seconds: Self.seconds, audio: .tone(hertz: 440, amplitude: 0.2)
            )
        }
    }

    private func audio(_ name: String) async -> URL? {
        await fixture(name) {
            try await FixtureLibrary.shared.aacFile(
                named: name, seconds: Self.seconds, title: "Tone", artist: "Lathe"
            )
        }
    }

    private func fixture(_ name: String, _ make: () async throws -> URL) async -> URL? {
        do {
            return try await make()
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

    /// A fixture of type `ext` carrying ``chapters``, built without
    /// ``ChapterWriter`` so the regression test does not depend on the code it
    /// guards.
    private func chaptered(
        _ ext: String, chapters: [Chapter] = Self.chapters, name: String? = nil
    ) async -> URL? {
        let base: URL?
        if ext == "m4a" {
            base = await audio("chapters-base-audio.m4a")
        } else {
            base = await movie("chapters-base-movie.mov")
        }
        guard let base else { return nil }
        let destination = await scratch(name ?? "chapters-fixture-\(ext).\(ext)")
        do {
            try await writeChapters(chapters, from: base, to: destination)
            return destination
        } catch {
            Issue.record("could not write the chaptered fixture: \(error)")
            return nil
        }
    }

    private func writeChapters(_ chapters: [Chapter], from source: URL, to destination: URL) async throws {
        let fileTypes: [String: AVFileType] = ["mp4": .mp4, "m4v": .m4v, "mov": .mov, "m4a": .m4a]
        let fileType = try #require(fileTypes[destination.pathExtension])
        let asset = AVURLAsset(url: source)
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: fileType)
        writer.metadata = try await asset.load(.metadata)

        var pumps: [MetaWriterPump] = []
        var anchor: AVAssetWriterInput?
        for track in try await asset.load(.tracks) where [.video, .audio].contains(track.mediaType) {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            let input = AVAssetWriterInput(
                mediaType: track.mediaType, outputSettings: nil,
                sourceFormatHint: try await track.load(.formatDescriptions).first
            )
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            if anchor == nil || track.mediaType == .video { anchor = input }
            pumps.append(MetaWriterPump(input: input, label: "fixture \(track.trackID)") {
                guard let sample = output.copyNextSampleBuffer() else { return false }
                return input.append(sample)
            })
        }
        let media = try #require(anchor)
        let chapterInput = chapters.isEmpty ? nil : try #require(
            ChapterTrack.makeInput(for: chapters, writer: writer, associatedWith: media).input
        )

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let chapterWrite = chapterInput.map { ChapterTrack.beginWriting(chapters, to: $0) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for pump in pumps { group.addTask { try await pump.run() } }
            try await group.waitForAll()
        }
        _ = await chapterWrite?.value
        await writer.finishWriting()
        #expect(writer.status == .completed, "\(String(describing: writer.error))")
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
}
