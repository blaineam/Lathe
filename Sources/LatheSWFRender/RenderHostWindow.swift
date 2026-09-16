import Foundation
import WebKit

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Puts the render host's WebView into a real window, positioned where nobody
/// will see it.
///
/// ## Why an offscreen window rather than no window at all
///
/// The reflex is to render "headless": make a `WKWebView`, never add it to
/// anything, read pixels out of it. It does not reliably work, and the reason is
/// worth stating because the failure it produces is a frozen first frame rather
/// than an error.
///
/// **A view that is in no window may never composite**, and when nothing
/// composites, `requestAnimationFrame` is not called. Ruffle's player loop is
/// driven by that callback — as is nearly every WebAssembly renderer on the web
/// — so an unattached host does not merely fail to *capture* the animation, it
/// fails to *advance* it. Every frame comes back identical, and identical frames
/// look exactly like a movie that has nothing moving in it.
///
/// So the view goes into a window placed far outside any screen. It is a real
/// window that the compositor services and no person ever sees.
///
/// ## Best effort, and reported as such
///
/// On macOS this always works. On iOS a window needs a `UIWindowScene` to belong
/// to, and a process that has none — a unit-test bundle, an extension, an app
/// that has not finished launching — cannot make one. Attachment therefore
/// *reports* whether it succeeded rather than throwing, and
/// ``SWFRenderResult/compositedInAWindow`` carries the answer to the caller,
/// because it is the first thing to look at when a capture comes back frozen.
/// The page's own capture path has a timeout fallback for exactly this case; it
/// gets a frame out, and it cannot make a stalled player advance.
@MainActor
final class RenderHostWindow {

    /// Far enough outside any plausible display arrangement that the window
    /// cannot land on a screen, while staying well inside the coordinate range.
    private static let offscreenOrigin = CGPoint(x: -30_000, y: -30_000)

    #if canImport(AppKit)
    private var window: NSWindow?
    #elseif canImport(UIKit)
    private var window: UIWindow?
    #endif

    /// Attaches the view, returning whether a window was actually obtained.
    @discardableResult
    func attach(_ webView: WKWebView, size: CGSize) -> Bool {
        let frame = CGRect(origin: Self.offscreenOrigin, size: size)

        #if canImport(AppKit)
        let window = NSWindow(
            contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false
        )
        // Without this, closing or releasing the window while the WebView is
        // still finishing a navigation is a use-after-free rather than an error.
        window.isReleasedWhenClosed = false
        window.isExcludedFromWindowsMenu = true
        window.contentView?.addSubview(webView)
        webView.frame = CGRect(origin: .zero, size: size)
        // `orderBack` rather than `makeKeyAndOrderFront`: the window must be
        // composited, and must never steal focus from the application that
        // happens to be hosting this render.
        window.orderBack(nil)
        self.window = window
        return true

        #elseif canImport(UIKit)
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        guard let scene else { return false }

        let window = UIWindow(windowScene: scene)
        window.frame = frame
        // Below every ordinary window, so that even if the geometry were wrong
        // this could not appear over the host application's interface.
        window.windowLevel = .normal - 1
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(webView)
        webView.frame = CGRect(origin: .zero, size: size)
        window.isHidden = false
        self.window = window
        return true

        #else
        return false
        #endif
    }

    func detach(_ webView: WKWebView) {
        webView.removeFromSuperview()
        #if canImport(AppKit)
        window?.orderOut(nil)
        window?.contentView = nil
        #elseif canImport(UIKit)
        window?.isHidden = true
        window?.rootViewController = nil
        #endif
        window = nil
    }
}
