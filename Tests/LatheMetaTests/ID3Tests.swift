import Foundation
import LatheCore
import LatheFixtures
import Testing

@testable import LatheMeta

/// ID3 tags: the bytes on disk, and the audio that must survive untouched.
///
/// ## Why several of these assert on raw bytes
///
/// There is no MP3 encoder on Apple platforms, so these tests cannot compare
/// against a file produced by anything else. A reader and a writer tested only
/// against each other agree about everything, including their shared mistakes —
/// a writer that emitted plain big-endian frame sizes and a reader that expected
/// them would round-trip perfectly and produce tags no other software could
/// read. So the layout tests below check the emitted bytes against values
/// computed by hand from the specification, and the parser tests feed it tags
/// assembled by hand rather than by the writer.
@Suite("ID3 tags")
struct ID3Tests {

    private let reader = MetadataReader()
    private let writer = MetadataWriter()

    // MARK: - Byte layout, checked against the spec rather than against ourselves

    /// A syncsafe integer is four bytes of seven bits, so no byte can be
    /// mistaken for the start of an MPEG frame sync. Getting this wrong is the
    /// single most common way a tag is written that only its author can read:
    /// v2.3 used a plain integer here and v2.4 did not.
    @Test("syncsafe integers use seven bits per byte, both ways")
    func syncsafeArithmetic() {
        // 255 is the first value where the difference shows: 0x000000FF plain,
        // 0x00000181 syncsafe.
        #expect(ID3Tag.syncsafeBytes(255) == [0x00, 0x00, 0x01, 0x7F])
        #expect(ID3Tag.syncsafe([0x00, 0x00, 0x01, 0x7F]) == 255)

        #expect(ID3Tag.syncsafeBytes(0) == [0, 0, 0, 0])
        #expect(ID3Tag.syncsafeBytes(127) == [0x00, 0x00, 0x00, 0x7F])
        #expect(ID3Tag.syncsafeBytes(128) == [0x00, 0x00, 0x01, 0x00])
        #expect(ID3Tag.syncsafe([0x00, 0x00, 0x01, 0x00]) == 128)

        // The largest value the format can express, and a round trip through it.
        let max = (1 << 28) - 1
        #expect(ID3Tag.syncsafe(ID3Tag.syncsafeBytes(max)) == max)

        // A byte with its high bit set is not syncsafe, and saying so is how a
        // v2.3 tag is caught being read as a v2.4 one.
        #expect(ID3Tag.syncsafe([0x00, 0x00, 0x00, 0xFF]) == nil)
    }

    /// The header and the first frame, byte by byte, against the spec.
    @Test("the emitted tag has the header and frame layout the format specifies")
    func emittedLayoutMatchesTheSpecification() {
        let tag = ID3Tag(
            frames: [ID3Tag.Frame(id: "TIT2", payload: .text(["Hi"]))],
            byteCount: 0
        )
        let bytes = [UInt8](tag.serialise())

        // Header: "ID3", version 4.0, no flags, then the body size syncsafe.
        #expect(Array(bytes[0..<3]) == Array("ID3".utf8))
        #expect(bytes[3] == 0x04)
        #expect(bytes[4] == 0x00)
        #expect(bytes[5] == 0x00)

        // One frame: 4-byte ID, 4-byte syncsafe size, 2 flag bytes, payload.
        // The payload is one encoding byte (0x03, UTF-8) plus "Hi".
        let payloadSize = 1 + 2
        let bodySize = 10 + payloadSize
        #expect(Array(bytes[6..<10]) == ID3Tag.syncsafeBytes(bodySize))
        #expect(Array(bytes[10..<14]) == Array("TIT2".utf8))
        #expect(Array(bytes[14..<18]) == ID3Tag.syncsafeBytes(payloadSize))
        #expect(Array(bytes[18..<20]) == [0x00, 0x00])
        #expect(bytes[20] == 0x03)
        #expect(Array(bytes[21..<23]) == Array("Hi".utf8))
        #expect(bytes.count == 10 + bodySize)
    }

    /// A tag assembled by hand, parsed. The input here owes nothing to the
    /// writer, so agreement means the parser reads the format rather than our
    /// own dialect of it.
    @Test("a hand-built v2.4 tag parses")
    func parsesAHandBuiltTag() throws {
        var body = Data()
        let payload = Data([0x03]) + Data("Hand Built".utf8)
        body.append(Data("TIT2".utf8))
        body.append(contentsOf: ID3Tag.syncsafeBytes(payload.count))
        body.append(contentsOf: [0x00, 0x00])
        body.append(payload)

        var file = Data("ID3".utf8)
        file.append(contentsOf: [0x04, 0x00, 0x00])
        file.append(contentsOf: ID3Tag.syncsafeBytes(body.count))
        file.append(body)
        let audioOffset = file.count
        file.append(contentsOf: [0xFF, 0xFB, 0x90, 0x00])

        let tag = try #require(try ID3Tag.parse(file, name: "hand.mp3"))
        #expect(tag.byteCount == audioOffset)
        #expect(tag.frames.count == 1)
        #expect(tag.frames.first?.id == "TIT2")
        #expect(tag.frames.first?.payload == .text(["Hand Built"]))
    }

    /// **v2.3 frame sizes are plain integers, not syncsafe.** A parser that
    /// assumes otherwise reads a wrong length for every frame past the first and
    /// silently returns a truncated tag.
    @Test("a v2.3 tag's plain frame sizes are read as plain, not syncsafe")
    func parsesVersion23FrameSizes() throws {
        // A payload of 130 bytes: syncsafe that is [0,0,1,2], plain [0,0,0,130].
        // Reading one as the other lands 128 bytes away from the truth.
        let text = String(repeating: "x", count: 129)
        let payload = Data([0x00]) + Data(text.utf8)   // ISO-8859-1
        #expect(payload.count == 130)

        var body = Data()
        body.append(Data("TIT2".utf8))
        body.append(contentsOf: [0x00, 0x00, 0x00, 0x82])   // 130, plain
        body.append(contentsOf: [0x00, 0x00])
        body.append(payload)

        var file = Data("ID3".utf8)
        file.append(contentsOf: [0x03, 0x00, 0x00])          // v2.3
        file.append(contentsOf: ID3Tag.syncsafeBytes(body.count))
        file.append(body)
        file.append(contentsOf: [0xFF, 0xFB, 0x90, 0x00])

        let tag = try #require(try ID3Tag.parse(file, name: "v23.mp3"))
        #expect(tag.frames.first?.payload == .text([text]))
    }

    /// Unsynchronisation inserts a zero after every 0xFF. Undoing it has to
    /// happen before any length is read, or every length after the first
    /// inserted byte is wrong.
    @Test("unsynchronisation is undone before anything reads a length")
    func undoesUnsynchronisation() {
        #expect(ID3Tag.removeUnsynchronisation([0xFF, 0x00, 0xFB]) == [0xFF, 0xFB])
        #expect(ID3Tag.removeUnsynchronisation([0x01, 0xFF, 0x00, 0x02]) == [0x01, 0xFF, 0x02])
        // A 0xFF that was already last stays as it is.
        #expect(ID3Tag.removeUnsynchronisation([0x01, 0xFF]) == [0x01, 0xFF])
        // Nothing to undo.
        #expect(ID3Tag.removeUnsynchronisation([0x01, 0x02, 0x03]) == [0x01, 0x02, 0x03])
    }

    @Test("a file with no tag is not an error, it is a file with no tag")
    func noTagIsNotAnError() throws {
        let audio = Data([0xFF, 0xFB, 0x90, 0x00, 0x11, 0x22])
        #expect(try ID3Tag.parse(audio, name: "bare.mp3") == nil)
    }

    @Test("a tag claiming to be longer than the file is refused")
    func impossibleSizeIsRefused() {
        var file = Data("ID3".utf8)
        file.append(contentsOf: [0x04, 0x00, 0x00])
        file.append(contentsOf: ID3Tag.syncsafeBytes(9999))
        file.append(contentsOf: [0xFF, 0xFB])
        #expect(throws: LatheError.self) { try ID3Tag.parse(file, name: "lying.mp3") }
    }

    // MARK: - The audio must come across untouched

    /// **An ID3 write copies the audio; it does not re-mux it.**
    ///
    /// Stronger than the container case, and easier to verify: the bytes after
    /// the tag must be identical, in full.
    @Test("writing tags leaves every audio byte identical")
    func audioIsCopiedVerbatim() async throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("id3-audio")
        defer { try? FileManager.default.removeItem(at: directory) }

        let audio = Self.fakeAudio(bytes: 4096)
        let source = try DocumentFixtures.write(
            Self.mp3(tag: Self.handTag(title: "Before"), audio: audio),
            to: directory.appendingPathComponent("in.mp3")
        )
        let output = directory.appendingPathComponent("out.mp3")

        try await writer.write(MediaMetadata(title: "After"), to: source, writingTo: output)

        let written = try Data(contentsOf: output)
        let layout = try ID3File.layout(of: written, name: "out.mp3")
        #expect(written.subdata(in: layout.audio) == audio, "the audio changed")
    }

    // MARK: - Round trip through the model

    @Test("the fields ID3 has frames for survive a write")
    func fieldsRoundTrip() async throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("id3-round")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try DocumentFixtures.write(
            Self.mp3(tag: Data(), audio: Self.fakeAudio(bytes: 512)),
            to: directory.appendingPathComponent("in.mp3")
        )
        let output = directory.appendingPathComponent("out.mp3")

        let when = Date(timeIntervalSince1970: 1_600_000_000)
        var meta = MediaMetadata()
        meta.title = "A Song"
        meta.summary = "A subtitle"
        meta.longDescription = "Something much longer than the subtitle."
        meta.creators = ["First Artist", "Second Artist"]
        meta.genre = "Test"
        meta.comment = "A comment"
        meta.copyrightNotice = "© nobody"
        meta.date = when
        meta.track = TrackInfo(
            albumName: "An Album", albumArtist: "Various", trackNumber: 7, trackCount: 12,
            discNumber: 2, discCount: 2, composer: "A Composer", isCompilation: true
        )
        meta.identifiers = ["musicbrainz": "abc-123"]

        let result = try await writer.write(meta, to: source, writingTo: output)
        #expect(result.store == .id3)

        let read = try await reader.read(output)
        #expect(read.title == "A Song")
        #expect(read.summary == "A subtitle")
        #expect(read.longDescription == "Something much longer than the subtitle.")
        #expect(read.creators == ["First Artist", "Second Artist"],
                "v2.4 stores several values in one frame, separated by a null")
        #expect(read.genre == "Test")
        #expect(read.comment == "A comment")
        #expect(read.copyrightNotice == "© nobody")
        #expect(read.date.map { Int($0.timeIntervalSince1970) } == Int(when.timeIntervalSince1970))
        #expect(read.track?.albumName == "An Album")
        #expect(read.track?.albumArtist == "Various")
        #expect(read.track?.trackNumber == 7)
        #expect(read.track?.trackCount == 12)
        #expect(read.track?.discNumber == 2)
        #expect(read.track?.discCount == 2)
        #expect(read.track?.composer == "A Composer")
        #expect(read.track?.isCompilation == true)
        #expect(read.identifiers["musicbrainz"] == "abc-123")
    }

    /// Non-ASCII has to survive, which means writing UTF-8 and saying so. A
    /// tagger that writes UTF-8 bytes under the ISO-8859-1 encoding byte
    /// produces mojibake everywhere except its own reader.
    @Test("non-ASCII text survives, because the encoding byte is honest")
    func unicodeRoundTrips() async throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("id3-unicode")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try DocumentFixtures.write(
            Self.mp3(tag: Data(), audio: Self.fakeAudio(bytes: 256)),
            to: directory.appendingPathComponent("in.mp3")
        )
        let output = directory.appendingPathComponent("out.mp3")

        let title = "Où est la bibliothèque? 日本語 🎧"
        try await writer.write(MediaMetadata(title: title), to: source, writingTo: output)
        #expect(try await reader.read(output).title == title)
    }

    @Test("cover art survives, byte for byte, with its format")
    func artworkRoundTrips() async throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("id3-art")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try DocumentFixtures.write(
            Self.mp3(tag: Data(), audio: Self.fakeAudio(bytes: 256)),
            to: directory.appendingPathComponent("in.mp3")
        )
        let output = directory.appendingPathComponent("out.mp3")

        let png = try DocumentFixtures.solidPNG(gray: 0.3)
        let jpeg = try DocumentFixtures.solidJPEG(gray: 0.7)
        var meta = MediaMetadata()
        meta.artwork = [
            Artwork(sniffing: png)!,
            Artwork(data: jpeg, format: .jpeg, role: .poster),
        ]
        try await writer.write(meta, to: source, writingTo: output)

        let read = try await reader.read(output)
        #expect(read.artwork.count == 2)
        #expect(read.artwork.first?.data == png)
        #expect(read.artwork.first?.format == .png)
        #expect(read.artwork.first?.role == .cover)
        #expect(read.artwork.last?.data == jpeg)
        #expect(read.artwork.last?.format == .jpeg)
        #expect(read.artwork.last?.role == .poster)
    }

    // MARK: - What ID3 cannot say, and what it must not keep

    /// ID3 has no series or episode frames. Losing them is unavoidable; losing
    /// them quietly is not.
    @Test("fields ID3 cannot express are named in the result")
    func unrepresentedFieldsAreReported() async throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("id3-lossy")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try DocumentFixtures.write(
            Self.mp3(tag: Data(), audio: Self.fakeAudio(bytes: 256)),
            to: directory.appendingPathComponent("in.mp3")
        )
        let output = directory.appendingPathComponent("out.mp3")

        var meta = MediaMetadata(title: "T")
        meta.show = ShowInfo(seriesName: "A Series", seasonNumber: 1, episodeNumber: 2)
        meta.kind = .tvShow
        meta.location = Location(latitude: 1, longitude: 2)

        let result = try await writer.write(meta, to: source, writingTo: output)
        #expect(result.unrepresentedFields.count == 3)
        #expect(result.unrepresentedFields.contains { $0.hasPrefix("show") })
        #expect(result.unrepresentedFields.contains { $0.hasPrefix("kind") })
        #expect(result.unrepresentedFields.contains { $0.hasPrefix("location") })

        // A file whose title was written is still a success, not a failure.
        #expect(try await reader.read(output).title == "T")
    }

    /// **A stale ID3v1 tag is why a file shows one title on a phone and another
    /// in a car.** It is removed rather than left to disagree with the v2 tag
    /// just written — and the removal is reported, because it is a change beyond
    /// the one asked for.
    @Test("a trailing ID3v1 tag is removed rather than left to contradict the new one")
    func trailingV1IsRemoved() async throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("id3-v1")
        defer { try? FileManager.default.removeItem(at: directory) }

        let audio = Self.fakeAudio(bytes: 512)
        var file = Self.mp3(tag: Self.handTag(title: "Old"), audio: audio)
        var v1 = Data("TAG".utf8)
        v1.append(Data("Old v1 title".padding(toLength: 30, withPad: " ", startingAt: 0).utf8))
        v1.append(Data(repeating: 0x20, count: 125 - 30))
        #expect(v1.count == 128)
        file.append(v1)

        let source = try DocumentFixtures.write(file, to: directory.appendingPathComponent("in.mp3"))
        let output = directory.appendingPathComponent("out.mp3")

        let result = try await writer.write(MediaMetadata(title: "New"), to: source, writingTo: output)
        #expect(result.removedTrailingID3v1)

        let written = try Data(contentsOf: output)
        #expect(!written.suffix(128).starts(with: Array("TAG".utf8)))
        let layout = try ID3File.layout(of: written, name: "out.mp3")
        #expect(written.subdata(in: layout.audio) == audio, "removing the v1 tag took audio with it")
        #expect(try await reader.read(output).title == "New")
    }

    /// Frames this module has no name for ride along, so fixing a title does not
    /// strip a tagger's replay-gain or acoustic-fingerprint frames on the way.
    @Test("frames the model has no name for survive an edit")
    func unknownFramesAreCarried() async throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("id3-carry")
        defer { try? FileManager.default.removeItem(at: directory) }

        // RVA2 is a real frame this module does not model.
        let odd = Data([0x01, 0x02, 0x03, 0x04])
        var body = Data()
        body.append(Data("RVA2".utf8))
        body.append(contentsOf: ID3Tag.syncsafeBytes(odd.count))
        body.append(contentsOf: [0x00, 0x00])
        body.append(odd)

        var tag = Data("ID3".utf8)
        tag.append(contentsOf: [0x04, 0x00, 0x00])
        tag.append(contentsOf: ID3Tag.syncsafeBytes(body.count))
        tag.append(body)

        let source = try DocumentFixtures.write(
            Self.mp3(tag: tag, audio: Self.fakeAudio(bytes: 256)),
            to: directory.appendingPathComponent("in.mp3")
        )
        let output = directory.appendingPathComponent("out.mp3")
        try await writer.write(MediaMetadata(title: "New"), to: source, writingTo: output)

        let written = try ID3Tag.parse(try Data(contentsOf: output), name: "out.mp3")
        let carried = try #require(written?.frames.first { $0.id == "RVA2" })
        #expect(carried.payload == .raw(odd))
        // And exactly one title, not the old one beside the new one.
        #expect(written?.frames.filter { $0.id == "TIT2" }.count == 1)
    }

    /// Clearing has to clear. A write replaces the tag, so a field left out is
    /// gone rather than inherited.
    @Test("clearing a field removes its frame")
    func clearingRemovesTheFrame() async throws {
        let directory = try DocumentFixtures.makeTemporaryDirectory("id3-clear")
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try DocumentFixtures.write(
            Self.mp3(tag: Self.handTag(title: "Old Title"), audio: Self.fakeAudio(bytes: 256)),
            to: directory.appendingPathComponent("in.mp3")
        )
        #expect(try await reader.read(source).title == "Old Title")

        let output = directory.appendingPathComponent("out.mp3")
        try await writer.update(source, writingTo: output) { $0.title = nil; $0.comment = "kept" }

        let read = try await reader.read(output)
        #expect(read.title == nil, "the old title survived being cleared")
        #expect(read.comment == "kept")
    }

    // MARK: - Fixtures

    /// Bytes that begin with an MPEG frame sync so the store is detected as ID3,
    /// and are otherwise arbitrary.
    ///
    /// Not a decodable MP3, and deliberately so: nothing on an Apple platform
    /// can encode one, and nothing here needs to decode one. The writer copies
    /// these bytes and the test asserts they are unchanged, which is a stronger
    /// statement about the writer than a real file would allow, since any
    /// difference at all fails.
    static func fakeAudio(bytes count: Int) -> Data {
        var data = Data([0xFF, 0xFB, 0x90, 0x00])
        var seed: UInt8 = 7
        for _ in 4..<count {
            seed = seed &* 31 &+ 17
            data.append(seed)
        }
        return data
    }

    static func mp3(tag: Data, audio: Data) -> Data {
        var file = tag
        file.append(audio)
        return file
    }

    /// A minimal v2.4 tag with one title frame, built here rather than by the
    /// writer so a test that uses it as INPUT is not testing the writer twice.
    static func handTag(title: String) -> Data {
        let payload = Data([0x03]) + Data(title.utf8)
        var body = Data()
        body.append(Data("TIT2".utf8))
        body.append(contentsOf: ID3Tag.syncsafeBytes(payload.count))
        body.append(contentsOf: [0x00, 0x00])
        body.append(payload)

        var tag = Data("ID3".utf8)
        tag.append(contentsOf: [0x04, 0x00, 0x00])
        tag.append(contentsOf: ID3Tag.syncsafeBytes(body.count))
        tag.append(body)
        return tag
    }
}
