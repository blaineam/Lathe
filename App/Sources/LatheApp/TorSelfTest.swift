import Foundation

/// Starts the embedded Tor client and reports whether it reached the network.
enum TorSelfTest {

    /// Written to standard error, not `print`.
    ///
    /// `print` goes to stdout, which is block-buffered when it is a file or a
    /// pipe rather than a terminal — and this process does not exit on its own,
    /// because the Tor thread keeps it alive. So every line sat in the buffer
    /// and the diagnostic looked exactly like a hang. Standard error is
    /// unbuffered.
    private static func say(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func run() {
        // `dispatchMain()`, not a semaphore and not a hand-rolled run loop.
        //
        // `TorController` is main-actor isolated, so this work has to run on
        // the main thread. Blocking that thread in `DispatchSemaphore.wait()`
        // deadlocks instantly — the task can never be scheduled on the thread
        // that is waiting for it — and a manual `RunLoop.run` does not reliably
        // service the concurrency runtime's main executor either. Both looked
        // exactly like Tor failing to bootstrap, which cost more time than the
        // feature did.
        //
        // `dispatchMain()` parks the main thread on the main queue, which *is*
        // where the main actor runs. It never returns, so the task exits the
        // process when it is done.
        Task { @MainActor in
            guard TorController.isAvailable else {
                say("tor: not built into this binary")
                exit(1)
            }
            let controller = TorController()
            say("tor: starting on port \(controller.socksPort)…")
            let started = Date()
            await controller.start()
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))

            switch controller.state {
            case .running:
                say("tor: connected in \(elapsed)s")
                // Reaching the SOCKS port only proves the daemon is listening.
                // Fetching something through it proves it reached the network,
                // which is the claim that matters.
                do {
                    let session = controller.endpoint.urlSession()
                    let (data, _) = try await session.data(
                        from: URL(string: "https://check.torproject.org/api/ip")!)
                    say("tor: check.torproject.org says \(String(decoding: data, as: UTF8.self))")
                } catch {
                    say("tor: listening, but the request failed: \(error.localizedDescription)")
                }
            default:
                say("tor: \(controller.state.label) after \(elapsed)s")
            }
            // `tor_run_main` never returns, so its thread would keep this
            // process alive forever after the diagnostic has said its piece.
            exit(0)
        }
        dispatchMain()
    }
}
