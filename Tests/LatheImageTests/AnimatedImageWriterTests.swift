import CoreGraphics
import Foundation
import ImageIO
import LatheCore
import LatheFixtures
import Testing

@testable import LatheImage

/// Assembling stills into an animation, and the ways an animation that looks
/// written is not: a file that plays once, a file whose frames are in the wrong
/// order, and a file that reports zero seconds because a zero delay was believed.
///
/// Every assertion here reads the produced **bytes** back — through
/// `ImageInspector` for the timing, and through `CGImageSource` for the pixels —
/// rather than trusting the result the writer handed back. The result type is
/// checked against the file, not instead of it.
@Suite("Animated image writing")
struct AnimatedImageWriterTests {

    private let writer = AnimatedImageWriter()
    private let inspector = ImageInspector()

    /// The formats worth testing on this machine.
    ///
    /// Probed, never listed. The package's standing rule is that capability is a
    /// runtime question, and a suite with `[.gif, .png, .heics]` hard-coded is a
    /// version check wearing a test's clothes — it would fail on a platform that
    /// legitimately cannot write one of them.
    private static var writableFormats: [ImageFormat] {
        [.gif, .png, .heics].filter { EncodeSupport.shared.canEncode($0) }
    }

    private func temporaryDirectory(_ label: String) throws -> URL {
        try DocumentFixtures.makeTemporaryDirectory("animate-\(label)")
    }

    // MARK: - The round trip

    /// **The headline: what went in comes back out, in order, with its timing.**
    ///
    /// Frame count, per-frame delay and total duration are all read off the
    /// written file. Reading them back through `ImageInspector` rather than
    /// through a second copy of the key table is deliberate — it is the same
    /// table, so a writer that put the delay in the wrong dictionary would be
    /// caught here as "not animated" rather than silently agreeing with itself.
    @Test("a run of stills becomes an animation that plays, in order",
          arguments: AnimatedImageWriterTests.writableFormats)
    func roundTrip(_ format: ImageFormat) throws {
        let directory = try temporaryDirectory("roundtrip-\(format.rawValue)")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 6, in: directory)
        let frames = try FrameSequence.contentsOfDirectory(directory)
        #expect(frames.count == 6)

        let output = directory.appendingPathComponent("out.\(format.preferredFilenameExtension)")
        let result = try writer.write(
            frames, to: output, format: format, delays: .uniform(seconds: 0.25)
        )

        #expect(result.frameCount == 6)
        #expect(abs(result.duration - 1.5) < 0.001)
        #expect(result.pixelSize == PixelSize(width: 64, height: 48))
        #expect(result.outputByteCount > 0)

        let info = try inspector.inspect(output)
        #expect(info.frameCount == 6, "the file must hold six frames, not one")
        #expect(info.isAnimated, "a delay in the wrong dictionary reads back as a still")
        #expect(info.frameDelays.count == 6)
        #expect(abs((info.duration ?? 0) - 1.5) < 0.01)
        #expect(info.pixelSize == PixelSize(width: 64, height: 48))

        // And the frames are the frames, in the order given. GIF is palettised
        // and HEICS is lossy, so the greys are compared with slack — but the
        // order is monotonic either way, which a shuffled or duplicated run is
        // not.
        let decoded = try FrameFixtures.decodeFrames(of: output)
        #expect(decoded.count == 6)
        for (index, image) in decoded.enumerated() {
            let expected = Double(FrameFixtures.gray(index, of: 6))
            let measured = try FrameFixtures.centreGray(of: image)
            #expect(abs(measured - expected) < 0.05,
                    "frame \(index + 1) reads \(measured), expected \(expected)")
        }
    }

    // MARK: - Looping

    /// **A loop count is a file property, and setting it per frame plays once.**
    ///
    /// ImageIO accepts a loop count inside a frame's properties without
    /// complaint and ignores it, so the mistake costs nothing at write time and
    /// produces an animation that plays exactly once. `0` is the container
    /// convention for "forever" in all four formats and is carried through
    /// rather than translated.
    @Test("the default loops forever, and a finite count survives the write")
    func loopCount() throws {
        let directory = try temporaryDirectory("loop")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 3, in: directory)
        let frames = try FrameSequence.contentsOfDirectory(directory)

        let forever = directory.appendingPathComponent("forever.gif")
        try writer.write(frames, to: forever, format: .gif)
        #expect(try inspector.inspect(forever).repeatsForever)

        let thrice = directory.appendingPathComponent("thrice.gif")
        try writer.write(frames, to: thrice, format: .gif, loopCount: 3)
        let info = try inspector.inspect(thrice)
        #expect(info.loopCount == 3)
        #expect(!info.repeatsForever)
    }

    // MARK: - Timing

    /// **A zero delay is clamped at write time, not believed.**
    ///
    /// Writing the literal zero produces a file every renderer shows at 100 ms
    /// per frame while `duration` reports 0.0 — a two-second animation that
    /// claims to be instantaneous. Clamping on the way in is what makes the
    /// write and the read agree.
    @Test("a zero delay is written as the clamp, so the duration is not a lie")
    func zeroDelayIsClamped() throws {
        let directory = try temporaryDirectory("zero-delay")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 4, in: directory)
        let frames = try FrameSequence.contentsOfDirectory(directory)
        let output = directory.appendingPathComponent("out.gif")

        let result = try writer.write(
            frames, to: output, format: .gif, delays: .uniform(seconds: 0)
        )
        let expected = 4 * ImageInspector.zeroDelayReplacement
        #expect(abs(result.duration - expected) < 0.001)
        #expect(abs((try inspector.inspect(output).duration ?? 0) - expected) < 0.01)
    }

    /// A zero frame rate is not the same mistake: there is no delay it could
    /// mean, so it is refused rather than clamped.
    @Test("a zero frame rate is refused, because it is a division and not an idiom")
    func zeroFrameRateIsRefused() throws {
        let directory = try temporaryDirectory("zero-rate")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 2, in: directory)
        let frames = try FrameSequence.contentsOfDirectory(directory)

        #expect(throws: LatheError.self) {
            try writer.write(
                frames, to: directory.appendingPathComponent("out.gif"),
                format: .gif, delays: .framesPerSecond(0)
            )
        }
        #expect(throws: LatheError.self) {
            try writer.write(
                frames, to: directory.appendingPathComponent("out.gif"),
                format: .gif, delays: .uniform(seconds: -1)
            )
        }
    }

    /// Per-frame delays are kept per frame rather than averaged — which is the
    /// whole reason `ImageFrameInfo.frameDelays` exists on the read side.
    @Test("per-frame delays survive as themselves, not as an average")
    func perFrameDelays() throws {
        let directory = try temporaryDirectory("per-frame")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 3, in: directory)
        let frames = try FrameSequence.contentsOfDirectory(directory)
        let output = directory.appendingPathComponent("out.gif")

        try writer.write(frames, to: output, format: .gif, delays: .perFrame([0.5, 0.2, 1.0]))

        let delays = try inspector.inspect(output).frameDelays
        #expect(delays.count == 3)
        #expect(abs(delays[0] - 0.5) < 0.02)
        #expect(abs(delays[1] - 0.2) < 0.02)
        #expect(abs(delays[2] - 1.0) < 0.02)
    }

    @Test("a delay list of the wrong length is refused rather than padded")
    func mismatchedDelayCount() throws {
        let directory = try temporaryDirectory("delay-count")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 3, in: directory)
        let frames = try FrameSequence.contentsOfDirectory(directory)

        #expect(throws: LatheError.self) {
            try writer.write(
                frames, to: directory.appendingPathComponent("out.gif"),
                format: .gif, delays: .perFrame([0.1, 0.1])
            )
        }
    }

    /// A frame rate is a convenience spelling of a uniform delay, and must agree
    /// with one.
    @Test("twelve frames per second is twelve frames in one second")
    func framesPerSecond() throws {
        let directory = try temporaryDirectory("fps")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 12, in: directory)
        let frames = try FrameSequence.contentsOfDirectory(directory)
        let output = directory.appendingPathComponent("out.gif")

        let result = try writer.write(
            frames, to: output, format: .gif, delays: .framesPerSecond(12)
        )
        #expect(abs(result.duration - 1.0) < 0.001)
        #expect(abs((try inspector.inspect(output).duration ?? 0) - 1.0) < 0.05)
    }

    // MARK: - Awkward inputs

    /// **Zero frames is an error, not an empty animation.** `CGImageDestination`
    /// finalises a zero-frame GIF perfectly happily, and the file is useless.
    @Test("no frames is refused rather than finalised into an empty file")
    func emptySequenceIsRefused() throws {
        let directory = try temporaryDirectory("empty")
        defer { try? FileManager.default.removeItem(at: directory) }

        let output = directory.appendingPathComponent("out.gif")
        #expect(throws: LatheError.self) {
            try writer.write(FrameSequence([]), to: output, format: .gif)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path),
                "a refusal must not leave a file behind")
    }

    /// One frame is legal. It produces a container holding a single image, which
    /// `ImageInspector` correctly declines to call animated — a one-frame GIF is
    /// not an animation, and the writer does not pretend otherwise.
    @Test("one frame writes a one-frame file, and it is honestly not animated")
    func singleFrame() throws {
        let directory = try temporaryDirectory("single")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 1, in: directory)
        let frames = try FrameSequence.contentsOfDirectory(directory)
        let output = directory.appendingPathComponent("out.gif")

        let result = try writer.write(frames, to: output, format: .gif)
        #expect(result.frameCount == 1)

        let info = try inspector.inspect(output)
        #expect(info.frameCount == 1)
        #expect(!info.isAnimated)
    }

    /// Mismatched sizes land on one canvas, taken from the first frame, with
    /// every frame fitted inside it and nothing cropped.
    @Test("frames of different sizes are fitted onto the first frame's canvas")
    func mismatchedSizesAreFitted() throws {
        let directory = try temporaryDirectory("mismatch")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 3, in: directory, sizes: [
            CGSize(width: 80, height: 60),
            CGSize(width: 40, height: 40),
            CGSize(width: 200, height: 50),
        ])
        let frames = try FrameSequence.contentsOfDirectory(directory)
        let output = directory.appendingPathComponent("out.gif")

        let result = try writer.write(frames, to: output, format: .gif)
        #expect(result.pixelSize == PixelSize(width: 80, height: 60))

        for image in try FrameFixtures.decodeFrames(of: output) {
            #expect(image.width == 80 && image.height == 60,
                    "every frame must be the canvas size, or the animation jumps")
        }
    }

    /// The other half of the same choice: a caller who would rather be told is
    /// told, and told *which* frame.
    @Test("requireUniform refuses a mismatched run and names the frame")
    func requireUniformRefuses() throws {
        let directory = try temporaryDirectory("uniform")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 3, in: directory, sizes: [
            CGSize(width: 80, height: 60),
            CGSize(width: 80, height: 60),
            CGSize(width: 40, height: 40),
        ])
        let frames = try FrameSequence.contentsOfDirectory(directory)

        #expect(throws: LatheError.self) {
            try writer.write(
                frames, to: directory.appendingPathComponent("out.gif"),
                format: .gif, canvas: .requireUniform
            )
        }
    }

    /// A caller-named canvas wins over the first frame's size.
    @Test("a fixed canvas is honoured whatever the frames measure")
    func fixedCanvas() throws {
        let directory = try temporaryDirectory("fixed")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 2, in: directory, size: CGSize(width: 64, height: 48))
        let frames = try FrameSequence.contentsOfDirectory(directory)
        let output = directory.appendingPathComponent("out.gif")

        let result = try writer.write(
            frames, to: output, format: .gif,
            canvas: .fixed(PixelSize(width: 100, height: 100))
        )
        #expect(result.pixelSize == PixelSize(width: 100, height: 100))
        #expect(try inspector.inspect(output).pixelSize == PixelSize(width: 100, height: 100))
    }

    // MARK: - Formats

    /// A format with nowhere to put a delay is refused by name. AVIF is the
    /// interesting one: `isAnimatable` admits it, and ImageIO exposes no timing
    /// dictionary for it, so a "success" would be a burst rather than an
    /// animation.
    @Test("a format with no per-frame timing is refused, animatable or not",
          arguments: [ImageFormat.jpeg, .heic, .tiff, .avif, .jp2])
    func formatsWithoutTiming(_ format: ImageFormat) throws {
        let directory = try temporaryDirectory("timing-\(format.rawValue)")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 2, in: directory)
        let frames = try FrameSequence.contentsOfDirectory(directory)

        #expect(throws: LatheError.self) {
            try writer.write(
                frames,
                to: directory.appendingPathComponent("out.\(format.preferredFilenameExtension)"),
                format: format
            )
        }
    }

    /// **WebP is refused for a reason that is not "this system cannot encode
    /// WebP".** It can — by the vendored libwebp — and saying otherwise would
    /// send the caller looking at their OS version. What is missing is the
    /// animation muxer, and the error says so.
    @Test("animated WebP is refused as a missing muxer, not a missing encoder")
    func webPIsRefusedForTheRightReason() throws {
        let directory = try temporaryDirectory("webp")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 2, in: directory)
        let frames = try FrameSequence.contentsOfDirectory(directory)

        // Still encodable as a single WebP — the premise of the message.
        #expect(EncodeSupport.shared.canEncode(.webp))

        let thrown: (any Error)? = {
            do {
                try writer.write(
                    frames, to: directory.appendingPathComponent("out.webp"), format: .webp
                )
                return nil
            } catch { return error }
        }()
        guard case .unsupportedOnThisPlatform = thrown as? LatheError else {
            Issue.record("expected unsupportedOnThisPlatform, got \(String(describing: thrown))")
            return
        }
    }

    /// An extension that contradicts the format is refused rather than
    /// corrected: APNG bytes in a file called `.gif` succeed at every layer here
    /// and fail in the caller's viewer.
    @Test("an extension that lies about the format is refused")
    func mismatchedExtension() throws {
        let directory = try temporaryDirectory("extension")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 2, in: directory)
        let frames = try FrameSequence.contentsOfDirectory(directory)

        #expect(throws: LatheError.self) {
            try writer.write(
                frames, to: directory.appendingPathComponent("out.gif"), format: .png
            )
        }
    }

    // MARK: - The sequence itself

    /// **The directory sort is numeric, not lexical.** A plain string sort puts
    /// `frame-10` between `frame-1` and `frame-2`, which is the classic way an
    /// assembled animation comes out shuffled — and an unpadded run produced by
    /// somebody else's tool is exactly where it bites.
    @Test("an unpadded directory still comes back in numeric order")
    func unpaddedNamesSortNumerically() throws {
        let directory = try temporaryDirectory("sorting")
        defer { try? FileManager.default.removeItem(at: directory) }

        for index in 1...12 {
            try DocumentFixtures.write(
                try DocumentFixtures.solidPNG(gray: CGFloat(index) / 13),
                to: directory.appendingPathComponent("frame-\(index).png")
            )
        }
        let frames = try FrameSequence.contentsOfDirectory(directory)
        #expect(frames.frames.map(\.lastPathComponent)
            == (1...12).map { "frame-\($0).png" })
    }

    /// Junk beside the frames is skipped rather than refused. A `.DS_Store` next
    /// to a hundred frames is not an error.
    @Test("non-image files in the directory are skipped, not refused")
    func nonImagesAreSkipped() throws {
        let directory = try temporaryDirectory("junk")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 3, in: directory)
        try Data("notes".utf8).write(to: directory.appendingPathComponent("notes.txt"))

        #expect(try FrameSequence.contentsOfDirectory(directory).count == 3)
    }

    // MARK: - Cancellation

    /// Cancellation unwinds without leaving a partial animation where the
    /// caller's previous one was.
    @Test("cancelling part way leaves the destination as it was")
    func cancellationLeavesNothingBehind() throws {
        let directory = try temporaryDirectory("cancel")
        defer { try? FileManager.default.removeItem(at: directory) }

        try FrameFixtures.stills(count: 8, in: directory)
        let frames = try FrameSequence.contentsOfDirectory(directory)
        let output = directory.appendingPathComponent("out.gif")
        try Data("previous".utf8).write(to: output)

        let handle = ProgressHandle(throttle: .unthrottled)
        handle.cancel()

        #expect(throws: LatheError.self) {
            try writer.write(frames, to: output, format: .gif, progress: handle)
        }
        #expect(try Data(contentsOf: output) == Data("previous".utf8),
                "a cancelled write must not touch what was already there")
    }
}
