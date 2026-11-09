import Foundation
import Testing
import WebKit

@testable import LatheSWFRender

/// The allowlist is what keeps an untrusted movie's page from navigating away.
///
/// WebKit's delegate methods are optional and found at run time, so a signature
/// that does not quite match the protocol compiles with only a warning, and
/// WebKit then allows every navigation without asking. Hence a real navigation
/// and not only a call to the method, which would pass either way.
@Suite("SWF render navigation policy")
@MainActor
struct NavigationPolicyTests {

    private let marker = "lathe-navigation-reached"

    private func bodyText(afterLoading url: URL, allowing schemes: Set<String>) async throws -> String {
        let loader = WebViewLoader()
        loader.allowedSchemes = schemes
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        webView.navigationDelegate = loader
        webView.load(URLRequest(url: url))
        // A refused navigation may report nothing at all, so running out of
        // time here is one of the expected outcomes.
        try? await loader.waitForLoad(timeout: .seconds(5))
        let text = try await webView.evaluateJavaScript("document.body ? document.body.innerText : ''")
        return (text as? String) ?? ""
    }

    @Test("a scheme outside the allowlist is refused")
    func refusesOtherSchemes() async throws {
        let url = try #require(URL(string: "data:text/html,\(marker)"))
        let text = try await bodyText(afterLoading: url, allowing: ["lathe-swf"])
        #expect(!text.contains(marker), "the page navigated to a scheme the allowlist does not name")
    }

    @Test("a scheme on the allowlist loads, so the refusal above is not just a failed load")
    func allowsItsOwnScheme() async throws {
        let url = try #require(URL(string: "data:text/html,\(marker)"))
        let text = try await bodyText(afterLoading: url, allowing: ["data"])
        #expect(text.contains(marker), "got \(text)")
    }
}
