import AppKit
import Foundation
import ServiceManagement

/// Checks whether this build can register itself as a login item.
enum LoginSelfTest {
    private static func say(_ message: String) {
        // Standard error, unbuffered — stdout is block-buffered to a pipe and
        // this process may not live long enough to flush it.
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func run() {
        let service = SMAppService.mainApp
        say("login: status before — \(describe(service.status))")

        do {
            if service.status == .enabled {
                try service.unregister()
                say("login: unregistered, so the test starts from off")
            }
            try service.register()
            say("login: register() succeeded")
        } catch {
            say("login: register() FAILED — \(error.localizedDescription)")
            exit(1)
        }

        say("login: status after — \(describe(SMAppService.mainApp.status))")

        // Left off, because this is a check and not a preference change.
        try? SMAppService.mainApp.unregister()
        say("login: cleaned up, status — \(describe(SMAppService.mainApp.status))")
        exit(0)
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "not registered"
        case .enabled: return "enabled"
        case .requiresApproval: return "waiting for the user to allow it"
        case .notFound: return "not found"
        @unknown default: return "unknown (\(status.rawValue))"
        }
    }
}
