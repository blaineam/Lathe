import Foundation

/// A log that can actually be read back.
///
/// `os_log` is the right home for this normally, and for this app it produces
/// nothing readable: `log show --predicate 'process == "Lathe"'` returns zero
/// entries for a running, working build, so an investigation that depends on
/// it is an investigation with no evidence. A file has none of that
/// sophistication and all of the availability.
///
/// Off unless `LATHE_DIAGNOSTIC_LOG` names a path, so a shipping app writes
/// nothing at all — this exists to answer a question, not to keep a record.
public enum DiagnosticLog {
    private static let destination: URL? = {
        guard let path = ProcessInfo.processInfo.environment["LATHE_DIAGNOSTIC_LOG"],
              !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }()

    private static let queue = DispatchQueue(label: "dev.lathe.diagnostic")

    public static var isOn: Bool { destination != nil }

    public static func note(_ message: @autoclosure () -> String) {
        guard let destination else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date()))  \(message())\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: destination) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
            } else {
                try? Data(line.utf8).write(to: destination)
            }
        }
    }
}
