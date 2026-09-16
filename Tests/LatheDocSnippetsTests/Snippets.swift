// The code on the documentation site, compiled.
//
// Every example on docs/documentation.html is cut from this file by
// docs/build.py, between `// snippet: <name>` and `// end`. A sample that
// stops compiling fails the test build, so the page cannot quietly go on
// showing an API that has changed. The functions are never called; the
// suite below only asserts they exist.

import AVFoundation
import Foundation
import Lathe
import LatheAV1
import LatheLookup
import LatheMP3
import LatheSWF
import LatheSWFRender
import Testing

enum Snippets {

    static func probe(_ url: URL) async throws {
        // snippet: probe
        // Reads container headers only, so a four-hour film costs what a
        // four-second clip costs.
        let info = try await MediaProbe().probe(url: url)
        print(info.duration, info.tracks.count)
        // end
    }

    static func frames(_ video: URL, _ folder: URL, _ still: URL) async throws {
        // snippet: frames
        // Twelve stills spread across the whole video, from one generator.
        let stills = try await FrameExtractor().frames(
            from: video, into: folder, selection: .count(12), format: .jpeg)

        // One poster frame, 640 pixels wide.
        let size = try await FrameExtractor().thumbnail(
            from: video, to: still, atSeconds: 5, maxWidth: 640)
        // end
        _ = (stills, size)
    }

    static func transcode(_ source: URL, _ out: URL) async throws {
        // snippet: transcode
        // HEVC on the media engine, at a constant quality rather than a
        // bitrate. Chapters and tags come along.
        let result = try await VideoTranscoder().transcode(
            source: source, to: out,
            codec: .hevc, quality: .quality(0.65), resize: .longestSide(1920))
        print(result.rateControl)   // what actually ran, not what was asked
        // end
    }

    static func image(_ source: URL, _ out: URL) async throws {
        // snippet: image
        // What this device can write is asked of the device, not guessed
        // from an OS version.
        let format = EncodeSupport.shared.firstSupported(of: [.avif, .heic, .jpeg]) ?? .jpeg
        let result = try await ImageEncoder().encode(
            source: source, to: out, format: format,
            quality: .quality(0.8), resize: .longestSide(2048))
        // end
        _ = result
    }

    static func visuallyLossless(_ photo: URL, _ out: URL) async throws {
        // snippet: lossless
        // The lowest quality this picture can take without a visible change,
        // decided for this picture alone. nil: nothing in range passed.
        if let result = try await ImageEncoder().encodeVisuallyLossless(
            source: photo, to: out, format: .heic) {
            print(result.quality, result.similarity.overall, result.encode.outputByteCount)
        }
        // end
    }

    static func videoSearch(_ video: URL, _ out: URL) async throws {
        // snippet: videosearch
        // Try settings on three short clips, not the whole film, then encode
        // once at the lowest one that still looks like the source.
        let search = try await VideoQualitySearch().run(
            asset: AVURLAsset(url: video), outputExtension: "mov"
        ) { clip, value, output in
            try await VideoTranscoder().transcode(
                source: clip, to: output, codec: .hevc, quality: .quality(value))
        }
        if let quality = search.value {
            try await VideoTranscoder().transcode(
                source: video, to: out, codec: .hevc, quality: .quality(quality))
        }
        // end
    }

    static func animate(_ folder: URL, _ out: URL, _ pdf: URL) throws {
        // snippet: animate
        // A folder of frames, in natural order, as an animation or a document.
        let frames = try FrameSequence.contentsOfDirectory(folder)
        try AnimatedImageWriter().write(
            frames, to: out, format: .webp, delays: .uniform(seconds: 1.0 / 12))
        try FrameDocumentWriter().writePDF(frames, to: pdf)
        // end
    }

    static func audio(_ source: URL, _ out: URL) async throws {
        // snippet: audio
        // A measurement, and a decision that stops as soon as it has an answer.
        let volume = try await LoudnessProbe().meanVolumeDB(url: source)
        let audible = try await LoudnessProbe().hasAudibleAudio(url: source)

        // Re-encoding a lossy source is refused unless asked for.
        let outcome = try await AudioTranscoder().transcode(
            source: source, to: out, codec: .aac, quality: .quality(0.5))
        // end
        _ = (volume, audible, outcome)
    }

    static func mp3(_ source: URL, _ out: URL) async throws {
        // snippet: mp3
        // A separate product: nothing else in Lathe links LAME.
        let result = try await MP3Encoder().encode(
            source: source, to: out, quality: .quality(0.6), mode: .jointStereo)
        // end
        _ = result
    }

    static func av1(_ source: URL, _ out: URL) async throws {
        // snippet: av1
        // SVT-AV1 on the CPU — no Apple device encodes AV1 in hardware.
        let result = try await AV1Encoder().encode(
            source: source, to: out,
            options: AV1EncodeOptions(resize: .fit(PixelSize(width: 1920, height: 1080)), bitrate: 2_500_000))
        print(result.frameCount, result.isTenBit)
        // end
    }

    static func tags(_ file: URL, _ out: URL, _ jpeg: Data) async throws {
        // snippet: tags
        // One model over iTunes atoms, ID3, EXIF/IPTC and PDF attributes.
        var metadata = try await MetadataReader().read(file)
        metadata.kind = .tvShow
        metadata.show = ShowInfo(seriesName: "Example", seasonNumber: 2, episodeNumber: 4)
        metadata.artwork = [Artwork(data: jpeg, format: .jpeg, role: .cover)]
        try await MetadataWriter().write(metadata, to: file, writingTo: out)
        // end
    }

    static func chapters(_ film: URL, _ out: URL) async throws {
        // snippet: chapters
        // Chapters are a text track, so writing them is a remux: every sample
        // is copied, nothing is re-encoded.
        let chapters = [
            Chapter(startSeconds: 0, durationSeconds: 90, title: "Opening"),
            Chapter(startSeconds: 90, durationSeconds: 600, title: "Act One"),
        ]
        try await ChapterWriter().write(chapters, into: film, writingTo: out)
        // end
    }

    static func subtitles(_ film: URL, _ srt: String, _ out: URL) async throws {
        // snippet: subtitles
        // SubRip or WebVTT in, a selectable subtitle track out.
        let parsed = try SubtitleParser.parse(srt)
        try await SubtitleMuxer().inject(
            [SubtitleTrackSource(cues: parsed.cues, language: "en")],
            into: film, writingTo: out)
        // end
    }

    static func documents(_ pdf: URL, _ out: URL, _ parts: [URL], _ merged: URL) throws {
        // snippet: documents
        // PDF and CBZ pages, reordered and merged. A CBZ is renamed, not
        // just reshuffled, because its readers sort by filename.
        try DocumentEditor().reorderPages(of: pdf, to: [2, 0, 1], writingTo: out)
        try DocumentEditor().merge(parts, into: merged)
        // end
    }

    static func lookup(_ key: String, _ file: URL) async throws {
        // snippet: lookup
        // The key is the caller's. A library that ships its own key ships one
        // rate limit shared by every app that uses it.
        let provider = TMDbProvider(credentials: ProviderCredentials(apiKey: key))
        let query = MediaTitleParser().query(forFilename: file)
        let matches = try await provider.search(query)
        // end
        _ = matches
    }

    static func flash(_ swf: URL, _ folder: URL) async throws {
        // snippet: flash
        // What a Flash movie stores, recovered as the original files ...
        let report = try SWFCapture().extract(swf, to: folder)

        // ... and what it draws, rendered by Ruffle in an offscreen web view.
        let rendered = try await SWFRenderer().render(swf, to: folder)
        // end
        _ = (report, rendered)
    }

    static func bulk(_ urls: [URL]) async {
        // snippet: bulk
        // Concurrency is rationed per workload: video waits for a hardware
        // encoder, recognition for the Neural Engine.
        let report = await BulkRun(pool: .automatic).run(urls, workload: .video) { url in
            try await MediaProbe().probe(url: url)
        }
        print(report.succeeded.count, report.failedInputs.map(\.input))
        // end
    }
}

@Suite("Documentation samples")
struct SnippetTests {
    @Test("the documented samples compile against the current API")
    func compiled() {
        // Their existence is the test: this file would not build otherwise.
        let samples: [Any] = [
            Snippets.probe, Snippets.frames, Snippets.transcode, Snippets.image,
            Snippets.animate, Snippets.audio, Snippets.mp3, Snippets.av1,
            Snippets.tags, Snippets.chapters, Snippets.subtitles, Snippets.documents,
            Snippets.lookup, Snippets.flash, Snippets.bulk,
            Snippets.visuallyLossless, Snippets.videoSearch,
        ]
        #expect(samples.count == 17)
    }
}
