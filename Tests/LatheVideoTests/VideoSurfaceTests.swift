import Foundation
import LatheCore
import Testing
import VideoToolbox

@testable import LatheVideo

/// Tests for the transcode *vocabulary* and for the encoder-property names the
/// implementation is written against.
///
/// The behaviour of the transcoder itself is in `VideoTranscoderTests`, against
/// real generated clips. What is left here is the part that needs no media: the
/// request type's defaults and arithmetic, and the string constants that stand
/// in for version-gated SDK symbols.
@Suite("Video API surface")
struct VideoSurfaceTests {

    private let source = URL(fileURLWithPath: "/tmp/lathe-test-in.mov")
    private let destination = URL(fileURLWithPath: "/tmp/lathe-test-out.mov")

    /// Requests carry a quality target and an aspect-fit downscale; neither
    /// needs an encoder to be verified.
    @Test("a transcode request's resize target never upsamples")
    func requestResizeNeverUpsamples() {
        let request = VideoTranscodeRequest(
            source: source, destination: destination, resize: .fit(PixelSize(width: 8000, height: 8000))
        )
        let source1080 = PixelSize(width: 1920, height: 1080)
        #expect(request.resize.resolve(from: source1080) == source1080)
    }

    @Test("defaults are the conservative ones")
    func defaults() {
        let request = VideoTranscodeRequest(source: source, destination: destination)
        #expect(request.codec == .hevc)
        #expect(request.resize == .none)
        #expect(request.metadata == .preserveAll)
        // B-frames on by default: they are a free compression win here.
        #expect(request.bFrames == .allow)
        #expect(request.passthroughAudio)
    }

    /// There is no hardware AV1 encoder on Apple silicon, so the vocabulary must
    /// not offer one. This is a promise about what Lathe claims, not about what
    /// the hardware does.
    @Test("no AV1 encode is offered")
    func noAV1EncodeCase() {
        #expect(!VideoCodec.allCases.contains { $0.rawValue.lowercased().contains("av1") })
    }

    @Test("every codec maps to a real VideoToolbox codec type", arguments: VideoCodec.allCases)
    func codecTypes(_ codec: VideoCodec) {
        #expect(codec.codecType != 0)
        #expect(codec.needsAlpha == (codec == .hevcWithAlpha))
    }

    /// The compression properties are named by raw string rather than by SDK
    /// constant, so that naming a key newer than the deployment floor does not
    /// drag in an `#available` — a version check being precisely what this
    /// package refuses to make codec decisions with.
    ///
    /// That trade is only safe if the strings are right, so they are pinned here
    /// against the SDK's own constants. The newest key is checked only where the
    /// running SDK declares it; everything else is checked unconditionally,
    /// because those constants have existed since macOS 10.8.
    @Test("the property names match VideoToolbox's own constants")
    func propertyKeyNames() {
        #expect(VTKey.quality == kVTCompressionPropertyKey_Quality as String)
        #expect(VTKey.averageBitRate == kVTCompressionPropertyKey_AverageBitRate as String)
        #expect(VTKey.allowFrameReordering == kVTCompressionPropertyKey_AllowFrameReordering as String)
        #expect(VTKey.usingHardwareAcceleratedVideoEncoder
            == kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder as String)
        #expect(VTKey.realTime == kVTCompressionPropertyKey_RealTime as String)
        #expect(VTKey.maximizePowerEfficiency
            == kVTCompressionPropertyKey_MaximizePowerEfficiency as String)
        #expect(VTKey.expectedFrameRate == kVTCompressionPropertyKey_ExpectedFrameRate as String)
        #expect(VTKey.colorPrimaries == kVTCompressionPropertyKey_ColorPrimaries as String)
        #expect(VTKey.transferFunction == kVTCompressionPropertyKey_TransferFunction as String)
        #expect(VTKey.yCbCrMatrix == kVTCompressionPropertyKey_YCbCrMatrix as String)
        #expect(VTKey.preserveDynamicHDRMetadata
            == kVTCompressionPropertyKey_PreserveDynamicHDRMetadata as String)

        if #available(macOS 27.0, iOS 27.0, *) {
            #expect(VTKey.constantQualityFactor
                == kVTCompressionPropertyKey_ConstantQualityFactor as String)
        }
    }

    /// The fallback bitrate is a rule of thumb, but it must at least be
    /// monotonic in quality and in pixel count — an "arbitrary" number that goes
    /// *down* as quality goes up would be a bug hiding in a comment.
    @Test("the fallback bitrate rises with quality and with size")
    func derivedBitrateIsMonotonic() {
        let small = PixelSize(width: 320, height: 240)
        let large = PixelSize(width: 1920, height: 1080)
        let low = VideoCompressor.derivedBitrate(for: 0.2, codec: .hevc, size: small, frameRate: 30)
        let high = VideoCompressor.derivedBitrate(for: 0.9, codec: .hevc, size: small, frameRate: 30)
        let bigger = VideoCompressor.derivedBitrate(for: 0.2, codec: .hevc, size: large, frameRate: 30)
        #expect(low < high)
        #expect(low < bigger)
        #expect(VideoCompressor.derivedBitrate(for: 0.5, codec: .h264, size: small, frameRate: 30)
            > VideoCompressor.derivedBitrate(for: 0.5, codec: .hevc, size: small, frameRate: 30))
    }
}
