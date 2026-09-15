import Foundation
import Network
import os

/// A SOCKS5 proxy to route downloads through — Tor, or anything else speaking
/// SOCKS5 on loopback.
///
/// ## Fail closed
///
/// Every method here refuses rather than falling back. A downloader that
/// quietly abandons the proxy it was told to use and fetches in the clear is
/// worse than one that has no proxy option at all: the user believes something
/// about their traffic that is not true, and nothing in the interface
/// contradicts them. So if the proxy is unreachable, the download fails and
/// says why.
///
/// ## Why the check is a handshake and not a connection
///
/// Anything at all can be listening on 9050. Confirming only that the port
/// accepts a connection would let a local web server, a stale tunnel, or a
/// different application's socket pass as Tor, and every download would then
/// fail somewhere much deeper with an error about the response not being
/// media. Speaking the first two bytes of SOCKS5 and checking the reply costs
/// one round trip on loopback and distinguishes "a SOCKS5 proxy" from "a port".
struct SOCKSProxy: Equatable, Sendable {

    var host: String = "127.0.0.1"

    /// 9050 is Tor's own default, and the port the Tor Browser bundle and a
    /// `brew install tor` both listen on. An app that embeds its own Tor
    /// usually picks something else to avoid colliding with those, so this is
    /// editable.
    var port: Int = 9050

    var endpoint: NWEndpoint {
        NWEndpoint.hostPort(host: NWEndpoint.Host(host),
                            port: NWEndpoint.Port(rawValue: UInt16(port)) ?? 9050)
    }

    /// What to hand an extractor as its `--proxy`.
    ///
    /// `socks5h`, not `socks5`: the `h` is what makes the *name* resolution
    /// happen at the proxy instead of locally. With plain `socks5` the client
    /// resolves the hostname itself, which means the one machine the user is
    /// trying not to tell has already been told — by a DNS query in the clear,
    /// before the first proxied byte. It is the classic way a proxied
    /// downloader leaks exactly what it was hiding.
    var extractorProxyURL: String { "socks5h://\(host):\(port)" }

    /// A session whose traffic goes through the proxy, name resolution included.
    ///
    /// `proxyConfigurations` rather than the older `connectionProxyDictionary`:
    /// the Network-framework configuration resolves names at the proxy the same
    /// way `socks5h` does, and the legacy dictionary's SOCKS support does not
    /// document that it does — which is not a thing to be vague about when the
    /// entire point of the setting is that nothing local learns the hostname.
    func urlSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.proxyConfigurations = [ProxyConfiguration(socksv5Proxy: endpoint)]
        // Ephemeral, and caching off: a cache on disk would outlive the proxied
        // session and record what was fetched through it.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }

    enum Failure: LocalizedError {
        case unreachable(String)
        case notSOCKS5
        case cannotReach(host: String, code: UInt8)

        var errorDescription: String? {
            switch self {
            case .unreachable(let why):
                return "Could not reach the proxy: \(why). Start Tor, or turn proxy routing off."
            case .notSOCKS5:
                return "Something is listening on that port, but it is not a SOCKS5 proxy."
            case let .cannotReach(host, code):
                // 0x04 is "host unreachable", which is what Tor answers while
                // it is still building its first circuit — not a broken proxy,
                // just one that is not ready.
                if code == 0x04 {
                    return "The proxy is running but cannot reach the network yet."
                }
                return "The proxy refused to connect to \(host) (SOCKS status \(code))."
            }
        }
    }

    /// Opens a connection and speaks SOCKS5's opening exchange.
    ///
    /// The client greeting is version 5, one method offered, method 0 — "no
    /// authentication". A SOCKS5 server replies with two bytes: the version it
    /// agreed on, and the method it picked. Anything else on the wire is not a
    /// SOCKS5 server, and `0xFF` back means it is one but wants credentials
    /// this has no way to supply.
    /// - Parameter reaching: a host to ask the proxy to connect to. Supplying
    ///   one turns this from "something is listening" into "the proxy can
    ///   actually carry traffic", which for Tor are minutes apart: it opens its
    ///   SOCKS listener immediately and cannot route anything until it has a
    ///   consensus and descriptors. A readiness check that stops at the
    ///   handshake reports "Connected" about a second after launch and every
    ///   download started then fails.
    func verify(timeout: Duration = .seconds(5), reaching host: String? = nil) async throws {
        let connection = NWConnection(to: endpoint, using: .tcp)
        defer { connection.cancel() }

        // The deadline cancels the connection, rather than racing a
        // `Task.sleep` against the work in a task group.
        //
        // That task-group version hung: the first probe never returned and the
        // timeout child never fired either, so Tor's status would have sat on
        // "Connecting…" forever and every download waiting on it would have
        // waited forever too. Cancelling the connection makes whatever is
        // pending on it fail, which is the same outcome through a mechanism
        // with one moving part instead of three.
        let deadline = DispatchWorkItem { connection.forceCancel() }
        DispatchQueue.global().asyncAfter(
            deadline: .now() + .milliseconds(Int(timeout.components.seconds * 1000)),
            execute: deadline)
        defer { deadline.cancel() }

        try await Self.handshake(over: connection)
        if let host {
            try await Self.connect(to: host, port: 443, over: connection)
        }
    }

    private static func handshake(over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, any Error>) in
            // `resumed` guards against the state handler firing twice — it is
            // called for every transition, and `.failed` after `.ready` is an
            // ordinary sequence.
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Result<Void, any Error>) -> Void = { result in
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { ready.resume(with: result) }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.success(()))
                case .failed(let error):
                    finish(.failure(Failure.unreachable(error.localizedDescription)))
                case .cancelled:
                    finish(.failure(Failure.unreachable("the connection was closed")))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }

        // Version 5, one method, "no authentication".
        try await send(Data([0x05, 0x01, 0x00]), over: connection)
        let reply = try await receive(2, from: connection)
        guard reply.count == 2, reply[0] == 0x05 else { throw Failure.notSOCKS5 }
        guard reply[1] != 0xFF else {
            throw Failure.unreachable("the proxy requires authentication")
        }
    }

    /// Asks the proxy to open a connection, and reads what it says about it.
    ///
    /// The request is version 5, command 1 (connect), address type 3 (a domain
    /// name, so the *proxy* resolves it and nothing local learns the hostname).
    /// The reply's second byte is the status: 0 succeeded, and everything else
    /// is a refusal worth repeating.
    private static func connect(
        to host: String, port: UInt16, over connection: NWConnection
    ) async throws {
        var request = Data([0x05, 0x01, 0x00, 0x03])
        let name = Array(host.utf8.prefix(255))
        request.append(UInt8(name.count))
        request.append(contentsOf: name)
        request.append(UInt8(port >> 8))
        request.append(UInt8(port & 0xFF))
        try await send(request, over: connection)

        // Version, status, reserved, address type — then an address whose
        // length depends on that type. Only the status is needed.
        let reply = try await receive(4, from: connection)
        guard reply.count == 4, reply[reply.startIndex] == 0x05 else {
            throw Failure.notSOCKS5
        }
        let status = reply[reply.startIndex + 1]
        guard status == 0x00 else {
            throw Failure.cannotReach(host: host, code: status)
        }
    }

    private static func send(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (sent: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    sent.resume(throwing: Failure.unreachable(error.localizedDescription))
                } else {
                    sent.resume()
                }
            })
        }
    }

    private static func receive(_ count: Int, from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { (got: CheckedContinuation<Data, any Error>) in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) {
                data, _, _, error in
                if let error {
                    got.resume(throwing: Failure.unreachable(error.localizedDescription))
                } else {
                    got.resume(returning: data ?? Data())
                }
            }
        }
    }
}
