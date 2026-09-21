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
                + "Nothing to install, and it goes quiet when you turn routing off."
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
    /// The owning controller's socket, pre-authenticated by Tor. Bootstrap
    /// progress arrives on it, and it is how the client is put to sleep and
    /// woken: `tor_run_main` cannot safely be run twice in one process, so the
    /// daemon is started once and parked rather than stopped.
    private var control: Int32 = -1
    /// Tor's own bootstrap percentage, from the control socket.
    private var bootstrapPercent = 0
    #endif

    func start() async {
        #if !LATHE_EMBEDDED_TOR
        state = .unavailable
        #else
        switch state {
        case .starting, .bootstrapping, .running: return
        default: break
        }

        // Already running from an earlier start: wake it rather than launching
        // a second daemon in the same process, which Tor does not support.
        if thread != nil {
            send("SIGNAL ACTIVE")
            state = .bootstrapping(bootstrapPercent)
            await waitForSOCKS()
            return
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
        let configuration = tor_main_configuration_new()
        guard configuration != nil else {
            state = .failed("Tor would not accept a configuration")
            return
        }
        tor_main_configuration_set_command_line(configuration, Int32(argv.count), &argv)
        control = tor_main_configuration_setup_control_socket(configuration)

        // The configuration is handed to exactly one thread and never touched
        // here again, which is what makes sending the raw pointer sound.
        nonisolated(unsafe) let handed = configuration
        let thread = Thread { [weak self] in
            // Blocks until the daemon exits.
            let code = tor_run_main(handed)
            Task { @MainActor in self?.daemonExited(code: code) }
        }
        thread.name = "Lathe.Tor"
        thread.stackSize = 4 * 1024 * 1024
        self.thread = thread
        thread.start()

        if control >= 0 { watchBootstrap(on: control) }

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
        // There is no supported way to run `tor_run_main` a second time, so
        // the daemon is parked rather than ended: DORMANT closes its circuits
        // and stops it touching the network until it is woken.
        send("SIGNAL DORMANT")
        state = .off
        #endif
    }

    /// After the app comes back from the background.
    ///
    /// iOS suspends the whole process, Tor's thread included, and the network
    /// underneath its circuits may be gone by the time it resumes. Waking it
    /// and proving a connection again is cheaper than finding out from a
    /// failed download.
    func resume() async {
        #if LATHE_EMBEDDED_TOR
        guard thread != nil else { return }
        switch state {
        case .off, .failed, .unavailable: return
        default: break
        }
        send("SIGNAL ACTIVE")
        state = .bootstrapping(bootstrapPercent)
        await waitForSOCKS()
        #endif
    }

    #if LATHE_EMBEDDED_TOR
    private func waitForSOCKS() async {
        let probe = endpoint
        // Tor on a warm data directory answers in a second or two; a cold one
        // has to fetch a consensus first, which is the slow case this waits
        // out rather than declaring a failure it would recover from.
        let tracing = ProcessInfo.processInfo.arguments.contains("--tor-selftest")
        for attempt in 0..<90 {
            if Task.isCancelled || state == .off { return }
            if case .failed = state { return }
            do {
                try await probe.verify(timeout: .seconds(4), reaching: "check.torproject.org")
                state = .running
                return
            } catch {
                if tracing {
                    FileHandle.standardError.write(Data(
                        "tor: probe \(attempt) at \(bootstrapPercent)%: \(error.localizedDescription)\n".utf8))
                }
                // Tor's own figure when there is one; an estimate otherwise.
                let percent = control >= 0 ? bootstrapPercent : attempt * 100 / 90
                state = .bootstrapping(min(99, percent))
                try? await Task.sleep(for: .seconds(1))
            }
        }
        state = .failed("it did not finish connecting (bootstrap stopped at \(bootstrapPercent)%)")
    }

    private func daemonExited(code: Int32) {
        thread = nil
        if control >= 0 { close(control); control = -1 }
        if state != .off { state = .failed("Tor stopped (exit \(code))") }
    }

    private func send(_ command: String) {
        guard control >= 0 else { return }
        let bytes = Array((command + "\r\n").utf8)
        _ = bytes.withUnsafeBytes { write(control, $0.baseAddress, $0.count) }
    }

    /// Reads `650 STATUS_CLIENT NOTICE BOOTSTRAP PROGRESS=NN …` events off the
    /// control socket on a thread of its own, since the read blocks.
    private func watchBootstrap(on descriptor: Int32) {
        send("SETEVENTS STATUS_CLIENT")
        // Events only report changes; a warm data directory can be most of the
        // way there before the first one. Ask for where it is now as well.
        send("GETINFO status/bootstrap-phase")
        Thread.detachNewThread { [weak self] in
            var pending = Data()
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(descriptor, &chunk, chunk.count)
                if count <= 0 { return }
                pending.append(contentsOf: chunk[0..<count])
                while let end = pending.range(of: Data([0x0d, 0x0a])) {
                    let line = String(decoding: pending[pending.startIndex..<end.lowerBound], as: UTF8.self)
                    pending.removeSubrange(pending.startIndex..<end.upperBound)
                    guard let percent = Self.bootstrapProgress(in: line) else { continue }
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.bootstrapPercent = percent
                        if case .bootstrapping = self.state {
                            self.state = .bootstrapping(min(99, percent))
                        } else if self.state == .starting {
                            self.state = .bootstrapping(min(99, percent))
                        }
                    }
                }
            }
        }
    }

    nonisolated static func bootstrapProgress(in line: String) -> Int? {
        guard line.contains("BOOTSTRAP"), let marker = line.range(of: "PROGRESS=") else { return nil }
        return Int(line[marker.upperBound...].prefix { $0.isNumber })
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
