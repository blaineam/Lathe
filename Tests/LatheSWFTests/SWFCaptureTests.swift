import CoreGraphics
import Foundation
import ImageIO
import LatheCore
import Testing

@testable import LatheSWF

/// What a capture gets out of a well-formed SWF, and — just as much the point —
/// what it says about the parts it cannot.
@Suite("SWF capture")
struct SWFCaptureTests {

    private let capture = SWFCapture()

    // MARK: - Rig

    private func withTemporaryDirectory<T>(_ body: (URL) throws -> T) rethrows -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("swf-capture-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(directory)
    }

    /// Writes synthesised bytes to a real `.swf` and runs the public extraction
    /// over it, so the path under test is the one callers use — file reading,
    /// directory creation and the manifest included, rather than the internal
    /// in-memory entry point.
    private func extract<T>(
        _ data: Data, name: String = "test.swf", limits: SWFLimits = .default,
        _ body: (SWFCaptureReport, URL) throws -> T
    ) throws -> T {
        try withTemporaryDirectory { root in
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appendingPathComponent(name)
            try data.write(to: source)
            let output = root.appendingPathComponent("out")
            let report = try SWFCapture(limits: limits).extract(source, to: output)
            return try body(report, output)
        }
    }

    /// The RGBA samples of a PNG on disk, premultiplied as Core Graphics keeps
    /// them. Opaque images are unaffected, which is why the colour assertions
    /// below only ever use opaque fixtures.
    private func samples(ofPNGAt url: URL) throws -> (
        width: Int, height: Int, pixels: [(UInt8, UInt8, UInt8, UInt8)]
    ) {
        let data = try Data(contentsOf: url)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(
            CGContext(
                data: &buffer, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var pixels: [(UInt8, UInt8, UInt8, UInt8)] = []
        for index in stride(from: 0, to: buffer.count, by: 4) {
            pixels.append((buffer[index], buffer[index + 1], buffer[index + 2], buffer[index + 3]))
        }
        return (image.width, image.height, pixels)
    }

    // MARK: - The header

    @Test("an uncompressed header is read: version, stage, frame rate, frame count")
    func uncompressedHeader() throws {
        let data = SWFFixtures.swf(
            tags: [], version: 9, width: 550, height: 400, frameRate: 24, frameCount: 120
        )
        let report = try capture.run(data, name: "intro.swf", writingTo: nil)

        #expect(report.header.compression == .none)
        #expect(report.header.version == 9)
        #expect(report.header.stageWidthInPixels == 550)
        #expect(report.header.stageHeightInPixels == 400)
        #expect(report.header.frameCount == 120)
        #expect(report.header.frameRate == 24.0)
    }

    /// The frame rate is 8.8 fixed point in a little-endian word, so the low
    /// byte is the *fraction*. A reader that takes it as an integer turns 12 fps
    /// into 3072.
    @Test("a fractional frame rate survives the 8.8 fixed-point encoding")
    func fractionalFrameRate() throws {
        let data = SWFFixtures.swf(tags: [], frameRate: 29.97)
        let report = try capture.run(data, name: "t.swf", writingTo: nil)
        #expect(abs(report.header.frameRate - 29.97) < 0.01)
    }

    @Test("a zlib-compressed CWS file reads identically to its FWS twin")
    func compressedFileMatchesUncompressed() throws {
        let jpeg = SWFFixtures.jpeg()
        let plain = SWFFixtures.swf(
            tags: [SWFFixtures.defineBitsJPEG2(characterID: 1, imageData: jpeg)]
        )
        let compressed = SWFFixtures.compressed(plain)

        let plainReport = try capture.run(plain, name: "a.swf", writingTo: nil)
        let compressedReport = try capture.run(compressed, name: "a.swf", writingTo: nil)

        #expect(plainReport.header.compression == .none)
        #expect(compressedReport.header.compression == .zlib)
        #expect(plainReport.assets == compressedReport.assets)
        #expect(plainReport.header.stageWidthInPixels == compressedReport.header.stageWidthInPixels)
    }

    // MARK: - JPEG

    @Test("a DefineBitsJPEG2 holding a JPEG comes out as a .jpg, byte for byte")
    func jpegExtraction() throws {
        let jpeg = SWFFixtures.jpeg(width: 24, height: 16)
        let data = SWFFixtures.swf(
            tags: [SWFFixtures.defineBitsJPEG2(characterID: 42, imageData: jpeg)]
        )
        try extract(data) { report, directory in
            #expect(report.assets.count == 1)
            let asset = try #require(report.assets.first)
            #expect(asset.characterID == 42)
            #expect(asset.fileName == "character-00042.jpg")
            guard case let .image(width, height, source, _) = asset.content else {
                Issue.record("expected an image")
                return
            }
            #expect(source == .jpeg)
            #expect(width == 24)
            #expect(height == 16)
            let written = try Data(
                contentsOf: directory.appendingPathComponent("character-00042.jpg")
            )
            #expect(written == jpeg)
        }
    }

    /// **The `FFD9 FFD8` prefix Macromedia's own tool wrote.** An end-of-image
    /// marker followed by a start-of-image marker, before the real start — so
    /// ImageIO reads an empty first image and gives up. Every Flash
    /// implementation strips it; a naive extractor writes a `.jpg` that will not
    /// open.
    @Test("the erroneous FFD9 FFD8 prefix is stripped, and the JPEG opens")
    func erroneousJPEGPrefixStripped() throws {
        let jpeg = SWFFixtures.jpeg()
        let quirked = Data([0xFF, 0xD9, 0xFF, 0xD8]) + jpeg
        let data = SWFFixtures.swf(
            tags: [SWFFixtures.defineBitsJPEG2(characterID: 7, imageData: quirked)]
        )
        try extract(data) { report, directory in
            #expect(report.assets.count == 1)
            let url = directory.appendingPathComponent("character-00007.jpg")
            let written = try Data(contentsOf: url)
            #expect(written == jpeg)
            #expect(SWFImageDecoder.pixelSize(of: written) != nil)
        }
    }

    /// `DefineBitsJPEG2` may hold a PNG, despite its name. The extension has to
    /// come from the bytes.
    @Test("a PNG inside a tag called JPEG2 is written as .png")
    func pngInsideJPEGTag() throws {
        let png = SWFFixtures.png()
        let data = SWFFixtures.swf(
            tags: [SWFFixtures.defineBitsJPEG2(characterID: 3, imageData: png)]
        )
        try extract(data) { report, _ in
            let asset = try #require(report.assets.first)
            #expect(asset.fileName == "character-00003.png")
            guard case let .image(_, _, source, _) = asset.content else {
                Issue.record("expected an image")
                return
            }
            #expect(source == .png)
        }
    }

    /// `DefineBits` carries scan data with no tables; `JPEGTables` carries the
    /// tables with no scan. Joined verbatim they make a two-image JPEG stream
    /// that ImageIO refuses. The join that works drops the tables' EOI and the
    /// image's SOI.
    @Test("DefineBits is reunited with JPEGTables, dropping the inner EOI/SOI pair")
    func jpegTablesMerge() throws {
        let tables = Data([0xFF, 0xD8, 0xFF, 0xDB, 0x00, 0x01, 0xAA, 0xFF, 0xD9])
        let scan = Data([0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x02, 0xBB, 0xFF, 0xD9])
        let data = SWFFixtures.swf(
            tags: [
                SWFFixtures.jpegTables(tables),
                SWFFixtures.defineBits(characterID: 5, scanData: scan),
            ]
        )
        try extract(data) { report, directory in
            let asset = try #require(report.assets.first)
            #expect(asset.sourceTag == "DefineBits")
            guard case let .image(_, _, source, _) = asset.content else {
                Issue.record("expected an image")
                return
            }
            #expect(source == .jpegSharingTables)
            let written = try Data(
                contentsOf: directory.appendingPathComponent("character-00005.jpg")
            )
            #expect(written == tables.dropLast(2) + scan.dropFirst(2))
        }
    }

    /// The tables can legally come *after* the image that needs them, so the
    /// merge has to be deferred to the end of the walk.
    @Test("JPEGTables appearing after DefineBits is still found")
    func jpegTablesAfterTheImage() throws {
        let tables = Data([0xFF, 0xD8, 0xFF, 0xDB, 0x00, 0x01, 0xAA, 0xFF, 0xD9])
        let scan = Data([0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x02, 0xBB, 0xFF, 0xD9])
        let data = SWFFixtures.swf(
            tags: [
                SWFFixtures.defineBits(characterID: 5, scanData: scan),
                SWFFixtures.jpegTables(tables),
            ]
        )
        let report = try capture.run(data, name: "t.swf", writingTo: nil)
        #expect(report.assets.count == 1)
    }

    @Test("DefineBits with no JPEGTables anywhere is reported, not written broken")
    func jpegWithoutTables() throws {
        let scan = Data([0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x02, 0xBB, 0xFF, 0xD9])
        let data = SWFFixtures.swf(tags: [SWFFixtures.defineBits(characterID: 5, scanData: scan)])
        try extract(data) { report, directory in
            #expect(report.assets.isEmpty)
            #expect(report.omissions.contains { $0.what == "DefineBits without JPEGTables" })
            let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(contents == ["manifest.json"])
        }
    }

    /// A JPEG and a separate alpha plane become one PNG. Writing the JPEG alone
    /// yields a rectangle where a cut-out sprite belongs — an image that looks
    /// completely fine and is completely wrong.
    @Test("DefineBitsJPEG3 composes its alpha channel into a PNG")
    func jpegWithAlpha() throws {
        let jpeg = SWFFixtures.jpeg(width: 4, height: 4, gray: 1.0)
        // Straight alpha, one byte per pixel, no row padding: left half opaque,
        // right half transparent.
        var alpha = Data()
        for _ in 0..<4 { alpha += Data([255, 255, 0, 0]) }

        let data = SWFFixtures.swf(
            tags: [SWFFixtures.defineBitsJPEG3(characterID: 9, jpeg: jpeg, alpha: alpha)]
        )
        try extract(data) { report, directory in
            let asset = try #require(report.assets.first)
            #expect(asset.fileName == "character-00009.png")
            guard case let .image(width, height, source, hasAlpha) = asset.content else {
                Issue.record("expected an image")
                return
            }
            #expect(source == .jpegWithAlpha)
            #expect(hasAlpha)
            #expect(width == 4)
            #expect(height == 4)

            let decoded = try samples(
                ofPNGAt: directory.appendingPathComponent("character-00009.png")
            )
            #expect(decoded.pixels[0].3 == 255)
            #expect(decoded.pixels[2].3 == 0)
        }
    }

    // MARK: - Lossless rasters

    /// Format 5 in `DefineBitsLossless` is `PIX24`: **four** bytes per pixel,
    /// the first of them padding. Reading it as a packed RGB triple produces the
    /// classic diagonal smear.
    @Test("a 24-bit lossless raster decodes, padding byte and all")
    func lossless24Bit() throws {
        // 2×2: red, green / blue, white. Each pixel is (pad, R, G, B).
        let raster = Data([
            0, 255, 0, 0, 0, 0, 255, 0,
            0, 0, 0, 255, 0, 255, 255, 255,
        ])
        let data = SWFFixtures.swf(
            tags: [
                SWFFixtures.defineBitsLossless(
                    characterID: 11, format: 5, width: 2, height: 2, raster: raster
                )
            ]
        )
        try extract(data) { report, directory in
            let asset = try #require(report.assets.first)
            guard case let .image(width, height, source, hasAlpha) = asset.content else {
                Issue.record("expected an image")
                return
            }
            #expect(source == .lossless24Bit)
            #expect(hasAlpha == false)
            #expect(width == 2)
            #expect(height == 2)

            let decoded = try samples(
                ofPNGAt: directory.appendingPathComponent("character-00011.png")
            )
            #expect(decoded.pixels[0] == (255, 0, 0, 255))
            #expect(decoded.pixels[1] == (0, 255, 0, 255))
            #expect(decoded.pixels[2] == (0, 0, 255, 255))
            #expect(decoded.pixels[3] == (255, 255, 255, 255))
        }
    }

    /// **Rows are padded to four bytes.** At a width of 3, a 15-bit raster's
    /// rows are 6 bytes of pixels and 2 of padding. A decoder that ignores the
    /// padding reads row two starting two bytes early and shears the image — and
    /// at widths that happen to be multiples of four, it looks perfect.
    @Test("15-bit rows are padded to a 32-bit boundary, and the second row proves it")
    func lossless15BitRowPadding() throws {
        func pix15(_ r: UInt16, _ g: UInt16, _ b: UInt16) -> Data {
            let value = (r << 10) | (g << 5) | b
            return Data([UInt8(value >> 8), UInt8(value & 0xFF)])
        }
        // Row 0: red, green, blue, then two bytes of padding.
        // Row 1: white, black, white, then two bytes of padding.
        var raster = pix15(31, 0, 0) + pix15(0, 31, 0) + pix15(0, 0, 31) + Data([0xEE, 0xEE])
        raster += pix15(31, 31, 31) + pix15(0, 0, 0) + pix15(31, 31, 31) + Data([0xEE, 0xEE])

        let data = SWFFixtures.swf(
            tags: [
                SWFFixtures.defineBitsLossless(
                    characterID: 12, format: 4, width: 3, height: 2, raster: raster
                )
            ]
        )
        try extract(data) { _, directory in
            let decoded = try samples(
                ofPNGAt: directory.appendingPathComponent("character-00012.png")
            )
            #expect(decoded.width == 3)
            #expect(decoded.height == 2)
            // Five bits replicated to eight, so 31 is 255 and not 248.
            #expect(decoded.pixels[0] == (255, 0, 0, 255))
            #expect(decoded.pixels[1] == (0, 255, 0, 255))
            #expect(decoded.pixels[2] == (0, 0, 255, 255))
            #expect(decoded.pixels[3] == (255, 255, 255, 255))
            #expect(decoded.pixels[4] == (0, 0, 0, 255))
        }
    }

    /// The palette size byte is a maximum *index*, so the entry count is one
    /// more. Off by one and every colour in the image shifts by a slot.
    @Test("a palette raster with alpha decodes, and the size byte is an index")
    func losslessPaletteWithAlpha() throws {
        // Two entries: opaque red, fully transparent black. Rows of 2 indices
        // padded to 4 bytes.
        var raster = Data([255, 0, 0, 255])
        raster += Data([0, 0, 0, 0])
        raster += Data([0, 1, 0xEE, 0xEE])
        raster += Data([1, 0, 0xEE, 0xEE])

        let data = SWFFixtures.swf(
            tags: [
                SWFFixtures.defineBitsLossless(
                    characterID: 13, format: 3, width: 2, height: 2, colorTableSize: 1,
                    raster: raster, withAlpha: true
                )
            ]
        )
        try extract(data) { report, directory in
            let asset = try #require(report.assets.first)
            guard case let .image(_, _, source, hasAlpha) = asset.content else {
                Issue.record("expected an image")
                return
            }
            #expect(source == .losslessPaletteWithAlpha)
            #expect(hasAlpha)

            let decoded = try samples(
                ofPNGAt: directory.appendingPathComponent("character-00013.png")
            )
            #expect(decoded.pixels[0].3 == 255)
            #expect(decoded.pixels[1].3 == 0)
            #expect(decoded.pixels[2].3 == 0)
            #expect(decoded.pixels[3].3 == 255)
        }
    }

    // MARK: - Sound

    /// A `DefineSound` MP3 is preceded by a two-byte seek field — *two*, not the
    /// four a stream block uses. Getting the constant wrong misaligns every
    /// frame header.
    @Test("an MP3 DefineSound drops its two-byte seek field and nothing else")
    func mp3Sound() throws {
        let frames = Data([0xFF, 0xFB, 0x90, 0x00] + Array(repeating: UInt8(0x55), count: 60))
        let body = SWFFixtures.u16(0) + frames  // SI16 SeekSamples
        let data = SWFFixtures.swf(
            tags: [
                SWFFixtures.defineSound(
                    characterID: 20, format: 2, rateIndex: 3, is16Bit: true, isStereo: true,
                    sampleCount: 1152, data: body
                )
            ]
        )
        try extract(data) { report, directory in
            let asset = try #require(report.assets.first)
            #expect(asset.fileName == "character-00020.mp3")
            guard case let .sound(info) = asset.content else {
                Issue.record("expected a sound")
                return
            }
            #expect(info.format == .mp3)
            #expect(info.sampleRateHz == 44_100)
            #expect(info.channelCount == 2)
            #expect(info.bitsPerSample == 16)
            #expect(info.isStreamingSoundtrack == false)
            let written = try Data(
                contentsOf: directory.appendingPathComponent("character-00020.mp3")
            )
            #expect(written == frames)
        }
    }

    @Test("uncompressed PCM is wrapped in a WAV header that describes it")
    func pcmSound() throws {
        let samples = Data(Array(repeating: UInt8(0x01), count: 64))
        let data = SWFFixtures.swf(
            tags: [
                SWFFixtures.defineSound(
                    characterID: 21, format: 3, rateIndex: 2, is16Bit: true, isStereo: false,
                    sampleCount: 32, data: samples
                )
            ]
        )
        try extract(data) { report, directory in
            let asset = try #require(report.assets.first)
            #expect(asset.fileName == "character-00021.wav")
            let wav = try Data(contentsOf: directory.appendingPathComponent("character-00021.wav"))

            #expect(wav.prefix(4) == Data("RIFF".utf8))
            #expect(wav[8..<12] == Data("WAVE".utf8))
            #expect(wav[36..<40] == Data("data".utf8))
            // 22050 Hz, mono, 16-bit.
            let rate = UInt32(wav[24]) | UInt32(wav[25]) << 8 | UInt32(wav[26]) << 16
                | UInt32(wav[27]) << 24
            #expect(rate == 22_050)
            #expect(wav[22] == 1)  // channels
            #expect(wav[34] == 16)  // bits per sample
            #expect(wav.count == 44 + samples.count)
            #expect(wav.suffix(samples.count) == samples)
        }
    }

    /// Adobe's ADPCM is not IMA ADPCM, and no Apple framework decodes it. The
    /// right answer is to say so, not to write a file full of noise.
    @Test("ADPCM is named as unrecoverable rather than written wrong")
    func adpcmIsRefused() throws {
        let data = SWFFixtures.swf(
            tags: [
                SWFFixtures.defineSound(
                    characterID: 22, format: 1, rateIndex: 1, is16Bit: true, isStereo: false,
                    sampleCount: 100, data: Data(Array(repeating: UInt8(0x7F), count: 40))
                )
            ]
        )
        let report = try capture.run(data, name: "t.swf", writingTo: nil)
        #expect(report.assets.isEmpty)
        #expect(report.verdict == .mediaFoundButUnrecoverable)
        let omission = try #require(report.omissions.first { $0.what.contains("ADPCM") })
        #expect(omission.reason == .codecNotDecodable)
    }

    /// Stream blocks carry a **four**-byte preamble. Leaving it in injects four
    /// bytes between every pair of MP3 frames; players resynchronise through it,
    /// so the file plays badly rather than failing, which is how the bug ships.
    @Test("a streaming soundtrack concatenates its blocks, minus each preamble")
    func streamingSoundtrack() throws {
        let first = Data([0xFF, 0xFB, 0x01, 0x02])
        let second = Data([0xFF, 0xFB, 0x03, 0x04])
        let data = SWFFixtures.swf(
            tags: [
                SWFFixtures.soundStreamHead(streamFormat: 2, rateIndex: 3, isStereo: true),
                SWFFixtures.soundStreamBlock(mp3Frames: first),
                SWFFixtures.tag(1),
                SWFFixtures.soundStreamBlock(mp3Frames: second),
            ]
        )
        try extract(data) { report, directory in
            let asset = try #require(report.assets.first)
            #expect(asset.fileName == "soundtrack-main.mp3")
            #expect(asset.characterID == nil)
            guard case let .sound(info) = asset.content else {
                Issue.record("expected a sound")
                return
            }
            #expect(info.isStreamingSoundtrack)
            #expect(info.format == .mp3)
            let written = try Data(
                contentsOf: directory.appendingPathComponent("soundtrack-main.mp3")
            )
            #expect(written == first + second)
        }
    }

    /// A sprite has its own timeline and therefore its own soundtrack. Merging
    /// it into the main one produces a single file of two unrelated pieces of
    /// music — and the walk has to descend into sprites at all, or the audio is
    /// simply reported as absent.
    @Test("a sprite's soundtrack is found, and kept separate from the main one")
    func spriteSoundtrackIsSeparate() throws {
        let mainFrames = Data([0xFF, 0xFB, 0xAA, 0xAA])
        let spriteFrames = Data([0xFF, 0xFB, 0xBB, 0xBB])
        let data = SWFFixtures.swf(
            tags: [
                SWFFixtures.soundStreamHead(streamFormat: 2, rateIndex: 3),
                SWFFixtures.soundStreamBlock(mp3Frames: mainFrames),
                SWFFixtures.defineSprite(
                    characterID: 77, frameCount: 2,
                    tags: [
                        SWFFixtures.soundStreamHead(streamFormat: 2, rateIndex: 2),
                        SWFFixtures.soundStreamBlock(mp3Frames: spriteFrames),
                    ]
                ),
            ]
        )
        try extract(data) { report, directory in
            #expect(report.assets.count == 2)
            let names = Set(report.assets.compactMap(\.fileName))
            #expect(names == ["soundtrack-main.mp3", "soundtrack-sprite-77.mp3"])

            let sprite = try Data(
                contentsOf: directory.appendingPathComponent("soundtrack-sprite-77.mp3")
            )
            #expect(sprite == spriteFrames)

            let spriteAsset = try #require(
                report.assets.first { $0.fileName == "soundtrack-sprite-77.mp3" }
            )
            #expect(spriteAsset.spritePath == [77])
        }
    }

    // MARK: - Video and embedded files

    @Test("an embedded video stream is reported by codec, never silently dropped")
    func videoIsReported() throws {
        let data = SWFFixtures.swf(
            tags: [
                SWFFixtures.defineVideoStream(
                    characterID: 30, frameCount: 450, width: 320, height: 240, codecID: 4
                )
            ]
        )
        let report = try capture.run(data, name: "t.swf", writingTo: nil)
        #expect(report.assets.isEmpty)
        #expect(report.verdict == .mediaFoundButUnrecoverable)
        let omission = try #require(report.omissions.first { $0.what.contains("VP6") })
        #expect(omission.reason == .codecNotDecodable)
        #expect(omission.detail?.contains("320×240") == true)
        #expect(omission.detail?.contains("450 frames") == true)
    }

    @Test("DefineBinaryData is written out under the extension its bytes deserve")
    func binaryDataIsSniffed() throws {
        let png = SWFFixtures.png()
        let data = SWFFixtures.swf(
            tags: [SWFFixtures.defineBinaryData(characterID: 40, payload: png)]
        )
        try extract(data) { report, directory in
            let asset = try #require(report.assets.first)
            #expect(asset.fileName == "binary-00040.png")
            guard case let .binaryData(sniffedAs) = asset.content else {
                Issue.record("expected binary data")
                return
            }
            #expect(sniffedAs == "png")
            let written = try Data(
                contentsOf: directory.appendingPathComponent("binary-00040.png")
            )
            #expect(written == png)
        }
    }

    // MARK: - Verdicts

    /// **The headline case.** A file of vector artwork is not an empty file, and
    /// a caller has to be able to tell the difference: one means "this SWF has
    /// no bitmaps in it", the other means "this is a cartoon, and rendering it
    /// is a renderer's job".
    @Test("a file of nothing but shapes says so, rather than reporting no media")
    func vectorOnlyFileIsNamedAsSuch() throws {
        let data = SWFFixtures.swf(
            tags: [
                SWFFixtures.tag(2, Data(repeating: 0xAB, count: 40)),  // DefineShape
                SWFFixtures.tag(26, Data(repeating: 0x01, count: 8)),  // PlaceObject2
                SWFFixtures.tag(1),  // ShowFrame
                SWFFixtures.tag(12, Data(repeating: 0x99, count: 12)),  // DoAction
            ]
        )
        let report = try capture.run(data, name: "cartoon.swf", writingTo: nil)

        #expect(report.assets.isEmpty)
        #expect(report.verdict == .vectorOrScriptOnly)
        #expect(report.summary.contains("vector artwork"))

        let shapes = try #require(report.omissions.first { $0.what == "DefineShape" })
        #expect(shapes.reason == .vectorArtwork)
        #expect(shapes.count == 1)
        #expect(shapes.byteCount == 40)

        let script = try #require(report.omissions.first { $0.what == "DoAction" })
        #expect(script.reason == .script)
    }

    @Test("a file with nothing in it is empty, not vector art")
    func emptyFile() throws {
        let report = try capture.run(
            SWFFixtures.swf(tags: [SWFFixtures.tag(1)]), name: "blank.swf", writingTo: nil
        )
        #expect(report.verdict == .empty)
    }

    /// A tag code outside the specification is reported by number and never
    /// given a name on a guess.
    @Test("an unknown tag code is counted by number and left unnamed")
    func unknownTagCode() throws {
        let data = SWFFixtures.swf(tags: [SWFFixtures.tag(200, Data(repeating: 0, count: 10))])
        let report = try capture.run(data, name: "odd.swf", writingTo: nil)

        #expect(report.verdict == .unrecognisedContent)
        let census = try #require(report.tagCensus.first { $0.code == 200 })
        #expect(census.name == nil)
        #expect(census.count == 1)
        let omission = try #require(report.omissions.first { $0.what == "tag 200" })
        #expect(omission.reason == .unrecognisedTag)
    }

    @Test("recovering anything at all is the verdict that outranks the rest")
    func mediaRecoveredWins() throws {
        let data = SWFFixtures.swf(
            tags: [
                SWFFixtures.tag(2, Data(repeating: 0xAB, count: 40)),
                SWFFixtures.defineBitsJPEG2(characterID: 1, imageData: SWFFixtures.jpeg()),
            ]
        )
        let report = try capture.run(data, name: "t.swf", writingTo: nil)
        #expect(report.verdict == .mediaRecovered)
        #expect(report.omissions.contains { $0.what == "DefineShape" })
    }

    // MARK: - Reporting and output

    @Test("inspecting finds the same assets as extracting, and writes nothing")
    func inspectMatchesExtract() throws {
        let data = SWFFixtures.swf(
            tags: [
                SWFFixtures.defineBitsJPEG2(characterID: 1, imageData: SWFFixtures.jpeg()),
                SWFFixtures.defineSound(
                    characterID: 2, format: 2, rateIndex: 3, is16Bit: true, isStereo: false,
                    sampleCount: 100, data: SWFFixtures.u16(0) + Data(repeating: 0xFF, count: 20)
                ),
            ]
        )
        let inspected = try capture.run(data, name: "t.swf", writingTo: nil)
        #expect(inspected.assets.count == 2)
        #expect(inspected.assets.allSatisfy { $0.fileName == nil })

        try extract(data) { extracted, _ in
            #expect(extracted.assets.count == inspected.assets.count)
            for (a, b) in zip(inspected.assets, extracted.assets) {
                #expect(a.characterID == b.characterID)
                #expect(a.byteCount == b.byteCount)
                #expect(a.content == b.content)
                #expect(b.fileName != nil)
            }
        }
    }

    @Test("the manifest is written beside the files and decodes back to the report")
    func manifestRoundTrips() throws {
        let data = SWFFixtures.swf(
            tags: [SWFFixtures.defineBitsJPEG2(characterID: 1, imageData: SWFFixtures.jpeg())]
        )
        try extract(data, name: "movie.swf") { report, directory in
            let manifest = directory.appendingPathComponent("manifest.json")
            #expect(FileManager.default.fileExists(atPath: manifest.path))
            let decoded = try JSONDecoder().decode(
                SWFCaptureReport.self, from: Data(contentsOf: manifest)
            )
            #expect(decoded == report)
            #expect(decoded.source == "movie.swf")
        }
    }

    /// Two tags claiming the same character ID is malformed, and a reader that
    /// names files after the ID would have the second silently replace the
    /// first.
    @Test("two characters with the same ID produce two files, not one")
    func filenameCollisionsAreResolved() throws {
        let first = SWFFixtures.jpeg(gray: 0.2)
        let second = SWFFixtures.jpeg(gray: 0.8)
        let data = SWFFixtures.swf(
            tags: [
                SWFFixtures.defineBitsJPEG2(characterID: 4, imageData: first),
                SWFFixtures.defineBitsJPEG2(characterID: 4, imageData: second),
            ]
        )
        try extract(data) { report, directory in
            #expect(report.assets.count == 2)
            let names = report.assets.compactMap(\.fileName)
            #expect(names == ["character-00004.jpg", "character-00004-2.jpg"])
            let written = try Data(
                contentsOf: directory.appendingPathComponent("character-00004-2.jpg")
            )
            #expect(written == second)
        }
    }

    @Test("the summary states what the file is and what came out of it")
    func summaryReads() throws {
        let data = SWFFixtures.swf(
            tags: [SWFFixtures.defineBitsJPEG2(characterID: 1, imageData: SWFFixtures.jpeg())],
            version: 8, width: 640, height: 480, frameRate: 30, frameCount: 60
        )
        let report = try capture.run(data, name: "banner.swf", writingTo: nil)
        #expect(report.summary.contains("banner.swf"))
        #expect(report.summary.contains("640×480"))
        #expect(report.summary.contains("SWF 8"))
        #expect(report.summary.contains("1 image"))
        #expect(report.imageCount == 1)
    }
}
