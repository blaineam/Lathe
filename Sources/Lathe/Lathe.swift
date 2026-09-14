/// Lathe — an on-device media processing engine for Apple platforms.
///
/// This umbrella module re-exports every domain module, so a consumer that wants
/// all of them can write a single import:
///
/// ```swift
/// import Lathe   // LatheCore · LatheImage · LatheVideo · LatheDoc · LatheAudio
/// ```
///
/// A consumer that only needs one domain should import that module directly
/// instead — `import LatheImage` links no PDF or video code.
@_exported import LatheAudio
@_exported import LatheCore
@_exported import LatheDoc
@_exported import LatheImage
@_exported import LatheVideo

public enum Lathe {
    /// The engine version. Also used as a cache-invalidation input, so it must
    /// change whenever codec settings or decision logic change.
    public static var version: String { LatheVersion.engine }

    /// A one-shot description of what this system can actually do, suitable for
    /// a bug report or a log line at startup.
    public static var capabilityReport: String {
        EncodeSupport.shared.diagnosticReport
    }

    /// What this system's Vision will recognise, and at which revision.
    ///
    /// Separate from ``capabilityReport`` because it costs a request to build
    /// and most consumers never OCR anything — but it belongs in the same bug
    /// report when one of them does, since "the text layer came out empty" and
    /// "this device has no recognition assets for that language" look identical
    /// from the outside.
    public static var textRecognitionReport: String {
        VisionTextSupport.shared.diagnosticReport
    }
}
