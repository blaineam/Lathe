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

    // MARK: - Metadata

    /// **The tag survives now.** Before the muxer was vendored a WebP had
    /// nowhere to put an orientation, so it was always baked into the pixels.
    /// It now goes into an `EXIF` chunk that ImageIO reads back, so the probe
    /// reports WebP as able to hold a tag and `.preserveTag` is honoured: the
    /// stored pixels stay stored, and the tag says how to show them.
    @Test("an orientation tag is kept as a tag, and the pixels are left alone")
    func orientationTagIsPreserved() async throws {
        try await Fixtures.withDirectory { directory in
            // Stored landscape, displayed portrait by the tag.
            let source = try Fixtures.quadrantImage(in: directory, format: .png, orientation: .right)
            let stored = Fixtures.quadrantSize
            let destination = directory.appendingPathComponent("tagged.webp")

            #expect(ImageFormat.webp.canStoreOrientationTag,
                    "the orientation probe should find WebP's EXIF chunk round-trips")

            let result = try await encoder.encode(
                source: source, to: destination,
                format: .webp, quality: .lossless, resize: nil, metadata: .preserveAll,
                orientation: .preserveTag
            )
            #expect(result.pixelSize == stored, "the pixels must not have been rotated")
            #expect(Fixtures.orientation(of: destination) == .right)

            let data = try Data(contentsOf: destination)
            #expect(Fixtures.fourCC(data, at: 12) == "VP8X")
            #expect(data[20] & 0x08 != 0, "the VP8X EXIF flag must be set")

            let decoded = try #require(Fixtures.decode(destination))
            #expect(decoded.width == stored.width && decoded.height == stored.height)
            #expect(Fixtures.corner(.topLeft, of: decoded).isCloseTo(Fixtures.topLeftColour))
        }
    }

    /// `.bake` still bakes, and then the tag must say "upright" — writing the
    /// original value too is the double-rotation bug.
    @Test("baking rotates the pixels and leaves no rotation in the tag")
    func orientationIsBakedWhenAsked() async throws {
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.quadrantImage(in: directory, format: .png, orientation: .right)
            let stored = Fixtures.quadrantSize
            let displayed = PixelSize(width: stored.height, height: stored.width)
            let destination = directory.appendingPathComponent("rotated.webp")

            let result = try await encoder.encode(
                source: source, to: destination,
                format: .webp, quality: .lossless, resize: nil, metadata: .preserveAll,
                orientation: .bake
            )
            #expect(result.pixelSize == displayed, "the pixels should have been rotated")

            let tag = Fixtures.orientation(of: destination)
            #expect(tag == nil || tag == .up, "a baked image must not also carry a rotation")

            // Under orientation 6 (`.right`) the stored top-left quadrant
            // belongs at the displayed top-right.
            let decoded = try #require(Fixtures.decode(destination))
            #expect(Fixtures.corner(.topRight, of: decoded).isCloseTo(Fixtures.topLeftColour))
            #expect(Fixtures.corner(.bottomRight, of: decoded).isCloseTo(Fixtures.topRightColour))
        }
    }

    /// EXIF, TIFF and GPS go through the same policy resolver as every ImageIO
    /// format, and come back out through ImageIO's WebP reader.
    @Test("preserveAll carries GPS, timestamps and camera identity into a WebP")
    func metadataPreserveAll() async throws {
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.taggedImage(in: directory)
            let destination = directory.appendingPathComponent("all.webp")

            let result = try await encoder.encode(
                source: source, to: destination,
                format: .webp, quality: .quality(0.9), resize: nil, metadata: .preserveAll
            )

            let out = Fixtures.properties(of: destination)
            #expect(Fixtures.gpsLatitude(out) != nil)
            #expect(Fixtures.exif(out, kCGImagePropertyExifDateTimeOriginal) as? String
                    == Fixtures.dateTimeOriginal)
            #expect(Fixtures.exif(out, kCGImagePropertyExifLensModel) as? String == "50mm f/1.8")
            #expect(Fixtures.tiff(out, kCGImagePropertyTIFFMake) as? String == Fixtures.make)
            #expect(Fixtures.tiff(out, kCGImagePropertyTIFFModel) as? String == Fixtures.model)

            // The EXIF block was serialised on a 1x1 carrier; the dimensions it
            // states must be the real image's, not the carrier's.
            #expect((Fixtures.exif(out, kCGImagePropertyExifPixelXDimension) as? NSNumber)?.intValue
                    == result.pixelSize.width)
            #expect((Fixtures.exif(out, kCGImagePropertyExifPixelYDimension) as? NSNumber)?.intValue
                    == result.pixelSize.height)

            // Still the right picture, and still lossy.
            let data = try Data(contentsOf: destination)
            #expect(Fixtures.fourCC(data, at: 12) == "VP8X")
            #expect(Fixtures.chunkTags(data).contains("VP8 "))
            #expect(Fixtures.chunkTags(data).contains("EXIF"))
            let decoded = try #require(Fixtures.decode(destination))
            #expect(Fixtures.corner(.topLeft, of: decoded).isCloseTo(Fixtures.topLeftColour))
        }
    }

    /// The privacy-critical policy, on the one format whose metadata does not
    /// go through ImageIO's writer.
    @Test("stripping GPS from a WebP removes the location and keeps the rest")
    func metadataStripLocation() async throws {
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.taggedImage(in: directory)
            let destination = directory.appendingPathComponent("nogps.webp")

            _ = try await encoder.encode(
                source: source, to: destination,
                format: .webp, quality: .quality(0.9), resize: nil, metadata: .stripLocation
            )

            let out = Fixtures.properties(of: destination)
            #expect(out[kCGImagePropertyGPSDictionary] == nil)
            #expect(Fixtures.exif(out, kCGImagePropertyExifDateTimeOriginal) as? String
                    == Fixtures.dateTimeOriginal)
            #expect(Fixtures.tiff(out, kCGImagePropertyTIFFMake) as? String == Fixtures.make)

            // And not merely hidden from ImageIO: the EXIF block has no GPS IFD.
            let exif = try #require(Fixtures.chunk("EXIF", in: try Data(contentsOf: destination)))
            #expect(!Fixtures.ifd0Tags(ofEXIF: exif).contains(0x8825))
            #expect(Fixtures.ifd0Tags(ofEXIF: exif).contains(0x010F), "Make must still be there")
        }
    }

    /// The GPS pointer is there when nothing asked for it to go — so the
    /// previous test's absence is a removal, not an accident of layout.
    @Test("preserveAll keeps the GPS IFD in the EXIF chunk")
    func gpsIFDIsPresentWhenPreserved() async throws {
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.taggedImage(in: directory)
            let destination = directory.appendingPathComponent("gps.webp")
            _ = try await encoder.encode(
                source: source, to: destination,
                format: .webp, quality: .lossless, resize: nil, metadata: .preserveAll
            )
            let exif = try #require(Fixtures.chunk("EXIF", in: try Data(contentsOf: destination)))
            #expect(Fixtures.ifd0Tags(ofEXIF: exif).contains(0x8825))
        }
    }

    /// IPTC has no WebP chunk of its own; ImageIO mirrors it into XMP, and the
    /// XMP packet becomes the `XMP ` chunk. The place name is a location
    /// disclosure in prose, so `.stripLocation` must take it out of *that*
    /// chunk too — checked on the raw bytes, not on ImageIO's opinion.
    @Test("an IPTC place name travels in the XMP chunk, and stripLocation removes it")
    func iptcLocationInXMP() async throws {
        try await Fixtures.withDirectory { directory in
            let source = try Self.iptcSource(in: directory)

            let kept = directory.appendingPathComponent("kept.webp")
            _ = try await encoder.encode(
                source: source, to: kept,
                format: .webp, quality: .lossless, resize: nil, metadata: .preserveAll
            )
            let keptXMP = try #require(Fixtures.chunk("XMP ", in: try Data(contentsOf: kept)),
                                       "IPTC should have produced an XMP chunk")
            #expect(Fixtures.containsASCII(keptXMP, "Lathe Street Town"))
            #expect(Fixtures.containsASCII(keptXMP, "fixture-keyword"))
            #expect(CGImageMetadataCreateFromXMPData(keptXMP as CFData) != nil,
                    "the XMP chunk must be a packet ImageIO can parse")

            let stripped = directory.appendingPathComponent("stripped.webp")
            _ = try await encoder.encode(
                source: source, to: stripped,
                format: .webp, quality: .lossless, resize: nil, metadata: .stripLocation
            )
            let bytes = try Data(contentsOf: stripped)
            #expect(!Fixtures.containsASCII(bytes, "Lathe Street Town"),
                    "the place name must not survive anywhere in the file")
            let strippedXMP = try #require(Fixtures.chunk("XMP ", in: bytes))
            #expect(Fixtures.containsASCII(strippedXMP, "fixture-keyword"),
                    "non-location IPTC must survive")
        }
    }

    private static func iptcSource(in directory: URL) throws -> URL {
        let context = try #require(CGContext(
            data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let image = try #require(context.makeImage())
        let url = directory.appendingPathComponent("iptc.jpg")
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyIPTCDictionary: [
                kCGImagePropertyIPTCCity: "Lathe Street Town",
                kCGImagePropertyIPTCKeywords: ["fixture-keyword"],
            ] as [CFString: Any],
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// `stripAll` removes what it may, and keeps only the force-preserved
    /// floor — the paired-photo content identifier — exactly as for a JPEG.
    @Test("stripAll removes everything the policy may remove from a WebP")
    func metadataStripAll() async throws {
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.taggedImage(in: directory)
            let destination = directory.appendingPathComponent("none.webp")

            _ = try await encoder.encode(
                source: source, to: destination,
                format: .webp, quality: .lossless, resize: nil, metadata: .stripAll
            )

            let out = Fixtures.properties(of: destination)
            #expect(out[kCGImagePropertyGPSDictionary] == nil)
            #expect(Fixtures.tiff(out, kCGImagePropertyTIFFMake) == nil)
            #expect(Fixtures.tiff(out, kCGImagePropertyTIFFModel) == nil)
            #expect(Fixtures.tiff(out, kCGImagePropertyTIFFSoftware) == nil)
            #expect(Fixtures.exif(out, kCGImagePropertyExifDateTimeOriginal) == nil)
            #expect(Fixtures.exif(out, kCGImagePropertyExifLensModel) == nil)
            let maker = out[kCGImagePropertyMakerAppleDictionary] as? [CFString: Any]
            #expect(maker?["17" as CFString] as? String == Fixtures.contentIdentifier,
                    "the force-preserved content identifier is the floor, and must survive")
            #expect(maker?["14" as CFString] == nil)
        }
    }

    /// An upright image with nothing to say gets a *simple* WebP: no `VP8X`,
    /// no chunks — the shape it had before the muxer existed.
    @Test("an image with no metadata writes a simple WebP, not an extended one",
          arguments: [MetadataPolicy.preserveAll, .stripAll])
    func noMetadataMeansSimpleFile(_ policy: MetadataPolicy) async throws {
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.quadrantImage(in: directory, format: .png, orientation: .up)
            let destination = directory.appendingPathComponent("plain.webp")

            _ = try await encoder.encode(
                source: source, to: destination,
                format: .webp, quality: .lossless, resize: nil, metadata: policy
            )
            #expect(Fixtures.chunkTags(try Data(contentsOf: destination)) == ["VP8L"])
        }
    }

    /// The JPEG segment reader is fed ImageIO's own output in practice, but it
    /// is still a parser over bytes and must stop cleanly on bad ones.
    @Test("the APP1 extractor survives malformed JPEG bytes")
    func app1ExtractorIsDefensive() {
        let cases: [Data] = [
            Data(),
            Data([0xFF, 0xD8]),
            Data([0xFF, 0xD8, 0xFF, 0xE1, 0xFF, 0xFF, 0x45]),        // length past the end
            Data([0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x01]),              // length below 2
            Data([0xFF, 0xD8, 0x00, 0x00, 0x00, 0x00]),              // not a marker
            Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),  // a PNG
        ]
        for bytes in cases {
            #expect(WebPMetadataChunks.app1Segments(ofJPEG: bytes).isEmpty)
        }

        // And a well-formed one is found, signature stripped.
        var jpeg = Data([0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x0C])
        jpeg.append(Data("Exif\0\0".utf8))
        jpeg.append(contentsOf: [0x4D, 0x4D, 0x00, 0x2A])
        jpeg.append(contentsOf: [0xFF, 0xDA, 0x00, 0x02])
        #expect(WebPMetadataChunks.app1Segments(ofJPEG: jpeg).exif == Data([0x4D, 0x4D, 0x00, 0x2A]))
    }

    /// The dimension patch rewrites exactly the two values, in either byte
    /// order and either integer width, and leaves a block it does not
    /// understand alone.
    @Test("the EXIF dimension patch rewrites the two values and nothing else",
          arguments: [true, false])
    func exifDimensionPatch(bigEndian: Bool) {
        // Header, IFD0 with one entry (ExifIFD pointer), then the Exif IFD with
        // PixelXDimension as SHORT and PixelYDimension as LONG.
        var b = TIFFBuilder(bigEndian: bigEndian)
        b.bytes += bigEndian ? [0x4D, 0x4D] : [0x49, 0x49]
        b.u16(42); b.u32(8)
        b.u16(1); b.u16(0x8769); b.u16(4); b.u32(1); b.u32(26); b.u32(0)  // IFD0, ends at 26
        b.u16(2)
        b.u16(0xA002); b.u16(3); b.u32(1); b.u16(1); b.u16(0)
        b.u16(0xA003); b.u16(4); b.u32(1); b.u32(1)
        b.u32(0)
        var exif = Data(b.bytes)
        let original = exif

        WebPMetadataChunks.patchDimensions(in: &exif, to: PixelSize(width: 4000, height: 3000))
        #expect(exif.count == original.count)
        var expected = TIFFBuilder(bigEndian: bigEndian)
        expected.bytes = Array(original)
        expected.put16(4000, at: 26 + 2 + 8)
        expected.put32(3000, at: 26 + 2 + 12 + 8)
        #expect([UInt8](exif) == expected.bytes)

        var garbage = Data([0x12, 0x34, 0x00, 0x2A, 0, 0, 0, 8, 0xFF])
        let before = garbage
        WebPMetadataChunks.patchDimensions(in: &garbage, to: PixelSize(width: 1, height: 1))
        #expect(garbage == before)

        var truncated = original.prefix(30)
        let truncatedBefore = truncated
        WebPMetadataChunks.patchDimensions(in: &truncated, to: PixelSize(width: 9, height: 9))
        #expect(truncated == truncatedBefore)
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

/// A little TIFF writer for the EXIF patch test.
private struct TIFFBuilder {
    let bigEndian: Bool
    var bytes: [UInt8] = []

    mutating func u16(_ value: Int) { bytes += encode(value, 2) }
    mutating func u32(_ value: Int) { bytes += encode(value, 4) }
    mutating func put16(_ value: Int, at offset: Int) {
        bytes.replaceSubrange(offset..<(offset + 2), with: encode(value, 2))
    }
    mutating func put32(_ value: Int, at offset: Int) {
        bytes.replaceSubrange(offset..<(offset + 4), with: encode(value, 4))
    }

    private func encode(_ value: Int, _ width: Int) -> [UInt8] {
        let little = (0..<width).map { UInt8((value >> (8 * $0)) & 0xFF) }
        return bigEndian ? little.reversed() : little
    }
}
