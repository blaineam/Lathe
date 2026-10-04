import Foundation

/// `lathe-image`: Lathe's still-image encoder, from a shell.
///
/// A thin wrapper. Every decision about pixels — never enlarging, never
/// leaving a partial file, the per-picture quality search, even dimensions
/// for AVIF — is the library's, so a batch run from here behaves exactly as
/// Sami does.
@main
enum LatheImageCommand {
    static func main() async {
        let options: Options
        do {
            options = try Options.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            let message = (error as? Options.UsageError)?.description ?? "\(error)"
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(message == Options.usage ? 0 : 64)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var summary = Summary()
        let jobs = options.inputs.map { Job(source: $0, options: options) }
        await runAll(jobs, width: options.jobs) { report in
            summary.add(report)
            if let line = try? encoder.encode(report) {
                FileHandle.standardOutput.write(line + Data("\n".utf8))
            }
        }
        FileHandle.standardError.write(Data((summary.description + "\n").utf8))
        exit(summary.failed > 0 ? 1 : 0)
    }
}

/// Totals for the run, for a person reading standard error.
struct Summary: CustomStringConvertible {
    var counts: [Report.Status: Int] = [:]
    var inputBytes: UInt64 = 0
    var outputBytes: UInt64 = 0

    var failed: Int { counts[.failed, default: 0] }

    mutating func add(_ report: Report) {
        counts[report.status, default: 0] += 1
        if report.status == .written {
            inputBytes += report.inputBytes ?? 0
            outputBytes += report.outputBytes ?? 0
        }
    }

    var description: String {
        let order: [Report.Status] = [.written, .keptSource, .skipped, .noQuality, .failed]
        let parts = order.compactMap { status in
            counts[status].map { "\($0) \(status.rawValue)" }
        }
        var line = parts.isEmpty ? "nothing to do" : parts.joined(separator: ", ")
        if inputBytes > 0 {
            let saved = 100 * (1 - Double(outputBytes) / Double(inputBytes))
            line += String(
                format: "; written: %@ → %@ (%.1f%% smaller)",
                ByteCountFormatter.string(fromByteCount: Int64(inputBytes), countStyle: .file),
                ByteCountFormatter.string(fromByteCount: Int64(outputBytes), countStyle: .file),
                saved)
        }
        return line
    }
}
