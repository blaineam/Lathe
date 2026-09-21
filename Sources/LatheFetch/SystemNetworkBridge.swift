import Foundation
import Network

// MARK: - Why Python's HTTP goes through URLSession

/// HTTP for the embedded interpreter, carried by `URLSession`.
///
/// ## The problem
///
/// Some sites decide whether to answer from the TLS ClientHello alone, before
/// a single header is read. The OpenSSL inside the embedded CPython (3.0, from
/// Python-Apple-support) has a ClientHello those sites reject: the very first
/// request comes back `410 Gone` with an empty body — a bot refusal, not a dead
/// link. The same yt-dlp, with the same headers and options, is answered from
/// a Mac whose Python links OpenSSL 3.6, and from the Browse tab, whose
/// WKWebView uses Apple's TLS stack. There is no header to fix, and yt-dlp's
/// own answer — impersonation through `curl_cffi` — is a compiled wheel that
/// cannot be installed on iOS.
///
/// So the requests leave through Apple's stack instead. yt-dlp and gallery-dl
/// still decide *what* to request — method, URL, headers, cookies, redirects —
/// and this type only carries the bytes, which is exactly the part whose
/// fingerprint matters.
///
/// ## The shape of the boundary
///
/// Four C functions whose addresses Python rebuilds with `ctypes.CFUNCTYPE`,
/// the same arrangement as ``JavaScriptBridge`` and for the same reasons:
///
/// - `open(json) -> json`: sends a request and blocks until the response
///   headers arrive (or it fails). Returns a handle for the body.
/// - `read(handle, max, &length) -> bytes`: blocks until body bytes are
///   available and returns up to `max` of them. `length == 0` is the end;
///   `length == -1` means the transfer failed and the bytes are the reason.
/// - `close(handle)`: cancels the transfer if it is still running.
/// - `free(pointer)`: frees anything the other three returned.
///
/// `ctypes` releases the GIL for each call, so a blocked read stalls only the
/// thread that asked.
///
/// ## What URLSession is not allowed to do
///
/// - **Cookies**: no cookie storage, `httpShouldSetCookies = false`. The
///   Python side owns the jar, sends the `Cookie` header it computes and is
///   handed every `Set-Cookie` back. A second, invisible jar in URLSession
///   would leak one site's session into another tool's requests.
/// - **Redirects**: never followed here. The 3xx comes back to Python, which
///   updates its jar and decides the next hop exactly as its own handlers do.
/// - **Proxies**: configured per session with `proxyConfigurations` and
///   `allowFailover = false`. A proxy that cannot be parsed or honoured is an
///   error, never a quiet direct connection — this is the Tor path.
/// - **Caching**: none.
///
/// Compression is URLSession's: it asks for and decodes gzip, deflate and br
/// itself, so the response headers handed back drop `Content-Encoding` and
/// `Content-Length` when it did, rather than describing bytes Python never sees.
///
/// Response bodies stream. The delegate appends to a small queue and the
/// transfer is suspended when more than ``Transfer/highWater`` bytes are
/// waiting, so a multi-gigabyte download never sits in memory.
public enum SystemNetworkBridge {

    /// The four function addresses, as decimal strings, keyed as the Python
    /// driver expects them.
    public static var addresses: [String: String] {
        [
            "net_open": address(of: openFunction),
            "net_read": address(of: readFunction),
            "net_close": address(of: closeFunction),
            "net_free": address(of: freeFunction),
        ]
    }

    private static func address<T>(of function: T) -> String {
        String(UInt(bitPattern: unsafeBitCast(function, to: UnsafeRawPointer.self)))
    }

    // MARK: C entry points

    private static let openFunction: @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = {
        json in
        let text = json.map { String(cString: $0) } ?? ""
        let reply = SystemHTTP.shared.open(requestJSON: text)
        let data = (try? JSONSerialization.data(withJSONObject: reply)) ?? Data(
            #"{"ok":false,"kind":"transport","error":"the reply could not be encoded"}"#.utf8)
        return duplicate(data, terminated: true)
    }

    private static let readFunction:
        @convention(c) (Int64, Int, UnsafeMutablePointer<Int>?) -> UnsafeMutableRawPointer? = {
            handle, maximum, length in
            switch SystemHTTP.shared.read(handle: handle, maximum: max(1, maximum)) {
            case .bytes(let data):
                length?.pointee = data.count
                return duplicate(data, terminated: false)
            case .end:
                length?.pointee = 0
                return nil
            case .failed(let reason):
                length?.pointee = -1
                return duplicate(Data(reason.utf8), terminated: true)
            }
        }

    private static let closeFunction: @convention(c) (Int64) -> Void = { handle in
        SystemHTTP.shared.close(handle: handle)
    }

    private static let freeFunction: @convention(c) (UnsafeMutableRawPointer?) -> Void = { pointer in
        free(pointer)
    }

    /// A `malloc`-ed copy the Python side frees with `net_free`.
    private static func duplicate(_ data: Data, terminated: Bool) -> UnsafeMutableRawPointer? {
        let size = data.count + (terminated ? 1 : 0)
        guard let buffer = malloc(max(size, 1)) else { return nil }
        data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
        if terminated { buffer.storeBytes(of: 0, toByteOffset: data.count, as: UInt8.self) }
        return buffer
    }
}

// MARK: - The transfers

/// One request's response body, handed from URLSession's delegate queue to
/// whichever Python thread is reading it.
final class Transfer: @unchecked Sendable {
    /// Suspend the task above this many buffered bytes, resume below ``lowWater``.
    static let highWater = 8 << 20
    static let lowWater = 2 << 20

    let condition = NSCondition()
    var task: URLSessionDataTask?
    var response: HTTPURLResponse?
    var chunks: [Data] = []
    var buffered = 0
    var finished = false
    var failure: String?
    var failureKind = "transport"
    var suspended = false
}

enum ReadResult {
    case bytes(Data)
    case end
    case failed(String)
}

final class SystemHTTP: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    static let shared = SystemHTTP()

    private let lock = NSLock()
    /// One session per proxy, because a proxy is a session property.
    private var sessions: [String: URLSession] = [:]
    private var transfers: [Int64: Transfer] = [:]
    /// Delegate callbacks arrive per task; this finds the transfer for one.
    private var byTask: [ObjectIdentifier: Transfer] = [:]
    private var nextHandle: Int64 = 1

    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "LatheFetch.SystemHTTP"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    // MARK: Open

    func open(requestJSON: String) -> [String: Any] {
        guard let data = requestJSON.data(using: .utf8),
            let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let urlText = request["url"] as? String, let url = URL(string: urlText)
        else {
            return failure("transport", "the request could not be read")
        }

        let proxy = (request["proxy"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let session: URLSession
        do {
            session = try self.session(proxy: proxy)
        } catch {
            // Fail closed: a proxy that was asked for and cannot be honoured
            // ends the request rather than letting it go direct.
            return failure("proxy", error.localizedDescription)
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = (request["method"] as? String) ?? "GET"
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.httpShouldHandleCookies = false
        if let timeout = request["timeout"] as? Double, timeout > 0 {
            urlRequest.timeoutInterval = timeout
        }
        for pair in (request["headers"] as? [[String]]) ?? [] where pair.count == 2 {
            let name = pair[0]
            switch name.lowercased() {
            // URLSession negotiates and decodes compression itself, and owns
            // the connection; a caller's values for these would only disagree
            // with what it actually does.
            case "accept-encoding", "connection", "content-length", "host": continue
            default: urlRequest.addValue(pair[1], forHTTPHeaderField: name)
            }
        }
        if let body = request["body"] as? String, let bytes = Data(base64Encoded: body) {
            urlRequest.httpBody = bytes
        }

        let transfer = Transfer()
        let task = session.dataTask(with: urlRequest)
        transfer.task = task
        let handle: Int64
        lock.lock()
        handle = nextHandle
        nextHandle += 1
        transfers[handle] = transfer
        byTask[ObjectIdentifier(task)] = transfer
        lock.unlock()
        task.resume()

        transfer.condition.lock()
        while transfer.response == nil && !transfer.finished {
            transfer.condition.wait()
        }
        let response = transfer.response
        let reason = transfer.failure
        let kind = transfer.failureKind
        transfer.condition.unlock()

        guard let response else {
            close(handle: handle)
            return failure(kind, reason ?? "the request ended without a response")
        }
        return [
            "ok": true,
            "handle": handle,
            "status": response.statusCode,
            "url": response.url?.absoluteString ?? urlText,
            "headers": Self.headerPairs(of: response, for: url),
        ]
    }

    // MARK: Read / close

    func read(handle: Int64, maximum: Int) -> ReadResult {
        lock.lock()
        let transfer = transfers[handle]
        lock.unlock()
        guard let transfer else { return .end }

        transfer.condition.lock()
        defer { transfer.condition.unlock() }
        while transfer.chunks.isEmpty && !transfer.finished {
            transfer.condition.wait()
        }
        if transfer.chunks.isEmpty {
            if let failure = transfer.failure { return .failed(failure) }
            return .end
        }

        var taken = Data()
        taken.reserveCapacity(min(maximum, transfer.buffered))
        while !transfer.chunks.isEmpty && taken.count < maximum {
            let first = transfer.chunks[0]
            let wanted = maximum - taken.count
            if first.count <= wanted {
                taken.append(first)
                transfer.chunks.removeFirst()
            } else {
                taken.append(first.prefix(wanted))
                transfer.chunks[0] = first.dropFirst(wanted)
            }
        }
        transfer.buffered -= taken.count
        if transfer.suspended && transfer.buffered < Transfer.lowWater {
            transfer.suspended = false
            transfer.task?.resume()
        }
        return .bytes(taken)
    }

    func close(handle: Int64) {
        lock.lock()
        let transfer = transfers.removeValue(forKey: handle)
        if let task = transfer?.task { byTask.removeValue(forKey: ObjectIdentifier(task)) }
        lock.unlock()
        guard let transfer else { return }
        transfer.condition.lock()
        let running = !transfer.finished
        transfer.finished = true
        transfer.chunks.removeAll()
        transfer.condition.broadcast()
        transfer.condition.unlock()
        if running { transfer.task?.cancel() }
    }

    // MARK: Sessions

    private func session(proxy: String?) throws -> URLSession {
        let key = proxy ?? ""
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[key] { return existing }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        configuration.waitsForConnectivity = false
        if let proxy {
            configuration.proxyConfigurations = [try Self.proxyConfiguration(proxy)]
        }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        sessions[key] = session
        return session
    }

    struct ProxyProblem: LocalizedError {
        let proxy: String
        let reason: String
        var errorDescription: String? { "the proxy \(proxy) cannot be used: \(reason)" }
    }

    /// `socks5`/`socks5h` and `http`/`https` CONNECT proxies. Anything else —
    /// `socks4`, a malformed URL — is refused, not ignored.
    static func proxyConfiguration(_ proxy: String) throws -> ProxyConfiguration {
        guard let components = URLComponents(string: proxy), let scheme = components.scheme?.lowercased(),
            let host = components.host, !host.isEmpty
        else {
            throw ProxyProblem(proxy: proxy, reason: "it is not a proxy URL")
        }
        let defaultPort: Int
        switch scheme {
        case "socks5", "socks5h": defaultPort = 1080
        case "http": defaultPort = 80
        case "https": defaultPort = 443
        default: throw ProxyProblem(proxy: proxy, reason: "\(scheme) proxies are not supported here")
        }
        guard let port = NWEndpoint.Port(rawValue: UInt16(components.port ?? defaultPort)) else {
            throw ProxyProblem(proxy: proxy, reason: "the port is out of range")
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
        var configuration: ProxyConfiguration
        switch scheme {
        case "socks5", "socks5h":
            // Names are sent to the proxy to resolve, as socks5h asks — and
            // as Tor needs, since a local DNS lookup is exactly the leak it
            // exists to prevent.
            configuration = ProxyConfiguration(socksv5Proxy: endpoint)
        case "https":
            configuration = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: NWProtocolTLS.Options())
        default:
            configuration = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
        }
        if let user = components.user {
            configuration.applyCredential(
                username: user.removingPercentEncoding ?? user,
                password: components.password?.removingPercentEncoding ?? components.password ?? "")
        }
        configuration.allowFailover = false
        return configuration
    }

    // MARK: Delegate

    private func transfer(for task: URLSessionTask) -> Transfer? {
        lock.lock()
        defer { lock.unlock() }
        return byTask[ObjectIdentifier(task)]
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let transfer = transfer(for: dataTask) {
            transfer.condition.lock()
            transfer.response = response as? HTTPURLResponse
            if transfer.response == nil {
                transfer.failure = "the response was not HTTP"
                transfer.finished = true
            }
            transfer.condition.broadcast()
            transfer.condition.unlock()
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer = transfer(for: dataTask) else { return }
        transfer.condition.lock()
        if !transfer.finished {
            transfer.chunks.append(data)
            transfer.buffered += data.count
            if transfer.buffered > Transfer.highWater && !transfer.suspended {
                transfer.suspended = true
                dataTask.suspend()
            }
        }
        transfer.condition.broadcast()
        transfer.condition.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let transfer = transfer(for: task) else { return }
        transfer.condition.lock()
        if let error, !transfer.finished {
            let (kind, reason) = Self.classify(error, proxied: session.configuration.proxyConfigurations.isEmpty == false)
            transfer.failure = reason
            transfer.failureKind = kind
        }
        transfer.finished = true
        transfer.condition.broadcast()
        transfer.condition.unlock()
    }

    /// Redirects go back to Python, which owns the cookie jar and the policy.
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    // MARK: Mapping

    static func classify(_ error: any Error, proxied: Bool) -> (kind: String, reason: String) {
        let nsError = error as NSError
        let reason = nsError.localizedDescription
        guard nsError.domain == NSURLErrorDomain else {
            return (proxied ? "proxy" : "transport", reason)
        }
        switch nsError.code {
        case NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid:
            return ("certificate", reason)
        case NSURLErrorSecureConnectionFailed, NSURLErrorClientCertificateRejected,
            NSURLErrorClientCertificateRequired:
            return ("ssl", reason)
        case NSURLErrorTimedOut:
            return ("timeout", reason)
        case NSURLErrorCannotConnectToHost where proxied, NSURLErrorCannotFindHost where proxied:
            return ("proxy", reason)
        default:
            return ("transport", reason)
        }
    }

    /// Header pairs as the server sent them, as far as URLSession allows.
    ///
    /// `allHeaderFields` joins repeated fields with ", ", which destroys
    /// `Set-Cookie` (its `Expires` dates contain commas). Cookies are therefore
    /// parsed by Foundation and written back out one per line, and every other
    /// field is passed through.
    static func headerPairs(of response: HTTPURLResponse, for url: URL) -> [[String]] {
        var fields: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            guard let name = name as? String else { continue }
            fields[name] = "\(value)"
        }
        let encoding = fields.first { $0.key.lowercased() == "content-encoding" }?.value.lowercased() ?? ""
        let decoded = ["gzip", "deflate", "br", "x-gzip"].contains { encoding.contains($0) }

        var pairs: [[String]] = []
        for (name, value) in fields {
            switch name.lowercased() {
            case "set-cookie": continue
            case "content-encoding" where decoded, "content-length" where decoded: continue
            default: pairs.append([name, value])
            }
        }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: fields, for: response.url ?? url) {
            pairs.append(["Set-Cookie", serialize(cookie)])
        }
        return pairs
    }

    private static let cookieDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()

    static func serialize(_ cookie: HTTPCookie) -> String {
        var text = "\(cookie.name)=\(cookie.value); Path=\(cookie.path)"
        // A host-only cookie has no leading dot; writing Domain= for it would
        // widen it to every subdomain in the Python jar.
        if cookie.domain.hasPrefix(".") { text += "; Domain=\(cookie.domain)" }
        if let expires = cookie.expiresDate { text += "; Expires=\(cookieDate.string(from: expires))" }
        if cookie.isSecure { text += "; Secure" }
        if cookie.isHTTPOnly { text += "; HttpOnly" }
        return text
    }

    private func failure(_ kind: String, _ reason: String) -> [String: Any] {
        ["ok": false, "kind": kind, "error": reason]
    }
}
