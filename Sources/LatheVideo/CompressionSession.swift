import CoreMedia
import CoreVideo
import Foundation
import LatheCore
import VideoToolbox

// MARK: - Property names

/// VideoToolbox compression property keys, by name.
///
/// **Spelled as raw strings on purpose, and it is not a shortcut.** A
/// `kVTCompressionPropertyKey_…` constant carries an `API_AVAILABLE` annotation,
/// so merely *naming* one that is newer than the deployment floor forces an
/// `#available` branch — and an `#available` branch is a version check, which is
/// the one thing this package has a standing rule against for codec capability
/// (see `EncodeSupport` in `LatheImage`, and the README). The values are stable
/// and self-describing: every one of these constants' string value is the name
/// after the underscore, which the video suite's key-name test pins
/// against the SDK constants wherever the running SDK declares them.
///
/// What replaces the version check is ``CompressionProperties/supported``, which
/// asks the *session* what it accepts. An encoder that does not know a key is
/// then a fact about this machine rather than a guess from a calendar.
enum VTKey {
    static let quality = "Quality"
    static let constantQualityFactor = "ConstantQualityFactor"
    static let averageBitRate = "AverageBitRate"
    static let allowFrameReordering = "AllowFrameReordering"
    static let usingHardwareAcceleratedVideoEncoder = "UsingHardwareAcceleratedVideoEncoder"
    static let realTime = "RealTime"
    static let maximizePowerEfficiency = "MaximizePowerEfficiency"
    static let expectedFrameRate = "ExpectedFrameRate"
    static let colorPrimaries = "ColorPrimaries"
    static let transferFunction = "TransferFunction"
    static let yCbCrMatrix = "YCbCrMatrix"
    static let preserveDynamicHDRMetadata = "PreserveDynamicHDRMetadata"
    static let profileLevel = "ProfileLevel"
    static let alphaChannelMode = "AlphaChannelMode"
}

// MARK: - The encoded-sample queue

/// The hand-off between the encoder's callback thread and the writer's pump.
///
/// It exists because **encoded output lags encoded input, by design**. With
/// frame reordering on — which is the default, and the point — VideoToolbox
/// must hold several frames before it can emit the first B-frame-bearing one, so
/// there is no such thing as "encode this frame and take its output". Anything
/// built on that assumption deadlocks the moment B-frames are enabled, which is
/// a plausible reason to find them switched off in somebody else's transcoder.
final class SampleQueue: @unchecked Sendable {

    private let lock = NSLock()
    private var buffers: [CMSampleBuffer] = []
    private var failure: (any Error)?

    func push(_ buffer: CMSampleBuffer) {
        lock.lock()
        buffers.append(buffer)
        lock.unlock()
    }

    func pop() -> CMSampleBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return buffers.isEmpty ? nil : buffers.removeFirst()
    }

    /// Records the first failure. Later ones are dropped: the first is the cause
    /// and the rest are consequences.
    func fail(_ error: any Error) {
        lock.lock()
        if failure == nil { failure = error }
        lock.unlock()
    }

    var recordedFailure: (any Error)? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }
}

// MARK: - The compression session

/// One `VTCompressionSession`, configured from a ``QualityTarget`` and
/// interrogated afterwards about what it actually did.
///
/// Creating the session **is** the capability probe. There is no table of which
/// codec works on which chip: `VTCompressionSessionCreate` either returns a
/// session or it does not, and the failure becomes
/// ``LatheError/encodeUnavailable(format:)``. That is the same rule the
/// still-image path follows.
final class VideoCompressor: @unchecked Sendable {

    let queue = SampleQueue()

    /// Read back off the session after creation, never assumed. Asking for
    /// hardware via the encoder specification is a *hint*; this is the answer.
    let usedHardwareAcceleration: Bool

    /// Read back after being set, for the same reason.
    let frameReordering: Bool

    /// What rate control was actually negotiated, after any fallback.
    let rateControl: RateControl

    private let session: VTCompressionSession
    private let lock = NSLock()
    private var invalidated = false

    init(
        codec: VideoCodec,
        size: PixelSize,
        quality: QualityTarget,
        bFrames: BFramePolicy,
        sourceFormat: CMFormatDescription?,
        expectedFrameRate: Double?
    ) throws {
        var created: VTCompressionSession?
        // A hint, not a demand: this asks for hardware but does not require it,
        // so a machine without one still gets a session instead of a refusal.
        // What actually happened is read back below.
        //
        // The key is spelled as a literal rather than via
        // `kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder`,
        // which is `API_AVAILABLE(ios(17.4))` while this package's floor is
        // iOS 17.0 — referencing the symbol fails the iOS build outright.
        //
        // A literal is the right answer rather than a workaround, and for the
        // same reason the property keys elsewhere in this file are probed
        // rather than version-gated: VideoToolbox specification keys ARE their
        // names (verified — the constant's value is exactly this string), and
        // an encoder ignores a specification key it does not recognise. So an
        // older OS quietly does what it would have done anyway; the header
        // documents hardware as the default there in any case.
        let specification: [CFString: Any] = [
            "EnableHardwareAcceleratedVideoEncoder" as CFString: true,
        ]
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(size.width),
            height: Int32(size.height),
            codecType: codec.codecType,
            encoderSpecification: specification as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let created else {
            throw LatheError.encodeUnavailable(
                format: "\(codec.rawValue) at \(size) (VTCompressionSessionCreate returned \(status))"
            )
        }
        session = created

        let supported = Self.supportedPropertyNames(of: created)

        // Apple's own guidance for "offline transcode initiated by a user, who is
        // waiting for the results", quoted from VTCompressionProperties.h: real
        // time off, power efficiency off. Both are hints the encoder may ignore.
        Self.set(VTKey.realTime, false as CFBoolean, on: created)
        Self.set(VTKey.maximizePowerEfficiency, false as CFBoolean, on: created)

        if let expectedFrameRate, expectedFrameRate > 0 {
            Self.set(VTKey.expectedFrameRate, expectedFrameRate as CFNumber, on: created)
        }

        // Frame reordering, set in both directions and then read back. See
        // ``BFramePolicy``.
        Self.set(
            VTKey.allowFrameReordering,
            (bFrames.allowsFrameReordering ? kCFBooleanTrue : kCFBooleanFalse) as CFBoolean,
            on: created
        )
        frameReordering = Self.copyBool(VTKey.allowFrameReordering, from: created)
            ?? bFrames.allowsFrameReordering

        if codec == .hevcWithAlpha, supported.contains(VTKey.alphaChannelMode) {
            // The encoder has to be told how alpha relates to the colour
            // channels. Premultiplied is what a decoded BGRA buffer from
            // AVFoundation carries.
            Self.set(
                VTKey.alphaChannelMode,
                kVTAlphaChannelMode_PremultipliedAlpha,
                on: created
            )
        }

        // Colour tags travel from the source's format description, not from the
        // pixel buffers: an encoder told nothing writes no tags at all, and a
        // file with no tags is interpreted as Rec. 709 by every player — which is
        // wrong, and visibly so, for anything shot in a wide gamut.
        Self.propagateColourTags(from: sourceFormat, to: created, supported: supported)

        if supported.contains(VTKey.preserveDynamicHDRMetadata) {
            // Best effort, and deliberately not advertised as HDR support: this
            // only carries dynamic metadata that the *decoder* attached to the
            // pixel buffers. See the note on HDR in ``VideoTranscoder``.
            Self.set(VTKey.preserveDynamicHDRMetadata, true as CFBoolean, on: created)
        }

        rateControl = try Self.configureRateControl(
            quality, on: created, supported: supported,
            codec: codec, size: size, frameRate: expectedFrameRate
        )

        usedHardwareAcceleration =
            Self.copyBool(VTKey.usingHardwareAcceleratedVideoEncoder, from: created) ?? false

        LatheLog.video.debug(
            """
            compression session: \(codec.rawValue, privacy: .public) \(size.description, privacy: .public) \
            hardware=\(self.usedHardwareAcceleration, privacy: .public) \
            reordering=\(self.frameReordering, privacy: .public)
            """
        )
    }

    // MARK: Encoding

    /// Hands one decoded frame to the encoder. Output arrives later, on
    /// VideoToolbox's own thread, in ``queue``.
    func encode(_ image: CVImageBuffer, at presentationTime: CMTime, duration: CMTime) throws {
        let queue = self.queue
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: image,
            presentationTimeStamp: presentationTime,
            duration: duration,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { status, flags, sample in
            guard status == noErr else {
                queue.fail(LatheError.encodingFailed(
                    stage: "encode", code: status, reason: "VideoToolbox could not encode a frame"
                ))
                return
            }
            // A dropped frame is not an error — the encoder is allowed to decide
            // a frame carries nothing — but it must not be pushed as output.
            guard !flags.contains(.frameDropped), let sample else { return }
            queue.push(sample)
        }
        guard status == noErr else {
            throw LatheError.encodingFailed(
                stage: "encode", code: status,
                reason: "VTCompressionSessionEncodeFrame refused a frame"
            )
        }
    }

    /// Flushes every frame the encoder is still holding.
    ///
    /// This is what makes frame reordering safe to enable: the frames held back
    /// for reordering are emitted here, synchronously, before the writer's input
    /// is marked finished. Skipping it truncates the video by however many
    /// frames the encoder had in flight — a corruption that looks like a
    /// slightly short file rather than like an error.
    func finish() throws {
        let status = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard status == noErr else {
            throw LatheError.encodingFailed(
                stage: "flush", code: status, reason: "VideoToolbox could not flush the encoder"
            )
        }
        if let failure = queue.recordedFailure { throw failure }
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        guard !invalidated else { return }
        invalidated = true
        VTCompressionSessionInvalidate(session)
    }

    // MARK: Rate control

    /// Maps a ``QualityTarget`` onto the session, degrading through documented
    /// fallbacks rather than failing or silently changing the request.
    private static func configureRateControl(
        _ quality: QualityTarget,
        on session: VTCompressionSession,
        supported: Set<String>,
        codec: VideoCodec,
        size: PixelSize,
        frameRate: Double?
    ) throws -> RateControl {
        switch quality {
        case .lossless:
            // Defence in depth: `VideoTranscoder` refuses this before creating
            // anything, so reaching here is a programming error rather than a
            // user one.
            throw LatheError.invalidConfiguration(
                reason: "QualityTarget.lossless cannot be honoured by a video encoder"
            )

        case let .quality(value):
            let clamped = min(max(value, 0), 1)
            if supported.contains(VTKey.quality),
               set(VTKey.quality, clamped as CFNumber, on: session) {
                return .constantQuality(clamped)
            }
            // The documented fallback. `Quality` has existed since macOS 10.8 and
            // is accepted by both Apple hardware encoders, so this path is for
            // an encoder that is neither — and a caller that asked for constant
            // quality should be told it got a bitrate, which is what the result
            // reports.
            let bitrate = derivedBitrate(for: clamped, codec: codec, size: size, frameRate: frameRate)
            guard set(VTKey.averageBitRate, bitrate as CFNumber, on: session) else {
                throw LatheError.encodingFailed(
                    stage: "configure", code: nil,
                    reason: "this encoder accepted neither a quality nor an average bitrate"
                )
            }
            LatheLog.video.info(
                """
                this encoder does not take a constant quality; fell back to \
                \(bitrate, privacy: .public) bit/s for quality \(clamped, privacy: .public)
                """
            )
            return .averageBitrate(bitrate)

        case let .constantQualityFactor(value):
            let clamped = min(max(value, 0), 1)
            if supported.contains(VTKey.constantQualityFactor),
               set(VTKey.constantQualityFactor, clamped as CFNumber, on: session) {
                return .constantQualityFactor(clamped)
            }
            // The documented fallback for an OS older than the key: the same
            // number against `Quality`. The two are not the same control —
            // `Quality` pins the quantiser, `ConstantQualityFactor` targets
            // consistent *visual* quality and lets the bitrate vary more — but
            // they share a direction and a range (0 worst, 1 best), so the
            // request degrades instead of inverting. The result says which one
            // ran.
            if supported.contains(VTKey.quality),
               set(VTKey.quality, clamped as CFNumber, on: session) {
                return .constantQuality(clamped)
            }
            let bitrate = derivedBitrate(for: clamped, codec: codec, size: size, frameRate: frameRate)
            guard set(VTKey.averageBitRate, bitrate as CFNumber, on: session) else {
                throw LatheError.encodingFailed(
                    stage: "configure", code: nil,
                    reason: "this encoder accepted neither a quality factor nor an average bitrate"
                )
            }
            return .averageBitrate(bitrate)

        case let .averageBitrate(bitsPerSecond):
            guard bitsPerSecond > 0 else {
                throw LatheError.invalidConfiguration(
                    reason: "an average bitrate must be positive, got \(bitsPerSecond)"
                )
            }
            guard set(VTKey.averageBitRate, bitsPerSecond as CFNumber, on: session) else {
                throw LatheError.encodingFailed(
                    stage: "configure", code: nil,
                    reason: "this encoder would not take an average bitrate"
                )
            }
            return .averageBitrate(bitsPerSecond)
        }
    }

    /// A bitrate for a quality, for the encoder that takes no quality.
    ///
    /// A rule of thumb and labelled as one: bits per pixel per frame, scaled by
    /// the requested quality, with HEVC given roughly half of H.264's budget for
    /// the same picture. It exists so the fallback path produces a *plausible*
    /// file rather than an arbitrary one; nothing else depends on the numbers.
    static func derivedBitrate(
        for quality: Double,
        codec: VideoCodec,
        size: PixelSize,
        frameRate: Double?
    ) -> Int {
        let bitsPerPixel = codec == .h264 ? 0.12 : 0.07
        let rate = (frameRate.map { $0 > 0 ? $0 : 30 }) ?? 30
        let scale = 0.25 + 0.75 * min(max(quality, 0), 1)
        let bits = Double(size.pixelCount) * rate * bitsPerPixel * scale
        return max(64_000, Int(bits))
    }

    // MARK: Properties

    private static func supportedPropertyNames(of session: VTCompressionSession) -> Set<String> {
        var dictionary: CFDictionary?
        let status = withUnsafeMutablePointer(to: &dictionary) { pointer in
            VTSessionCopySupportedPropertyDictionary(session, supportedPropertyDictionaryOut: pointer)
        }
        guard status == noErr, let names = dictionary as? [String: Any] else { return [] }
        return Set(names.keys)
    }

    @discardableResult
    private static func set(_ key: String, _ value: CFTypeRef, on session: VTCompressionSession) -> Bool {
        VTSessionSetProperty(session, key: key as CFString, value: value) == noErr
    }

    private static func copyBool(_ key: String, from session: VTCompressionSession) -> Bool? {
        var value: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            VTSessionCopyProperty(
                session, key: key as CFString, allocator: kCFAllocatorDefault, valueOut: pointer
            )
        }
        guard status == noErr, let number = value as? NSNumber else { return nil }
        return number.boolValue
    }

    /// Copies colour primaries, transfer function and matrix across from the
    /// source's format description.
    private static func propagateColourTags(
        from format: CMFormatDescription?,
        to session: VTCompressionSession,
        supported: Set<String>
    ) {
        guard let format else { return }
        let pairs: [(CFString, String)] = [
            (kCMFormatDescriptionExtension_ColorPrimaries, VTKey.colorPrimaries),
            (kCMFormatDescriptionExtension_TransferFunction, VTKey.transferFunction),
            (kCMFormatDescriptionExtension_YCbCrMatrix, VTKey.yCbCrMatrix),
        ]
        for (extensionKey, propertyKey) in pairs {
            guard supported.contains(propertyKey),
                  let value = CMFormatDescriptionGetExtension(format, extensionKey: extensionKey)
            else { continue }
            set(propertyKey, value, on: session)
        }
    }
}

// MARK: - Codec mapping

extension VideoCodec {
    var codecType: CMVideoCodecType {
        switch self {
        case .h264: kCMVideoCodecType_H264
        case .hevc: kCMVideoCodecType_HEVC
        case .hevcWithAlpha: kCMVideoCodecType_HEVCWithAlpha
        }
    }

    /// Whether the encoder needs a pixel format that has an alpha channel.
    var needsAlpha: Bool { self == .hevcWithAlpha }
}

// MARK: - Scaling

/// Scales decoded frames, when — and only when — a resize was asked for.
///
/// **This is the reason no `AVVideoComposition` appears anywhere in this
/// module.** The obvious way to resize through `AVAssetReader`/`AVAssetWriter` is
/// an `AVVideoComposition` with a `renderSize`, and it works; what it also does
/// is route every frame through the compositor, which flattens the source to
/// ordinary SDR/HDR10 pixel buffers and drops Dolby Vision's per-frame RPU
/// entirely. A `VTPixelTransferSession` sits between the decoder and the encoder
/// instead: it scales the buffer and nothing else, and buffer attachments are
/// propagated across explicitly.
///
/// Honesty about what a resize still costs, since the point of the note is to be
/// checkable: this is a plain scale, so per-frame dynamic HDR metadata that
/// describes the *original* resolution is not recomputed, and a transcode is a
/// re-encode either way — nothing here promises a Dolby Vision file in equals a
/// Dolby Vision file out. It promises not to be the thing that threw the
/// information away before the encoder ever saw it.
final class PixelScaler {

    private let target: PixelSize
    private let session: VTPixelTransferSession
    private var pool: CVPixelBufferPool?
    private var poolFormat: OSType = 0

    init(target: PixelSize) throws {
        self.target = target
        var created: VTPixelTransferSession?
        let status = VTPixelTransferSessionCreate(
            allocator: kCFAllocatorDefault, pixelTransferSessionOut: &created
        )
        guard status == noErr, let created else {
            throw LatheError.encodingFailed(
                stage: "scale", code: status, reason: "could not create a pixel transfer session"
            )
        }
        session = created
        // The aspect-fit arithmetic has already happened in `ResizeTarget`, so
        // the target rectangle has the source's shape and a plain scale is
        // exact. Letterboxing here would add bars to a picture that does not
        // need them.
        VTSessionSetProperty(
            session, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal
        )
    }

    deinit { VTPixelTransferSessionInvalidate(session) }

    /// Returns `buffer` at exactly the target size, scaling only when it is not
    /// already that size.
    func scaled(_ buffer: CVPixelBuffer) throws -> CVPixelBuffer {
        guard CVPixelBufferGetWidth(buffer) != target.width
            || CVPixelBufferGetHeight(buffer) != target.height
        else { return buffer }

        let format = CVPixelBufferGetPixelFormatType(buffer)
        let pool = try pool(for: format)

        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination) == kCVReturnSuccess,
              let destination
        else {
            throw LatheError.encodingFailed(
                stage: "scale", code: nil, reason: "could not take a \(target) pixel buffer from the pool"
            )
        }

        // Colour attachments live on the buffer, not in the transfer session, so
        // they are carried across explicitly. Without this a wide-gamut frame
        // arrives at the encoder untagged.
        CVBufferPropagateAttachments(buffer, destination)

        let status = VTPixelTransferSessionTransferImage(session, from: buffer, to: destination)
        guard status == noErr else {
            throw LatheError.encodingFailed(
                stage: "scale", code: status, reason: "could not scale a frame to \(target)"
            )
        }
        return destination
    }

    private func pool(for format: OSType) throws -> CVPixelBufferPool {
        if let pool, poolFormat == format { return pool }
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: format,
            kCVPixelBufferWidthKey: target.width,
            kCVPixelBufferHeightKey: target.height,
            // IOSurface-backed, so the hardware encoder can take the buffer
            // without a copy through main memory.
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var created: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault, nil, attributes as CFDictionary, &created
        ) == kCVReturnSuccess, let created else {
            throw LatheError.encodingFailed(
                stage: "scale", code: nil, reason: "could not create a \(target) pixel buffer pool"
            )
        }
        pool = created
        poolFormat = format
        return created
    }
}
