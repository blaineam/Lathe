import AppKit
import SwiftUI

/// Decides what the app looks like before the first window appears.
///
/// ## Why the window is closed rather than the launch detected
///
/// "Start at login, invisibly" sounds like it needs to know whether *this*
/// launch came from the login item. It does not, and trying to find out means
/// inspecting the Apple Event that started the process — a check that is
/// fragile, undocumented in any useful detail, and wrong the first time Apple
/// changes how login items are started.
///
/// The rule that needs no detection: **menu-bar-only mode never opens a window
/// by itself.** Somebody who asked for no Dock icon did not ask for a window
/// in front of what they were doing, whether the app was started by them or by
/// the system. Opening one is then always explicit — from the menu bar item,
/// or by launching the app again.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        let style = Presence.storedStyle
        // Before anything is drawn, so the Dock icon never appears and vanishes.
        NSApp.setActivationPolicy(style.activationPolicy)

        // In background mode the Dock icon follows the windows.
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                // After the close has happened, not while it is happening.
                DispatchQueue.main.async { MainActor.assumeIsolated { Presence.syncDockIcon() } }
            }
        }

        guard style != .dock else { return }
        // SwiftUI has already made the window by this point; there is no scene
        // modifier that suppresses it conditionally at runtime.
        for window in NSApp.windows where window.isVisible {
            window.orderOut(nil)
        }
    }

    /// Clicking the Dock icon, or opening the app again while it runs.
    ///
    /// In background mode this is the way in: the second open is what shows
    /// the window, and the Dock icon with it.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows flag: Bool
    ) -> Bool {
        if Presence.storedStyle == .background {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        guard !flag else { return true }
        // The window hidden at launch still exists; showing it keeps its
        // state. When it has been closed, SwiftUI makes a new one.
        if let main = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) {
            main.makeKeyAndOrderFront(nil)
            return false
        }
        return true
    }

    /// Closing the window is not quitting.
    ///
    /// A downloader with a queue running should keep running, and in
    /// menu-bar-only mode there is no window to close back to in the first
    /// place — terminating there would make the menu bar item disappear the
    /// moment somebody tidied their screen.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
