import LatheCore
import os

/// `LatheFetch`'s logging categories.
///
/// Reuses `LatheLog.subsystem` rather than inventing a second subsystem, so one
/// predicate still filters the whole package out of a host application's logs:
/// `log stream --predicate 'subsystem == "dev.lathe"'`.
///
/// The privacy defaults follow `LatheLog`'s: **paths and URLs are private**.
/// This module's job is network ingest on a user's behalf, so a log line that
/// recorded which URL was fetched would be a browsing history written to the
/// system log.
enum LatheFetchLog {
    /// Interpreter lifecycle and execution.
    static let python = Logger(subsystem: LatheLog.subsystem, category: "python")

    /// Package resolution, download and installation.
    static let packages = Logger(subsystem: LatheLog.subsystem, category: "packages")

    /// Muxing, and the sample timing that goes into it.
    ///
    /// Durations rather than paths, so this stays on the public side of the
    /// module's privacy rule: how long a track is says nothing about what was
    /// fetched.
    static let timing = Logger(subsystem: LatheLog.subsystem, category: "timing")
}
