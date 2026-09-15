import AVFoundation
import CoreGraphics
import Foundation
import LatheCore
import LatheFixtures
import Testing

#if canImport(PDFKit)
import PDFKit
#endif

@testable import LatheMeta

/// Reading and writing metadata, and the two ways a metadata tool quietly
/// destroys things: re-encoding what it was only supposed to describe, and
/// writing a field somewhere nothing reads it.
@Suite("Metadata round trip", .serialized)
struct MetadataRoundTripTests {

    private let reader = MetadataReader()
    private let writer = MetadataWriter()

    // MARK: - The headline: nothing is re-encoded

    /// **Injecting metadata into a still must not touch a single DCT
    /// coefficient.**
    ///
    /// Proven rather than assumed, by comparing the entropy-coded scan — every
    /// byte after the `SOS` marker. Re-encoding a JPEG changes that region even
    /// when the image looks identical, so a tool that re-encodes fails this and
    /// passes any test that compares pixels.
    @Test("editing a JPEG's metadata leaves its compressed image bytes identical")
    func jpegIsNotReencoded() async throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("jpeg-lossless")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try DocumentFixtures.write(
            try DocumentFixtures.solidJPEG(),
            to: directory.appendingPathComponent("in.jpg")
        )
        let output = directory.appendingPathComponent("out.jpg")

        var meta = MediaMetadata()
        meta.title = "A corrected title"
        meta.creators = ["A Photographer"]
        try await writer.write(meta, to: source, writingTo: output)

        let before = try jpegScan(of: source)
        let after = try jpegScan(of: output)
        #expect(!before.isEmpty, "the fixture has no scan data to compare")
        #expect(before == after, "the image was re-encoded; metadata editing must be lossless")
    }

    /// The same guarantee for an MP4-family container: every audio sample comes
    /// across untouched.
    @Test("editing an M4A's metadata leaves its samples identical")
    func containerSamplesAreNotReencoded() async throws {
        guard let source = await fixture("meta-source.m4a", {
            try await FixtureLibrary.shared.aacFile(named: "meta-source.m4a", seconds: 2)
        }) else { return }
        let output = await scratch("meta-source-out.m4a")

        var meta = try await reader.read(source)
        meta.title = "Renamed"
        try await writer.write(meta, to: source, writingTo: output)

        let before = try await sampleBytes(of: source)
        let after = try await sampleBytes(of: output)
        #expect(!before.isEmpty, "the fixture has no samples to compare")
        #expect(before == after, "the audio was re-encoded; metadata editing must be lossless")
    }

    // MARK: - The field that decides where a file files itself

    /// **`stik` is what puts a file under TV Shows rather than Movies.**
    ///
    /// A file can have a perfect title, artwork and episode number and still
    /// land in the wrong library section, which reads to a user as the metadata
    /// not having been written at all.
    @Test("the media kind survives, so a player files the result correctly")
    func mediaKindRoundTrips() async throws {
        guard let source = await fixture("meta-kind.m4a", {
            try await FixtureLibrary.shared.aacFile(named: "meta-kind.m4a", seconds: 1)
        }) else { return }

        for kind in [MediaKind.movie, .tvShow, .audiobook, .musicVideo] {
            let output = await scratch("meta-kind-\(kind.rawValue).m4a")
            var meta = MediaMetadata()
            meta.title = "T"
            meta.kind = kind
            try await writer.write(meta, to: source, writingTo: output)

            let read = try await reader.read(output)
            #expect(read.kind == kind, "\(kind.displayName) did not survive the write")
        }
    }

    /// Television's own fields, which have no common-keyspace equivalent and so
    /// are exactly the ones a naive implementation drops.
    @Test("series, season and episode survive a write")
    func showInfoRoundTrips() async throws {
        guard let source = await fixture("meta-show.m4a", {
            try await FixtureLibrary.shared.aacFile(named: "meta-show.m4a", seconds: 1)
        }) else { return }
        let output = await scratch("meta-show-out.m4a")

        var meta = MediaMetadata()
        meta.title = "The One With The Test"
        meta.kind = .tvShow
        meta.show = ShowInfo(
            seriesName: "A Series", seasonNumber: 3, episodeNumber: 5,
            episodeID: "305", network: "A Network"
        )
        meta.longDescription = "A long description that is not the short one."
        meta.summary = "A short one."
        try await writer.write(meta, to: source, writingTo: output)

        let read = try await reader.read(output)
        #expect(read.title == "The One With The Test")
        #expect(read.show?.seriesName == "A Series")
        #expect(read.show?.seasonNumber == 3)
        #expect(read.show?.episodeNumber == 5)
        #expect(read.show?.episodeID == "305")
        #expect(read.show?.network == "A Network")
        // desc and ldes are different atoms and players show them in different
        // places; collapsing them into one field loses that distinction.
        #expect(read.summary == "A short one.")
        #expect(read.longDescription == "A long description that is not the short one.")
    }

    /// Track and disc numbers are an 8-byte packed record, not a number. Written
    /// as a bare integer they produce an atom players ignore — which looks like
    /// the track number simply not being there.
    @Test("track and disc numbers survive, packed the way the atom wants them")
    func trackNumbersRoundTrip() async throws {
        guard let source = await fixture("meta-track.m4a", {
            try await FixtureLibrary.shared.aacFile(named: "meta-track.m4a", seconds: 1)
        }) else { return }
        let output = await scratch("meta-track-out.m4a")

        var meta = MediaMetadata()
        meta.title = "Track"
        meta.kind = .music
        meta.track = TrackInfo(
            albumName: "An Album", albumArtist: "Various", trackNumber: 7, trackCount: 12,
            discNumber: 2, discCount: 2, composer: "A Composer", isCompilation: true
        )
        try await writer.write(meta, to: source, writingTo: output)

        let read = try await reader.read(output)
        #expect(read.track?.trackNumber == 7)
        #expect(read.track?.discNumber == 2)
        #expect(read.track?.albumName == "An Album")
        #expect(read.track?.albumArtist == "Various")
        #expect(read.track?.composer == "A Composer")
        #expect(read.track?.isCompilation == true)
    }

    /// Artwork is the loss a user sees instantly across a whole library, and the
    /// item most likely to go missing because it needs a data type the container
    /// cannot infer.
    @Test("cover art survives a write, byte for byte")
    func artworkRoundTrips() async throws {
        guard let source = await fixture("meta-art.m4a", {
            try await FixtureLibrary.shared.aacFile(named: "meta-art.m4a", seconds: 1)
        }) else { return }
        let output = await scratch("meta-art-out.m4a")

        let png = try DocumentFixtures.solidPNG(gray: 0.25)
        guard let art = Artwork(sniffing: png) else {
            Issue.record("the fixture PNG was not recognised as one")
            return
        }
        #expect(art.format == .png)

        var meta = MediaMetadata()
        meta.title = "With Art"
        meta.artwork = [art]
        try await writer.write(meta, to: source, writingTo: output)

        let read = try await reader.read(output)
        #expect(read.artwork.count == 1)
        #expect(read.artwork.first?.data == png, "the artwork bytes changed")
        #expect(read.artwork.first?.format == .png)
    }

    // MARK: - Stills

    @Test("a still's title, author and date survive")
    func stillTextRoundTrips() async throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("still-text")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try DocumentFixtures.write(
            try DocumentFixtures.solidJPEG(),
            to: directory.appendingPathComponent("in.jpg")
        )
        let output = directory.appendingPathComponent("out.jpg")

        // EXIF timestamps have one-second resolution and no sub-second field, so
        // a fixture date with a fraction would fail on the round trip for a
        // reason that has nothing to do with the code.
        let when = Date(timeIntervalSince1970: 1_600_000_000)
        var meta = MediaMetadata()
        meta.title = "A Photograph"
        meta.summary = "Taken for a test"
        meta.creators = ["A Photographer"]
        meta.copyrightNotice = "© nobody"
        meta.date = when
        try await writer.write(meta, to: source, writingTo: output)

        let read = try await reader.read(output)
        #expect(read.title == "A Photograph")
        #expect(read.summary == "Taken for a test")
        #expect(read.creators.first == "A Photographer")
        #expect(read.copyrightNotice == "© nobody")
        #expect(read.date.map { Int($0.timeIntervalSince1970) } == Int(when.timeIntervalSince1970))
    }

    /// **A southern or western coordinate must not come back mirrored.**
    ///
    /// EXIF stores a magnitude and a hemisphere in separate fields. Reading the
    /// magnitude without its reference — or writing a new magnitude beside the
    /// old reference — puts the photo on the wrong side of the equator or the
    /// meridian, which is a plausible-looking wrong answer rather than an error.
    @Test("a location in the southern and western hemispheres survives with its sign")
    func southWesternLocationRoundTrips() async throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("still-gps")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try DocumentFixtures.write(
            try DocumentFixtures.solidJPEG(),
            to: directory.appendingPathComponent("in.jpg")
        )

        for location in [
            Location(latitude: -33.8688, longitude: 151.2093),       // south, east
            Location(latitude: 51.5072, longitude: -0.1276),         // north, west
            Location(latitude: -34.6037, longitude: -58.3816, altitude: 25),
            Location(latitude: 47.6062, longitude: -122.3321, altitude: -12),
        ] {
            let output = directory.appendingPathComponent("out-\(location.latitude).jpg")
            var meta = MediaMetadata()
            meta.location = location
            try await writer.write(meta, to: source, writingTo: output)

            let read = try await reader.read(output)
            let got = try #require(read.location)
            #expect(abs(got.latitude - location.latitude) < 0.0001,
                    "latitude \(location.latitude) came back as \(got.latitude)")
            #expect(abs(got.longitude - location.longitude) < 0.0001,
                    "longitude \(location.longitude) came back as \(got.longitude)")
            if let expected = location.altitude {
                let altitude = try #require(got.altitude)
                #expect(abs(altitude - expected) < 0.5,
                        "altitude \(expected) came back as \(altitude)")
            }
        }
    }

    /// A write replaces, so clearing a field has to actually clear it —
    /// otherwise there is no way to express "remove the location" that differs
    /// from "leave it alone".
    @Test("clearing a field removes it rather than leaving the old value")
    func clearingAFieldRemovesIt() async throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("still-clear")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try DocumentFixtures.write(
            try DocumentFixtures.solidJPEG(),
            to: directory.appendingPathComponent("in.jpg")
        )
        let tagged = directory.appendingPathComponent("tagged.jpg")
        let cleared = directory.appendingPathComponent("cleared.jpg")

        var meta = MediaMetadata()
        meta.title = "Temporary"
        meta.location = Location(latitude: 10, longitude: 20)
        try await writer.write(meta, to: source, writingTo: tagged)
        #expect(try await reader.read(tagged).location != nil)

        try await writer.update(tagged, writingTo: cleared) { edited in
            edited.location = nil
            edited.title = nil
        }
        let read = try await reader.read(cleared)
        #expect(read.location == nil, "the location survived being cleared")
        #expect(read.title == nil, "the title survived being cleared")
    }

    /// The container write has to REPLACE, not merge, for exactly the reason the
    /// still write does: if the export carried the source's own atoms across and
    /// merged ours on top, removing a field would be impossible and the failure
    /// would be silent.
    @Test("clearing a container field removes it rather than merging over it")
    func containerClearingRemovesFields() async throws {
        guard let source = await fixture("meta-clear.m4a", {
            try await FixtureLibrary.shared.aacFile(
                named: "meta-clear.m4a", seconds: 1,
                title: "Original Title", artist: "Original Artist", album: "Original Album"
            )
        }) else { return }

        // The fixture really does carry the values being cleared, or this test
        // would pass against a file that never had them.
        let original = try await reader.read(source)
        #expect(original.title == "Original Title")

        let tagged = await scratch("meta-clear-out.m4a")
        try await writer.write(MediaMetadata(comment: "only this"), to: source, writingTo: tagged)

        let read = try await reader.read(tagged)
        #expect(read.comment == "only this")
        #expect(read.title == nil, "the old title survived a write that did not include one")
        #expect(read.creators.isEmpty, "the old artist survived")
        #expect(read.track?.albumName == nil, "the old album survived")
    }

    // MARK: - PDF

    @Test("a PDF's title, author and subject survive, and its pages are untouched")
    func pdfRoundTrips() async throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("pdf-meta")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try DocumentFixtures.write(
            try DocumentFixtures.numberedPDF(pageCount: 3),
            to: directory.appendingPathComponent("in.pdf")
        )
        let output = directory.appendingPathComponent("out.pdf")

        var meta = MediaMetadata()
        meta.title = "A Document"
        meta.summary = "What it is about"
        meta.creators = ["An Author"]
        try await writer.write(meta, to: source, writingTo: output)

        let read = try await reader.read(output)
        #expect(read.title == "A Document")
        #expect(read.summary == "What it is about")
        #expect(read.creators.first == "An Author")

        #if canImport(PDFKit)
        let document = try #require(PDFDocument(url: output))
        #expect(document.pageCount == 3)
        #expect(document.page(at: 0)?.string?.contains("PAGE-1") == true)
        #expect(document.page(at: 2)?.string?.contains("PAGE-3") == true)
        #endif
    }

    // MARK: - Store detection and refusals

    @Test("the store is chosen by the bytes, not the filename")
    func storeIsSniffed() async throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("sniff")
        defer { try? FileManager.default.removeItem(at: directory) }

        // A JPEG wearing a .pdf extension is still a JPEG.
        let lying = try DocumentFixtures.write(
            try DocumentFixtures.solidJPEG(),
            to: directory.appendingPathComponent("lying.pdf")
        )
        #expect(try reader.store(of: lying) == .imageProperties)

        let pdf = try DocumentFixtures.write(
            try DocumentFixtures.numberedPDF(pageCount: 1),
            to: directory.appendingPathComponent("real.pdf")
        )
        #expect(try reader.store(of: pdf) == .pdfInfo)

        let png = try DocumentFixtures.write(
            try DocumentFixtures.solidPNG(),
            to: directory.appendingPathComponent("p.png")
        )
        #expect(try reader.store(of: png) == .imageProperties)
    }

    @Test("a file with no metadata store is refused by what it actually is")
    func unknownFileIsRefused() async throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("unknown")
        defer { try? FileManager.default.removeItem(at: directory) }

        let text = try DocumentFixtures.write(
            Data("this is not media".utf8),
            to: directory.appendingPathComponent("notes.txt")
        )
        #expect(throws: LatheError.self) { try reader.store(of: text) }
    }

    /// An MP3 goes through the same public call as everything else, which is
    /// the point of the normalised model: the caller does not have to know that
    /// this one file has no container and its tags are a block bolted to the
    /// front. See ``ID3Tests`` for the format itself.
    @Test("an MP3 is written through the same API as everything else")
    func mp3WritesThroughTheSameAPI() async throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("mp3")
        defer { try? FileManager.default.removeItem(at: directory) }

        var bytes = Data([0xFF, 0xFB, 0x90, 0x00])
        bytes.append(Data(repeating: 0x5A, count: 500))
        let mp3 = try DocumentFixtures.write(bytes, to: directory.appendingPathComponent("a.mp3"))
        let output = directory.appendingPathComponent("b.mp3")

        #expect(try reader.store(of: mp3) == .id3)
        let result = try await writer.write(
            MediaMetadata(title: "Written", creators: ["Someone"]), to: mp3, writingTo: output
        )
        #expect(result.store == .id3)

        let read = try await reader.read(output)
        #expect(read.title == "Written")
        #expect(read.creators == ["Someone"])
    }

    /// Metadata editing is the operation most likely to be asked for in place.
    /// Truncating the input while reading it is not the way to provide that.
    @Test("an edit cannot overwrite the file it is reading")
    func inPlaceIsRefused() async throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("inplace")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try DocumentFixtures.write(
            try DocumentFixtures.solidJPEG(),
            to: directory.appendingPathComponent("in.jpg")
        )
        await #expect(throws: LatheError.self) {
            try await writer.write(MediaMetadata(title: "x"), to: source, writingTo: source)
        }
        // And through a differently spelled path to the same file.
        await #expect(throws: LatheError.self) {
            try await writer.write(
                MediaMetadata(title: "x"), to: source,
                writingTo: directory.appendingPathComponent("./in.jpg")
            )
        }
    }

    // MARK: - Helpers

    /// Everything after the JPEG `SOS` marker: the entropy-coded image data.
    ///
    /// This is the region a re-encode changes and a metadata-only edit does not,
    /// which is what makes "was this re-encoded?" a question with a yes-or-no
    /// answer rather than a visual judgement.
    private func jpegScan(of url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        var index = data.startIndex
        while index < data.index(data.endIndex, offsetBy: -1) {
            if data[index] == 0xFF, data[data.index(after: index)] == 0xDA {
                return data.suffix(from: data.index(index, offsetBy: 2))
            }
            index = data.index(after: index)
        }
        return Data()
    }

    /// Every compressed sample of a file's first track, concatenated.
    ///
    /// Read at passthrough settings — `nil` output settings — so the bytes are
    /// the ones in the file rather than a decoded rendering of them.
    private func sampleBytes(of url: URL) async throws -> Data {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            return Data()
        }
        let assetReader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        assetReader.add(output)
        assetReader.startReading()

        var collected = Data()
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<CChar>?
            guard CMBlockBufferGetDataPointer(
                block, atOffset: 0, lengthAtOffsetOut: nil,
                totalLengthOut: &length, dataPointerOut: &pointer
            ) == noErr, let pointer else { continue }
            collected.append(UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self),
                             count: length)
        }
        return collected
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
            withKnownIssue("could not generate the fixture \"\(name)\" on this machine: \(error)") {
                Issue.record("fixture generation failed")
            }
            return nil
        }
    }
}
