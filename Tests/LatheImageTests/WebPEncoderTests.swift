import CoreGraphics
import Foundation
import ImageIO
import LatheCore
import Testing

@testable import LatheImage

/// Tests for the WebP encode path — the one format this package writes itself.
///
/// Everything here goes through `ImageEncoder`, not through `WebPEncoder`
/// directly, because the claim being tested is that WebP is a *transparent*
/// destination: same call, same options, same result type. A test that reached
/// past the router would pass while the router was broken.
///
/// The output is verified two ways on purpose. ImageIO decodes WebP, so a real
/// decoder confirms the file is readable and the right shape — but ImageIO would
/// decode a WebP-shaped file that no other tool accepts, so the RIFF header is
/// also checked byte by byte.
@Suite("WebP encoding", .serialized)
struct WebPEncoderTests {

    private let encoder = ImageEncoder()

    // MARK: - It is really WebP

    @Test("a WebP encode round-trips through ImageIO at the right size")
    func roundTripsThroughImageIO() async throws {
        try await Fixtures.withDirectory { directory in
            let size = PixelSize(width: 64, height: 48)
            let source = try Fixtures.plainImage(in: directory, size: size)
            let destination = directory.appendingPathComponent("out.webp")

            let result = try await encoder.encode(
                source: source, to: destination,
                format: .webp, quality: .quality(0.8), resize: nil, metadata: .preserveAll
            )

            #expect(result.format == .webp)
            #expect(result.pixelSize == size)
            #expect(result.outputByteCount > 0)
            #expect(!result.wasLosslessRewrite)
            #expect(result.outputByteCount == Fixtures.byteCount(of: destination))

            let decoded = try #require(Fixtures.decode(destination),
                                       "ImageIO could not decode the WebP we wrote")
            #expect(decoded.width == size.width)
            #expect(decoded.height == size.height)
            #expect(Fixtures.strayFiles(in: directory).isEmpty)
        }
    }

    /// The header, not the decoder's opinion of it.
    ///
    /// A WebP file is a RIFF container: `"RIFF"`, a little-endian size covering
    /// everything after those eight bytes, then `"WEBP"`, then a chunk FourCC
    /// that says which coder produced it — `VP8 ` lossy, `VP8L` lossless, `VP8X`
    /// extended. Checking the size field too means a truncated file fails here
    /// rather than somewhere downstream.
    @Test("the bytes are a RIFF/WEBP container",
          arguments: [(QualityTarget.quality(0.7), "VP8 "), (.lossless, "VP8L")])
    func magicBytes(quality: QualityTarget, expectedChunk: String) async throws {
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.plainImage(in: directory,
                                                 size: PixelSize(width: 48, height: 32))
            let destination = directory.appendingPathComponent("magic.webp")
            _ = try await encoder.encode(
                source: source, to: destination,
                format: .webp, quality: quality, resize: nil, metadata: .preserveAll
            )

            let data = try Data(contentsOf: destination)
            #expect(data.count >= 16)
            #expect(Fixtures.fourCC(data, at: 0) == "RIFF")
            #expect(Fixtures.fourCC(data, at: 8) == "WEBP")
            #expect(Fixtures.fourCC(data, at: 12) == expectedChunk,
                    "expected the \(expectedChunk) coder for \(quality)")

            // The RIFF size covers everything after the first eight bytes.
            let declared = Int(Fixtures.littleEndianUInt32(data, at: 4))
            #expect(declared == data.count - 8,
                    "RIFF size \(declared) does not match a \(data.count)-byte file")
        }
    }

    // MARK: - Quality

    /// Lower quality must mean fewer bytes. Not a tautology: the quality number
    /// has to reach libwebp's config, and a mapping bug — 0...1 handed to a
    /// field expecting 0...100 — makes every request land at "almost zero" and
    /// produces files that are all the same tiny size.
    @Test("a low lossy quality is smaller than a high one")
    func lowQualityIsSmaller() async throws {
        try await Fixtures.withDirectory { directory in
            // A photographic-ish gradient: a flat image compresses to nearly
            // nothing at every setting and would make this test pass by accident.
            let source = try Fixtures.plainImage(in: directory,
                                                 size: PixelSize(width: 256, height: 192))

            var sizes: [(Double, UInt64)] = []
            for quality in [0.1, 0.5, 0.95] {
                let destination = directory.appendingPathComponent("q\(Int(quality * 100)).webp")
                let result = try await encoder.encode(
                    source: source, to: destination,
                    format: .webp, quality: .quality(quality), resize: nil, metadata: .preserveAll
                )
                sizes.append((quality, result.outputByteCount))
            }
            print("  WebP lossy sizes: "
                  + sizes.map { "q\(Int($0.0 * 100))=\($0.1)B" }.joined(separator: ", "))

            #expect(sizes[0].1 < sizes[1].1, "q10 should be smaller than q50")
            #expect(sizes[1].1 < sizes[2].1, "q50 should be smaller than q95")
        }
    }

    // MARK: - Lossless

    /// `.lossless` used to be refused for every format. It is honoured for WebP,
    /// and "honoured" has to mean pixel-exact or the word is doing no work.
    ///
    /// Every pixel, not a sample: an off-by-one in the RGBA import or a stray
    /// premultiply would survive a spot check of four corners.
    @Test("lossless round-trips every pixel exactly")
    func losslessIsPixelExact() async throws {
        try await Fixtures.withDirectory { directory in
            let size = PixelSize(width: 64, height: 48)
            let source = try Fixtures.plainImage(in: directory, size: size)
            let destination = directory.appendingPathComponent("lossless.webp")

            let result = try await encoder.encode(
                source: source, to: destination,
                format: .webp, quality: .lossless, resize: nil, metadata: .preserveAll
            )
            #expect(result.pixelSize == size)

            let original = try #require(Fixtures.decode(source))
            let decoded = try #require(Fixtures.decode(destination))
            #expect(decoded.width == size.width && decoded.height == size.height)

            let before = try #require(Fixtures.rgbaBytes(of: original))
            let after = try #require(Fixtures.rgbaBytes(of: decoded))
            #expect(before.count == after.count)

            let differing = zip(before, after).reduce(into: 0) { count, pair in
                if pair.0 != pair.1 { count += 1 }
            }
            #expect(differing == 0, "lossless changed \(differing) of \(before.count) bytes")
        }
    }

    /// The two coders really are two coders, and which one wins depends on the
    /// picture.
    ///
    /// The assertion is made on **noise**, because that is where the answer is
    /// not in doubt: VP8L is an entropy coder over exact pixels and cannot beat a
    /// coder that is allowed to throw detail away.
    ///
    /// The smooth gradient is printed rather than asserted, and the reason is
    /// worth writing down because it is the opposite of the intuition: on
    /// synthetic content VP8L wins *enormously* — a 256x192 gradient measured at
    /// roughly 700 bytes lossy and under 100 lossless, because a predictable
    /// image is nearly free to describe exactly and the lossy coder still pays
    /// for a DCT. "Lossless is bigger" is a fact about photographs, not about
    /// WebP, and a test that asserted it on a gradient would be asserting a
    /// falsehood that happened to be convenient.
    @Test("lossless beats lossy on synthetic images and loses on noise")
    func losslessVersusLossy() async throws {
        try await Fixtures.withDirectory { directory in
            let size = PixelSize(width: 256, height: 192)

            func sizes(of source: URL, named name: String) async throws -> (UInt64, UInt64) {
                let lossy = try await encoder.encode(
                    source: source, to: directory.appendingPathComponent("\(name)-l.webp"),
                    format: .webp, quality: .quality(0.7), resize: nil, metadata: .preserveAll
                )
                let lossless = try await encoder.encode(
                    source: source, to: directory.appendingPathComponent("\(name)-ll.webp"),
                    format: .webp, quality: .lossless, resize: nil, metadata: .preserveAll
                )
                print("  \(name): lossy=\(lossy.outputByteCount)B "
                      + "lossless=\(lossless.outputByteCount)B")
                return (lossy.outputByteCount, lossless.outputByteCount)
            }

            print("")
            let (gradientLossy, gradientLossless) =
                try await sizes(of: try Fixtures.plainImage(in: directory, size: size),
                                named: "gradient")
            let (noiseLossy, noiseLossless) =
                try await sizes(of: try Fixtures.noiseImage(in: directory, size: size),
                                named: "noise   ")
            print("")

            #expect(noiseLossless > noiseLossy,
                    "lossless must cost bytes on incompressible content")
            #expect(gradientLossless < gradientLossy,
                    "VP8L should win outright on a smooth synthetic gradient")
        }
    }

    // MARK: - The shared contract

    /// The downscale-only rule is `ImageEncoder`'s, not ImageIO's, so it has to
    /// keep holding on a path that never touches ImageIO's encoder.
    @Test("WebP never enlarges either",
          arguments: [ResizeTarget.longestSide(4000),
                      .fit(PixelSize(width: 4000, height: 4000)),
                      .scale(8),
                      .maxPixels(50_000_000)])
    func neverEnlarges(target: ResizeTarget) async throws {
        try await Fixtures.withDirectory { directory in
            let size = PixelSize(width: 40, height: 30)
            let source = try Fixtures.plainImage(in: directory, size: size)
            let destination = directory.appendingPathComponent("small.webp")

            let result = try await encoder.encode(
                source: source, to: destination,
                format: .webp, quality: .quality(0.8), resize: target, metadata: .preserveAll
            )
            #expect(result.pixelSize == size)
            let decoded = try #require(Fixtures.decode(destination))
            #expect(decoded.width == size.width && decoded.height == size.height)
        }
    }

    @Test("a WebP downscale downscales, and keeps the aspect ratio")
    func downscales() async throws {
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.plainImage(in: directory,
                                                 size: PixelSize(width: 200, height: 100))
            let destination = directory.appendingPathComponent("small.webp")

            let result = try await encoder.encode(
                source: source, to: destination,
                format: .webp, quality: .quality(0.8),
                resize: .longestSide(50), metadata: .preserveAll
            )
            #expect(result.pixelSize == PixelSize(width: 50, height: 25))
            let decoded = try #require(Fixtures.decode(destination))
            #expect(decoded.width == 50)
            #expect(decoded.height == 25)
        }
    }

    /// The never-a-partial-file rule, on the vendored path.
    ///
    /// The failure is provoked rather than simulated: WebP's frame header gives
    /// each dimension 14 bits, so 16383 is a hard ceiling in the format itself.
    /// A 16400-pixel-wide strip is a few hundred kilobytes to build and cannot be
    /// encoded by any conforming WebP encoder, which makes it a failure that will
    /// still be a failure in ten years.
    @Test("an encode that cannot succeed leaves no file and no temporary")
    func failedEncodeLeavesNothing() async throws {
        try await Fixtures.withDirectory { directory in
            let tooWide = PixelSize(width: WebPEncoder.maximumDimension + 17, height: 8)
            let source = try Fixtures.plainImage(in: directory, size: tooWide)
            let destination = directory.appendingPathComponent("huge.webp")

            do {
                _ = try await encoder.encode(
                    source: source, to: destination,
                    format: .webp, quality: .quality(0.8), resize: nil, metadata: .preserveAll
                )
                Issue.record("expected a refusal for \(tooWide)")
            } catch let error as LatheError {
                guard case let .invalidConfiguration(reason) = error else {
                    Issue.record("expected .invalidConfiguration, got \(error)")
                    return
                }
                // The message has to name the remedy; the caller cannot guess it.
                #expect(reason.contains("\(WebPEncoder.maximumDimension)"))
            }

            #expect(!FileManager.default.fileExists(atPath: destination.path),
                    "a failed encode must not leave a 0-byte file")
            #expect(Fixtures.strayFiles(in: directory).isEmpty,
                    "a failed encode must not leave a temporary behind")
        }
    }

    /// An existing file must survive a failed encode over the top of it.
    @Test("a failed WebP encode leaves the previous file intact")
    func failedEncodeKeepsThePreviousFile() async throws {
        try await Fixtures.withDirectory { directory in
            let destination = directory.appendingPathComponent("existing.webp")
            let good = try Fixtures.plainImage(in: directory, size: PixelSize(width: 32, height: 24))
            _ = try await encoder.encode(
                source: good, to: destination,
                format: .webp, quality: .quality(0.8), resize: nil, metadata: .preserveAll
            )
            let originalBytes = try Data(contentsOf: destination)
            #expect(!originalBytes.isEmpty)

            let tooWide = try Fixtures.plainImage(
                in: directory,
                size: PixelSize(width: WebPEncoder.maximumDimension + 17, height: 8)
            )
            _ = try? await encoder.encode(
                source: tooWide, to: destination,
                format: .webp, quality: .quality(0.8), resize: nil, metadata: .preserveAll
            )

            #expect(try Data(contentsOf: destination) == originalBytes,
                    "the previous file must be byte-identical after a failed overwrite")
        }
    }

    /// Orientation is baked, because a WebP written here has nowhere to put a
    /// tag — no muxer is vendored, so there is no `EXIF` chunk. That is the
    /// already-established rule for tagless formats, and this pins that WebP is
    /// on that side of it rather than silently losing the rotation.
    @Test("an orientation tag is baked into the WebP's pixels, not dropped")
    func orientationIsBaked() async throws {
        try await Fixtures.withDirectory { directory in
            // Stored landscape, displayed portrait by the tag.
            let source = try Fixtures.quadrantImage(in: directory, format: .png, orientation: .right)
            let stored = Fixtures.quadrantSize
            let displayed = PixelSize(width: stored.height, height: stored.width)
            let destination = directory.appendingPathComponent("rotated.webp")

            #expect(!ImageFormat.webp.canStoreOrientationTag,
                    "WebP must report that it cannot hold a tag, or the bake never happens")

            let result = try await encoder.encode(
                source: source, to: destination,
                format: .webp, quality: .lossless, resize: nil, metadata: .preserveAll,
                orientation: .preserveTag  // asked for, and correctly overridden
            )
            #expect(result.pixelSize == displayed, "the pixels should have been rotated")

            let tag = Fixtures.orientation(of: destination)
            #expect(tag == nil || tag == .up, "a baked image must not also carry a rotation")

            // And the rotation went the right way: under orientation 6 (`.right`)
            // the stored top-left quadrant belongs at the displayed top-right.
            let decoded = try #require(Fixtures.decode(destination))
            #expect(Fixtures.corner(.topRight, of: decoded).isCloseTo(Fixtures.topLeftColour))
            #expect(Fixtures.corner(.bottomRight, of: decoded).isCloseTo(Fixtures.topRightColour))
        }
    }

    /// Alpha has to survive, and has to survive *straight* — the encoder draws
    /// into a premultiplied context because Core Graphics has no other kind, then
    /// divides back out. Skipping that step darkens every semi-transparent pixel
    /// and is invisible on an opaque test image.
    @Test("a semi-transparent image keeps its colour under its alpha")
    func alphaIsNotPremultiplied() async throws {
        try await Fixtures.withDirectory { directory in
            // Pure red at 50% alpha, everywhere.
            let source = try Fixtures.translucentImage(
                in: directory, size: PixelSize(width: 32, height: 32),
                colour: RGB(255, 0, 0), alpha: 128
            )
            let destination = directory.appendingPathComponent("alpha.webp")
            _ = try await encoder.encode(
                source: source, to: destination,
                format: .webp, quality: .lossless, resize: nil, metadata: .preserveAll
            )

            let decoded = try #require(Fixtures.decode(destination))
            #expect(decoded.alphaInfo != .none, "the alpha channel was dropped")

            let bytes = try #require(Fixtures.rgbaBytes(of: decoded, premultiplied: false))
            // Straight red would be 255; premultiplied-and-not-divided would be
            // about 128. The difference is the whole test.
            #expect(bytes[0] > 240, "red came back as \(bytes[0]) — alpha was not un-premultiplied")
            #expect(abs(Int(bytes[3]) - 128) <= 2, "alpha came back as \(bytes[3])")
        }
    }
}
