import CoreGraphics
import Foundation
import ImageIO
import LatheCore
import LatheFixtures
import Testing

@testable import LatheImage

/// Animated WebP, written by the vendored `WebPAnimEncoder` and read back by
/// ImageIO.
///
/// The two halves are deliberately different code: the writer is libwebp, the
/// reader is Apple's. A round trip through both is therefore a real check that
/// the file is what the container spec says, not a writer agreeing with itself.
/// Every timing assertion goes through `ImageInspector`, every pixel assertion
/// through `CGImageSource`, and the container layout is also read byte by byte.
@Suite("Animated WebP", .serialized)
struct AnimatedWebPTests {

    private let writer = AnimatedImageWriter()
    private let inspector = ImageInspector()

    private func temporaryDirectory(_ label: String) throws -> URL {
        try DocumentFixtures.makeTemporaryDirectory("webp-anim-\(label)")
    }

    // MARK: - The round trip

    /// **The headline.** Unequal delays, a finite loop count, lossless frames:
    /// every one of them read back off the bytes.
    @Test("writer and inspector agree on frames, delays, loop count and canvas")
    func roundTrip() throws {
        let directory = try temporaryDirectory("roundtrip")
        defer { try? FileManager.default.removeItem(at: directory) }

        let stills = try FrameFixtures.stills(count: 4, in: directory)
        let frames = try FrameSequence.contentsOfDirectory(directory)
        let delays: [TimeInterval] = [0.05, 0.3, 0.12, 1.0]
        let output = directory.appendingPathComponent("out.webp")

        let result = try writer.write(
            frames, to: output, format: .webp,
            delays: .perFrame(delays), loopCount: 3, quality: .lossless
        )
        #expect(result.format == .webp)
        #expect(result.frameCount == 4)
        #expect(result.loopCount == 3)
        #expect(abs(result.duration - 1.47) < 0.001)
        #expect(result.pixelSize == PixelSize(width: 64, height: 48))
        #expect(result.outputByteCount == UInt64(try Data(contentsOf: output).count))

        // The container, byte by byte.
        let layout = try WebPLayout(try Data(contentsOf: output))
        #expect(layout.chunks.first?.tag == "VP8X", "an animation needs the extended format")
        #expect(layout.vp8xFlags & 0x02 != 0, "the VP8X animation flag must be set")
        #expect(layout.vp8xCanvas == PixelSize(width: 64, height: 48))
        #expect(layout.chunks.filter { $0.tag == "ANIM" }.count == 1)
        #expect(layout.loopCount == 3)
        #expect(layout.frames.count == 4)
        #expect(layout.frames.map(\.durationMilliseconds) == [50, 300, 120, 1000])
        #expect(layout.frames.allSatisfy { $0.coder == "VP8L" }, "lossless must select VP8L")

        // The same facts, through ImageIO.
        let info = try inspector.inspect(output)
        #expect(info.format == .webp)
        #expect(info.frameCount == 4)
        #expect(info.isAnimated)
        #expect(info.loopCount == 3)
        #expect(!info.repeatsForever)
        #expect(info.pixelSize == PixelSize(width: 64, height: 48))
        #expect(info.frameDelays.count == 4)
        for (read, written) in zip(info.frameDelays, delays) {
            #expect(abs(read - written) < 0.001, "delay \(read) should be \(written)")
        }
        #expect(abs((info.duration ?? 0) - 1.47) < 0.001)
        #expect(abs((info.totalPlaybackDuration ?? 0) - 4.41) < 0.003)

        // And the frames are the frames: lossless, so each one matches its
        // source to within a rounding step, and no two neighbours are alike.
        let decoded = try FrameFixtures.decodeFrames(of: output)
        #expect(decoded.count == 4)
        var previous: Double?
        for (index, image) in decoded.enumerated() {
            #expect(image.width == 64 && image.height == 48)
            let source = try FrameFixtures.centreGray(of: try FrameReader.decode(stills[index]))
            let measured = try FrameFixtures.centreGray(of: image)
            #expect(abs(measured - source) <= 2.0 / 255,
                    "frame \(index + 1) reads \(measured), its source \(source)")
            if let previous {
                #expect(abs(measured - previous) > 10.0 / 255, "frame \(index + 1) repeats its predecessor")
            }
            previous = measured
        }
    }

    /// The default loop count is forever, and it is written as the container's
    /// `0`, not left out.
    @Test("the default loops forever")
    func loopsForeverByDefault() throws {
        let directory = try temporaryDirectory("forever")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 3, in: directory)
        let output = directory.appendingPathComponent("out.webp")
        try writer.write(try FrameSequence.contentsOfDirectory(directory), to: output, format: .webp)

        #expect(try WebPLayout(try Data(contentsOf: output)).loopCount == 0)
        let info = try inspector.inspect(output)
        #expect(info.loopCount == 0)
        #expect(info.repeatsForever)
        #expect(info.totalPlaybackDuration == nil)
    }

    // MARK: - Quality

    /// `.quality` means the lossy coder, `.lossless` the lossless one — the
    /// same mapping a WebP still gets — and it is visible in each frame's
    /// bitstream chunk, not just in the size.
    @Test("quality picks the coder for every frame",
          arguments: [(QualityTarget.quality(0.6), "VP8 "), (.lossless, "VP8L")])
    func qualitySelectsCoder(_ quality: QualityTarget, coder: String) throws {
        let directory = try temporaryDirectory("coder-\(coder.trimmingCharacters(in: .whitespaces))")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 3, in: directory)
        let output = directory.appendingPathComponent("out.webp")
        try writer.write(
            try FrameSequence.contentsOfDirectory(directory), to: output, format: .webp,
            quality: quality
        )

        let layout = try WebPLayout(try Data(contentsOf: output))
        #expect(layout.frames.count == 3)
        #expect(layout.frames.allSatisfy { $0.coder == coder },
                "expected \(coder), got \(layout.frames.map(\.coder))")

        // Lossy or not, the greys come back in order.
        let decoded = try FrameFixtures.decodeFrames(of: output)
        for (index, image) in decoded.enumerated() {
            let expected = Double(FrameFixtures.gray(index, of: 3))
            #expect(abs(try FrameFixtures.centreGray(of: image) - expected) < 0.05)
        }
    }

    // MARK: - Partial frames

    /// **The encoder stores what changed, and ImageIO puts it back.**
    ///
    /// Flat frames that differ everywhere are always stored whole, which would
    /// leave the sub-rectangle path — offsets, blending, disposal — untested on
    /// the read side. So here a small square moves across a fixed background:
    /// `WebPAnimEncoder` stores only the changed region, and each decoded frame
    /// must still show the whole picture, with the square in exactly one place.
    @Test("sub-rectangle frames are composited back into whole frames")
    func partialFramesComposite() throws {
        let directory = try temporaryDirectory("partial")
        defer { try? FileManager.default.removeItem(at: directory) }

        let canvas = PixelSize(width: 96, height: 48)
        let positions = [4, 28, 52, 76]
        for (index, x) in positions.enumerated() {
            let image = try #require(Self.movingSquare(canvas: canvas, squareX: x))
            try Self.writePNG(image, to: directory.appendingPathComponent("frame-\(index + 1).png"))
        }
        let output = directory.appendingPathComponent("out.webp")
        try writer.write(
            try FrameSequence.contentsOfDirectory(directory), to: output, format: .webp,
            delays: .uniform(seconds: 0.1), quality: .lossless
        )

        let layout = try WebPLayout(try Data(contentsOf: output))
        #expect(layout.frames.count == 4)
        #expect(layout.frames.dropFirst().contains { $0.size.width < canvas.width },
                "the encoder should have stored a sub-rectangle; this test needs it to")

        let decoded = try FrameFixtures.decodeFrames(of: output)
        #expect(decoded.count == 4)
        for (index, image) in decoded.enumerated() {
            #expect(image.width == canvas.width && image.height == canvas.height)
            let pixels = try #require(Fixtures.rgbaBytes(of: image))
            for (other, x) in positions.enumerated() {
                let sample = Self.rgb(pixels, width: canvas.width, x: x + 4, y: 24)
                if other == index {
                    #expect(sample == Self.square, "frame \(index + 1): square missing at x=\(x)")
                } else {
                    #expect(sample == Self.background,
                            "frame \(index + 1): x=\(x) should be background, reads \(sample)")
                }
            }
        }
    }

    // MARK: - Canvas

    /// Mismatched frames are fitted onto the first frame's canvas with
    /// transparent margins — the same composition every other format gets.
    @Test("mismatched frames are fitted onto the canvas, margins transparent")
    func mismatchedSizesAreFitted() throws {
        let directory = try temporaryDirectory("mismatch")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 3, in: directory, sizes: [
            CGSize(width: 80, height: 60),
            CGSize(width: 40, height: 40),
            CGSize(width: 200, height: 50),
        ])
        let output = directory.appendingPathComponent("out.webp")
        let result = try writer.write(
            try FrameSequence.contentsOfDirectory(directory), to: output, format: .webp,
            quality: .lossless
        )
        #expect(result.pixelSize == PixelSize(width: 80, height: 60))
        #expect(try inspector.inspect(output).pixelSize == PixelSize(width: 80, height: 60))

        let decoded = try FrameFixtures.decodeFrames(of: output)
        #expect(decoded.count == 3)
        for image in decoded {
            #expect(image.width == 80 && image.height == 60)
        }
        // Frame 2 is 40x40, fitted to 60x60 at x = 10: the left margin is clear.
        let pixels = try #require(Fixtures.rgbaBytes(of: decoded[1]))
        #expect(pixels[(30 * 80 + 2) * 4 + 3] == 0, "the letterbox margin should be transparent")
        #expect(pixels[(30 * 80 + 40) * 4 + 3] == 255, "the frame itself is opaque")
    }

    // MARK: - What the encoder decides

    /// **Identical neighbours are merged, and the result says so.** The
    /// animation plays the same; the file holds one frame fewer; the reported
    /// count is the file's, and the duration is unchanged.
    @Test("consecutive identical frames merge into one longer frame")
    func identicalFramesMerge() throws {
        let directory = try temporaryDirectory("merge")
        defer { try? FileManager.default.removeItem(at: directory) }

        for (index, gray) in [0.3, 0.3, 0.7].enumerated() {
            try DocumentFixtures.write(
                try DocumentFixtures.solidPNG(size: CGSize(width: 32, height: 32), gray: gray),
                to: directory.appendingPathComponent("frame-\(index + 1).png")
            )
        }
        let output = directory.appendingPathComponent("out.webp")
        let result = try writer.write(
            try FrameSequence.contentsOfDirectory(directory), to: output, format: .webp,
            delays: .perFrame([0.1, 0.2, 0.3]), quality: .lossless
        )
        #expect(result.frameCount == 2)
        #expect(abs(result.duration - 0.6) < 0.001)

        let info = try inspector.inspect(output)
        #expect(info.frameCount == 2)
        #expect(info.frameDelays.count == 2)
        #expect(abs(info.frameDelays[0] - 0.3) < 0.001)
        #expect(abs(info.frameDelays[1] - 0.3) < 0.001)
    }

    /// One frame is a still, exactly as a one-frame GIF is not an animation.
    @Test("one frame writes a still WebP, honestly not animated")
    func singleFrame() throws {
        let directory = try temporaryDirectory("single")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 1, in: directory)
        let output = directory.appendingPathComponent("out.webp")
        let result = try writer.write(
            try FrameSequence.contentsOfDirectory(directory), to: output, format: .webp,
            delays: .uniform(seconds: 0.4)
        )
        #expect(result.frameCount == 1)
        #expect(abs(result.duration - 0.4) < 0.001)

        #expect(try WebPLayout(try Data(contentsOf: output)).frames.isEmpty)
        let info = try inspector.inspect(output)
        #expect(info.frameCount == 1)
        #expect(!info.isAnimated)
    }

    /// Rounding happens on the running total, so a 30 fps run is one second
    /// long, not 990 ms or 1020 ms.
    @Test("a 30 fps run does not drift")
    func frameRateDoesNotDrift() throws {
        let directory = try temporaryDirectory("fps")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 30, in: directory, size: CGSize(width: 16, height: 16))
        let output = directory.appendingPathComponent("out.webp")
        let result = try writer.write(
            try FrameSequence.contentsOfDirectory(directory), to: output, format: .webp,
            delays: .framesPerSecond(30)
        )
        #expect(result.frameCount == 30)
        #expect(abs(result.duration - 1.0) < 0.0005)

        let info = try inspector.inspect(output)
        #expect(info.frameCount == 30)
        #expect(abs((info.duration ?? 0) - 1.0) < 0.0005)
        #expect(info.frameDelays.allSatisfy { abs($0 - 1.0 / 30) < 0.001 })
    }

    // MARK: - Refusals

    /// WebP's loop count is sixteen bits. A larger one is refused, not
    /// truncated into a different number.
    @Test("a loop count WebP cannot store is refused, and nothing is written")
    func loopCountOutOfRange() throws {
        let directory = try temporaryDirectory("loop-range")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 2, in: directory)
        let output = directory.appendingPathComponent("out.webp")
        #expect(throws: LatheError.self) {
            try writer.write(
                try FrameSequence.contentsOfDirectory(directory), to: output, format: .webp,
                loopCount: 70_000
            )
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .allSatisfy { !$0.hasPrefix(".lathe-") }, "no scratch file may be left behind")
    }

    @Test("cancelling part way leaves the previous WebP untouched")
    func cancellation() throws {
        let directory = try temporaryDirectory("cancel")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 6, in: directory)
        let output = directory.appendingPathComponent("out.webp")
        try Data("previous".utf8).write(to: output)

        let handle = ProgressHandle(throttle: .unthrottled)
        handle.cancel()
        #expect(throws: LatheError.self) {
            try writer.write(
                try FrameSequence.contentsOfDirectory(directory), to: output, format: .webp,
                progress: handle
            )
        }
        #expect(try Data(contentsOf: output) == Data("previous".utf8))
    }

    /// Progress is per frame, under the same stage name the ImageIO formats use.
    @Test("progress ticks once per frame, under \"frames\"")
    func progressPerFrame() throws {
        let directory = try temporaryDirectory("progress")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 5, in: directory)
        let seen = Ticks()
        let handle = ProgressHandle(
            sink: ObservingProgressSink { seen.append($0) }, throttle: .unthrottled
        )
        try writer.write(
            try FrameSequence.contentsOfDirectory(directory),
            to: directory.appendingPathComponent("out.webp"), format: .webp, progress: handle
        )
        let frames = seen.all.filter { $0.stage == "frames" }
        #expect(frames.map(\.unitIndex) == [1, 2, 3, 4, 5])
        #expect(frames.allSatisfy { $0.unitCount == 5 })
    }

    // MARK: - Malformed input, read side

    /// A file cut off mid-frame is either refused or read as the frames that
    /// survived — never reported as the whole animation, and never a crash.
    @Test("a truncated animated WebP is not read as the whole animation")
    func truncatedFile() throws {
        let directory = try temporaryDirectory("truncated")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 4, in: directory)
        let whole = directory.appendingPathComponent("whole.webp")
        try writer.write(
            try FrameSequence.contentsOfDirectory(directory), to: whole, format: .webp,
            quality: .lossless
        )
        let bytes = try Data(contentsOf: whole)
        let layout = try WebPLayout(bytes)
        let cut = try #require(layout.frames.last).offset + 12  // inside the last ANMF

        let truncated = directory.appendingPathComponent("truncated.webp")
        try bytes.prefix(cut).write(to: truncated)

        do {
            let info = try inspector.inspect(truncated)
            #expect(info.frameCount < 4, "a truncated file must not report every frame")
        } catch let error as LatheError {
            guard case .invalidInput = error else {
                Issue.record("expected invalidInput, got \(error)")
                return
            }
        }
    }

    /// A RIFF/WEBP header in front of garbage is not an image.
    @Test("a WebP header over garbage is refused as not an image",
          arguments: WebPGarbage.allCases)
    func garbage(_ kind: WebPGarbage) throws {
        let directory = try temporaryDirectory("garbage-\(kind)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("bad.webp")
        try kind.bytes.write(to: url)

        #expect(throws: LatheError.self) { try inspector.inspect(url) }
    }

    // MARK: - Helpers

    private static let background = Fixtures.bottomLeftColour  // blue
    private static let square = Fixtures.topLeftColour         // red

    /// A `canvas` of background with an 8x16 square at (`squareX`, 16).
    private static func movingSquare(canvas: PixelSize, squareX: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: canvas.width, height: canvas.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let colour = { (rgb: RGB) in
            CGColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255,
                    blue: CGFloat(rgb.b) / 255, alpha: 1)
        }
        context.setFillColor(colour(background))
        context.fill(CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
        context.setFillColor(colour(square))
        context.fill(CGRect(x: squareX, y: 16, width: 8, height: 16))
        return context.makeImage()
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private static func rgb(_ pixels: [UInt8], width: Int, x: Int, y: Int) -> RGB {
        let i = (y * width + x) * 4
        return RGB(pixels[i], pixels[i + 1], pixels[i + 2])
    }
}

// MARK: - Fixtures

/// Headers that promise a WebP and bytes that are not one.
enum WebPGarbage: String, CaseIterable, CustomTestStringConvertible, Sendable {
    /// A valid `VP8X` announcing animation, followed by noise.
    case noiseAfterHeader
    /// An `ANMF` chunk whose declared size runs far past the end of the file.
    case frameSizeOverflows
    /// A RIFF size field of zero.
    case emptyRIFF

    var testDescription: String { rawValue }

    var bytes: Data {
        switch self {
        case .noiseAfterHeader:
            var body = Data("WEBP".utf8)
            body.append(WebPLayout.chunk("VP8X", Data([0x02, 0, 0, 0, 15, 0, 0, 15, 0, 0])))
            body.append(Data((0..<200).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }))
            return WebPLayout.riff(body)

        case .frameSizeOverflows:
            var body = Data("WEBP".utf8)
            body.append(WebPLayout.chunk("VP8X", Data([0x02, 0, 0, 0, 15, 0, 0, 15, 0, 0])))
            body.append(WebPLayout.chunk("ANIM", Data([0, 0, 0, 0, 0, 0])))
            var anmf = Data("ANMF".utf8)
            anmf.append(contentsOf: [0xF0, 0xFF, 0xFF, 0x7F])  // ~2 GB
            anmf.append(Data(repeating: 0, count: 32))
            body.append(anmf)
            return WebPLayout.riff(body)

        case .emptyRIFF:
            var file = Data("RIFF".utf8)
            file.append(contentsOf: [0, 0, 0, 0])
            file.append(Data("WEBP".utf8))
            return file
        }
    }
}

/// A WebP file's chunk layout, parsed independently of libwebp and ImageIO.
struct WebPLayout {
    struct Chunk {
        var tag: String
        var offset: Int
        var payload: Data
    }

    struct Frame {
        var offset: Int
        var size: PixelSize
        var durationMilliseconds: Int
        /// The bitstream chunk inside the `ANMF`: `VP8 `, `VP8L`, or `ALPH`
        /// (which precedes a lossy bitstream with alpha).
        var coder: String
    }

    var chunks: [Chunk] = []

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 12,
              String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: bytes[8..<12], as: UTF8.self) == "WEBP"
        else { throw FixtureError.writeFailed("not a RIFF/WEBP file") }
        #expect(Int(Self.le(bytes, 4, 4)) == bytes.count - 8, "the RIFF size must cover the file")

        var offset = 12
        while offset + 8 <= bytes.count {
            let tag = String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
            let size = Int(Self.le(bytes, offset + 4, 4))
            let end = offset + 8 + size
            guard end <= bytes.count else {
                throw FixtureError.writeFailed("chunk \(tag) overruns the file")
            }
            chunks.append(Chunk(tag: tag, offset: offset, payload: Data(bytes[(offset + 8)..<end])))
            offset = end + (size & 1)
        }
    }

    var vp8xFlags: UInt8 { chunks.first { $0.tag == "VP8X" }.map { $0.payload[$0.payload.startIndex] } ?? 0 }

    var vp8xCanvas: PixelSize? {
        guard let payload = chunks.first(where: { $0.tag == "VP8X" }).map({ [UInt8]($0.payload) })
        else { return nil }
        return PixelSize(width: Int(Self.le(payload, 4, 3)) + 1,
                         height: Int(Self.le(payload, 7, 3)) + 1)
    }

    var loopCount: Int? {
        guard let payload = chunks.first(where: { $0.tag == "ANIM" }).map({ [UInt8]($0.payload) })
        else { return nil }
        return Int(Self.le(payload, 4, 2))
    }

    var frames: [Frame] {
        chunks.filter { $0.tag == "ANMF" }.map { chunk in
            let payload = [UInt8](chunk.payload)
            return Frame(
                offset: chunk.offset,
                size: PixelSize(width: Int(Self.le(payload, 6, 3)) + 1,
                                height: Int(Self.le(payload, 9, 3)) + 1),
                durationMilliseconds: Int(Self.le(payload, 12, 3)),
                coder: String(decoding: payload[16..<20], as: UTF8.self) == "ALPH"
                    ? Self.bitstreamAfterAlpha(payload)
                    : String(decoding: payload[16..<20], as: UTF8.self)
            )
        }
    }

    private static func bitstreamAfterAlpha(_ payload: [UInt8]) -> String {
        let alphaSize = Int(le(payload, 20, 4))
        let next = 24 + alphaSize + (alphaSize & 1)
        guard next + 4 <= payload.count else { return "ALPH" }
        return String(decoding: payload[next..<(next + 4)], as: UTF8.self)
    }

    static func le(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> UInt32 {
        (0..<count).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
    }

    static func chunk(_ tag: String, _ payload: Data) -> Data {
        var chunk = Data(tag.utf8)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { chunk.append(contentsOf: $0) }
        chunk.append(payload)
        if payload.count % 2 == 1 { chunk.append(0) }
        return chunk
    }

    static func riff(_ body: Data) -> Data {
        var file = Data("RIFF".utf8)
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { file.append(contentsOf: $0) }
        file.append(body)
        return file
    }
}

/// A thread-safe tick recorder for the progress test.
private final class Ticks: @unchecked Sendable {
    private let lock = NSLock()
    private var ticks: [LatheProgress] = []
    func append(_ tick: LatheProgress) { lock.withLock { ticks.append(tick) } }
    var all: [LatheProgress] { lock.withLock { ticks } }
}
