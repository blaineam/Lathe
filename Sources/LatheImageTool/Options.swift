import Foundation
import LatheCore
import LatheImage

/// What `lathe-image` was asked to do, parsed from its arguments.
///
/// Hand-parsed rather than built on an argument-parsing package: the tool has
/// a dozen flags, and a dependency would be the first one this package takes
/// from outside Apple's SDKs for something other than a codec.
struct Options: Equatable {
    enum Quality: Equatable {
        /// Encode once at this setting.
        case fixed(Double)
        /// Search for the lowest setting that still passes the threshold.
        case visuallyLossless(QualitySearch)
    }

    var inputs: [URL] = []
    var format: ImageFormat = .avif
    var quality: Quality = .visuallyLossless(QualitySearch())
    var resize: ResizeTarget = .none
    var metadata: MetadataPolicy = .preserveAll
    var outputDirectory: URL?
    var base: URL?
    var onlyIfSmaller = false
    var skipExisting = false
    var jobs = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)

    static let usage = """
        USAGE: lathe-image [options] <file>... [-]

        Re-encodes stills with Lathe, one output per input, several at a time.
        By default each picture gets the lowest quality whose result cannot be
        told apart from it (SSIM; see Lathe's README, "Visually lossless").
        A `-` reads more paths from standard input, one per line.

        One JSON object per input is written to standard output; a summary goes
        to standard error. Exits 1 if any input failed.

        OPTIONS:
          --format <f>            avif (default), heic, jpeg, png or webp
          --quality <q>           encode once at q in 0...1 instead of searching
          --min-ssim <x>          search: whole-picture SSIM floor (default 0.99)
          --min-region-ssim <x>   search: worst 32x32 region floor (default 0.97)
          --range <lo>-<hi>       search: qualities to consider (default 0.4-0.98)
          --max-side <px>         fit the longest side to px; never enlarges
          --metadata <m>          keep (default), strip-location or strip
          --output-dir <dir>      write here instead of beside each source,
                                  mirroring each path below --base
          --base <dir>            root that --output-dir mirrors (default: cwd)
          --only-if-smaller       discard an output that is not smaller
          --skip-existing         leave an existing output alone
          --jobs <n>              pictures in flight (default: half the cores)
          -h, --help              show this
        """

    struct UsageError: Error, Equatable, CustomStringConvertible {
        var description: String
    }

    /// Parses `arguments` (without the program name). `readStandardInput` is
    /// called once if a `-` is present.
    static func parse(
        _ arguments: [String],
        readStandardInput: () -> [String] = { Options.standardInputLines() }
    ) throws -> Options {
        var options = Options()
        var search = QualitySearch()
        var fixed: Double?
        var searchFlagSeen = false
        var iterator = arguments.makeIterator()

        func value(for flag: String) throws -> String {
            guard let next = iterator.next() else { throw UsageError(description: "\(flag) needs a value") }
            return next
        }
        func number(for flag: String, in range: ClosedRange<Double>) throws -> Double {
            let raw = try value(for: flag)
            guard let parsed = Double(raw), range.contains(parsed) else {
                throw UsageError(description: "\(flag) \(raw): expected a number in \(range.lowerBound)...\(range.upperBound)")
            }
            return parsed
        }

        while let argument = iterator.next() {
            switch argument {
            case "-h", "--help":
                throw UsageError(description: usage)
            case "--format":
                let raw = try value(for: argument)
                guard let format = Self.formats[raw.lowercased()] else {
                    throw UsageError(description: "--format \(raw): expected one of \(Self.formats.keys.sorted().joined(separator: ", "))")
                }
                options.format = format
            case "--quality":
                fixed = try number(for: argument, in: 0...1)
            case "--min-ssim":
                search.threshold.minimumSimilarity = try number(for: argument, in: 0...1)
                searchFlagSeen = true
            case "--min-region-ssim":
                search.threshold.minimumRegionSimilarity = try number(for: argument, in: 0...1)
                searchFlagSeen = true
            case "--range":
                let raw = try value(for: argument)
                let parts = raw.split(separator: "-").compactMap { Double($0) }
                guard parts.count == 2, parts[0] >= 0, parts[1] <= 1, parts[0] <= parts[1] else {
                    throw UsageError(description: "--range \(raw): expected <lo>-<hi> within 0...1, e.g. 0.4-0.9")
                }
                search.range = parts[0]...parts[1]
                searchFlagSeen = true
            case "--max-side":
                let raw = try value(for: argument)
                guard let side = Int(raw), side > 0 else {
                    throw UsageError(description: "--max-side \(raw): expected a positive number of pixels")
                }
                options.resize = .longestSide(side)
            case "--metadata":
                switch try value(for: argument) {
                case "keep": options.metadata = .preserveAll
                case "strip-location": options.metadata = .stripLocation
                case "strip": options.metadata = .stripAll
                case let other: throw UsageError(description: "--metadata \(other): expected keep, strip-location or strip")
                }
            case "--output-dir":
                options.outputDirectory = URL(fileURLWithPath: try value(for: argument), isDirectory: true)
            case "--base":
                options.base = URL(fileURLWithPath: try value(for: argument), isDirectory: true)
            case "--only-if-smaller":
                options.onlyIfSmaller = true
            case "--skip-existing":
                options.skipExisting = true
            case "--jobs":
                let raw = try value(for: argument)
                guard let jobs = Int(raw), jobs > 0 else {
                    throw UsageError(description: "--jobs \(raw): expected a positive number")
                }
                options.jobs = jobs
            case "-":
                options.inputs += readStandardInput().map { URL(fileURLWithPath: $0) }
            case let flag where flag.hasPrefix("--"):
                throw UsageError(description: "unknown option \(flag)\n\n\(usage)")
            default:
                options.inputs.append(URL(fileURLWithPath: argument))
            }
        }

        if let fixed {
            guard !searchFlagSeen else {
                throw UsageError(description: "--quality fixes the setting; --min-ssim, --min-region-ssim and --range only apply to the search")
            }
            options.quality = .fixed(fixed)
        } else {
            options.quality = .visuallyLossless(search)
        }
        if options.base != nil, options.outputDirectory == nil {
            throw UsageError(description: "--base only means something with --output-dir")
        }
        guard !options.inputs.isEmpty else { throw UsageError(description: usage) }
        return options
    }

    static let formats: [String: ImageFormat] = [
        "avif": .avif, "heic": .heic, "jpeg": .jpeg, "jpg": .jpeg, "png": .png, "webp": .webp,
    ]

    /// Where `source` is written.
    ///
    /// Beside it by default, with the format's extension. Under
    /// `--output-dir`, at the same path relative to `--base` (or the working
    /// directory); a source outside the base keeps only its file name.
    func destination(for source: URL) -> URL {
        let name = source.deletingPathExtension().lastPathComponent + "." + format.preferredFilenameExtension
        guard let outputDirectory else {
            return source.deletingLastPathComponent().appendingPathComponent(name)
        }
        let base = (base ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
            .standardizedFileURL.path
        let parent = source.standardizedFileURL.deletingLastPathComponent().path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        var directory = outputDirectory
        if parent.hasPrefix(prefix) {
            directory = directory.appendingPathComponent(String(parent.dropFirst(prefix.count)), isDirectory: true)
        }
        return directory.appendingPathComponent(name)
    }

    static func standardInputLines() -> [String] {
        var lines: [String] = []
        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { lines.append(trimmed) }
        }
        return lines
    }
}
