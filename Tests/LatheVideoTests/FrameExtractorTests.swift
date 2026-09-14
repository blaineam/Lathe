import CoreGraphics
import Foundation
import ImageIO
import LatheCore
import LatheFixtures
import LatheImage
import Testing

@testable import LatheVideo

/// Tests for frame extraction.
///
/// The fixture is deliberately **not square** — 160x120 — because a square
/// source hides every aspect-ratio and row-padding bug there is.
@Suite("Frame extraction", .serialized)
struct FrameExtractorTests {

    private let extractor = FrameExtractor()
    private static let size = PixelSize(width: 160, height: 120)

    /// A clip whose left half is black and right half white, so a grayscale
    /// reduction has structure to preserve. A solid-colour frame cannot tell a
    /// working luminance conversion from one that returns a constant.
    private func splitMovie() async -> URL? {
        await fixture("frames-split.mov") {
            try await FixtureLibrary.shared.movie(
                named: "frames-split.mov", size: Self.size, frameRate: 24, seconds: 2,
                colour: .black, rightHalf: .white
            )
        }
    }

    // MARK: - Thumbnails

    @Test("a thumbnail lands on the requested longest edge, aspect preserved")
    func thumbnailIsScaledToTheRequestedEdge() async throws {
        guard let movie = await splitMovie() else { return }
        let output = await FixtureLibrary.shared.scratchURL(named: "thumb-64.png")

        let reported = try await extractor.thumbnail(
            from: movie, to: output, atSeconds: 1, maxWidth: 64
        )
        #expect(reported == PixelSize(width: 64, height: 48))

        let written = try #require(Self.pixelSize(ofImageAt: output))
        #expect(written == PixelSize(width: 64, height: 48))
        // 160:120 is 4:3, and so is 64:48. Asserted as arithmetic rather than by
        // eye, because a rounding bug shows up as a one-pixel difference.
        #expect(written.width * Self.size.height == written.height * Self.size.width)
        #expect((Self.byteCount(of: output) ?? 0) > 0)
    }

    @Test("a thumbnail is never enlarged past the source")
    func thumbnailNeverUpsamples() async throws {
        guard let movie = await splitMovie() else { return }
        let output = await FixtureLibrary.shared.scratchURL(named: "thumb-huge.png")

        // Asking for a 4000-pixel edge from a 160-pixel source.
        let reported = try await extractor.thumbnail(
            from: movie, to: output, atSeconds: 0.5, maxWidth: 4000
        )
        #expect(reported == Self.size)
        #expect(Self.pixelSize(ofImageAt: output) == Self.size)
    }

    @Test("the output format follows the destination's extension",
          arguments: ["jpg", "png", "tiff"])
    func formatFollowsExtension(_ fileExtension: String) async throws {
        let format = try #require(ImageFormat.named(byFilenameExtension: fileExtension))
        guard EncodeSupport.shared.canEncode(format) else {
            withKnownIssue("this system cannot encode \(format.description)") {
                Issue.record("unsupported here")
            }
            return
        }
        guard let movie = await splitMovie() else { return }

        let output = await FixtureLibrary.shared.scratchURL(named: "thumb-format.\(fileExtension)")
        try? FileManager.default.removeItem(at: output)
        _ = try await extractor.thumbnail(from: movie, to: output, atSeconds: 1, maxWidth: 80)

        // Read the type back from the file's own bytes, not from its name.
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let written = try #require(CGImageSourceGetType(source) as String?)
        #expect(format.allTypeIdentifiers.contains { $0.caseInsensitiveCompare(written) == .orderedSame },
                "wrote \(written), expected one of \(format.allTypeIdentifiers)")
    }

    /// The failure this guards against is a **0-byte file**: ImageIO returns a
    /// nil destination for a format it cannot write, and code that ignores that
    /// leaves an empty file that looks like a successful thumbnail.
    @Test("an unencodable output format fails cleanly and writes nothing")
    func unencodableFormatFails() async throws {
        guard !EncodeSupport.shared.canEncode(.webp) else {
            withKnownIssue("this system can encode WebP, so it is no longer the unwritable case") {
                Issue.record("pick another decode-only format for this test")
            }
            return
        }
        guard let movie = await splitMovie() else { return }

        let output = await FixtureLibrary.shared.scratchURL(named: "thumb-unwritable.webp")
        try? FileManager.default.removeItem(at: output)

        do {
            _ = try await extractor.thumbnail(from: movie, to: output, atSeconds: 1, maxWidth: 64)
            Issue.record("expected a refusal")
        } catch let error as LatheError {
            guard case let .encodeUnavailable(format) = error else {
                Issue.record("expected .encodeUnavailable, got \(error)")
                return
            }
            #expect(format == ImageFormat.webp.description)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path),
                "a refused encode must not leave a file behind")
    }

    @Test("an unrecognised extension is a configuration error, not a codec error")
    func unknownExtensionFails() async throws {
        guard let movie = await splitMovie() else { return }
        let output = await FixtureLibrary.shared.scratchURL(named: "thumb.sideways")

        do {
            _ = try await extractor.thumbnail(from: movie, to: output, atSeconds: 1, maxWidth: 64)
            Issue.record("expected a refusal")
        } catch let error as LatheError {
            // The distinction matters: "I do not know that extension" is fixed
            // by the caller, "this system cannot encode that" is not.
            guard case .invalidConfiguration = error else {
                Issue.record("expected .invalidConfiguration, got \(error)")
                return
            }
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("a file with no video track cannot produce a thumbnail")
    func noVideoTrack() async throws {
        guard let wav = await fixture("frames-audio-only.wav", {
            try await FixtureLibrary.shared.wav(
                named: "frames-audio-only.wav", seconds: 1,
                audio: .tone(hertz: 440, amplitude: 0.3)
            )
        }) else { return }
        let output = await FixtureLibrary.shared.scratchURL(named: "thumb-no-video.png")

        await #expect(throws: LatheError.self) {
            _ = try await extractor.thumbnail(from: wav, to: output, atSeconds: 0, maxWidth: 64)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("a non-positive maximum edge is refused")
    func invalidMaxWidth() async throws {
        guard let movie = await splitMovie() else { return }
        let output = await FixtureLibrary.shared.scratchURL(named: "thumb-zero.png")
        await #expect(throws: LatheError.self) {
            _ = try await extractor.thumbnail(from: movie, to: output, atSeconds: 1, maxWidth: 0)
        }
    }

    // MARK: - Grayscale

    /// The padding assertion. A `vImage_Buffer`'s `rowBytes` is padded for
    /// alignment far more often than not, so an extractor that returns
    /// `rowBytes × height` bytes looks right until something checks the count.
    @Test("the grayscale buffer is exactly size × size bytes",
          arguments: [8, 9, 16, 31, 32, 33, 64])
    func grayscaleLengthIsExact(_ side: Int) async throws {
        guard let movie = await splitMovie() else { return }
        let data = try await extractor.grayscaleFrame(from: movie, atSeconds: 1, size: side)
        #expect(data.count == side * side,
                "\(side)x\(side) produced \(data.count) bytes, expected \(side * side)")
    }

    @Test("the grayscale frame carries the source's structure, not a constant")
    func grayscalePreservesStructure() async throws {
        guard let movie = await splitMovie() else { return }
        let side = 32
        let data = try await extractor.grayscaleFrame(from: movie, atSeconds: 1, size: side)
        #expect(data.count == side * side)

        let bytes = [UInt8](data)
        // The fixture is black on the left, white on the right. Sampling the
        // outer quarters avoids the soft edge H.264's chroma subsampling leaves
        // down the middle.
        var leftTotal = 0, rightTotal = 0, samples = 0
        for row in 0..<side {
            for column in 0..<(side / 4) {
                leftTotal += Int(bytes[row * side + column])
                rightTotal += Int(bytes[row * side + (side - 1 - column)])
                samples += 1
            }
        }
        let leftMean = Double(leftTotal) / Double(samples)
        let rightMean = Double(rightTotal) / Double(samples)

        #expect(leftMean < 64, "the dark half measured \(leftMean)")
        #expect(rightMean > 190, "the light half measured \(rightMean)")
        // If the conversion returned a constant — the classic way a luminance
        // matrix goes wrong — these would be equal.
        #expect(rightMean - leftMean > 100)
    }

    @Test("the grayscale frame squashes rather than crops")
    func grayscaleSquashesToSquare() async throws {
        guard let movie = await splitMovie() else { return }
        let side = 16
        let bytes = [UInt8](try await extractor.grayscaleFrame(
            from: movie, atSeconds: 1, size: side
        ))

        // Cropping a 4:3 frame to a square would cut the sides off and lose one
        // of the two halves; squashing keeps both. Column 0 must still be dark
        // and column 15 still light.
        let firstColumn = (0..<side).map { Int(bytes[$0 * side]) }.reduce(0, +) / side
        let lastColumn = (0..<side).map { Int(bytes[$0 * side + side - 1]) }.reduce(0, +) / side
        #expect(firstColumn < 80)
        #expect(lastColumn > 170)
    }

    @Test("the grayscale extraction is reproducible")
    func grayscaleIsDeterministic() async throws {
        guard let movie = await splitMovie() else { return }
        // A perceptual hash is only useful if the same frame hashes the same way
        // twice, which requires both the seek and the scale to be deterministic.
        let first = try await extractor.grayscaleFrame(from: movie, atSeconds: 1, size: 32)
        let second = try await extractor.grayscaleFrame(from: movie, atSeconds: 1, size: 32)
        #expect(first == second)
    }

    @Test("a non-positive grayscale size is refused")
    func invalidGrayscaleSize() async throws {
        guard let movie = await splitMovie() else { return }
        await #expect(throws: LatheError.self) {
            _ = try await extractor.grayscaleFrame(from: movie, atSeconds: 1, size: 0)
        }
    }

    // MARK: - Accuracy

    @Test("tolerance choices map to the documented CMTime values")
    func accuracyTolerances() {
        #expect(FrameAccuracy.precise.tolerance == .zero)
        #expect(FrameAccuracy.nearestKeyframe.tolerance == .positiveInfinity)
        #expect(FrameAccuracy.within(seconds: 0.5).tolerance.seconds == 0.5)
    }

    /// The fast path has to actually work, not merely compile — a keyframe
    /// tolerance that returned no frame at all would otherwise go unnoticed
    /// until somebody used it on a long file.
    @Test("a keyframe-tolerant extraction still produces a frame")
    func nearestKeyframeStillWorks() async throws {
        guard let movie = await splitMovie() else { return }
        let output = await FixtureLibrary.shared.scratchURL(named: "thumb-keyframe.png")
        let reported = try await extractor.thumbnail(
            from: movie, to: output, atSeconds: 1.5, maxWidth: 40, accuracy: .nearestKeyframe
        )
        #expect(reported == PixelSize(width: 40, height: 30))
        #expect(Self.pixelSize(ofImageAt: output) == PixelSize(width: 40, height: 30))
    }

    // MARK: - Helpers

    private static func pixelSize(ofImageAt url: URL) -> PixelSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return PixelSize(width: width, height: height)
    }

    private static func byteCount(of url: URL) -> Int? {
        try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
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
