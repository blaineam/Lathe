import Foundation

/// What one application asks another to do with some files.
///
/// ## Why this is a document and not a message
///
/// The receiving application is sandboxed. It cannot read a folder the sender
/// chose, it cannot see the sender's preferences, and it has no shared
/// container unless both are signed into the same App Group — which a locally
/// built tool is not.
///
/// What a sandbox *does* admit is a file the user's system handed it.
/// `NSWorkspace.open(_:withApplicationAt:)` grants the receiving application
/// access to exactly the files in that call, through the same machinery that
/// makes double-clicking a document work. So the request travels as one of
/// those files: a small document opened alongside the media it describes, and
/// readable for the same reason the media is.
///
/// The alternative — a URL scheme carrying the options and a separate open
/// carrying the files — is two deliveries that can arrive in either order, or
/// only one of which arrives at all.
public struct Handoff: Codable, Sendable, Equatable {

    /// What the sender would like done.
    public enum Intent: String, Codable, Sendable {
        /// Make it smaller, leaving the format alone.
        case compress
        /// Change the format.
        case convert
        /// The sender has no opinion; ask.
        case ask
    }

    /// The files this is about, in the order they should be worked through.
    ///
    /// Absolute paths. They are meaningful to the receiver only because they
    /// arrived in the same `open` call as this document — a path on its own
    /// would be a string it is not allowed to follow.
    public var files: [URL]

    public var intent: Intent

    /// The receiver's own name for a set of settings. Not interpreted here:
    /// this package has no opinion about what presets exist, and a handoff
    /// that hard-coded a list would go stale the first time one was renamed.
    public var preset: String?

    /// Where the sender would like results to go, when it has a preference.
    ///
    /// Advisory. The receiver may not be allowed to write there, and should
    /// fall back to its own destination rather than fail.
    public var destination: URL?

    /// Which application sent this, for the receiver to show.
    public var origin: String

    public var createdAt: Date

    /// The version of this format.
    ///
    /// Present from the first release so that a later one can add fields and
    /// an older receiver can recognise what it is looking at instead of
    /// failing to decode and silently dropping the request.
    public var version: Int

    public static let currentVersion = 1

    /// What a handoff document is called, and what it is.
    public static let fileExtension = "lathehandoff"
    public static let contentType = "com.blainemiller.lathe.handoff"

    public init(
        files: [URL],
        intent: Intent = .ask,
        preset: String? = nil,
        destination: URL? = nil,
        origin: String = "Lathe",
        createdAt: Date = Date(),
        version: Int = Handoff.currentVersion
    ) {
        self.files = files
        self.intent = intent
        self.preset = preset
        self.destination = destination
        self.origin = origin
        self.createdAt = createdAt
        self.version = version
    }

    // MARK: - Reading and writing

    public enum Failure: LocalizedError, Equatable {
        case notAHandoff
        case unsupportedVersion(Int)
        case noFiles

        public var errorDescription: String? {
            switch self {
            case .notAHandoff:
                return "That file is not a handoff request."
            case .unsupportedVersion(let version):
                return "This handoff was written by a newer version (format \(version))."
            case .noFiles:
                return "The handoff names no files."
            }
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Reads a handoff, refusing anything that is not one.
    ///
    /// Strict on purpose. This is read from a file another process wrote, and
    /// "decode whatever fields happen to be there" is how a receiver ends up
    /// acting on a document that was never meant for it.
    public static func decode(_ data: Data) throws -> Handoff {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let handoff = try? decoder.decode(Handoff.self, from: data) else {
            throw Failure.notAHandoff
        }
        guard handoff.version <= currentVersion else {
            throw Failure.unsupportedVersion(handoff.version)
        }
        guard !handoff.files.isEmpty else { throw Failure.noFiles }
        return handoff
    }

    /// Whether a URL looks like a handoff document.
    public static func isHandoff(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == fileExtension
    }

    /// Writes the document into a directory of its own.
    ///
    /// Its own directory because the file is transient and the receiver may
    /// take a moment to read it; leaving it beside the media would put a stray
    /// file in the user's download folder, and reusing one name would mean two
    /// handoffs in quick succession overwrote each other.
    @discardableResult
    public func write(into directory: URL? = nil) throws -> URL {
        let base = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("lathe-handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let name = "\(origin) request".replacingOccurrences(of: "/", with: "-")
        let url = base.appendingPathComponent(name).appendingPathExtension(Self.fileExtension)
        try encoded().write(to: url, options: .atomic)
        return url
    }

    /// Everything to hand to `NSWorkspace.open`: the request, then the media.
    ///
    /// The request comes first so a receiver that processes them in order sees
    /// what is being asked before it sees what it is being asked about.
    public func openList(documentAt url: URL) -> [URL] {
        [url] + files
    }
}
