import CoreGraphics
import Foundation
import LatheCore
import LatheImage

/// How much of a movie to record.
///
/// There is no "all of it" option, and the absence is the point: **a Flash movie
/// need not end.** A timeline loops by default, and ActionScript content may
/// have no timeline at all — it runs until something stops it. A renderer that
/// waited for the end would, for a great deal of real content, wait forever.
public enum SWFRenderLimit: Sendable, Equatable {

    /// The main timeline's declared length: its frame count divided by its frame
    /// rate, taken from the file's own header.
    ///
    /// The right default, and still only a guess about intent — it is the length
    /// of one pass through the timeline, which for looping content is one loop
    /// and for script-driven content may bear no relation to anything.
    case timeline

    /// A fixed wall-clock duration.
    case seconds(Double)

    /// A fixed number of captured frames.
    case frames(Int)
}

/// What to record, how fast, and how big.
public struct SWFRenderOptions: Sendable {

    /// Frames captured per second. `nil` takes the movie's own frame rate.
    ///
    /// This is a *sampling* rate, and capture is real time — see
    /// ``SWFRenderer`` — so asking for more frames per second does not slow the
    /// movie down, it only samples the same wall-clock playback more finely, and
    /// asking for more than the machine can capture silently samples less finely
    /// than requested. ``SWFRenderResult/achievedFramesPerSecond`` is what
    /// actually happened.
    public var framesPerSecond: Double?

    /// The canvas size. `nil` takes the movie's stage size from its header.
    public var pixelSize: CGSize?

    /// How much to record.
    public var limit: SWFRenderLimit

    /// A hard ceiling on captured frames, applied whatever ``limit`` says.
    ///
    /// Present because every other stopping condition is derived from numbers
    /// **the file chose** — its declared frame rate and frame count — and a file
    /// claiming 65535 frames at 0.1 fps asks for a seven-day capture. Default
    /// 36,000, which is twenty minutes at 30 fps.
    public var maximumFrameCount: Int

    /// How long to wait for the player to load the movie and put something on
    /// the stage.
    public var startupTimeout: Duration

    /// How long a single frame's capture may take before the render gives up.
    public var frameTimeout: Duration

    /// How long the page waits for a frame callback before reading the canvas
    /// anyway.
    ///
    /// A last resort. The page supplies its own frame callbacks when WebKit
    /// stops delivering them (see ``SWFRenderResult/renderingUpdatesObserved``),
    /// so this only matters if the page's timers have stopped as well — and a
    /// large value is then paid on every frame.
    public var frameCallbackTimeout: Duration

    /// Ruffle's rendering backend: `"wgpu-webgl"`, `"webgl"` or `"canvas"`.
    ///
    /// `nil` leaves the choice to Ruffle, and also allows one retry with
    /// `"canvas"` if the chosen GPU renderer panics before the first frame —
    /// see ``SWFRenderResult/renderer``. Naming one here means that renderer or
    /// a failure, with no substitute.
    public var preferredRenderer: String?

    public init(
        framesPerSecond: Double? = nil,
        pixelSize: CGSize? = nil,
        limit: SWFRenderLimit = .timeline,
        maximumFrameCount: Int = 36_000,
        startupTimeout: Duration = .seconds(30),
        frameTimeout: Duration = .seconds(10),
        frameCallbackTimeout: Duration = .milliseconds(250),
        preferredRenderer: String? = nil
    ) {
        self.framesPerSecond = framesPerSecond
        self.pixelSize = pixelSize
        self.limit = limit
        self.maximumFrameCount = maximumFrameCount
        self.startupTimeout = startupTimeout
        self.frameTimeout = frameTimeout
        self.frameCallbackTimeout = frameCallbackTimeout
        self.preferredRenderer = preferredRenderer
    }

    /// Resolves the options against a movie's header into the numbers the render
    /// loop actually uses.
    ///
    /// Every value in a SWF header is a claim by the file about itself, so each
    /// is clamped here rather than trusted: a zero or absurd frame rate, a zero
    /// or enormous stage. The clamps are visible in one place because a movie
    /// that renders at 0.0001 fps is not a crash, it is a job that appears to
    /// hang.
    func resolved(againstStageOf header: SWFRenderStage) throws -> ResolvedPlan {
        let rate = framesPerSecond ?? header.framesPerSecond
        guard rate.isFinite, rate >= 0.1, rate <= 240 else {
            throw LatheError.invalidConfiguration(
                reason: "a capture rate of \(rate) fps is outside the 0.1…240 this will attempt; "
                    + (framesPerSecond == nil
                        ? "the movie's own header declares it, so pass framesPerSecond to override"
                        : "pass a different framesPerSecond")
            )
        }

        let size = pixelSize ?? header.pixelSize
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0, width <= 8192, height <= 8192 else {
            throw LatheError.invalidConfiguration(
                reason: "a \(width)×\(height) stage is outside the 1…8192 this will render; "
                    + "pass pixelSize to override the movie's own"
            )
        }

        let requested: Int
        switch limit {
        case .timeline:
            requested = max(1, Int((header.timelineSeconds * rate).rounded()))
        case let .seconds(seconds):
            guard seconds > 0, seconds.isFinite else {
                throw LatheError.invalidConfiguration(
                    reason: "a duration of \(seconds) seconds cannot be recorded"
                )
            }
            requested = max(1, Int((seconds * rate).rounded()))
        case let .frames(count):
            guard count > 0 else {
                throw LatheError.invalidConfiguration(
                    reason: "a capture of \(count) frames cannot be recorded"
                )
            }
            requested = count
        }

        guard maximumFrameCount > 0 else {
            throw LatheError.invalidConfiguration(
                reason: "maximumFrameCount must be positive, got \(maximumFrameCount)"
            )
        }

        return ResolvedPlan(
            framesPerSecond: rate,
            width: width,
            height: height,
            frameCount: min(requested, maximumFrameCount),
            wasTruncated: requested > maximumFrameCount
        )
    }

    struct ResolvedPlan: Equatable {
        let framesPerSecond: Double
        let width: Int
        let height: Int
        let frameCount: Int
        let wasTruncated: Bool
    }
}

/// The subset of a SWF header the renderer needs, so the option arithmetic can
/// be tested without a file.
struct SWFRenderStage: Equatable {
    let pixelSize: CGSize
    let framesPerSecond: Double
    /// The main timeline's declared length in seconds, clamped away from the
    /// absurd — a header declaring 0 fps would otherwise divide by zero, and one
    /// declaring 0.01 fps would ask for a capture measured in days.
    var timelineSeconds: Double {
        let rate = max(0.1, min(framesPerSecond, 240))
        return Double(declaredFrameCount) / rate
    }
    let declaredFrameCount: Int
}

/// What a render produced, and how well it went.
public struct SWFRenderResult: Sendable {

    /// The captured frames, in order, as PNG files on disk — ready to hand
    /// straight to `AnimatedImageWriter`, `FrameVideoWriter` or
    /// `FrameDocumentWriter`.
    public let frames: FrameSequence

    /// The rate the frames are *meant* to be played back at. Pass this on to a
    /// writer; it is not the same number as ``achievedFramesPerSecond``.
    public let framesPerSecond: Double

    public let pixelSize: CGSize

    /// How long the capture took. For a real-time capture this is approximately
    /// the duration of the movie that was recorded.
    public let wallClockSeconds: Double

    /// Frames captured per second of wall clock — what the machine managed.
    ///
    /// **When this is below ``framesPerSecond``, the recording is decimated, not
    /// slowed.** Ruffle plays at wall-clock speed regardless, so sampling too
    /// slowly skips content, and the result plays back fast. The remedy is a
    /// lower ``SWFRenderOptions/framesPerSecond``, a smaller stage, or accepting
    /// it.
    public let achievedFramesPerSecond: Double

    /// Whether the capture kept up, within ten percent.
    public var keptUp: Bool { achievedFramesPerSecond >= framesPerSecond * 0.9 }

    /// Whether ``SWFRenderOptions/maximumFrameCount`` cut the capture short.
    public let wasTruncatedByFrameCeiling: Bool

    /// Whether the host view was attached to a real window.
    ///
    /// Diagnostic, and the first thing to look at when a capture comes back
    /// blank or frozen: an unattached WebView may never composite, and a player
    /// driven by `requestAnimationFrame` does not advance when nothing
    /// composites. See ``SWFRenderer``.
    public let compositedInAWindow: Bool

    /// How many frames were read inside a frame callback WebKit itself
    /// delivered, as opposed to one from the page's fallback clock.
    public let framesReadInFrameCallback: Int

    /// The rendering backend Ruffle reported using — `"wgpu-webgl"`,
    /// `"webgl"`, `"canvas"` and so on — or `nil` if it did not say.
    ///
    /// Worth logging. When no renderer was requested and Ruffle's GPU renderer
    /// panics before the first frame, the render is retried with `"canvas"`,
    /// which is slower and draws some effects less faithfully; this is how a
    /// caller finds out that happened. The iOS Simulator is one place it does.
    public let renderer: String?

    /// Whether WebKit delivered **any** of its own `requestAnimationFrame`
    /// callbacks during the capture.
    ///
    /// WebKit suspends rendering updates for content it considers not visible —
    /// an offscreen or occluded window, or a process with no running
    /// application, such as a `swift test` bundle — and `requestAnimationFrame`
    /// is the casualty. That matters beyond capture, because **Ruffle's player
    /// loop is driven by the same callback**: left alone, the movie would not
    /// advance and every frame would be the same picture.
    ///
    /// The render host does not leave it alone. Its page races every frame
    /// request against a 60 Hz fallback clock, so a `false` here means the
    /// fallback carried the render, not that it froze — the suite's Ruffle test
    /// runs entirely on it and sees the movie move. It is reported because it
    /// is the first thing to know when a capture looks wrong: the fallback is
    /// ordinary timers, and anything that throttles a page's timers harder than
    /// WebKit does today would show up there first.
    public var renderingUpdatesObserved: Bool { framesReadInFrameCallback > 0 }
}
