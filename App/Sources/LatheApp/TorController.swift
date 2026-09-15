import Foundation
#if LATHE_EMBEDDED_TOR
import CTorShim
#endif

/// How proxy routing is provided.
enum TorMode: String, CaseIterable, Identifiable, Sendable {
    /// The Tor client inside this app.
    case embedded
    /// A SOCKS5 proxy somewhere else — Tor Browser, a system `tor`, a tunnel.
    case external

    var id: String { rawValue }

    var label: String {
        switch self {
        case .embedded: return "Tor, built in"
        case .external: return "A proxy I run myself"
        }
    }

    var explanation: String {
        switch self {
        case .embedded:
            return "Lathe starts its own Tor client and routes through it. "
                + "Nothing to install, and it stops when you turn routing off."
        case .external:
            return "Point Lathe at a SOCKS5 proxy you already run. 9050 is "
                + "Tor's default; Tor Browser uses 9150 while it is open."
        }
    }
}

/// The Tor client running inside this process.
///
/// ## Why in-process rather than a bundled `tor` binary
///
/// A binary would have to be launched, which means a subprocess — fine on a
/// Mac and impossible on iOS, where this app's engine has to work too. Linking
/// the daemon and calling `tor_run_main` on a thread is the arrangement that
/// works on both, and it is the one the Tor Project's own Apple packaging is
/// built for.
///
/// ## What it is
///
/// `tor_run_main` blocks for the lifetime of the daemon, so it gets a thread of
/// its own. The configuration is a C `argv` whose strings must outlive that
/// thread, because Tor keeps the pointers rather than copying them — hence the
/// storage held here rather than a local array that would be freed on return.
@MainActor
@Observable
final class TorController {

    enum State: Equatable {
        case off
        case starting
        case bootstrapping(Int)
        case running
        case failed(String)
        case unavailable

        var label: String {
            switch self {
            case .off: return "Off"
            case .starting: return "Starting…"
            case .bootstrapping(let percent): return "Connecting… \(percent)%"
            case .running: return "Connected"
            case .failed(let why): return "Failed: \(why)"
            case .unavailable: return "Not built in"
            }
        }

        var isUsable: Bool { self == .running }
    }

    private(set) var state: State = .off

    /// The loopback port the embedded client listens on.
    ///
    /// Deliberately not 9050 or 9150: those belong to a system `tor` and to
    /// Tor Browser, and binding over one of them would either fail or, worse,
    /// quietly capture traffic meant for somebody else's client.
    let socksPort = 39051

    var endpoint: SOCKSProxy { SOCKSProxy(host: "127.0.0.1", port: socksPort) }

    /// Whether this build has the daemon linked at all.
    static var isAvailable: Bool {
        #if LATHE_EMBEDDED_TOR
        return true
        #else
        return false
        #endif
    }

    #if LATHE_EMBEDDED_TOR
    private var thread: Thread?
    /// Backing storage for `argv`. Tor keeps the pointers, so these strings
    /// have to outlive the thread rather than the call that made them.
    private var argv: [UnsafeMutablePointer<CChar>?] = []
    #endif

    func start() async {
        #if !LATHE_EMBEDDED_TOR
        state = .unavailable
        #else
        switch state {
        case .starting, .bootstrapping, .running: return
        default: break
        }
        state = .starting

        let dataDirectory: URL
        do {
            dataDirectory = try Self.dataDirectory()
        } catch {
            state = .failed("could not make a data directory: \(error.localizedDescription)")
            return
        }

        let arguments = [
            "tor",
            "--DataDirectory", dataDirectory.path,
            "--SocksPort", "127.0.0.1:\(socksPort)",
            "--CookieAuthentication", "0",
            // Tor writes its state constantly; on a laptop that is a lot of
            // disk for no benefit to a client that is not a relay.
            "--AvoidDiskWrites", "1",
            "--ClientOnly", "1",
            "--Log", "notice stdout",
        ]

        argv = arguments.map { strdup($0) }
        var configuration = tor_main_configuration_new()
        guard configuration != nil else {
            state = .failed("Tor would not accept a configuration")
            return
        }
        tor_main_configuration_set_command_line(configuration, Int32(argv.count), &argv)

        let thread = Thread { [configuration] in
            // Blocks until the daemon exits.
            _ = tor_run_main(configuration)
        }
        thread.name = "Lathe.Tor"
        thread.stackSize = 4 * 1024 * 1024
        self.thread = thread
        thread.start()

        // Readiness is a real connection through the proxy, not a handshake
        // with it. Tor opens its SOCKS listener about a second after launch
        // and cannot carry anything for a minute or more after that, so a
        // check that stops at the handshake reports "Connected" while every
        // download started against it fails.
        await waitForSOCKS()
        #endif
    }

    func stop() {
        #if LATHE_EMBEDDED_TOR
        // There is no supported way to ask a linked `tor_run_main` to return,
        // so the daemon lives until the process does. Marking it off stops
        // anything new from being routed, and the client costs nothing while
        // idle.
        state = .off
        #endif
    }

    #if LATHE_EMBEDDED_TOR
    private func waitForSOCKS() async {
        let probe = endpoint
        // Tor on a warm data directory answers in a second or two; a cold one
        // has to fetch a consensus first, which is the slow case this waits
        // out rather than declaring a failure it would recover from.
        let tracing = ProcessInfo.processInfo.arguments.contains("--tor-selftest")
        for attempt in 0..<60 {
            if Task.isCancelled { return }
            if tracing {
                FileHandle.standardError.write(Data("tor: probe \(attempt) starting\n".utf8))
            }
            do {
                try await probe.verify(timeout: .seconds(4), reaching: "check.torproject.org")
                state = .running
                return
            } catch {
                if ProcessInfo.processInfo.arguments.contains("--tor-selftest") {
                    FileHandle.standardError.write(
                        Data("tor: probe \(attempt): \(error.localizedDescription)\n".utf8))
                }
                state = .bootstrapping(min(95, attempt * 100 / 60))
                try? await Task.sleep(for: .seconds(1))
            }
        }
        state = .failed("it did not finish connecting")
    }

    private static func dataDirectory() throws -> URL {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lathe/Tor", isDirectory: true)
        // Tor refuses to start on a data directory that anybody else can read.
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return url
    }
    #endif
}
