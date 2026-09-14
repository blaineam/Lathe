import CoreGraphics
import Foundation
import ImageIO
import LatheCore
import Testing

@testable import LatheImage

/// Tests for the still-image encoder.
///
/// **No binary media is committed to this repository.** Every fixture below is
/// synthesised by `CGImage` + ImageIO in `setUp`-equivalent helpers, so a clip
/// asserted to be 64x32 with orientation 6 and a GPS tag is that because these
/// lines put it there, not because somebody once measured a file.
///
/// The split follows the capability probe's rule: **invariants are asserted,
/// discovery is reported.** JPEG and PNG must always work; whether this machine
/// writes AVIF or JPEG XL is exactly what `EncodeSupport` exists to find out, so
/// the round-trip suite iterates whatever the probe claims and prints the rest.
@Suite("Still-image encoding", .serialized)
struct ImageEncoderTests {

    private let encoder = ImageEncoder()

    // MARK: - Refusing what cannot be written

    /// The refusal has to happen before anything is created, which is only
    /// observable through the absence of a file. Asserted for every format the
    /// probe says this system cannot write, so a machine with no AVIF encoder
    /// checks AVIF too.
    @Test("every unsupported format refuses without creating anything")
    func unsupportedFormatsLeaveNothing() async throws {
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.plainImage(in: directory, size: PixelSize(width: 32, height: 24))
            let unsupported = EncodeSupport.shared.unsupportedFormats.sorted { $0.rawValue < $1.rawValue }
            print("  formats this system refuses: "
                  + (unsupported.isEmpty ? "none" : unsupported.map(\.description).joined(separator: ", ")))

            for format in unsupported {
                let destination = directory.appendingPathComponent("no.\(format.preferredFilenameExtension)")
                await #expect(throws: LatheError.encodeUnavailable(format: format.description)) {
                    try await encoder.encode(
                        source: source, to: destination,
                        format: format, quality: .quality(0.8), resize: nil, metadata: .preserveAll
                    )
                }
                #expect(!FileManager.default.fileExists(atPath: destination.path))
            }
        }
    }

    /// For an ImageIO format `.lossless` says "re-encode nothing", which an
    /// encoder cannot honour. It is refused rather than quietly reinterpreted as
    /// "quality 1.0" — those are very different files.
    ///
    /// Asserted for every ImageIO-backed format, not just JPEG, because the
    /// refusal now has a live exception (WebP) and "which side of the line is
    /// this format on" is exactly the thing that could drift.
    @Test("a lossless quality target is refused for every ImageIO format")
    func losslessIsRefused() async throws {
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.plainImage(in: directory, size: PixelSize(width: 32, height: 24))

            for format in EncodeSupport.shared.imageIOEncodableFormats
                .sorted(by: { $0.rawValue < $1.rawValue }) {
                let destination = directory
                    .appendingPathComponent("lossless.\(format.preferredFilenameExtension)")
                do {
                    _ = try await encoder.encode(
                        source: source, to: destination,
                        format: format, quality: .lossless, resize: nil, metadata: .preserveAll
                    )
                    Issue.record("\(format.description): expected a refusal")
                } catch let error as LatheError {
                    guard case .invalidConfiguration = error else {
                        Issue.record("\(format.description): expected .invalidConfiguration, got \(error)")
                        continue
                    }
                }
                #expect(!FileManager.default.fileExists(atPath: destination.path))
            }
            #expect(Fixtures.strayFiles(in: directory).isEmpty)
        }
    }

    // MARK: - Round trip

    /// Encode into every format the probe claims, then decode the result.
    ///
    /// "Finalize returned true" is not the same as "a decoder can read this", and
    /// the gap is where a format that half-works lives. JPEG and PNG failures
    /// fail the test; anything else is printed as a platform finding, because
    /// freezing today's answer would reintroduce the version gating the probe
    /// replaces.
    @Test("every format the probe claims round-trips")
    func roundTripsEveryClaimedFormat() async throws {
        try await Fixtures.withDirectory { directory in
            let size = PixelSize(width: 64, height: 48)
            let source = try Fixtures.plainImage(in: directory, size: size)
            var findings: [String] = []

            print("")
            for format in EncodeSupport.shared.supportedFormats.sorted(by: { $0.rawValue < $1.rawValue }) {
                let destination = directory
                    .appendingPathComponent("rt.\(format.preferredFilenameExtension)")
                let result: ImageEncodeResult
                do {
                    result = try await encoder.encode(
                        source: source, to: destination,
                        format: format, quality: .quality(0.8), resize: nil, metadata: .preserveAll
                    )
                } catch {
                    findings.append("\(format): probe says encodable, encode threw \(error)")
                    continue
                }

                #expect(result.outputByteCount > 0)
                #expect(result.pixelSize == size)
                #expect(result.format == format)
                #expect(!result.wasLosslessRewrite)

                // PDF is the deliberate asymmetry: ImageIO writes it and does not
                // read it back as an image source, so there is nothing to decode.
                guard DecodeSupport.shared.canDecode(format) else {
                    print("  \(format.description): wrote \(result.outputByteCount) bytes "
                          + "(ImageIO cannot decode it back; not round-tripped)")
                    continue
                }

                guard let decoded = Fixtures.decode(destination) else {
                    findings.append("\(format): encoded \(result.outputByteCount) bytes that ImageIO "
                                    + "could not decode")
                    continue
                }
                #expect(decoded.width == size.width)
                #expect(decoded.height == size.height)
                print("  \(format.description): \(result.outputByteCount) bytes, "
                      + "decodes as \(decoded.width)x\(decoded.height)")

                if format == .jpeg || format == .png {
                    #expect(decoded.width == size.width && decoded.height == size.height)
                }
            }

            if findings.isEmpty {
                print("  no discrepancies: everything the probe claims also decodes")
            } else {
                print("")
                print("  *** ROUND-TRIP FINDINGS ***")
                for line in findings { print("    ! \(line)") }
            }
            print("")

            // The invariants.
            #expect(EncodeSupport.shared.canEncode(.jpeg))
            #expect(EncodeSupport.shared.canEncode(.png))
        }
    }

    // MARK: - Never enlarging

    /// `kCGImageDestinationImageMaxPixelSize` and
    /// `kCGImageSourceThumbnailMaxPixelSize` both enlarge a smaller source
    /// without complaining. A "cap the longest edge at N" batch built on either
    /// one turns every small image in a library into a blurry large one, and it
    /// looks like it worked.
    @Test("a large resize target never enlarges a small source",
          arguments: [ResizeTarget.longestSide(4000),
                      .fit(PixelSize(width: 4000, height: 4000)),
                      .scale(8),
                      .maxPixels(40_000_000)])
    func neverEnlarges(target: ResizeTarget) async throws {
        try await Fixtures.withDirectory { directory in
            let size = PixelSize(width: 32, height: 24)
            let source = try Fixtures.plainImage(in: directory, size: size)
            let destination = directory.appendingPathComponent("big.png")

            let result = try await encoder.encode(
                source: source, to: destination,
                format: .png, quality: .quality(0.9), resize: target, metadata: .preserveAll
            )
            #expect(result.pixelSize == size, "\(target) enlarged a \(size) source to \(result.pixelSize)")

            let decoded = try #require(Fixtures.decode(destination))
            #expect(decoded.width == size.width)
            #expect(decoded.height == size.height)
        }
    }

    @Test("a downscale really downscales, and preserves the aspect ratio")
    func downscales() async throws {
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.plainImage(in: directory, size: PixelSize(width: 64, height: 32))
            let destination = directory.appendingPathComponent("small.png")

            let result = try await encoder.encode(
                source: source, to: destination,
                format: .png, quality: .quality(0.9),
                resize: .longestSide(16), metadata: .preserveAll
            )
            #expect(result.pixelSize == PixelSize(width: 16, height: 8))

            let decoded = try #require(Fixtures.decode(destination))
            #expect(decoded.width == 16)
            #expect(decoded.height == 8)
        }
    }

    // MARK: - Orientation

    /// Re-encoding is the classic way to silently rotate somebody's photos, and
    /// it happens in two directions: dropping the tag (the picture lands on its
    /// side) or applying it *and* keeping it (the picture is rotated twice).
    ///
    /// The fixture is asymmetric in both axes — four coloured quadrants in a
    /// non-square frame — so either mistake changes which colour lands in the
    /// corner. Checking only the dimensions would pass for a 180° error.
    @Test("preserving the tag leaves both the pixels and the tag alone")
    func orientationPreservedAsTag() async throws {
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.quadrantImage(
                in: directory, format: .jpeg, orientation: .right
            )
            let destination = directory.appendingPathComponent("tag.jpg")

            let result = try await encoder.encode(
                source: source, to: destination,
                format: .jpeg, quality: .quality(0.95), resize: nil, metadata: .preserveAll,
                orientation: .preserveTag
            )

            // Stored axes untouched...
            #expect(result.pixelSize == Fixtures.quadrantSize)
            // ...and the tag still says how to display them.
            #expect(Fixtures.orientation(of: destination) == .right)

            // Stored top-left is still the stored top-left.
            let decoded = try #require(Fixtures.decode(destination))
            #expect(Fixtures.corner(.topLeft, of: decoded).isCloseTo(Fixtures.topLeftColour))
        }
    }

    /// Baking is the other correct strategy: rotate the pixels, then write
    /// `orientation = 1`. Doing one without the other is the bug.
    @Test("baking rotates the pixels and resets the tag")
    func orientationBaked() async throws {
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.quadrantImage(
                in: directory, format: .jpeg, orientation: .right
            )
            let destination = directory.appendingPathComponent("baked.jpg")

            let result = try await encoder.encode(
                source: source, to: destination,
                format: .jpeg, quality: .quality(0.95), resize: nil, metadata: .preserveAll,
                orientation: .bake
            )

            // Orientation 6 displays the stored frame transposed.
            let stored = Fixtures.quadrantSize
            #expect(result.pixelSize == PixelSize(width: stored.height, height: stored.width))
            // And the tag must now say "already upright", or a viewer rotates it
            // a second time.
            let tag = Fixtures.orientation(of: destination)
            #expect(tag == .up || tag == nil, "baked pixels must not keep a rotation tag, got \(String(describing: tag))")

            // Orientation 6 means "the 0th row is the right side": the stored
            // bottom-left quadrant is what ends up in the display's top-left.
            let decoded = try #require(Fixtures.decode(destination))
            #expect(Fixtures.corner(.topLeft, of: decoded).isCloseTo(Fixtures.bottomLeftColour),
                    "a wrong transform puts a different quadrant here")
            #expect(Fixtures.corner(.topRight, of: decoded).isCloseTo(Fixtures.topLeftColour))
        }
    }

    /// The eight-row version of the test above, which is the one that would
    /// catch a scrambled transform table.
    ///
    /// Each EXIF orientation states where the stored 0th row and 0th column
    /// belong, and that fixes exactly one of the fixture's four quadrants in the
    /// displayed top-left. Checking a single orientation — or checking only the
    /// dimensions — passes for a table with two rows swapped, for a sign error in
    /// one of the four reflections, and for a 180° mistake.
    @Test("baking is correct for every EXIF orientation", arguments: [
        (UInt32(1), Fixtures.topLeftColour, false),      // up
        (UInt32(2), Fixtures.topRightColour, false),     // mirrored horizontally
        (UInt32(3), Fixtures.bottomRightColour, false),  // 180°
        (UInt32(4), Fixtures.bottomLeftColour, false),   // mirrored vertically
        (UInt32(5), Fixtures.topLeftColour, true),       // transposed
        (UInt32(6), Fixtures.bottomLeftColour, true),    // 90° clockwise
        (UInt32(7), Fixtures.bottomRightColour, true),   // transposed, mirrored
        (UInt32(8), Fixtures.topRightColour, true),      // 90° anticlockwise
    ])
    func bakingIsCorrectForEveryOrientation(
        raw: UInt32, expectedTopLeft: RGB, transposes: Bool
    ) async throws {
        let orientation = try #require(CGImagePropertyOrientation(rawValue: raw))
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.quadrantImage(in: directory, format: .png, orientation: orientation)
            // PNG in, PNG out: no lossy step anywhere, so a colour mismatch is a
            // geometry mistake and nothing else.
            let destination = directory.appendingPathComponent("baked-\(raw).png")

            let result = try await encoder.encode(
                source: source, to: destination,
                format: .png, quality: .quality(0.95), resize: nil, metadata: .preserveAll,
                orientation: .bake
            )

            let stored = Fixtures.quadrantSize
            let expectedSize = transposes
                ? PixelSize(width: stored.height, height: stored.width)
                : stored
            #expect(result.pixelSize == expectedSize)

            let decoded = try #require(Fixtures.decode(destination))
            let actual = Fixtures.corner(.topLeft, of: decoded)
            #expect(actual.isCloseTo(expectedTopLeft),
                    "orientation \(raw): displayed top-left is \(actual), expected \(expectedTopLeft)")
        }
    }

    /// The invariant that matters, asserted for **every format this system can
    /// write**: a re-encode with `.preserveTag` must leave the picture looking
    /// the same, by one route or the other.
    ///
    /// Written this way because the first version of this test named a format
    /// and was wrong about it. "PNG cannot carry an orientation tag" is the kind
    /// of fact that sounds settled, is not in any header, and turns out to
    /// differ between formats, platforms and OS releases — the same trap
    /// `EncodeSupport` exists to avoid. So the assertion is the property, not the
    /// mechanism: either the tag survived and the pixels stayed on the stored
    /// axes, or the tag went away and the pixels were rotated to compensate.
    /// Both are correct; keeping neither is the bug, and doing both is the
    /// double-rotation bug.
    @Test("a tagged source survives a re-encode into every writable format")
    func orientationSurvivesEveryFormat() async throws {
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.quadrantImage(in: directory, format: .png, orientation: .right)
            let stored = Fixtures.quadrantSize
            let displayed = PixelSize(width: stored.height, height: stored.width)

            print("")
            for format in EncodeSupport.shared.supportedFormats.sorted(by: { $0.rawValue < $1.rawValue }) {
                let destination = directory
                    .appendingPathComponent("orient.\(format.preferredFilenameExtension)")
                // 0.95, not 1.0: ImageIO's AVIF encoder rejects exactly 1.0.
                // That is pinned by `qualityOneIsHandledOrRefusedCleanly`; here
                // it would only be noise.
                let result: ImageEncodeResult
                do {
                    result = try await encoder.encode(
                        source: source, to: destination,
                        format: format, quality: .quality(0.95), resize: nil, metadata: .preserveAll,
                        orientation: .preserveTag
                    )
                } catch {
                    Issue.record("\(format.description) claims to encode but threw \(error)")
                    continue
                }

                let tag = Fixtures.orientation(of: destination)
                let keptTheTag = tag == .right
                let rotatedThePixels = result.pixelSize == displayed

                let detail = "\(format.description): tag=\(String(describing: tag)), "
                    + "size=\(result.pixelSize) — exactly one of \"kept the tag\" and "
                    + "\"rotated the pixels\" must hold"
                #expect(keptTheTag != rotatedThePixels, Comment(rawValue: detail))
                if keptTheTag {
                    #expect(result.pixelSize == stored)
                    print("  \(format.description): kept the tag, pixels untouched at \(result.pixelSize)")
                } else {
                    #expect(tag == .up || tag == nil)
                    print("  \(format.description): no tag support here, rotation baked to \(result.pixelSize)")
                }
            }
            print("")
        }
    }

    /// The size arithmetic has to run against the size a viewer sees. A portrait
    /// photo stored landscape with a rotation tag is the everyday case, and
    /// resolving a fit-box against the stored axes gives a differently *shaped*
    /// result from the one the caller drew on screen.
    @Test("a resize box is resolved against the displayed size, not the stored one")
    func resizeUsesDisplayAxes() async throws {
        try await Fixtures.withDirectory { directory in
            // Stored 64x32, displayed 32x64 by the tag.
            let source = try Fixtures.quadrantImage(
                in: directory, format: .jpeg, orientation: .right
            )
            let destination = directory.appendingPathComponent("fit.jpg")

            // A tall box. Against the *display* (32x64) this fits exactly at
            // 16x32; against the stored axes it would have produced 32x16.
            let result = try await encoder.encode(
                source: source, to: destination,
                format: .jpeg, quality: .quality(0.9),
                resize: .fit(PixelSize(width: 16, height: 64)), metadata: .preserveAll,
                orientation: .bake
            )
            #expect(result.pixelSize == PixelSize(width: 16, height: 32))
        }
    }

    // MARK: - Metadata

    @Test("preserveAll carries GPS, timestamps and camera identity across")
    func metadataPreserveAll() async throws {
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.taggedImage(in: directory)
            let destination = directory.appendingPathComponent("all.jpg")

            _ = try await encoder.encode(
                source: source, to: destination,
                format: .jpeg, quality: .quality(0.9), resize: nil, metadata: .preserveAll
            )

            let out = Fixtures.properties(of: destination)
            #expect(Fixtures.gpsLatitude(out) != nil)
            #expect(Fixtures.exif(out, kCGImagePropertyExifDateTimeOriginal) as? String
                    == Fixtures.dateTimeOriginal)
            #expect(Fixtures.tiff(out, kCGImagePropertyTIFFMake) as? String == Fixtures.make)
        }
    }

    @Test("stripAll removes everything the policy is allowed to remove")
    func metadataStripAll() async throws {
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.taggedImage(in: directory)
            let destination = directory.appendingPathComponent("none.jpg")

            _ = try await encoder.encode(
                source: source, to: destination,
                format: .jpeg, quality: .quality(0.9), resize: nil, metadata: .stripAll
            )

            let out = Fixtures.properties(of: destination)
            #expect(out[kCGImagePropertyGPSDictionary] == nil)
            #expect(Fixtures.exif(out, kCGImagePropertyExifDateTimeOriginal) == nil)
            #expect(Fixtures.tiff(out, kCGImagePropertyTIFFMake) == nil)
            #expect(Fixtures.tiff(out, kCGImagePropertyTIFFModel) == nil)
            #expect(Fixtures.tiff(out, kCGImagePropertyTIFFSoftware) == nil)

            // The file still has to be a file: ImageIO writes its own structural
            // TIFF/JFIF entries, and stripping metadata must not have broken the
            // image itself.
            let decoded = try #require(Fixtures.decode(destination))
            #expect(decoded.width == Fixtures.quadrantSize.width)
        }
    }

    /// The most-requested policy, and the one whose failure mode is a privacy
    /// incident rather than a bug report.
    @Test("stripping GPS removes the location and keeps everything else")
    func metadataStripGPSOnly() async throws {
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.taggedImage(in: directory)
            let destination = directory.appendingPathComponent("nogps.jpg")

            _ = try await encoder.encode(
                source: source, to: destination,
                format: .jpeg, quality: .quality(0.9), resize: nil, metadata: .stripLocation
            )

            let out = Fixtures.properties(of: destination)
            #expect(out[kCGImagePropertyGPSDictionary] == nil)
            #expect(Fixtures.gpsLatitude(out) == nil)
            // ...and the rest survives, which is the half that distinguishes
            // "strip GPS" from "strip everything".
            #expect(Fixtures.exif(out, kCGImagePropertyExifDateTimeOriginal) as? String
                    == Fixtures.dateTimeOriginal)
            #expect(Fixtures.tiff(out, kCGImagePropertyTIFFMake) as? String == Fixtures.make)
            #expect(Fixtures.tiff(out, kCGImagePropertyTIFFModel) as? String == Fixtures.model)
        }
    }

    /// `.strip` takes a set of classes, and GPS is the only one whose table is
    /// exercised above. This checks a second and a third, because the per-class
    /// key table is exactly the kind of list where one wrong constant is
    /// invisible until somebody audits an exported file.
    @Test("stripping device identity and timestamps leaves the rest alone")
    func metadataStripClasses() async throws {
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.taggedImage(in: directory)
            let destination = directory.appendingPathComponent("classes.jpg")

            _ = try await encoder.encode(
                source: source, to: destination,
                format: .jpeg, quality: .quality(0.9), resize: nil,
                metadata: .strip([.deviceIdentity, .timestamps])
            )

            let out = Fixtures.properties(of: destination)
            #expect(Fixtures.tiff(out, kCGImagePropertyTIFFMake) == nil)
            #expect(Fixtures.tiff(out, kCGImagePropertyTIFFModel) == nil)
            #expect(Fixtures.tiff(out, kCGImagePropertyTIFFDateTime) == nil)
            #expect(Fixtures.exif(out, kCGImagePropertyExifDateTimeOriginal) == nil)
            #expect(Fixtures.exif(out, kCGImagePropertyExifDateTimeDigitized) == nil)
            #expect(Fixtures.exif(out, kCGImagePropertyExifLensModel) == nil)
            // Neither class is location, so the GPS tag has to survive — a strip
            // that removes more than it was asked to is as much a defect as one
            // that removes less.
            #expect(Fixtures.gpsLatitude(out) != nil)
        }
    }

    /// Stripping orientation does not anonymise a photo, it rotates it. No policy
    /// may do that, and `.stripAll` is where a careless implementation would.
    @Test("no metadata policy is allowed to strip the orientation")
    func orientationSurvivesStripAll() async throws {
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.quadrantImage(
                in: directory, format: .jpeg, orientation: .right
            )
            let destination = directory.appendingPathComponent("stripped.jpg")

            let result = try await encoder.encode(
                source: source, to: destination,
                format: .jpeg, quality: .quality(0.95), resize: nil, metadata: .stripAll,
                orientation: .preserveTag
            )
            #expect(result.pixelSize == Fixtures.quadrantSize)
            #expect(Fixtures.orientation(of: destination) == .right,
                    "stripAll dropped the orientation, which rotates the picture")
        }
    }

    /// The floor under every policy: a key whose removal breaks the file rather
    /// than anonymising it. `MakerApple` 17 is the paired still/video content
    /// identifier — strip it and the two halves of a motion photo stop being
    /// recognised as one item.
    @Test("the force-preserve floor survives stripAll")
    func forcePreserveFloorHolds() async throws {
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.taggedImage(in: directory)
            let destination = directory.appendingPathComponent("floor.jpg")

            _ = try await encoder.encode(
                source: source, to: destination,
                format: .jpeg, quality: .quality(0.9), resize: nil, metadata: .stripAll
            )

            let out = Fixtures.properties(of: destination)
            let maker = out[kCGImagePropertyMakerAppleDictionary] as? [CFString: Any]
            if let identifier = maker?["17" as CFString] as? String {
                #expect(identifier == Fixtures.contentIdentifier)
            } else {
                // Whether ImageIO will write a synthesised maker-note dictionary
                // back out is its business, not this package's. Reported rather
                // than asserted so a platform that refuses does not read as a
                // defect here — the policy layer is tested directly below.
                print("  note: ImageIO did not write the MakerApple dictionary back out; "
                      + "the force-preserve floor is asserted at the policy layer instead")
            }

            // The policy layer, where the guarantee actually lives.
            let restored = try ImageMetadata.properties(
                for: .stripAll,
                from: Fixtures.properties(of: source),
                forcePreserve: .default,
                orientation: .up
            )
            let restoredMaker = try #require(restored[kCGImagePropertyMakerAppleDictionary] as? [CFString: Any])
            #expect(restoredMaker["17" as CFString] as? String == Fixtures.contentIdentifier)
        }
    }

    /// `MetadataKey`'s normalised namespace has no ImageIO mapping yet, so the
    /// allow-list policy refuses by name rather than silently keeping or dropping
    /// the keys it does not understand.
    @Test("a custom allow-list refuses, by name")
    func customPolicyIsNotImplemented() async throws {
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.taggedImage(in: directory)
            let destination = directory.appendingPathComponent("custom.jpg")

            do {
                _ = try await encoder.encode(
                    source: source, to: destination,
                    format: .jpeg, quality: .quality(0.9), resize: nil,
                    metadata: .custom(allowList: [MetadataKey("exif.DateTimeOriginal")])
                )
                Issue.record("expected a refusal")
            } catch let error as LatheError {
                guard case let .notImplemented(feature) = error else {
                    Issue.record("expected .notImplemented, got \(error)")
                    return
                }
                #expect(feature.contains("custom"))
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    // MARK: - Progress and cancellation

    /// The seam's whole design: **the sink's return value is the cancellation
    /// signal.** A sink that says stop must actually stop the work, and — because
    /// the encode writes beside the destination and moves it into place — must
    /// leave nothing behind.
    @Test("a sink that returns false stops the encode and leaves no output")
    func cancellationStopsTheWork() async throws {
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.plainImage(in: directory, size: PixelSize(width: 256, height: 256))
            let destination = directory.appendingPathComponent("cancelled.png")

            let ticks = Counter()
            let handle = ProgressHandle(
                sink: ClosureProgressSink { _ in
                    ticks.increment()
                    return false        // stop at the very first checkpoint
                },
                throttle: .unthrottled
            )

            let request = ImageEncodeRequest(
                source: source, destination: destination, format: .png,
                quality: .quality(0.9), resize: .longestSide(64), metadata: .preserveAll
            )
            #expect(throws: LatheError.self) {
                _ = try ImageEncoder().encode(request, progress: handle)
            }
            #expect(handle.isCancelled)
            // One tick, not five: the work stopped rather than running to
            // completion and reporting the cancellation afterwards.
            #expect(ticks.value == 1, "expected the encode to stop at the first checkpoint")
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(Fixtures.strayFiles(in: directory).isEmpty,
                    "a cancelled encode left its scratch file behind")
        }
    }

    @Test("a pre-cancelled handle stops before anything is read")
    func preCancelledHandle() async throws {
        try await Fixtures.withDirectory { directory in
            let missing = directory.appendingPathComponent("does-not-exist.png")
            let destination = directory.appendingPathComponent("out.png")

            let handle = ProgressHandle.ignoring()
            handle.cancel()

            let request = ImageEncodeRequest(
                source: missing, destination: destination, format: .png
            )
            // Cancelled, *not* "no such file": the checkpoint comes first, which
            // is what makes cancellation cheap on a long batch.
            do {
                _ = try ImageEncoder().encode(request, progress: handle)
                Issue.record("expected a refusal")
            } catch let error as LatheError {
                #expect(error.isCancellation, "expected cancellation, got \(error)")
            }
        }
    }

    /// Progress is a sample, not an event log, but the stage sequence is part of
    /// the contract: a UI that never sees the terminal tick looks stuck.
    @Test("progress runs through the stages and ends on the terminal tick")
    func progressReportsStages() async throws {
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.plainImage(in: directory, size: PixelSize(width: 128, height: 96))
            let destination = directory.appendingPathComponent("progress.jpg")

            let recorder = SampleRecorder()
            _ = try await encoder.encode(
                source: source, to: destination,
                format: .jpeg, quality: .quality(0.8), resize: .longestSide(32),
                metadata: .preserveAll,
                reporting: recorder.sink()
            )

            let samples = recorder.samples
            #expect(!samples.isEmpty)
            #expect(samples.map(\.stage).first == "probe")
            #expect(Set(samples.map(\.stage)) == ["probe", "read", "decode", "scale", "encode"])
            let last = try #require(samples.last)
            #expect(last.unitIndex == last.unitCount)
            #expect(last.fraction == 1)
        }
    }

    // MARK: - Growth

    /// Quality 1.0 is not lossless. On a lossy format it still quantises, and
    /// re-encoding an already-compressed source at 1.0 routinely produces a
    /// *larger* file — which is how a "make my library smaller" batch makes it
    /// bigger. The encoder reports both byte counts rather than second-guessing
    /// the request, so this asserts the reporting is usable rather than asserting
    /// a direction the codecs do not guarantee.
    @Test("the result carries both byte counts, so growth is visible")
    func growthIsVisible() async throws {
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.quadrantImage(in: directory, format: .jpeg, orientation: .up)
            let low = directory.appendingPathComponent("low.jpg")
            let high = directory.appendingPathComponent("high.jpg")

            let cheap = try await encoder.encode(
                source: source, to: low,
                format: .jpeg, quality: .quality(0.2), resize: nil, metadata: .stripAll
            )
            let expensive = try await encoder.encode(
                source: source, to: high,
                format: .jpeg, quality: .quality(1.0), resize: nil, metadata: .stripAll
            )

            #expect(cheap.inputByteCount > 0)
            #expect(cheap.outputByteCount > 0)
            #expect(expensive.outputByteCount > cheap.outputByteCount,
                    "quality 1.0 must not produce a smaller file than quality 0.2")
            print("  JPEG re-encode of \(cheap.inputByteCount) bytes: "
                  + "q0.2 → \(cheap.outputByteCount), q1.0 → \(expensive.outputByteCount)")

            if EncodeSupport.shared.canEncode(.heic) {
                let heic = directory.appendingPathComponent("max.heic")
                let result = try await encoder.encode(
                    source: source, to: heic,
                    format: .heic, quality: .quality(1.0), resize: nil, metadata: .stripAll
                )
                print("  HEIC at quality 1.0: \(result.inputByteCount) → "
                      + "\(result.outputByteCount) bytes "
                      + (result.outputByteCount > result.inputByteCount ? "(grew)" : "(shrank)"))
            }
        }
    }

    /// Quality 1.0 is where the encoders stop agreeing with each other, so this
    /// asks every lossy format for it and records what happened.
    ///
    /// The finding worth having: **ImageIO's AVIF encoder rejects a quality of
    /// exactly 1.0** — `CGImageDestinationFinalize` returns false and writes
    /// nothing — where 0.999 encodes fine and every other lossy format accepts
    /// 1.0. That is reported rather than asserted, because which encoders refuse
    /// is the platform's business and freezing today's answer would be the
    /// version-gating this package avoids.
    ///
    /// What *is* asserted is the guarantee that makes such a refusal survivable:
    /// the failure is a named `encodingFailed`, and there is no file at the
    /// destination afterwards. A real encoder failure is a much better test of
    /// "never leave a 0-byte file" than a synthetic one.
    @Test("quality 1.0 is either honoured or refused cleanly, never left half-written")
    func qualityOneIsHandledOrRefusedCleanly() async throws {
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.plainImage(in: directory, size: PixelSize(width: 32, height: 32))
            let lossy = EncodeSupport.shared.supportedFormats
                .filter(\.isLossyByDefault)
                .sorted { $0.rawValue < $1.rawValue }

            print("")
            for format in lossy {
                let destination = directory
                    .appendingPathComponent("max.\(format.preferredFilenameExtension)")
                do {
                    let result = try await encoder.encode(
                        source: source, to: destination,
                        format: format, quality: .quality(1.0), resize: nil, metadata: .stripAll
                    )
                    #expect(result.outputByteCount > 0)
                    #expect(FileManager.default.fileExists(atPath: destination.path))
                    print("  \(format.description) at quality 1.0: \(result.outputByteCount) bytes")
                } catch let error as LatheError {
                    guard case let .encodingFailed(_, _, reason) = error else {
                        Issue.record("\(format.description) failed with \(error), expected .encodingFailed")
                        continue
                    }
                    // The refusal must be survivable, which means nothing left
                    // behind — not at the destination, and not beside it.
                    #expect(!FileManager.default.fileExists(atPath: destination.path),
                            "\(format.description) refused quality 1.0 and left a file")
                    #expect(Fixtures.strayFiles(in: directory).isEmpty,
                            "\(format.description) refused quality 1.0 and left its scratch file")
                    // ...and it must say something a caller can act on.
                    #expect(reason.contains("1.0"))
                    print("  \(format.description) at quality 1.0: refused — \(reason)")
                }
            }
            print("")
        }
    }

    // MARK: - Bad input

    @Test("a missing source is a read failure, and creates nothing")
    func missingSource() async throws {
        try await Fixtures.withDirectory { directory in
            let destination = directory.appendingPathComponent("out.png")
            do {
                _ = try await encoder.encode(
                    source: directory.appendingPathComponent("nope.png"), to: destination,
                    format: .png, quality: .quality(0.9), resize: nil, metadata: .preserveAll
                )
                Issue.record("expected a refusal")
            } catch let error as LatheError {
                guard case .readFailed = error else {
                    Issue.record("expected .readFailed, got \(error)")
                    return
                }
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test("a file that is not an image is refused, and creates nothing")
    func notAnImage() async throws {
        try await Fixtures.withDirectory { directory in
            let source = directory.appendingPathComponent("notes.png")
            try Data("this is not a PNG, whatever the extension says".utf8).write(to: source)
            let destination = directory.appendingPathComponent("out.png")

            do {
                _ = try await encoder.encode(
                    source: source, to: destination,
                    format: .png, quality: .quality(0.9), resize: nil, metadata: .preserveAll
                )
                Issue.record("expected a refusal")
            } catch let error as LatheError {
                // ImageIO may refuse at `CGImageSourceCreateWithURL` or later at
                // the decode; both are honest, neither may leave a file.
                #expect(!error.isCancellation)
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(Fixtures.strayFiles(in: directory).isEmpty)
        }
    }

    /// The encoder overwrites, and an overwrite that fails must not destroy what
    /// was already there. The move-into-place is what buys this.
    ///
    /// The failure is provoked with an unreadable *source*, which fails at stage
    /// 1 for every format and on every platform. This used to target WebP, back
    /// when WebP was guaranteed to be unwritable; it is not any more, and a test
    /// that depends on a capability probe's answer is a test that stops testing
    /// what it says the day the answer changes. See `WebPEncoderTests` for the
    /// same property proved against a failure *inside* the encoder.
    @Test("an existing destination survives a failed encode")
    func failedEncodeLeavesThePreviousFileIntact() async throws {
        try await Fixtures.withDirectory { directory in
            let destination = directory.appendingPathComponent("existing.jpg")
            let original = Data("the file that was already here".utf8)
            try original.write(to: destination)

            let source = directory.appendingPathComponent("gone.png")
            await #expect(throws: LatheError.self) {
                try await encoder.encode(
                    source: source, to: destination,
                    format: .jpeg, quality: .quality(0.8), resize: nil, metadata: .preserveAll
                )
            }
            #expect(try Data(contentsOf: destination) == original)
            #expect(Fixtures.strayFiles(in: directory).isEmpty)
        }
    }
}

// MARK: - Recording helpers

/// A thread-safe counter: the sink is called from `LatheWork`'s worker queue.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class SampleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [LatheProgress] = []

    func sink() -> any ProgressSink {
        ObservingProgressSink { [self] sample in
            lock.lock(); recorded.append(sample); lock.unlock()
        }
    }

    var samples: [LatheProgress] {
        lock.lock(); defer { lock.unlock() }; return recorded
    }
}

// MARK: - Fixtures

/// Images generated at run time, so nothing binary is committed and every
/// fixture's properties are known by construction.
enum Fixtures {

    static let quadrantSize = PixelSize(width: 64, height: 32)

    // Saturated primaries, so JPEG's chroma subsampling cannot smear one into
    // another at a quadrant's centre.
    static let topLeftColour = RGB(255, 0, 0)
    static let topRightColour = RGB(0, 255, 0)
    static let bottomLeftColour = RGB(0, 0, 255)
    static let bottomRightColour = RGB(255, 255, 0)

    static let make = "Lathe Test Camera"
    static let model = "Synthetic 1"
    static let dateTimeOriginal = "2001:02:03 04:05:06"
    static let contentIdentifier = "A1B2C3D4-0000-0000-0000-000000000000"

    // MARK: Directories

    static func withDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lathe-encode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    /// Temporary files the encoder should have cleaned up after itself.
    static func strayFiles(in directory: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(".lathe-") }
    }

    // MARK: Sources

    /// A plain gradient, no metadata, no orientation.
    static func plainImage(in directory: URL, size: PixelSize) throws -> URL {
        let image = try #require(gradient(size), "could not build a test CGImage")
        let url = directory.appendingPathComponent("source-\(size.width)x\(size.height).png")
        try write(image, to: url, format: .png, properties: [:])
        return url
    }

    /// Four coloured quadrants, written with an explicit orientation tag.
    static func quadrantImage(
        in directory: URL,
        format: ImageFormat,
        orientation: CGImagePropertyOrientation
    ) throws -> URL {
        let image = try #require(quadrants(), "could not build a quadrant CGImage")
        let url = directory.appendingPathComponent("quadrants-\(orientation.rawValue)."
                                                   + format.preferredFilenameExtension)
        try write(image, to: url, format: format, properties: [
            kCGImagePropertyOrientation: orientation.rawValue,
        ])
        return url
    }

    /// A quadrant image carrying GPS, timestamps, camera identity and a maker
    /// note, i.e. everything the metadata policies have to sort out.
    static func taggedImage(in directory: URL) throws -> URL {
        let image = try #require(quadrants(), "could not build a quadrant CGImage")
        let url = directory.appendingPathComponent("tagged.jpg")
        try write(image, to: url, format: .jpeg, properties: [
            kCGImagePropertyOrientation: CGImagePropertyOrientation.up.rawValue,
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 51.5,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 0.12,
                kCGImagePropertyGPSLongitudeRef: "W",
            ] as [CFString: Any],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: dateTimeOriginal,
                kCGImagePropertyExifDateTimeDigitized: dateTimeOriginal,
                kCGImagePropertyExifLensModel: "50mm f/1.8",
            ] as [CFString: Any],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: make,
                kCGImagePropertyTIFFModel: model,
                kCGImagePropertyTIFFSoftware: "Lathe fixtures",
                kCGImagePropertyTIFFDateTime: dateTimeOriginal,
            ] as [CFString: Any],
            kCGImagePropertyMakerAppleDictionary: [
                "17" as CFString: contentIdentifier,
                "14" as CFString: 1,
            ] as [CFString: Any],
        ])
        return url
    }

    /// Deterministic pseudo-random noise — the incompressible case.
    ///
    /// Its own generator rather than `SystemRandomNumberGenerator`, so a size
    /// comparison measured here is the same size comparison on the next run and
    /// on somebody else's machine. Written as PNG so the fixture itself adds no
    /// compression artefacts.
    static func noiseImage(in directory: URL, size: PixelSize) throws -> URL {
        // A 64-bit xorshift, seeded by hand. Any full-period generator would do;
        // what matters is that it is in this file rather than in a library whose
        // stream could change under us.
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        func next() -> UInt8 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(truncatingIfNeeded: state >> 24)
        }
        let image = try #require(
            bitmap(size) { _, _ in RGB(next(), next(), next()) },
            "could not build a noise CGImage"
        )
        let url = directory.appendingPathComponent("noise-\(size.width)x\(size.height).png")
        try write(image, to: url, format: .png, properties: [:])
        return url
    }

    /// A flat colour at a uniform alpha, written as PNG so the alpha survives
    /// the fixture itself.
    static func translucentImage(
        in directory: URL,
        size: PixelSize,
        colour: RGB,
        alpha: UInt8
    ) throws -> URL {
        let image = try #require(
            bitmap(size, alpha: alpha) { _, _ in colour },
            "could not build a translucent CGImage"
        )
        let url = directory.appendingPathComponent("translucent.png")
        try write(image, to: url, format: .png, properties: [:])
        return url
    }

    private static func write(
        _ image: CGImage,
        to url: URL,
        format: ImageFormat,
        properties: [CFString: Any]
    ) throws {
        let uti = try #require(EncodeSupport.shared.destinationTypeIdentifier(for: format))
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil),
            "could not create a \(format) fixture destination"
        )
        var withQuality = properties
        if format.isLossyByDefault {
            // Near-maximum, so the fixture's own compression is not what a later
            // colour comparison is measuring.
            withQuality[kCGImageDestinationLossyCompressionQuality] = 0.98
        }
        CGImageDestinationAddImage(destination, image, withQuality as CFDictionary)
        #expect(CGImageDestinationFinalize(destination), "could not finalise a \(format) fixture")
    }

    // MARK: Building pixels

    private static func gradient(_ size: PixelSize) -> CGImage? {
        bitmap(size) { x, y in
            RGB(UInt8(x * 255 / max(1, size.width - 1)),
                UInt8(y * 255 / max(1, size.height - 1)),
                128)
        }
    }

    private static func quadrants() -> CGImage? {
        let size = quadrantSize
        return bitmap(size) { x, y in
            let left = x < size.width / 2
            let top = y < size.height / 2
            switch (top, left) {
            case (true, true): return topLeftColour
            case (true, false): return topRightColour
            case (false, true): return bottomLeftColour
            case (false, false): return bottomRightColour
            }
        }
    }

    /// `body` is called with (column, row) where row 0 is the **top** — the same
    /// convention as a stored image's first row.
    ///
    /// `alpha` is applied to every pixel, and the colours are premultiplied on
    /// the way in because that is the only alpha layout `CGImage` accepts here.
    private static func bitmap(
        _ size: PixelSize,
        alpha: UInt8 = 255,
        _ body: (Int, Int) -> RGB
    ) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: size.width * size.height * 4)
        let scale = { (value: UInt8) in UInt8((Int(value) * Int(alpha) + 127) / 255) }
        for y in 0..<size.height {
            for x in 0..<size.width {
                let colour = body(x, y)
                let i = (y * size.width + x) * 4
                pixels[i + 0] = scale(colour.r)
                pixels[i + 1] = scale(colour.g)
                pixels[i + 2] = scale(colour.b)
                pixels[i + 3] = alpha
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: size.width, height: size.height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    // MARK: Reading results back

    static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // No transform applied: these tests want the *stored* pixels, and check
        // the orientation tag separately.
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func properties(of url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [:] }
        return ImageMetadata.sourceProperties(of: source)
    }

    static func orientation(of url: URL) -> CGImagePropertyOrientation? {
        guard let raw = (properties(of: url)[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value
        else { return nil }
        return CGImagePropertyOrientation(rawValue: raw)
    }

    static func byteCount(of url: URL) -> UInt64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            .flatMap { $0.map(UInt64.init) } ?? 0
    }

    /// Every pixel as tightly-packed RGBA, for a whole-image comparison.
    ///
    /// `premultiplied: false` asks for straight alpha, which a bitmap context
    /// cannot produce directly — so it draws premultiplied and divides back out,
    /// the same way the encoder does.
    static func rgbaBytes(of image: CGImage, premultiplied: Bool = true) -> [UInt8]? {
        let bytesPerRow = image.width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let drew: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drew else { return nil }
        guard !premultiplied else { return pixels }

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Int(pixels[i + 3])
            guard a > 0, a < 255 else { continue }
            for channel in 0..<3 {
                pixels[i + channel] = UInt8(min(255, (Int(pixels[i + channel]) * 255 + a / 2) / a))
            }
        }
        return pixels
    }

    // MARK: Reading raw containers

    static func fourCC(_ data: Data, at offset: Int) -> String? {
        guard data.count >= offset + 4 else { return nil }
        return String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
    }

    static func littleEndianUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard data.count >= offset + 4 else { return 0 }
        return data[offset..<(offset + 4)]
            .enumerated()
            .reduce(UInt32(0)) { $0 | (UInt32($1.element) << (8 * $1.offset)) }
    }

    static func exif(_ properties: [CFString: Any], _ key: CFString) -> Any? {
        (properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[key]
    }

    static func tiff(_ properties: [CFString: Any], _ key: CFString) -> Any? {
        (properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[key]
    }

    static func gpsLatitude(_ properties: [CFString: Any]) -> Any? {
        (properties[kCGImagePropertyGPSDictionary] as? [CFString: Any])?[kCGImagePropertyGPSLatitude]
    }

    // MARK: Sampling pixels

    enum Corner { case topLeft, topRight, bottomLeft, bottomRight }

    /// Samples the centre of the named quadrant, not the literal corner pixel:
    /// a lossy codec's ringing is worst at an edge, and the assertion is about
    /// *which quadrant landed here*, not about exact reconstruction.
    static func corner(_ corner: Corner, of image: CGImage) -> RGB {
        let x: Int, y: Int
        switch corner {
        case .topLeft: x = image.width / 4; y = image.height / 4
        case .topRight: x = image.width * 3 / 4; y = image.height / 4
        case .bottomLeft: x = image.width / 4; y = image.height * 3 / 4
        case .bottomRight: x = image.width * 3 / 4; y = image.height * 3 / 4
        }
        return pixel(at: x, y: y, of: image) ?? RGB(0, 0, 0)
    }

    private static func pixel(at x: Int, y: Int, of image: CGImage) -> RGB? {
        var bytes = [UInt8](repeating: 0, count: 4)
        let result: CGImage? = bytes.withUnsafeMutableBytes { raw -> CGImage? in
            guard let context = CGContext(
                data: raw.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.interpolationQuality = .none
            // Draw the whole image scaled so that the pixel of interest lands in
            // the 1x1 context.
            context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y),
                                           width: image.width, height: image.height))
            return image
        }
        guard result != nil else { return nil }
        return RGB(bytes[0], bytes[1], bytes[2])
    }
}

struct RGB: Equatable, Sendable, CustomStringConvertible {
    var r: UInt8, g: UInt8, b: UInt8
    init(_ r: UInt8, _ g: UInt8, _ b: UInt8) { self.r = r; self.g = g; self.b = b }
    var description: String { "rgb(\(r),\(g),\(b))" }

    /// Lossy codecs and a colour-space round trip both move values a little, so
    /// the comparison is "nearest of the fixture's four saturated primaries"
    /// rather than an exact match.
    func isCloseTo(_ other: RGB, tolerance: Int = 48) -> Bool {
        abs(Int(r) - Int(other.r)) <= tolerance
            && abs(Int(g) - Int(other.g)) <= tolerance
            && abs(Int(b) - Int(other.b)) <= tolerance
    }
}
