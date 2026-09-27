import WebKit
import XCTest
@testable import Mango

@MainActor
final class NovelHighlightTests: XCTestCase {
    private final class Messages: NSObject, WKScriptMessageHandler {
        var anchor: [String: Any]?
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            anchor = (message.body as? [String: Any])?["anchor"] as? [String: Any]
        }
    }
    func testSelectionHighlightSurvivesTypographyAndRepeatedQuotesAreNotGuessed() async throws {
        let config = WKWebViewConfiguration(), messages = Messages()
        config.userContentController.add(messages, name: "mangoNavigation")
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: config)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller; controller.view.addSubview(web); window.makeKeyAndVisible()
        defer { window.isHidden = true }
        web.loadHTMLString("<html><body><p>Before the garden.</p><p id='quote'>A remembered passage.</p><p>After the garden.</p></body></html>", baseURL: nil)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("document.getElementById('quote') !== null")) as? Bool == true, !web.isLoading { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = try await web.evaluateJavaScript(NovelTextScript.source)
        _ = try await web.evaluateJavaScript("var r=document.createRange(); r.selectNodeContents(document.getElementById('quote').firstChild); window.getSelection().removeAllRanges(); window.getSelection().addRange(r)")
        for _ in 0..<40 where messages.anchor == nil { try await Task.sleep(for: .milliseconds(25)) }
        let anchor = try XCTUnwrap(messages.anchor)
        XCTAssertEqual(anchor["quote"] as? String, "A remembered passage.")
        let json = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: anchor), encoding: .utf8))
        _ = try await web.evaluateJavaScript("mangoText.paint([\(json)]); document.body.style.fontSize='32px'; document.body.style.columnWidth='240px'; window.getSelection().removeAllRanges()")
        let highlighted = try await web.evaluateJavaScript("Array.from(CSS.highlights.get('mango'))[0].toString()") as? String
        XCTAssertEqual(highlighted, "A remembered passage.")
        let jumped = try await web.evaluateJavaScript("mangoText.jump(\(json))") as? Bool
        XCTAssertEqual(jumped, true)
        let ambiguous = try await web.evaluateJavaScript("mangoText.locate({quote:'same', offset:99, prefix:'', suffix:''}, 'same and same')") as? Int
        XCTAssertEqual(ambiguous, -1)
        let contextual = try await web.evaluateJavaScript("mangoText.locate({quote:'same', offset:99, prefix:'and ', suffix:''}, 'same and same')") as? Int
        XCTAssertEqual(contextual, 9)
    }
}
