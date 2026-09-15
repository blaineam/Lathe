import Foundation

/// Fetches bytes for ``MediaSource``.
///
/// A protocol rather than a direct `URLSession` call so the staging *policy* —
/// the size cap, the redirect rule, cancellation, what a failure turns into —
/// is testable without a network. Those are the parts that matter and the parts
/// a live test exercises least reliably: nobody has a convenient URL that is
/// exactly one byte over the limit.
public protocol MediaDataTransport: Sendable {

    /// Downloads `url` to `destination`, refusing past `limits.maximumByteCount`.
    func download(
        _ url: URL,
        to destination: URL,
        limits: RemoteLimits,
        progress: ProgressHandle?
    ) async throws

    /// Reads a byte range, for readers that need only part of a file.
    ///
    /// A ZIP's index is at its end and a media container's header is at its
    /// start, so a range request answers "how many pages?" for a two-gigabyte
    /// archive in one round trip of a few kilobytes. Servers that do not support
    /// ranges answer with the whole file, which is why callers must treat this
    /// as an optimisation and not a guarantee.
    func range(_ url: URL, offset: Int64, length: Int, limits: RemoteLimits) async throws -> Data

    /// How many bytes the resource is, without fetching it.
    ///
    /// Needed before a range request can address the END of a file, which is
    /// where a ZIP keeps its index. Returns `0` when the server declines to say,
    /// which callers must treat as "fall back to downloading" rather than as an
    /// empty file.
    func length(_ url: URL, limits: RemoteLimits) async throws -> Int64
}

/// The real one.
public struct URLSessionMediaTransport: MediaDataTransport {

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func download(
        _ url: URL,
        to destination: URL,
        limits: RemoteLimits,
        progress: ProgressHandle?
    ) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = limits.timeout

        let (stream, response) = try await bytes(for: request, url: url)
        try Self.checkStatus(response, url: url)

        // The declared length, when there is one, lets an oversized download be
        // refused before a single byte is written rather than after most of them
        // are.
        let declared = response.expectedContentLength
        if declared > 0, declared > limits.maximumByteCount {
            throw LatheError.invalidInput(
                reason: "\(url.lastPathComponent) is \(declared) bytes, over the "
                    + "\(limits.maximumByteCount)-byte limit for a remote read"
            )
        }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            throw LatheError.writeFailed(path: destination.lastPathComponent, reason: "could not open")
        }
        defer { try? handle.close() }

        var written: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(1 << 16)

        do {
            for try await byte in stream {
                buffer.append(byte)
                if buffer.count >= 1 << 16 {
                    written += Int64(buffer.count)
                    guard written <= limits.maximumByteCount else {
                        throw LatheError.invalidInput(
                            reason: "\(url.lastPathComponent) passed the "
                                + "\(limits.maximumByteCount)-byte limit for a remote read"
                        )
                    }
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)

                    if let progress, declared > 0 {
                        try progress.checkpoint(LatheProgress(
                            fraction: min(1, Double(written) / Double(declared)),
                            stage: "download",
                            unitIndex: UInt64(written),
                            unitCount: UInt64(declared)
                        ))
                    } else {
                        try progress?.checkCancellation()
                    }
                }
            }
        } catch let error as LatheError {
            throw error
        } catch {
            throw LatheError.readFailed(
                path: url.lastPathComponent, reason: (error as NSError).localizedDescription
            )
        }

        if !buffer.isEmpty {
            written += Int64(buffer.count)
            guard written <= limits.maximumByteCount else {
                throw LatheError.invalidInput(
                    reason: "\(url.lastPathComponent) passed the "
                        + "\(limits.maximumByteCount)-byte limit for a remote read"
                )
            }
            try handle.write(contentsOf: buffer)
        }

        guard written > 0 else {
            throw LatheError.readFailed(path: url.lastPathComponent, reason: "the response was empty")
        }
    }

    public func range(
        _ url: URL, offset: Int64, length: Int, limits: RemoteLimits
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = limits.timeout
        request.setValue("bytes=\(offset)-\(offset + Int64(length) - 1)", forHTTPHeaderField: "Range")

        let (data, response) = try await data(for: request, url: url)
        try Self.checkStatus(response, url: url)
        // 200 rather than 206 means the server ignored the range and sent
        // everything; taking the tail of it is still correct, and cheaper than
        // failing.
        if response.statusCode == 200, data.count > length {
            return Data(data.suffix(length))
        }
        return data
    }

    private func bytes(
        for request: URLRequest, url: URL
    ) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        do {
            let (stream, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LatheError.readFailed(path: url.lastPathComponent, reason: "not an HTTP response")
            }
            return (stream, http)
        } catch let error as LatheError {
            throw error
        } catch {
            throw LatheError.readFailed(
                path: url.lastPathComponent, reason: (error as NSError).localizedDescription
            )
        }
    }

    private func data(for request: URLRequest, url: URL) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LatheError.readFailed(path: url.lastPathComponent, reason: "not an HTTP response")
            }
            return (data, http)
        } catch let error as LatheError {
            throw error
        } catch {
            throw LatheError.readFailed(
                path: url.lastPathComponent, reason: (error as NSError).localizedDescription
            )
        }
    }

    public func length(_ url: URL, limits: RemoteLimits) async throws -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = limits.timeout

        let (_, response) = try await data(for: request, url: url)
        try Self.checkStatus(response, url: url)
        if response.expectedContentLength > 0 { return response.expectedContentLength }

        // Some servers answer HEAD without a length but honour a range. Asking
        // for one byte gets a Content-Range whose total is the answer, at the
        // cost of a single byte.
        var probe = URLRequest(url: url)
        probe.timeoutInterval = limits.timeout
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, ranged) = try await data(for: probe, url: url)
        if let contentRange = ranged.value(forHTTPHeaderField: "Content-Range"),
           let total = contentRange.split(separator: "/").last,
           let value = Int64(total) {
            return value
        }
        return 0
    }

    static func checkStatus(_ response: HTTPURLResponse, url: URL) throws {
        switch response.statusCode {
        case 200...299:
            return
        case 401, 403:
            throw LatheError.readFailed(
                path: url.lastPathComponent,
                reason: "the server refused the request (\(response.statusCode)) — this reads "
                    + "public URLs and does not authenticate"
            )
        case 404:
            throw LatheError.readFailed(path: url.lastPathComponent, reason: "not found")
        default:
            throw LatheError.readFailed(
                path: url.lastPathComponent, reason: "the server returned \(response.statusCode)"
            )
        }
    }
}
