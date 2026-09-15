import Foundation

/// Where a piece of media is, which may be a file on disk or a plain URL.
///
/// ## The distinction this type exists to draw
///
/// "Reads local files only" conflates two very different things, and the
/// conflation costs real capability for no benefit.
///
/// **Reading a URL the caller handed you** is an ordinary network fetch. Any app
/// that loads an image from the web does it. It is not a policy question on any
/// platform, and refusing it only means the caller writes the same download
/// themselves, worse, before calling back in.
///
/// **Discovering media inside a web page** — following a gallery, parsing a
/// player's page for a stream, resolving a share link into a file — is the thing
/// that carries review risk, and it lives in a separate module that a store
/// build can leave out entirely.
///
/// So this type accepts a URL and never goes looking for one. It does not parse
/// HTML, does not follow a page to its media, and does not know what a gallery
/// is. Given `https://example.com/clip.mp4` it will read that clip; given
/// `https://example.com/gallery` it will faithfully read whatever bytes that
/// returns, and find them not to be media.
///
/// ## Streaming versus staging
///
/// Remote media does not have to be downloaded first. AVFoundation reads an
/// `http(s)` URL by range request, so probing the duration of a two-hour film
/// over the network costs a few kilobytes rather than a few gigabytes — see
/// ``canStreamDirectly``. Formats whose readers cannot do that (ImageIO, PDFKit,
/// a ZIP central directory) are staged to a temporary file by
/// ``withLocalFile(transport:limits:progress:_:)``, which is a real download and
/// is bounded accordingly.
public struct MediaSource: Sendable, Equatable {

    public enum Location: Sendable, Equatable {
        case localFile
        case remote
    }

    public let url: URL
    public let location: Location

    /// - Throws: ``LatheError/invalidInput(reason:)`` for a scheme this does not
    ///   read.
    public init(_ url: URL) throws {
        if url.isFileURL {
            self.url = url
            self.location = .localFile
            return
        }
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw LatheError.invalidInput(
                reason: "\(url.scheme.map { "\($0):" } ?? "that") is not a scheme Lathe reads "
                    + "(expected a file path, http or https)"
            )
        }
        // A bare scheme with no host is not a URL anything can fetch, and the
        // failure is far clearer here than as a transport error later.
        guard url.host != nil else {
            throw LatheError.invalidInput(reason: "\(url.absoluteString) has no host")
        }
        self.url = url
        self.location = .remote
    }

    /// A source for a path on disk.
    public init(path: String) throws {
        try self.init(URL(fileURLWithPath: path))
    }

    public var isRemote: Bool { location == .remote }

    /// Whether a reader that understands `http(s)` can work from this source
    /// without downloading it first.
    ///
    /// True for every remote source: it describes what AVFoundation-backed
    /// readers can do, not what any particular format allows. A caller that
    /// cannot stream uses ``withLocalFile(transport:limits:progress:_:)``
    /// instead, and the two are different code paths on purpose — a reader that
    /// silently downloaded two gigabytes to answer "how long is this?" would be
    /// a surprising thing to have done.
    public var canStreamDirectly: Bool { isRemote }

    /// Checks a local source is readable. A remote one is not checked here,
    /// because the only way to check it is to fetch it.
    public func validateLocal() throws {
        guard location == .localFile else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw LatheError.readFailed(path: url.lastPathComponent, reason: "no such file")
        }
        guard !isDirectory.boolValue else {
            throw LatheError.readFailed(path: url.lastPathComponent, reason: "is a directory")
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw LatheError.readFailed(path: url.lastPathComponent, reason: "not readable")
        }
    }

    /// Runs `body` against a local file, downloading first if this source is
    /// remote and removing the download afterwards.
    ///
    /// A local source is passed straight through — no copy, no temporary file —
    /// so wrapping a call in this costs nothing when nothing is remote.
    public func withLocalFile<T>(
        transport: any MediaDataTransport = URLSessionMediaTransport(),
        limits: RemoteLimits = .standard,
        progress: ProgressHandle? = nil,
        _ body: (URL) async throws -> T
    ) async throws -> T {
        guard location == .remote else {
            try validateLocal()
            return try await body(url)
        }

        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent("lathe-remote-\(UUID().uuidString)")
            .appendingPathExtension(url.pathExtension.isEmpty ? "bin" : url.pathExtension)
        defer { try? FileManager.default.removeItem(at: staged) }

        try await transport.download(url, to: staged, limits: limits, progress: progress)
        return try await body(staged)
    }

    /// A name to use in messages and in a destination filename.
    public var suggestedName: String {
        let name = url.lastPathComponent
        return name.isEmpty || name == "/" ? "media" : name
    }
}

/// Bounds on reading something remote.
///
/// A URL is whatever it turns out to be, and a caller that asked for a thumbnail
/// should not be able to fill the disk by mistyping one. The cap is a refusal
/// rather than a truncation: half a file is not a smaller file, it is a broken
/// one, and a reader handed a truncated download reports a corrupt media file
/// rather than a download that was too big.
public struct RemoteLimits: Sendable, Equatable {
    /// The most that will be downloaded before the read is refused.
    public var maximumByteCount: Int64
    /// How long to wait for the first byte.
    public var timeout: TimeInterval

    public init(maximumByteCount: Int64 = 4 * 1024 * 1024 * 1024, timeout: TimeInterval = 30) {
        self.maximumByteCount = maximumByteCount
        self.timeout = timeout
    }

    /// Four gigabytes: larger than any still, document or short video, and small
    /// enough that a mistake is caught before it matters.
    public static let standard = RemoteLimits()
}
