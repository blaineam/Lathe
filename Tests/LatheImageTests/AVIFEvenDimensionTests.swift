import CoreGraphics
import Foundation
import ImageIO
import LatheCore
import Testing

@testable import LatheImage

/// ImageIO writes odd-sized AVIF that only Apple's decoder reads: small
/// pictures are coded padded (601 × 400 decodes as 602 × 400 in libavif) and
/// tiled ones are refused as an invalid grid. Chrome and Firefox decode with
/// libavif, so the encoder crops AVIF to even dimensions. See
/// `ImageFormat.requiresEvenDimensions`.
///
/// libavif is not linked here, so what is asserted is the property it checks:
/// every image-spatial-extent (`ispe`) box in the file — the picture's, and
/// each grid tile's — is even in both directions.
@Suite("AVIF is written at even dimensions",
       .enabled(if: EncodeSupport.shared.canEncode(.avif), "this system cannot encode AVIF"))
struct AVIFEvenDimensionTests {

    let encoder = ImageEncoder()

    @Test("an odd-sized picture loses its last column and row",
          arguments: [PixelSize(width: 601, height: 401), PixelSize(width: 2047, height: 365),
                      PixelSize(width: 600, height: 401), PixelSize(width: 601, height: 400)])
    func oddIsCropped(size: PixelSize) async throws {
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.plainImage(in: directory, size: size)
            let destination = directory.appendingPathComponent("out.avif")
            let result = try await encoder.encode(
                source: source, to: destination, format: .avif,
                quality: .quality(0.8), resize: nil, metadata: .stripAll)

            let expected = PixelSize(width: size.width & ~1, height: size.height & ~1)
            #expect(result.pixelSize == expected)
            #expect(Self.storedSize(of: destination) == expected)
            let extents = try Self.spatialExtents(in: destination)
            #expect(!extents.isEmpty, "no ispe box found; the parser is wrong, not the file")
            for extent in extents {
                #expect(extent.width % 2 == 0 && extent.height % 2 == 0, "odd ispe \(extent)")
            }
        }
    }

    @Test("a resize that lands on an odd size is cropped too")
    func oddAfterResize() async throws {
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.plainImage(in: directory, size: PixelSize(width: 1000, height: 600))
            let destination = directory.appendingPathComponent("out.avif")
            // 333 × 200 before the crop.
            let result = try await encoder.encode(
                source: source, to: destination, format: .avif,
                quality: .quality(0.8), resize: .longestSide(333), metadata: .stripAll)
            #expect(result.pixelSize == PixelSize(width: 332, height: 200))
        }
    }

    @Test("a rotated odd-sized picture is baked upright, then cropped on its displayed axes")
    func rotatedOddIsBakedThenCropped() async throws {
        try await Fixtures.withDirectory { directory in
            let made = Fixtures.gradient(PixelSize(width: 63, height: 33))
            let image = try #require(made)
            let source = directory.appendingPathComponent("rotated.png")
            try Fixtures.write(image, to: source, format: .png, properties: [
                kCGImagePropertyOrientation: CGImagePropertyOrientation.right.rawValue,
            ])
            let destination = directory.appendingPathComponent("out.avif")
            let result = try await encoder.encode(
                source: source, to: destination, format: .avif,
                quality: .quality(0.8), resize: nil, metadata: .preserveAll)

            // Displayed 33 × 63, so 32 × 62 — and upright, with no tag left to
            // rotate it a second time.
            #expect(result.pixelSize == PixelSize(width: 32, height: 62))
            let tag = Fixtures.orientation(of: destination)
            #expect(tag == .up || tag == nil)
        }
    }

    @Test("other formats keep odd dimensions", arguments: [ImageFormat.jpeg, .heic, .png])
    func otherFormatsUntouched(format: ImageFormat) async throws {
        try #require(EncodeSupport.shared.canEncode(format))
        try await Fixtures.withDirectory { directory in
            let source = try Fixtures.plainImage(in: directory, size: PixelSize(width: 601, height: 401))
            let destination = directory.appendingPathComponent("out.\(format.preferredFilenameExtension)")
            let result = try await encoder.encode(
                source: source, to: destination, format: format,
                quality: .quality(0.8), resize: nil, metadata: .stripAll)
            #expect(result.pixelSize == PixelSize(width: 601, height: 401))
        }
    }

    @Test("the even floor never crops a single pixel to nothing")
    func evenFloor() {
        #expect(ImageEncoder.evenFloor(1) == 1)
        #expect(ImageEncoder.evenFloor(2) == 2)
        #expect(ImageEncoder.evenFloor(3) == 2)
        #expect(ImageEncoder.evenFloor(4607) == 4606)
    }

    @Test("the visually lossless search passes an odd-sized AVIF at a real quality")
    func searchSurvivesTheCrop() async throws {
        try await Fixtures.withDirectory { directory in
            let card = try VisualComparisonTests.testCard(width: 641, height: 481)
            let source = directory.appendingPathComponent("card.png")
            try Fixtures.write(card, to: source, format: .png, properties: [:])
            let destination = directory.appendingPathComponent("card.avif")
            let result = try #require(try await encoder.encodeVisuallyLossless(
                source: source, to: destination, format: .avif))
            #expect(result.encode.pixelSize == PixelSize(width: 640, height: 480))
            #expect(result.quality < 0.98, "the crop should not push the search to its ceiling")
        }
    }

    // MARK: - Reading the file

    static func storedSize(of url: URL) -> PixelSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return PixelSize(width: width, height: height)
    }

    /// Every `ispe` box: size(4) 'ispe'(4) version+flags(4) width(4) height(4).
    /// A byte scan rather than a box walk — the boxes sit inside `iprp`/`ipco`
    /// and the fourcc cannot occur by accident in a file this small.
    static func spatialExtents(in url: URL) throws -> [PixelSize] {
        let bytes = [UInt8](try Data(contentsOf: url))
        let tag: [UInt8] = Array("ispe".utf8)
        func word(_ at: Int) -> Int {
            Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
        }
        var extents: [PixelSize] = []
        var index = 4
        while index + 16 <= bytes.count {
            if Array(bytes[index..<index + 4]) == tag {
                extents.append(PixelSize(width: word(index + 8), height: word(index + 12)))
            }
            index += 1
        }
        return extents
    }
}
