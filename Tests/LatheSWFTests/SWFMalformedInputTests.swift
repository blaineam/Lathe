import Foundation
import LatheCore
import Testing

@testable import LatheSWF

/// The half of the suite that matters most.
///
/// A `.swf` reaching this module is a file of unknown provenance from a dead
/// platform, so every test here builds a file that is wrong in one specific way
/// and asserts that the result is a **thrown error** — not a crash, not a hang,
/// and not a plausible-looking report assembled from garbage.
///
/// Each test names the failure it is standing in the way of, because in six
/// months the assertion `#expect(throws:)` will look like a formality and the
/// comment is the only thing that says it is not.
@Suite("SWF malformed input")
struct SWFMalformedInputTests {

    private let capture = SWFCapture()

    /// Asserts that the capture refuses this file with
    /// ``LatheError/invalidInput(reason:)`` — a thrown, typed refusal, which is
    /// the whole contract these tests exist to hold.
    private func expectInvalidInput(
        _ data: Data, name: String = "hostile.swf", limits: SWFLimits = .default,
        _ comment: Comment? = nil, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        var refused = false
        do {
            _ = try SWFCapture(limits: limits).run(data, name: name, writingTo: nil)
        } catch let error as LatheError {
            if case .invalidInput = error { refused = true }
        } catch {
            // Any other error type is a failure: the taxonomy is the contract.
        }
        #expect(refused, comment, sourceLocation: sourceLocation)
    }

    // MARK: - The container

    @Test("a file too short to hold a header throws instead of indexing past its end")
    func truncatedHeader() {
        for length in 0...7 {
            expectInvalidInput(Data(repeating: 0x41, count: length))
        }
    }

    @Test("a header that ends before the frame rate throws")
    func headerWithoutFrameFields() {
        // A valid signature and length, and then nothing: the RECT, frame rate
        // and frame count all have to be read before the first tag, and running
        // out mid-RECT must not be mistaken for an empty movie.
        expectInvalidInput(Data("FWS".utf8) + Data([6]) + SWFFixtures.u32(8))
    }

    @Test("a file that is not a SWF at all is refused by signature")
    func badSignature() {
        expectInvalidInput(Data("PK\u{03}\u{04}".utf8) + Data(repeating: 0, count: 40))
        expectInvalidInput(Data("%PDF-1.4".utf8) + Data(repeating: 0, count: 40))
    }

    /// LZMA is refused *by name*, with the reason, rather than being reported as
    /// a corrupt file. A caller holding a perfectly valid `ZWS` SWF needs to be
    /// told to decompress it elsewhere — not told their file is broken.
    @Test("an LZMA (ZWS) file is refused as undecodable, not as invalid")
    func lzmaIsNamedNotMisreported() throws {
        var data = SWFFixtures.swf(tags: [])
        data.replaceSubrange(
            data.startIndex..<(data.startIndex + 3), with: Data("ZWS".utf8)
        )
        do {
            _ = try capture.run(data, name: "old.swf", writingTo: nil)
            Issue.record("expected LZMA to be refused")
        } catch let error as LatheError {
            guard case let .decodeUnavailable(format) = error else {
                Issue.record("expected decodeUnavailable, got \(error)")
                return
            }
            #expect(format.contains("LZMA"))
            #expect(format.contains("xz"))
        }
    }

    @Test("the signature can be read without decompressing, so LZMA is detectable up front")
    func signatureIsCheapToRead() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swf-sig-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var data = SWFFixtures.swf(tags: [], version: 13)
        data.replaceSubrange(data.startIndex..<(data.startIndex + 3), with: Data("ZWS".utf8))
        let url = directory.appendingPathComponent("old.swf")
        try data.write(to: url)

        let signature = try capture.signature(of: url)
        #expect(signature.compression == .lzma)
        #expect(signature.version == 13)
    }

    @Test("a CWS file whose body is not zlib throws rather than inflating to noise")
    func corruptCompressedBody() {
        let plain = SWFFixtures.swf(tags: [])
        var broken = SWFFixtures.compressed(plain)
        // Wreck the zlib header. The check is the two bytes' divisibility by 31,
        // which is exactly what stops a non-zlib payload being handed to the
        // inflater and producing a short, plausible-looking body.
        broken[broken.startIndex + 8] = 0x00
        broken[broken.startIndex + 9] = 0x00
        expectInvalidInput(broken)
    }

    @Test("a CWS file whose compressed data is truncated throws")
    func truncatedCompressedBody() {
        let plain = SWFFixtures.swf(
            tags: [SWFFixtures.tag(2, Data(repeating: 0xAB, count: 4000))]
        )
        let compressed = SWFFixtures.compressed(plain)
        expectInvalidInput(compressed.dropLast(compressed.count / 2))
    }

    // MARK: - Tag framing

    /// The one that is easiest to get wrong and hardest to notice: a tag says it
    /// is longer than the file. Trusting it means reading whatever memory
    /// happens to follow.
    @Test("a tag claiming more bytes than the file holds throws")
    func tagLengthPastEndOfFile() {
        let body = SWFFixtures.lyingTag(
            2, declaredLength: 100_000, body: Data(repeating: 0xAB, count: 8)
        )
        expectInvalidInput(SWFFixtures.swfWithRawBody(body))
    }

    @Test("a tag declaring a negative length throws rather than rewinding the cursor")
    func negativeTagLength() {
        // The long-form length field is signed, so a file can write -1. Acting
        // on it would move the cursor backwards and the walk would never end.
        let body = SWFFixtures.lyingTag(
            2, declaredLength: -1, body: Data(repeating: 0xAB, count: 8)
        )
        expectInvalidInput(SWFFixtures.swfWithRawBody(body))
    }

    @Test("a length of 0x7FFFFFFF throws instead of being used to size anything")
    func absurdTagLength() {
        let body = SWFFixtures.lyingTag(
            21, declaredLength: .max, body: Data(repeating: 0xAB, count: 8)
        )
        expectInvalidInput(SWFFixtures.swfWithRawBody(body))
    }

    /// A zero-length tag is legal — `ShowFrame` is one — so the walk cannot
    /// require every tag to advance the cursor. What it can require is that
    /// every *iteration* consumes the two-byte header, which is what stops this
    /// file spinning forever.
    @Test("thousands of zero-length tags with no End tag terminate, and do not hang")
    func zeroLengthTagsTerminate() throws {
        var body = Data()
        for _ in 0..<20_000 { body += SWFFixtures.tag(1) }
        let data = SWFFixtures.swf(tags: [body], includeEndTag: false)

        let report = try capture.run(data, name: "spin.swf", writingTo: nil)
        #expect(report.verdict == .empty)
        let showFrames = try #require(report.tagCensus.first { $0.code == 1 })
        #expect(showFrames.count == 20_000)
    }

    @Test("a stream that simply runs out is treated as ended, not as corrupt")
    func missingEndTagIsTolerated() throws {
        // Authoring tools shipped files without the terminating End tag for
        // years. Refusing them would throw away every bitmap to enforce a
        // terminator nothing reads.
        let data = SWFFixtures.swf(
            tags: [SWFFixtures.defineBitsJPEG2(characterID: 1, imageData: SWFFixtures.jpeg())],
            includeEndTag: false
        )
        let report = try capture.run(data, name: "t.swf", writingTo: nil)
        #expect(report.assets.count == 1)
    }

    @Test("a tag stream longer than the ceiling is refused")
    func tagCountCeiling() {
        var body = Data()
        for _ in 0..<500 { body += SWFFixtures.tag(1) }
        expectInvalidInput(
            SWFFixtures.swf(tags: [body]),
            limits: SWFLimits(maximumTagCount: 100)
        )
    }

    /// Sprites nest, so the walk recurses. Stack exhaustion is not a catchable
    /// error in Swift — it is a crash in whatever application linked this — so
    /// the depth has to be bounded before the stack is.
    @Test("deeply nested sprites are refused before the stack runs out")
    func spriteRecursionIsBounded() {
        var innermost = SWFFixtures.defineSprite(characterID: 999, frameCount: 1, tags: [])
        for index in 0..<40 {
            innermost = SWFFixtures.defineSprite(
                characterID: UInt16(index), frameCount: 1, tags: [innermost]
            )
        }
        expectInvalidInput(SWFFixtures.swf(tags: [innermost]))
    }

    @Test("a sprite cannot describe tags outside its own body")
    func spriteCannotEscapeItsBody() throws {
        // The sprite's nested stream is a slice of the sprite's own bytes, so a
        // nested tag whose length reaches past the sprite is bounded by the
        // slice — and since the sprite's own length was checked against the
        // file, the read cannot leave it.
        let nested = SWFFixtures.lyingTag(2, declaredLength: 4096, body: Data([0xAA, 0xBB]))
        let sprite = SWFFixtures.defineSprite(characterID: 5, frameCount: 1, tags: [nested])
        let data = SWFFixtures.swf(tags: [sprite])
        expectInvalidInput(data)
    }

    // MARK: - Tag contents

    /// **Framing errors are fatal; content errors are not.** A tag whose length
    /// does not fit has lost the stream's framing, and everything after it is
    /// noise. A bitmap that does not inflate says nothing about the next tag —
    /// so a file with one bad image and one good one must still yield the good
    /// one.
    @Test("one malformed bitmap does not cost the file its other images")
    func malformedBitmapIsIsolated() throws {
        let good = SWFFixtures.jpeg()
        let data = SWFFixtures.swf(
            tags: [
                SWFFixtures.defineBitsLossless(
                    characterID: 1, format: 5, width: 64, height: 64,
                    raster: Data(repeating: 0, count: 16)  // far too small
                ),
                SWFFixtures.defineBitsJPEG2(characterID: 2, imageData: good),
            ]
        )
        let report = try capture.run(data, name: "partly-broken.swf", writingTo: nil)

        #expect(report.assets.count == 1)
        #expect(report.assets.first?.characterID == 2)
        #expect(report.verdict == .mediaRecovered)
        #expect(report.omissions.contains { $0.reason == .malformed })
    }

    /// The bitmap dimensions are two `UInt16`s, so a malformed tag can ask for
    /// 65535 × 65535 — four billion pixels, sixteen gigabytes of RGBA. On iOS
    /// that is not a slow program, it is a jetsam kill blamed on the host app.
    @Test("an absurdly large bitmap is refused before anything is allocated")
    func hugeBitmapIsRefused() throws {
        let data = SWFFixtures.swf(
            tags: [
                SWFFixtures.defineBitsLossless(
                    characterID: 1, format: 5, width: 65_535, height: 65_535,
                    raster: Data(repeating: 0, count: 64)
                ),
                SWFFixtures.defineBitsJPEG2(characterID: 2, imageData: SWFFixtures.jpeg()),
            ]
        )
        let report = try capture.run(data, name: "bomb.swf", writingTo: nil)

        #expect(report.assets.count == 1)
        let omission = try #require(report.omissions.first { $0.reason == .malformed })
        #expect(omission.detail?.contains("ceiling") == true)
    }

    @Test("a bitmap format the tag does not define is rejected, not guessed at")
    func unknownBitmapFormat() throws {
        // Format 4 exists in DefineBitsLossless and not in DefineBitsLossless2.
        let data = SWFFixtures.swf(
            tags: [
                SWFFixtures.defineBitsLossless(
                    characterID: 1, format: 4, width: 2, height: 2,
                    raster: Data(repeating: 0, count: 16), withAlpha: true
                )
            ]
        )
        let report = try capture.run(data, name: "t.swf", writingTo: nil)
        #expect(report.assets.isEmpty)
        #expect(report.omissions.contains { $0.reason == .malformed })
    }

    @Test("a JPEG3 whose declared image length overruns its own tag is isolated")
    func jpegAlphaOffsetPastTagEnd() throws {
        let jpeg = SWFFixtures.jpeg()
        // Declare an image far longer than the tag body actually holds.
        let body = SWFFixtures.u16(8) + SWFFixtures.u32(UInt32(jpeg.count * 10)) + jpeg
        let data = SWFFixtures.swf(
            tags: [
                SWFFixtures.tag(35, body),
                SWFFixtures.defineBitsJPEG2(characterID: 9, imageData: jpeg),
            ]
        )
        let report = try capture.run(data, name: "t.swf", writingTo: nil)
        #expect(report.assets.count == 1)
        #expect(report.assets.first?.characterID == 9)
        #expect(report.omissions.contains { $0.reason == .malformed })
    }

    @Test("a sound whose flags run off the end of its tag is isolated")
    func truncatedSoundTag() throws {
        let data = SWFFixtures.swf(
            tags: [
                SWFFixtures.tag(14, Data([0x01])),  // a DefineSound of one byte
                SWFFixtures.defineBitsJPEG2(characterID: 3, imageData: SWFFixtures.jpeg()),
            ]
        )
        let report = try capture.run(data, name: "t.swf", writingTo: nil)
        #expect(report.assets.count == 1)
        #expect(report.omissions.contains { $0.reason == .malformed })
    }

    @Test("stream blocks with no stream head are reported rather than guessed at")
    func streamBlocksWithoutAHead() throws {
        let data = SWFFixtures.swf(
            tags: [SWFFixtures.soundStreamBlock(mp3Frames: Data([0xFF, 0xFB, 0x00, 0x00]))]
        )
        let report = try capture.run(data, name: "t.swf", writingTo: nil)
        #expect(report.assets.isEmpty)
        let omission = try #require(
            report.omissions.first { $0.what.contains("SoundStreamBlock") }
        )
        #expect(omission.reason == .malformed)
    }

    @Test("a declared file length far larger than the file changes nothing")
    func lyingFileLength() throws {
        // The header's length field is a claim. It sizes a decompression buffer
        // and is used for nothing else, so overstating it by 4 GB must not be a
        // 4 GB allocation — nor a different parse.
        var data = SWFFixtures.swf(
            tags: [SWFFixtures.defineBitsJPEG2(characterID: 1, imageData: SWFFixtures.jpeg())]
        )
        data.replaceSubrange(
            (data.startIndex + 4)..<(data.startIndex + 8), with: SWFFixtures.u32(.max)
        )
        let report = try capture.run(data, name: "t.swf", writingTo: nil)
        #expect(report.assets.count == 1)
        #expect(report.header.declaredFileLength == .max)
    }

    /// A refusal should leave the filesystem exactly as it found it. Creating
    /// the output directory before parsing is the easy spelling, and it litters
    /// a folder for every file the caller tried and could not read.
    @Test("a file that is refused leaves no output directory behind")
    func refusalCreatesNothing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swf-refusal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var data = SWFFixtures.swf(tags: [])
        data.replaceSubrange(data.startIndex..<(data.startIndex + 3), with: Data("ZWS".utf8))
        let source = root.appendingPathComponent("old.swf")
        try data.write(to: source)

        let output = root.appendingPathComponent("out")
        #expect(throws: LatheError.self) {
            try SWFCapture().extract(source, to: output)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    /// A vector-only movie still gets a directory and a manifest, because the
    /// manifest is the answer: it is what says the file is a cartoon rather
    /// than empty.
    @Test("a vector-only movie still produces a manifest explaining itself")
    func vectorOnlyStillGetsAManifest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("swf-vector-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("cartoon.swf")
        try SWFFixtures.swf(tags: [SWFFixtures.tag(2, Data(repeating: 0xAB, count: 40))])
            .write(to: source)

        let output = root.appendingPathComponent("out")
        let report = try SWFCapture().extract(source, to: output)

        #expect(report.verdict == .vectorOrScriptOnly)
        let contents = try FileManager.default.contentsOfDirectory(atPath: output.path)
        #expect(contents == ["manifest.json"])
    }

    @Test("a decompression ceiling below the file's size refuses rather than growing")
    func decompressionCeiling() {
        let plain = SWFFixtures.swf(
            tags: [SWFFixtures.tag(2, Data(repeating: 0xAB, count: 200_000))]
        )
        expectInvalidInput(
            SWFFixtures.compressed(plain),
            limits: SWFLimits(maximumDecompressedBytes: 1024)
        )
    }
}
