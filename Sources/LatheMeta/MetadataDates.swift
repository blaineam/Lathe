import Foundation

/// The date spellings that turn up in media metadata, and the one this
/// module writes.
///
/// A `©day` atom is whatever the tagger wrote: a full ISO 8601 timestamp, a bare
/// `YYYY-MM-DD`, or just `YYYY`. Refusing the short forms would drop the release
/// year off most of a library, so each is tried in turn, longest first.
public enum MetadataDates {
    public static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: trimmed) { return date }
        iso.formatOptions = [.withFullDate]
        if let date = iso.date(from: trimmed) { return date }

        for format in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    /// The spelling to write. ISO 8601 with a full timestamp, which every
    /// reader accepts and which round-trips without losing the day.
    public static func format(_ date: Date) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone(secondsFromGMT: 0)
        return iso.string(from: date)
    }
}
