import CoreGraphics
import Foundation
import ImageIO
import LatheCore
import LatheFixtures
import Testing
import UniformTypeIdentifiers

@testable import LatheImage

@Suite("Visual comparison and quality search")
struct VisualComparisonTests {

    /// A picture with the things encoders damage: a slow gradient, hard edges
    /// and fine detail.
    static func testCard(width: Int = 640, height: Int = 480) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for x in 0..<width {
            let t = CGFloat(x) / CGFloat(width)
            context.setFillColor(CGColor(red: 0.1 + 0.5 * t, green: 0.2 + 0.3 * t, blue: 0.7 - 0.4 * t, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        var seed: UInt64 = 42
        for _ in 0..<400 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let x = Int(seed >> 33) % width, y = Int(seed >> 13) % height
            let shade = CGFloat(seed & 255) / 255
            context.setFillColor(CGColor(red: shade, green: 1 - shade, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: 3 + Int(seed & 7), height: 2 + Int((seed >> 8) & 5)))
        }
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.setLineWidth(1)
        for line in stride(from: 0, to: width, by: 6) {
            context.move(to: CGPoint(x: line, y: height / 2))
            context.addLine(to: CGPoint(x: line + 3, y: height))
        }
        context.strokePath()
        return try #require(context.makeImage())
    }

    static func encode(_ image: CGImage, as type: UTType, quality: Double) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test("a picture compared with itself is identical")
    func identical() throws {
        let card = try Self.testCard()
        let similarity = try VisualComparison.similarity(of: card, to: card)
        #expect(similarity.overall > 0.9999)
        #expect(similarity.worstRegion > 0.9999)
        #expect(similarity.meets(.visuallyLossless))
        #expect(similarity.comparedSize == PixelSize(width: 640, height: 480))
    }

    @Test("a gentle JPEG passes and a crushed one does not")
    func jpegQuality() throws {
        let card = try Self.testCard()
        let png = try Self.encode(card, as: .png, quality: 1)
        let gentle = try VisualComparison.similarity(
            ofImageData: try Self.encode(card, as: .jpeg, quality: 0.97), to: png)
        let crushed = try VisualComparison.similarity(
            ofImageData: try Self.encode(card, as: .jpeg, quality: 0.05), to: png)
        #expect(gentle.meets(.visuallyLossless), "q0.97 scored \(gentle)")
        #expect(!crushed.meets(.visuallyLossless), "q0.05 scored \(crushed)")
        #expect(crushed.overall < gentle.overall)
    }

    @Test("a local blemish fails the region bound even when the average is fine")
    func localDamage() throws {
        let card = try Self.testCard()
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: card.width, height: card.height, bitsPerComponent: 8,
            bytesPerRow: card.width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(card, in: CGRect(x: 0, y: 0, width: card.width, height: card.height))
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 300, y: 300, width: 24, height: 24))
        let damaged = try #require(context.makeImage())

        let similarity = try VisualComparison.similarity(of: damaged, to: card)
        #expect(similarity.overall > 0.99, "the patch is small: \(similarity.overall)")
        #expect(similarity.worstRegion < 0.97)
        #expect(!similarity.meets(.visuallyLossless))
    }

    @Test("a candidate at a smaller size is compared at that size")
    func resizedCandidate() throws {
        let card = try Self.testCard()
        let png = try Self.encode(card, as: .png, quality: 1)
        let pngSource = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let smaller = try #require(CGImageSourceCreateThumbnailAtIndex(
            pngSource, 0,
            [kCGImageSourceCreateThumbnailFromImageAlways: true,
             kCGImageSourceThumbnailMaxPixelSize: 320] as CFDictionary))
        let similarity = try VisualComparison.similarity(
            ofImageData: try Self.encode(smaller, as: .png, quality: 1), to: png)
        #expect(similarity.comparedSize == PixelSize(width: 320, height: 240))
        #expect(similarity.meets(.visuallyLossless), "\(similarity)")
    }

    // MARK: - The search

    private static func fake(_ value: Double) -> VisualSimilarity {
        // Passes at 0.62 and above.
        VisualSimilarity(overall: 0.9 + value * 0.15, worstRegion: 0.99,
                         comparedSize: PixelSize(width: 1, height: 1))
    }

    @Test("the search settles near the lowest passing value")
    func searchFindsTheEdge() async throws {
        let search = QualitySearch(range: 0.2...1, maximumAttempts: 8)
        let outcome = try await search.run { value in (value, Self.fake(value)) }
        let value = try #require(outcome.value)
        #expect(value >= 0.6 && value < 0.66, "settled at \(value)")
        #expect(outcome.output == value)
        #expect(outcome.attempts.first?.value == 1)
        #expect(outcome.attempts.count <= 8)
    }

    @Test("nothing is found when even the top of the range fails")
    func searchGivesUp() async throws {
        let search = QualitySearch(range: 0.2...0.5, maximumAttempts: 6)
        let outcome = try await search.run { value in (value, Self.fake(value)) }
        #expect(!outcome.found)
        #expect(outcome.output == nil)
        #expect(outcome.attempts.count == 1, "one failing attempt at the top is enough")
    }

    @Test("a still search picks a quality below the maximum, and its output passes")
    func stillSearch() async throws {
        let card = try Self.testCard()
        let png = try Self.encode(card, as: .png, quality: 1)
        let outcome = try await QualitySearch().still(reference: png) { quality in
            try Self.encode(card, as: .jpeg, quality: quality)
        }
        let quality = try #require(outcome.value)
        let data = try #require(outcome.output)
        #expect(quality < 0.98)
        #expect(try VisualComparison.similarity(ofImageData: data, to: png).meets(.visuallyLossless))
        #expect(data.count < (try Self.encode(card, as: .jpeg, quality: 0.98)).count)
    }

    @Test("the encoder writes only the chosen file, or nothing")
    func encoderWritesTheChoice() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lathe-vl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("card.png")
        try Self.encode(try Self.testCard(), as: .png, quality: 1).write(to: source)

        let destination = directory.appendingPathComponent("card.jpg")
        let encoded = try await ImageEncoder().encodeVisuallyLossless(
            source: source, to: destination, format: .jpeg)
        let result = try #require(encoded)
        #expect(result.encode.output == destination)
        #expect(result.quality < 0.98)
        #expect(result.similarity.meets(.visuallyLossless))
        #expect(try VisualComparison.similarity(ofImageAt: destination, to: source).meets(.visuallyLossless))

        let impossible = directory.appendingPathComponent("never.jpg")
        let none = try await ImageEncoder().encodeVisuallyLossless(
            source: source, to: impossible, format: .jpeg,
            search: QualitySearch(threshold: VisualThreshold(minimumSimilarity: 1.01, minimumRegionSimilarity: 1)))
        #expect(none == nil)
        #expect(!FileManager.default.fileExists(atPath: impossible.path))

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".lathe-") }
        #expect(leftovers.isEmpty, "scratch files left behind: \(leftovers)")
    }
}
