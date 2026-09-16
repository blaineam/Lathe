import CoreGraphics
import Foundation
import ImageIO
import LatheCore
import Testing

@testable import LatheImage

/// Tests for the frame/animation inspector.
///
/// The suite is built around the two mistakes the obvious implementation makes,
/// and those two are asserted rather than reported: a **multi-page TIFF** has
/// more than one frame and is not animated, and a **single-frame GIF** is in an
/// animated container and is not animated. Everything else here exists to keep
/// those two honest.
///
/// Every fixture is generated at run time, as everywhere else in this suite. The
/// animated WebP here is built byte by byte — see `Fixtures.animatedWebP` — so
/// that the reader is tested against a container libwebp's muxer did not write;
/// `AnimatedWebPTests` covers the files it does write.
@Suite("Image frame inspection", .serialized)
struct ImageInspectorTests {

    private let inspector = ImageInspector()

    // MARK: - Animated

    /// Deliberately **unequal** delays. Equal ones would pass against an
    /// implementation that read frame 0's delay and multiplied by the count,
    /// which is the shortcut this test exists to forbid.
    @Test("an animated GIF reports its frames, its delays and their sum")
    func animatedGIF() async throws {
        try await Fixtures.withDirectory { directory in
            let delays: [TimeInterval] = [0.05, 0.25, 0.7]
            let url = try Fixtures.animatedGIF(in: directory, delays: delays, loopCount: 0)

            let info = try inspector.inspect(url)
            #expect(info.format == .gif)
            #expect(info.frameCount == 3)
            #expect(info.isAnimated)
            #expect(!info.isMultiPageStill)
            #expect(info.pixelSize == Fixtures.animationSize)

            #expect(info.frameDelays.count == 3)
            for (actual, expected) in zip(info.frameDelays, delays) {
                #expect(abs(actual - expected) < 0.005,
                        "delay \(actual) should be \(expected)")
            }
            let duration = try #require(info.duration)
            #expect(abs(duration - 1.0) < 0.01, "three unequal delays should sum to 1.0s")

            // 0 means forever, which is the container's convention carried
            // through rather than translated.
            #expect(info.loopCount == 0)
            #expect(info.repeatsForever)
            #expect(info.totalPlaybackDuration == nil, "a forever loop has no total")
        }
    }

    /// A finite loop count multiplies; one pass does not.
    @Test("a finite loop count gives a total playtime, and duration stays one pass")
    func finiteLoopCount() async throws {
        try await Fixtures.withDirectory { directory in
            let url = try Fixtures.animatedGIF(in: directory, delays: [0.2, 0.3], loopCount: 4)
            let info = try inspector.inspect(url)

            #expect(info.isAnimated)
            #expect(info.loopCount == 4)
            #expect(!info.repeatsForever)
            let duration = try #require(info.duration)
            #expect(abs(duration - 0.5) < 0.01, "duration is ONE pass")
            let total = try #require(info.totalPlaybackDuration)
            #expect(abs(total - 2.0) < 0.02)
        }
    }

    /// A zero delay means "as fast as possible", not "no time at all". Summing
    /// zeros literally reports 0.0 seconds for a file that visibly plays.
    @Test("a zero frame delay is clamped, not summed as nothing")
    func zeroDelayIsClamped() async throws {
        try await Fixtures.withDirectory { directory in
            let url = try Fixtures.animatedGIF(in: directory, delays: [0, 0, 0.5], loopCount: 0)
            let info = try inspector.inspect(url)

            #expect(info.isAnimated, "zero-delay frames still carry timing")
            #expect(info.frameDelays.count == 3)
            #expect(info.frameDelays[0] == ImageInspector.zeroDelayReplacement)
            #expect(info.frameDelays[1] == ImageInspector.zeroDelayReplacement)
            #expect(abs(info.frameDelays[2] - 0.5) < 0.005)

            let duration = try #require(info.duration)
            #expect(abs(duration - 0.7) < 0.01,
                    "0 + 0 + 0.5 must be 0.1 + 0.1 + 0.5, not 0.5")
            #expect(duration > 0)
        }
    }

    /// APNG is a second delay key in a different dictionary — `kCGImageProperty`
    /// **`PNG`**`Dictionary`, not an APNG one — so a table that assumed one
    /// dictionary per format would miss it.
    @Test("an animated PNG is animated, and a still PNG is not")
    func animatedPNG() async throws {
        try await Fixtures.withDirectory { directory in
            let animated = try Fixtures.animatedPNG(in: directory, delays: [0.1, 0.4])
            let info = try inspector.inspect(animated)
            print("  APNG: \(info.frameCount) frames, animated=\(info.isAnimated), "
                  + "duration=\(info.duration.map { String(format: "%.3f", $0) } ?? "nil")")

            // ImageIO's APNG writer is real but has been known to vary; if it
            // produced a single frame there is nothing to assert about animation.
            if info.frameCount > 1 {
                #expect(info.isAnimated)
                let duration = try #require(info.duration)
                #expect(abs(duration - 0.5) < 0.02)
            } else {
                print("  ! ImageIO wrote a single-frame PNG; APNG timing not exercised")
            }

            let still = try Fixtures.plainImage(in: directory, size: PixelSize(width: 8, height: 8))
            let stillInfo = try inspector.inspect(still)
            #expect(stillInfo.frameCount == 1)
            #expect(!stillInfo.isAnimated)
            #expect(stillInfo.duration == nil)
        }
    }

    /// An animated WebP, assembled by hand.
    ///
    /// ImageIO is the WebP reader — no demuxer is vendored — and this pins that
    /// it reports WebP's frames, delays and loop count through
    /// `kCGImagePropertyWebPDictionary`, the dictionary `AnimationContainer`
    /// names. The container is built from the spec rather than by the vendored
    /// `WebPAnimEncoder`, so a reader that only understood libwebp's particular
    /// layout would fail here; the frames inside are real `VP8L` stills.
    @Test("an animated WebP is animated, with WebP's own delay key")
    func animatedWebP() async throws {
        try await Fixtures.withDirectory { directory in
            #expect(ImageFormat.webp.isAnimatable, "WebP is an animated container")

            let url = try await Fixtures.animatedWebP(
                in: directory, delays: [0.08, 0.32], loopCount: 3
            )
            let info = try inspector.inspect(url)
            print("  animated WebP: \(info.frameCount) frames, animated=\(info.isAnimated), "
                  + "duration=\(info.duration.map { String(format: "%.3f", $0) } ?? "nil"), "
                  + "loop=\(info.loopCount.map(String.init) ?? "nil")")

            #expect(info.format == .webp)
            #expect(info.frameCount == 2)
            #expect(info.isAnimated)
            #expect(info.loopCount == 3)
            let duration = try #require(info.duration)
            #expect(abs(duration - 0.4) < 0.01)
        }
    }

    /// HEICS is the fourth delay key, and the only one whose *encoder* this
    /// system may not have. Whether it does is exactly what `EncodeSupport`
    /// exists to discover, so the fixture is written only where the probe says it
    /// can be — and the absence is printed rather than passing silently.
    ///
    /// What is asserted here is deliberately weaker than for GIF: that the
    /// container is recognised as animated, that the delays come back per-frame,
    /// and that the duration is their sum. The *requested* delays are reported,
    /// not asserted, because ImageIO's HEICS writer does not round-trip them —
    /// measured on this SDK, `[0.15, 0.35]` comes back as roughly `[0.15, 0.15]`.
    /// That is the writer quantising to the sequence's own frame timing, not the
    /// inspector mis-reading it, and pinning today's rounding would be asserting
    /// a fact about ImageIO's encoder in a test about Lathe's reader.
    @Test("an animated HEICS is animated, where this system can write one")
    func animatedHEICS() async throws {
        guard EncodeSupport.shared.canEncode(.heics) else {
            print("  ! this system cannot write HEICS; the HEICS delay key is not exercised here")
            return
        }
        try await Fixtures.withDirectory { directory in
            let requested: [TimeInterval] = [0.15, 0.35]
            let url = try Fixtures.animatedHEICS(in: directory, delays: requested)
            let info = try inspector.inspect(url)
            print("  HEICS: \(info.frameCount) frames, animated=\(info.isAnimated), "
                  + "requested \(requested), read back "
                  + "\(info.frameDelays.map { String(format: "%.3f", $0) })")
            if abs(info.frameDelays.reduce(0, +) - requested.reduce(0, +)) > 0.02 {
                print("  ! ImageIO's HEICS writer did not round-trip the requested delays")
            }

            #expect(info.format == .heics)
            #expect(info.frameCount == 2)
            #expect(info.isAnimated, "the HEICS delay key must be one the inspector looks under")
            #expect(info.frameDelays.count == 2)
            let duration = try #require(info.duration)
            #expect(duration > 0)
            #expect(abs(duration - info.frameDelays.reduce(0, +)) < 0.0001,
                    "the duration must be the sum of the delays that were actually read")
        }
    }

    // MARK: - Multiple frames that are not an animation

    /// **The assertion that makes this feature worth having.**
    ///
    /// A multi-page TIFF reports a frame count above one and does not play. An
    /// implementation built on `CGImageSourceGetCount(source) > 1` calls it
    /// animated, and a pipeline that branches on that turns a scanned document
    /// into a slideshow.
    @Test("a multi-page TIFF has many frames and is NOT animated")
    func multiPageTIFFIsNotAnimated() async throws {
        try await Fixtures.withDirectory { directory in
            let url = try Fixtures.multiPageTIFF(in: directory, pages: 4)
            let info = try inspector.inspect(url)

            #expect(info.format == .tiff)
            #expect(info.frameCount == 4, "the count really is above one")
            #expect(!info.isAnimated, "…and it still must not be animated")
            #expect(info.isMultiPageStill)
            #expect(info.duration == nil)
            #expect(info.frameDelays.isEmpty)
            #expect(info.totalPlaybackDuration == nil)
        }
    }

    /// The other direction, and the one most likely to regress: a GIF with one
    /// frame is a still, whatever its extension says.
    @Test("a single-frame GIF is NOT animated")
    func singleFrameGIFIsNotAnimated() async throws {
        try await Fixtures.withDirectory { directory in
            let url = try Fixtures.animatedGIF(in: directory, delays: [0.5], loopCount: 0)
            let info = try inspector.inspect(url)

            #expect(info.format == .gif)
            #expect(info.frameCount == 1)
            #expect(!info.isAnimated,
                    "one frame is a still even when the container can hold timing")
            #expect(!info.isMultiPageStill)
            #expect(info.duration == nil)
            #expect(info.frameDelays.isEmpty)
        }
    }

    @Test("a plain still is one frame, not animated, no duration",
          arguments: [ImageFormat.png, .jpeg])
    func plainStills(format: ImageFormat) async throws {
        try await Fixtures.withDirectory { directory in
            let size = PixelSize(width: 24, height: 16)
            let url = try Fixtures.still(in: directory, format: format, size: size)
            let info = try inspector.inspect(url)

            #expect(info.format == format)
            #expect(info.frameCount == 1)
            #expect(!info.isAnimated)
            #expect(info.duration == nil)
            #expect(info.loopCount == nil, "a still container has no loop count")
            #expect(info.pixelSize == size)
        }
    }

    // MARK: - Not an image

    /// "Not animated" and "not an image" are different answers, and returning
    /// `false` for the second is how a corrupt file gets silently treated as a
    /// still and re-encoded into nothing.
    @Test("a non-image file is an error, not a still")
    func nonImageIsAnError() async throws {
        try await Fixtures.withDirectory { directory in
            let url = directory.appendingPathComponent("notes.gif")
            try Data("this is not a GIF, whatever the extension says".utf8).write(to: url)

            #expect(throws: LatheError.self) { try inspector.inspect(url) }
            do {
                _ = try inspector.inspect(url)
            } catch let error as LatheError {
                guard case .invalidInput = error else {
                    Issue.record("expected .invalidInput, got \(error)")
                    return
                }
            }
        }
    }

    @Test("a missing file is a read failure, not an empty result")
    func missingFileIsAReadFailure() async throws {
        try await Fixtures.withDirectory { directory in
            let url = directory.appendingPathComponent("absent.png")
            do {
                _ = try inspector.inspect(url)
                Issue.record("expected a refusal")
            } catch let error as LatheError {
                guard case .readFailed = error else {
                    Issue.record("expected .readFailed, got \(error)")
                    return
                }
            }
        }
    }

    @Test("a directory is a read failure too")
    func directoryIsAReadFailure() async throws {
        try await Fixtures.withDirectory { directory in
            #expect(throws: LatheError.self) { try inspector.inspect(directory) }
        }
    }

    // MARK: - Type identifiers

    @Test("every format is named by its own type identifier", arguments: ImageFormat.allCases)
    func namedByTypeIdentifier(format: ImageFormat) {
        #expect(ImageFormat.named(byTypeIdentifier: format.typeIdentifier) == format)
        for alias in format.alternateTypeIdentifiers {
            #expect(ImageFormat.named(byTypeIdentifier: alias) == format)
        }
        #expect(ImageFormat.named(byTypeIdentifier: format.typeIdentifier.uppercased()) == format)
    }

    @Test("an unknown type identifier names no format",
          arguments: ["", "public.text", "com.apple.quicktime-movie", "public.jpegg"])
    func unknownTypeIdentifier(_ identifier: String) {
        #expect(ImageFormat.named(byTypeIdentifier: identifier) == nil)
    }
}
