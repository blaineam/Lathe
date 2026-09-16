import Accelerate
import CoreGraphics
import Foundation
import LatheCore

import CWebP

/// The WebP encoder, on top of the vendored libwebp.
///
/// ## Why this exists at all
///
/// ImageIO **reads** WebP and does not **write** it — see ``EncodeSupport``,
/// which proves that by attempting an encode rather than believing a list. That
/// asymmetry is the one genuine gap in Apple's still-image frameworks, and it is
/// the only reason this package vendors any third-party codec. See
/// `Sources/CWebP/VENDORING.md` for what was taken and how to refresh it.
///
/// ## What it does and does not carry
///
/// **Pixels, plus EXIF and XMP when asked.** WebP stores metadata in
/// `EXIF`/`XMP `/`ICCP` chunks of the *extended* (`VP8X`) file format, which
/// only libwebp's muxer writes. The muxer is now vendored — it came with
/// animation, see ``WebPAnimationEncoder`` — so ``ImageEncoder`` hands this
/// encoder the same policy-filtered properties it hands ImageIO, and
/// ``WebPMetadataChunks`` turns them into chunks. The orientation tag is among
/// them, and ImageIO reads it back, so ``OrientationTagSupport`` now finds WebP
/// able to hold one and ``OrientationStrategy/preserveTag`` is honoured rather
/// than overridden.
///
/// Still not carried: an **ICC profile**. Pixels are converted to sRGB on the
/// way in, which is what an untagged WebP is read as anyway, so there is no
/// profile to store. And the XMP packet is whatever ImageIO derives from the
/// properties dictionary — the source's own raw packet is not copied, the same
/// gap every ImageIO format has (see ``ImageMetadata``).
///
/// ## Lossless
///
/// libwebp has a real lossless mode, so ``QualityTarget/lossless`` means
/// something here that it means for no other format in this package. See
/// ``ImageEncoder`` for the seam.
enum WebPEncoder {

    /// The largest side libwebp will encode. Not a Lathe limit — it is the bit
    /// budget of the VP8 frame header, so it is the same everywhere WebP exists.
    static let maximumDimension = Int(WEBP_MAX_DIMENSION)

    /// Encodes `image` and returns the WebP bytes.
    ///
    /// - Parameters:
    ///   - quality: ``QualityTarget/quality(_:)`` maps `0...1` onto libwebp's
    ///     `0...100`; ``QualityTarget/lossless`` selects the lossless coder. The
    ///     bitrate-shaped cases have no meaning for a still and fall back to
    ///     libwebp's own default quality, matching how the ImageIO path treats
    ///     them (it sets no quality key at all).
    ///   - metadata: chunks to store beside the pixels. Empty — the default —
    ///     writes a *simple* file (`VP8 ` / `VP8L`), exactly as before the muxer
    ///     was vendored; anything else writes an *extended* (`VP8X`) one.
    static func encode(
        _ image: CGImage,
        quality: QualityTarget,
        metadata: WebPMetadataChunks = WebPMetadataChunks()
    ) throws -> Data {
        try requireEncodableSize(width: image.width, height: image.height)
        var config = try configuration(for: quality)

        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else {
            throw LatheError.encodingFailed(
                stage: "encode", code: nil, reason: "WebPPictureInit failed (ABI mismatch)"
            )
        }
        defer { WebPPictureFree(&picture) }
        try importPixels(of: image, into: &picture)

        let writer = UnsafeMutablePointer<WebPMemoryWriter>.allocate(capacity: 1)
        defer {
            WebPMemoryWriterClear(writer)
            writer.deallocate()
        }
        WebPMemoryWriterInit(writer)
        picture.writer = WebPMemoryWrite
        picture.custom_ptr = UnsafeMutableRawPointer(writer)

        guard WebPEncode(&config, &picture) != 0 else {
            throw LatheError.encodingFailed(
                stage: "encode", code: picture.error_code.rawValue.int32,
                reason: "libwebp: " + Self.describe(picture.error_code)
            )
        }
        guard let bytes = writer.pointee.mem, writer.pointee.size > 0 else {
            throw LatheError.encodingFailed(
                stage: "encode", code: nil, reason: "libwebp reported success and produced no bytes"
            )
        }
        let still = Data(bytes: bytes, count: writer.pointee.size)
        return metadata.isEmpty ? still : try attach(metadata, to: still)
    }

    // MARK: - Shared with the animation encoder

    /// Refuses a size WebP cannot store, with the remedy in the message.
    static func requireEncodableSize(width: Int, height: Int) throws {
        guard width > 0, height > 0 else {
            throw LatheError.invalidConfiguration(reason: "cannot encode a \(width)x\(height) image")
        }
        guard width <= maximumDimension, height <= maximumDimension else {
            // Worth a named refusal rather than a codec error: the remedy is a
            // `ResizeTarget`, and the caller can only work that out if the limit
            // is in the message.
            throw LatheError.invalidConfiguration(
                reason: "WebP cannot store \(width)x\(height): neither side may exceed "
                    + "\(maximumDimension) pixels. Downscale first — e.g. "
                    + "resize: .longestSide(\(maximumDimension))."
            )
        }
    }

    /// A validated libwebp configuration for `quality`. One mapping for stills
    /// and animation frames, so `.quality(0.8)` means the same file either way.
    static func configuration(for quality: QualityTarget) throws -> WebPConfig {
        var config = WebPConfig()
        guard WebPConfigInit(&config) != 0 else {
            throw LatheError.encodingFailed(
                stage: "encode", code: nil,
                reason: "libwebp rejected its own default configuration — ABI mismatch between "
                    + "the vendored headers and sources"
            )
        }
        switch quality {
        case .lossless:
            // Preset 6 of 0...9: upstream's own middle-of-the-road effort. The
            // quality field means *effort* in lossless mode, not fidelity.
            guard WebPConfigLosslessPreset(&config, 6) != 0 else {
                throw LatheError.encodingFailed(
                    stage: "encode", code: nil, reason: "libwebp rejected the lossless preset"
                )
            }
            // Without this libwebp is free to rewrite the RGB of fully
            // transparent pixels to whatever compresses best. Invisible, and
            // still not what "lossless" should mean.
            config.exact = 1
        case let .quality(value):
            config.quality = Float(min(max(value, 0), 1) * 100)
        case .constantQualityFactor, .averageBitrate:
            break  // libwebp's default quality (75). See the doc comment.
        }
        guard WebPValidateConfig(&config) != 0 else {
            throw LatheError.invalidConfiguration(
                reason: "libwebp rejected quality \(config.quality) for WebP"
            )
        }
        return config
    }

    /// Sizes `picture` to `image` and copies the pixels in, as straight sRGB.
    ///
    /// `picture` must already have been through `WebPPictureInit`; freeing it
    /// stays the caller's job.
    ///
    /// - Returns: whether any pixel is less than fully opaque. The animation
    ///   encoder needs to know; see ``WebPAnimationEncoder``.
    @discardableResult
    static func importPixels(of image: CGImage, into picture: inout WebPPicture) throws -> Bool {
        let width = image.width
        let height = image.height
        picture.width = Int32(width)
        picture.height = Int32(height)
        // ARGB rather than YUV as the import target even for the lossy path:
        // libwebp then does its own conversion at encode time, which is the same
        // thing `cwebp` does and keeps one import path for both coders.
        picture.use_argb = 1

        let hasAlpha = image.hasMeaningfulAlpha
        var pixels = try rgbaBytes(of: image, hasAlpha: hasAlpha)
        let bytesPerRow = Int32(width * 4)
        let imported = pixels.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return 0 }
            // `…RGBX` tells libwebp the fourth byte is padding, so an opaque
            // image does not get an alpha plane it does not need — which is a
            // real size difference, not a tidiness point.
            return hasAlpha
                ? WebPPictureImportRGBA(&picture, base, bytesPerRow)
                : WebPPictureImportRGBX(&picture, base, bytesPerRow)
        }
        guard imported != 0 else {
            throw LatheError.encodingFailed(
                stage: "encode", code: picture.error_code.rawValue.int32,
                reason: "libwebp could not take a \(width)x\(height) picture: "
                    + Self.describe(picture.error_code)
            )
        }
        guard hasAlpha else { return false }
        return stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] != 255 }
    }

    // MARK: - Metadata

    /// Rewrites a simple WebP as an extended one carrying `metadata`.
    ///
    /// The pixels are not touched: `WebPMuxCreate` parses the file,
    /// `WebPMuxSetChunk` adds the chunks, and `WebPMuxAssemble` writes the
    /// `VP8X` header whose flags announce them.
    private static func attach(_ metadata: WebPMetadataChunks, to still: Data) throws -> Data {
        try still.withUnsafeBytes { raw -> Data in
            var input = WebPData(
                bytes: raw.baseAddress?.assumingMemoryBound(to: UInt8.self), size: raw.count
            )
            // `copy_data: 1` so the mux owns its bytes and nothing here has to
            // outlive this closure.
            guard let mux = WebPMuxCreate(&input, 1) else {
                throw LatheError.encodingFailed(
                    stage: "mux", code: nil,
                    reason: "libwebp's muxer could not parse the WebP its own encoder wrote"
                )
            }
            defer { WebPMuxDelete(mux) }

            for (fourCC, payload) in [("EXIF", metadata.exif), ("XMP ", metadata.xmp)] {
                guard let payload, !payload.isEmpty else { continue }
                try WebPMux.check(payload.withUnsafeBytes { bytes -> WebPMuxError in
                    var chunk = WebPData(
                        bytes: bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        size: bytes.count
                    )
                    return WebPMuxSetChunk(mux, fourCC, &chunk, 1)
                }, doing: "adding the \(fourCC.trimmingCharacters(in: .whitespaces)) chunk")
            }
            return try WebPMux.assemble(doing: "assembling an extended WebP") { output in
                WebPMuxAssemble(mux, &output)
            }
        }
    }

    // MARK: - Pixels

    /// The image as tightly-packed, **straight** (not premultiplied) RGBA bytes.
    ///
    /// Two details that are easy to get wrong and invisible when you do:
    ///
    /// **Premultiplication.** Core Graphics bitmap contexts cannot hold straight
    /// alpha — `kCGImageAlphaLast` is not a supported context format — so the
    /// only way to obtain it is to draw premultiplied and divide afterwards.
    /// Handing premultiplied bytes to libwebp instead looks right on every
    /// opaque pixel and darkens every semi-transparent one, which is exactly the
    /// bug that survives review.
    ///
    /// **Colour space.** The destination is sRGB, chosen rather than inherited:
    /// nothing written here carries an ICC profile (see the type documentation),
    /// and an untagged WebP is read as sRGB by every decoder
    /// including ImageIO's. Converting on the way in therefore makes the file
    /// say what it means, where passing a Display P3 buffer through untagged
    /// would silently desaturate it on the way back out.
    static func rgbaBytes(of image: CGImage, hasAlpha: Bool) throws -> [UInt8] {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        // `byteOrder32Big` pins the in-memory order to R, G, B, A regardless of
        // the host's endianness, which is what libwebp's importers expect.
        let alphaInfo: CGImageAlphaInfo = hasAlpha ? .premultipliedLast : .noneSkipLast
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        let drew: Bool = pixels.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: alphaInfo.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else {
            throw LatheError.encodingFailed(
                stage: "encode", code: nil,
                reason: "could not create a \(width)x\(height) RGBA context for the WebP encoder"
            )
        }

        if hasAlpha {
            try unpremultiply(&pixels, width: width, height: height, bytesPerRow: bytesPerRow)
        }
        return pixels
    }

    /// Straight alpha, in place, via vImage — the division is per-channel and
    /// per-pixel, and Accelerate's is both correct at alpha 0 and far faster than
    /// a Swift loop.
    private static func unpremultiply(
        _ pixels: inout [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) throws {
        let status: vImage_Error = pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return vImage_Error(kvImageNullPointerArgument) }
            var buffer = vImage_Buffer(
                data: base,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: bytesPerRow
            )
            return vImageUnpremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
        }
        guard status == kvImageNoError else {
            throw LatheError.encodingFailed(
                stage: "encode", code: Int32(status),
                reason: "could not convert premultiplied alpha to straight alpha for WebP"
            )
        }
    }

    // MARK: - Errors

    static func describe(_ code: WebPEncodingError) -> String {
        switch code {
        case VP8_ENC_OK: "no error"
        case VP8_ENC_ERROR_OUT_OF_MEMORY: "out of memory"
        case VP8_ENC_ERROR_BITSTREAM_OUT_OF_MEMORY: "out of memory for the bitstream"
        case VP8_ENC_ERROR_NULL_PARAMETER: "a null parameter reached the encoder"
        case VP8_ENC_ERROR_INVALID_CONFIGURATION: "invalid configuration"
        case VP8_ENC_ERROR_BAD_DIMENSION:
            "bad dimensions — neither side may exceed \(maximumDimension) pixels"
        case VP8_ENC_ERROR_PARTITION0_OVERFLOW: "partition 0 overflowed its 512 KB limit"
        case VP8_ENC_ERROR_PARTITION_OVERFLOW: "a partition overflowed its 16 MB limit"
        case VP8_ENC_ERROR_BAD_WRITE: "the writer refused the bytes"
        case VP8_ENC_ERROR_FILE_TOO_BIG: "the file exceeded 4 GB"
        case VP8_ENC_ERROR_USER_ABORT: "aborted"
        default: "unknown encoder error \(code.rawValue)"
        }
    }
}

// MARK: - Helpers

extension CGImage {
    /// Whether an alpha channel is actually present, as opposed to a fourth byte
    /// the format ignores.
    ///
    /// `noneSkipFirst` / `noneSkipLast` are 32-bit-per-pixel layouts with no
    /// alpha, and treating them as transparent is how an opaque photo acquires an
    /// alpha plane — bytes spent storing 255 a few million times.
    var hasMeaningfulAlpha: Bool {
        switch alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly: true
        case .none, .noneSkipFirst, .noneSkipLast: false
        @unknown default: true  // assume alpha; losing it is worse than storing it
        }
    }
}

extension UInt32 {
    fileprivate var int32: Int32 { Int32(bitPattern: self) }
}
