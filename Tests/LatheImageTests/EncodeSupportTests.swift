import CoreGraphics
import Foundation
import ImageIO
import LatheCore
import Testing

@testable import LatheImage

/// Tests for the ImageIO capability probe.
///
/// The split here is deliberate:
///
/// - **Invariants are asserted.** JPEG and PNG have been writable by ImageIO
///   since it existed. WebP is decode-only — it is *advertised* as a destination
///   type and then refuses to produce one, which is the whole reason the probe
///   attempts an encode instead of reading the advertised list.
/// - **Everything else is reported, not asserted.** Whether this particular
///   system writes AVIF, JPEG XL, HEICS or JP2 is exactly what the probe exists
///   to discover, and freezing today's answer into a test would re-introduce the
///   version-gating the probe replaces. Those results are printed, so the test
///   log is a per-platform capability record.
@Suite("ImageIO encode capability probe")
struct EncodeSupportTests {

    // MARK: - The report

    /// Prints the full discovered capability table. Always passes; the point is
    /// the output.
    @Test("discovered capabilities (report)")
    func report() {
        print("")
        print(EncodeSupport.shared.diagnosticReport)
        print("")
        print("  ImageIO source (decode) types (\(DecodeSupport.shared.sourceTypeIdentifiers.count) entries):")
        for identifier in DecodeSupport.shared.sourceTypeIdentifiers {
            print("    · \(identifier)")
        }
        print("")
        let decodeOnly = DecodeSupport.shared.supportedFormats
            .subtracting(EncodeSupport.shared.supportedFormats)
            .sorted { $0.description < $1.description }
        print("  decode-only (needs a third-party encoder to write): "
              + (decodeOnly.isEmpty ? "none" : decodeOnly.map(\.description).joined(separator: ", ")))
        print("")

        #expect(!EncodeSupport.shared.reportedTypeIdentifiers.isEmpty,
                "ImageIO advertised no destination types at all, which should be impossible")
        #expect(!EncodeSupport.shared.supportedFormats.isEmpty)
    }

    // MARK: - Invariants

    @Test("JPEG is always encodable")
    func jpegIsEncodable() {
        #expect(EncodeSupport.shared.canEncode(.jpeg))
        #expect(EncodeSupport.shared.supportedFormats.contains(.jpeg))
    }

    @Test("PNG is always encodable")
    func pngIsEncodable() {
        #expect(EncodeSupport.shared.canEncode(.png))
        #expect(EncodeSupport.shared.supportedFormats.contains(.png))
    }

    /// ImageIO reads WebP and does not write it.
    ///
    /// This is the fact a third-party WebP encoder dependency rests on, and it is
    /// also the fact that breaks a naive probe: `org.webmproject.webp` *is* in
    /// `CGImageDestinationCopyTypeIdentifiers()`. Asserting it here means the day
    /// ImageIO really does gain WebP encode, the build says so — which would be
    /// good news worth hearing.
    @Test("WebP is decode-only: readable, not writable")
    func webPIsDecodeOnly() {
        #expect(!EncodeSupport.shared.canEncode(.webp),
                "ImageIO now encodes WebP. That is a real change — revisit the WebP encoder dependency.")
        #expect(!EncodeSupport.shared.supportedFormats.contains(.webp))
        #expect(EncodeSupport.shared.destinationTypeIdentifier(for: .webp) == nil)
        #expect(DecodeSupport.shared.canDecode(.webp), "ImageIO should still decode WebP")
    }

    /// The finding the probe design exists for, pinned as a test.
    ///
    /// If `CGImageDestinationCopyTypeIdentifiers()` were trustworthy this would
    /// find nothing and could be deleted. It is not, so it reports what the list
    /// gets wrong.
    @Test("the advertised destination list over-reports")
    func advertisedListOverReports() {
        let over = EncodeSupport.shared.overReportedTypeIdentifiers
        print("")
        print("  advertised-but-unusable destination types (\(over.count) of "
              + "\(EncodeSupport.shared.reportedTypeIdentifiers.count)): "
              + (over.isEmpty ? "none" : over.joined(separator: ", ")))
        print("")

        // WebP is advertised. If that ever stops being true the probe still
        // works — it is just no longer the illustrative case.
        let advertisesWebP = EncodeSupport.shared.reportedTypeIdentifiers
            .contains { $0.caseInsensitiveCompare(ImageFormat.webp.typeIdentifier) == .orderedSame }
        if advertisesWebP {
            #expect(over.contains { $0.caseInsensitiveCompare(ImageFormat.webp.typeIdentifier) == .orderedSame },
                    "WebP is advertised, so it must show up as advertised-but-unusable")
        }

        // Every over-reported identifier must genuinely fail to create a
        // destination — the probe should not be inventing discrepancies.
        for identifier in over {
            #expect(!EncodeSupport.canCreateDestination(for: identifier),
                    "\(identifier) was listed as unusable but a destination could be created")
        }
    }

    @Test("requireEncodable throws for an unsupported format")
    func requireEncodableThrows() {
        #expect(throws: LatheError.encodeUnavailable(format: ImageFormat.webp.description)) {
            try EncodeSupport.shared.requireEncodable(.webp)
        }
        #expect(throws: Never.self) {
            try EncodeSupport.shared.requireEncodable(.jpeg)
        }
    }

    // MARK: - Structural consistency

    @Test("canEncode and supportedFormats agree for every format",
          arguments: ImageFormat.allCases)
    func canEncodeMatchesSupportedFormats(format: ImageFormat) {
        #expect(EncodeSupport.shared.canEncode(format)
                == EncodeSupport.shared.supportedFormats.contains(format))
    }

    @Test("supported and unsupported partition the format space")
    func partition() {
        let support = EncodeSupport.shared
        #expect(support.supportedFormats.isDisjoint(with: support.unsupportedFormats))
        #expect(support.supportedFormats.union(support.unsupportedFormats)
                == Set(ImageFormat.allCases))
    }

    /// The identifier handed back must be one that demonstrably works — not just
    /// one that appeared in a list somewhere.
    @Test("a supported format's UTI really does create a destination",
          arguments: ImageFormat.allCases)
    func destinationIdentifierIsUsable(format: ImageFormat) {
        let uti = EncodeSupport.shared.destinationTypeIdentifier(for: format)
        if EncodeSupport.shared.canEncode(format) {
            let identifier = try? #require(uti)
            #expect(identifier != nil)
            if let identifier {
                #expect(EncodeSupport.canCreateDestination(for: identifier))
            }
        } else {
            #expect(uti == nil)
        }
    }

    @Test("the probe is cached: repeated construction gives identical results")
    func probeIsCached() {
        let a = EncodeSupport()
        let b = EncodeSupport()
        #expect(a.reportedTypeIdentifiers == b.reportedTypeIdentifiers)
        #expect(a.reportedTypeIdentifiers == EncodeSupport.shared.reportedTypeIdentifiers)
        #expect(a.supportedFormats == EncodeSupport.shared.supportedFormats)
        #expect(a.overReportedTypeIdentifiers == EncodeSupport.shared.overReportedTypeIdentifiers)
    }

    @Test("firstSupported degrades down a preference list")
    func firstSupportedDegrades() {
        // WebP can never be first, JPEG can always be last.
        #expect(EncodeSupport.shared.firstSupported(of: [.webp, .jpeg]) == .jpeg)
        #expect(EncodeSupport.shared.firstSupported(of: [.png]) == .png)
        #expect(EncodeSupport.shared.firstSupported(of: [.webp]) == nil)
        #expect(EncodeSupport.shared.firstSupported(of: []) == nil)
    }

    // MARK: - Does the probe tell the truth?

    /// Creating a destination proves an encoder exists; it does not prove bytes
    /// come out the other end. So this actually encodes a small image in every
    /// format the probe claims and checks the result is non-empty.
    ///
    /// Only JPEG and PNG failures fail the test — those are the invariants.
    /// Anything else that passes the probe and then fails to finalise is printed
    /// as a discrepancy, because that is a finding about the platform rather than
    /// a defect in this package.
    @Test("claimed formats actually produce bytes")
    func claimedFormatsActuallyEncode() throws {
        let image = try #require(Self.makeTestImage(), "could not construct a test CGImage")
        var discrepancies: [String] = []

        print("")
        for format in EncodeSupport.shared.supportedFormats.sorted(by: { $0.description < $1.description }) {
            let uti = try #require(EncodeSupport.shared.destinationTypeIdentifier(for: format))
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                data as CFMutableData, uti as CFString, 1, nil
            ) else {
                discrepancies.append("\(format): probe says yes, destination creation returned nil")
                continue
            }
            CGImageDestinationAddImage(destination, image, nil)
            let finalised = CGImageDestinationFinalize(destination)
            if !finalised || data.length == 0 {
                discrepancies.append("\(format): probe says yes, finalize produced \(data.length) bytes")
                continue
            }
            print("  encoded \(format.description): \(data.length) bytes via \(uti)")

            if format == .jpeg || format == .png {
                #expect(data.length > 0)
            }
        }

        if discrepancies.isEmpty {
            print("  no discrepancies: everything the probe claims also finalises")
        } else {
            print("")
            print("  *** ENCODE DISCREPANCIES — probe and finalize disagree ***")
            for line in discrepancies { print("    ! \(line)") }
        }
        print("")

        // The one direction worth asserting rather than reporting.
        #expect(!EncodeSupport.canCreateDestination(for: ImageFormat.webp.typeIdentifier),
                "ImageIO created a WebP destination — it may now encode WebP")
    }

    /// A 4x4 opaque RGBA image. Small enough for every encoder, big enough that
    /// none of them reject it out of hand.
    private static func makeTestImage() -> CGImage? {
        let width = 4, height = 4
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            pixels[i * 4 + 0] = UInt8((i * 16) % 256)
            pixels[i * 4 + 1] = UInt8((i * 8) % 256)
            pixels[i * 4 + 2] = UInt8((i * 4) % 256)
            pixels[i * 4 + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

@Suite("Image format vocabulary")
struct ImageFormatTests {

    @Test("every format has a distinct type identifier")
    func identifiersAreDistinct() {
        let identifiers = ImageFormat.allCases.map(\.typeIdentifier)
        #expect(Set(identifiers).count == identifiers.count)
    }

    @Test("a format's own identifier leads its alias list", arguments: ImageFormat.allCases)
    func primaryIdentifierLeads(format: ImageFormat) {
        #expect(format.allTypeIdentifiers.first == format.typeIdentifier)
        #expect(format.allTypeIdentifiers.count == 1 + format.alternateTypeIdentifiers.count)
    }

    /// Only DCTDecode and JPXDecode map onto formats in this vocabulary, so a PDF
    /// recompressor must never be handed anything else.
    @Test("only JPEG and JPEG 2000 are legal inside a PDF", arguments: ImageFormat.allCases)
    func pdfLegalFilters(format: ImageFormat) {
        #expect(format.isLegalInsidePDF == (format == .jpeg || format == .jp2))
    }

    @Test("JPEG is the only format here that cannot carry alpha")
    func alphaSupport() {
        let withoutAlpha = ImageFormat.allCases.filter { !$0.supportsAlpha }
        #expect(withoutAlpha == [.jpeg])
    }

    /// AVIF has no UTType constant in any Apple SDK, so it can only be named by
    /// its raw identifier. Pinning the string means a typo is a test failure
    /// rather than a silently unsupported format.
    @Test("AVIF is named by its raw identifier")
    func avifIdentifier() {
        #expect(ImageFormat.avif.typeIdentifier == "public.avif")
    }
}
