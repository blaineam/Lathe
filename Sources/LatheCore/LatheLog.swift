import Foundation
import os

/// Lathe's logging surface.
///
/// One subsystem, one category per module, so a host application can filter
/// Lathe out of its own logs:
/// `log stream --predicate 'subsystem == "dev.lathe"'`.
///
/// Privacy defaults matter here. Lathe handles personal media, so **file paths
/// are treated as private**. Use ``publicPath(_:)`` when a filename genuinely
/// needs to be legible in a log.
public enum LatheLog {
    public static let subsystem = "dev.lathe"

    public static let core = Logger(subsystem: subsystem, category: "core")
    public static let image = Logger(subsystem: subsystem, category: "image")
    public static let video = Logger(subsystem: subsystem, category: "video")
    public static let doc = Logger(subsystem: subsystem, category: "doc")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let capability = Logger(subsystem: subsystem, category: "capability")

    /// The last path component only — still useful for correlating a failure
    /// with a filename the user can see, without logging the whole path.
    public static func publicPath(_ url: URL) -> String { url.lastPathComponent }
}
