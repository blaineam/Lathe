import AppKit
import ServiceManagement
import SwiftUI

/// Whether Lathe is an app you switch to, or one that just sits there.
///
/// ## Why this is a real choice and not a preference nobody uses
///
/// A downloader is background work. Once a queue is running there is nothing to
/// look at, and an icon in the Dock for something that is only occasionally
/// interacted with is clutter. But it is also an app with a browser in it, and
/// a browser with no Dock icon and no window is a strange thing to own.
///
/// So both, and the user says which.
@MainActor
@Observable
final class Presence {

    enum Style: String, CaseIterable, Identifiable, Sendable {
        /// An ordinary app: Dock icon, menu bar, appears in the switcher.
        case dock
        /// A menu bar item and nothing else. No Dock icon, no ⌘-Tab entry.
        case menuBar

        var id: String { rawValue }

        var label: String {
            switch self {
            case .dock: return "In the Dock"
            case .menuBar: return "Menu bar only"
            }
        }

        var explanation: String {
            switch self {
            case .dock:
                return "An ordinary app, with a Dock icon and a place in the "
                    + "app switcher."
            case .menuBar:
                return "No Dock icon and no switcher entry — just the menu bar "
                    + "item. The window is still there when you want it."
            }
        }

        /// What AppKit calls this.
        ///
        /// `.accessory` rather than `.prohibited`: prohibited apps cannot be
        /// activated at all, so the window could never come forward and the
        /// browser would be unusable.
        var activationPolicy: NSApplication.ActivationPolicy {
            self == .dock ? .regular : .accessory
        }
    }

    private static let styleKey = "presence.style"

    var style: Style {
        didSet {
            guard style != oldValue else { return }
            UserDefaults.standard.set(style.rawValue, forKey: Self.styleKey)
            apply()
        }
    }

    /// Whether the menu bar item is showing.
    ///
    /// Always, in menu-bar mode — it is the only way back to the app. In Dock
    /// mode it is optional, because some people want both and some find a
    /// second entry point redundant.
    var showsMenuBarItem: Bool {
        didSet {
            UserDefaults.standard.set(showsMenuBarItem, forKey: "presence.menuBarItem")
        }
    }

    var menuBarItemIsVisible: Bool { style == .menuBar || showsMenuBarItem }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.styleKey)
        style = stored.flatMap(Style.init(rawValue:)) ?? .dock
        showsMenuBarItem = UserDefaults.standard.object(forKey: "presence.menuBarItem") as? Bool
            ?? true
    }

    /// Tells AppKit what kind of app this is.
    ///
    /// Safe to call repeatedly, and safe to call at any point after launch:
    /// the policy can be changed while running, which is what makes this a
    /// setting rather than a relaunch.
    func apply() {
        NSApp.setActivationPolicy(style.activationPolicy)
        if style == .dock {
            // Coming back to the Dock without this leaves the app running with
            // an icon nobody can click, because it is not frontmost and has no
            // way to be made so.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Login

    /// Whether macOS starts Lathe when the user logs in.
    ///
    /// `SMAppService` rather than a login item in the user's preferences: the
    /// old mechanism was deprecated in Ventura, and the new one is a
    /// registration the system owns, visible to the user in System Settings
    /// where they can revoke it. An app that installs something they cannot
    /// find and remove is one they will uninstall.
    var startsAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Whether the user has been asked to approve it.
    var loginApprovalPending: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    enum LoginFailure: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .failed(let reason):
                return "Could not change the login setting: \(reason)"
            }
        }
    }

    func setStartsAtLogin(_ enabled: Bool) throws {
        do {
            if enabled {
                // Registering an app that is already registered throws, and
                // "already on" is not a failure worth surfacing.
                guard SMAppService.mainApp.status != .enabled else { return }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            throw LoginFailure.failed(error.localizedDescription)
        }
    }
}
