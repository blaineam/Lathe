import Foundation
import LatheCore
import Testing

@testable import LatheVideo

/// Transcoding is the one part of the video engine that is still a surface
/// rather than an implementation — probing is `MediaProbe` and frame extraction
/// is `FrameExtractor`, both tested against real fixtures elsewhere. So these
/// tests check what a surface can be checked for: that the request type behaves,
/// and that the stub refuses in the one documented way rather than crashing,
/// hanging or silently succeeding.
@Suite("Video API surface")
struct VideoSurfaceTests {

    private let source = URL(fileURLWithPath: "/tmp/lathe-test-in.mov")
    private let destination = URL(fileURLWithPath: "/tmp/lathe-test-out.mov")

    @Test("transcode reports as not implemented")
    func transcodeIsNotImplemented() async throws {
        let request = VideoTranscodeRequest(
            source: source,
            destination: destination,
            codec: .hevc,
            quality: .quality(0.6),
            resize: .longestSide(1920)
        )
        await #expect(throws: LatheError.self) {
            _ = try await UnimplementedVideoPipeline().transcode(request, progress: .ignoring())
        }
    }

    @Test("the refusal names the feature it is refusing")
    func errorNamesTheFeature() async throws {
        let request = VideoTranscodeRequest(source: source, destination: destination)
        do {
            _ = try await UnimplementedVideoPipeline().transcode(request, progress: .ignoring())
            Issue.record("expected a refusal")
        } catch let error as LatheError {
            guard case let .notImplemented(feature) = error else {
                Issue.record("expected .notImplemented, got \(error)")
                return
            }
            #expect(feature.contains("transcode"))
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    /// Requests carry a quality target and an aspect-fit downscale; neither
    /// needs an implementation to be verified.
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
}
