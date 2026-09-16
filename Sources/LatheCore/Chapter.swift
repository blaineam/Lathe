import Foundation

/// One chapter: a named point in a file, with a duration.
///
/// ## Why this is in LatheCore rather than in the audio module
///
/// Chapters are not an audio feature. An audiobook has them, a podcast has them,
/// and so does a film with scene markers — the same structure written into the
/// same kind of track. Putting the model here means the audio and video paths
/// preserve the same thing in the same way rather than each growing its own
/// half-version.
public struct Chapter: Sendable, Equatable {

    /// Where the chapter starts, in seconds from the beginning.
    public var startSeconds: Double

    /// How long it lasts, in seconds.
    ///
    /// Stored rather than derived from the next chapter's start, because the
    /// two are not the same: a file can have a gap between chapters, and the
    /// last chapter's length is not knowable from the list alone.
    public var durationSeconds: Double

    /// What the chapter is called. The only field a player reliably shows.
    public var title: String

    /// Per-chapter artwork, where the source had it.
    ///
    /// Audiobooks and podcasts use it for section covers, and it is the part
    /// most likely to be dropped by a naive copy because it is not text.
    public var artwork: Data?

    public init(
        startSeconds: Double,
        durationSeconds: Double,
        title: String,
        artwork: Data? = nil
    ) {
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
        self.title = title
        self.artwork = artwork
    }

    /// Where the chapter ends.
    public var endSeconds: Double { startSeconds + durationSeconds }
}

public extension Array where Element == Chapter {

    /// The list in start order, with overlaps and zero-length entries removed.
    ///
    /// A writer will accept overlapping chapters and produce a file whose
    /// chapter list jumps backwards, which no player handles gracefully. Sources
    /// in the wild do contain them — a tagger that wrote a duration it guessed,
    /// an edit that moved one marker and not the next — so normalising on the
    /// way out is worth the small chance of altering a list that was fine.
    ///
    /// Overlaps are resolved by truncating the earlier chapter, not by moving
    /// the later one: a chapter's START is the thing a listener navigates to and
    /// the thing a producer chose, and its duration is usually implied rather
    /// than authored.
    func normalizedChapters(totalDuration: Double? = nil) -> [Chapter] {
        var sorted = filter { $0.startSeconds.isFinite && $0.startSeconds >= 0 }
            .sorted { $0.startSeconds < $1.startSeconds }
        guard !sorted.isEmpty else { return [] }

        for index in sorted.indices.dropLast() {
            let nextStart = sorted[index + 1].startSeconds
            if sorted[index].endSeconds > nextStart {
                sorted[index].durationSeconds = Swift.max(0, nextStart - sorted[index].startSeconds)
            }
        }
        if let totalDuration, totalDuration > 0, var last = sorted.last {
            if last.endSeconds > totalDuration || last.durationSeconds <= 0 {
                last.durationSeconds = Swift.max(0, totalDuration - last.startSeconds)
                sorted[sorted.count - 1] = last
            }
        }
        return sorted.filter { $0.durationSeconds > 0 }
    }
}
