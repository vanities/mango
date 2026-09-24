import WebKit
import XCTest
@testable import Mango

@MainActor
final class NovelPaginationTests: XCTestCase {
    private final class Messages: NSObject, WKScriptMessageHandler {
        var actions: [String] = []
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? [String: Any], let action = body["action"] as? String { actions.append(action) }
        }
    }

    func testRealWebKitPageTurnsBoundariesSelectionAndReflow() async throws {
        let files = [
            "META-INF/container.xml": "<container><rootfiles><rootfile full-path='book.opf'/></rootfiles></container>",
            "book.opf": "<package><manifest><item id='ch' href='ch.xhtml' media-type='application/xhtml+xml'/></manifest><spine><itemref idref='ch'/></spine></package>",
            "ch.xhtml": "<html><body>Fixture</body></html>"
        ]
        let zip = ZipTestBuilder.make(files.map { .init(name: $0.key, data: Data($0.value.utf8), deflate: false) })
        let document = try await EPUBDocument.open(reader: DataReader(zip), displayName: "Test")
        var view = NovelWebView(document: document, chapterPath: "ch.xhtml", fontScale: 1, dark: true,
                                paged: true, tapToTurn: true, fontFamily: "Georgia, serif", lineSpacing: 1.6,
                                margin: 22, restoreFraction: 0, onScroll: { _ in }, onTapMiddle: {},
                                onNextChapter: {}, onPreviousChapter: {}, onReachedBottom: {})
        let messages = Messages()
        let config = WKWebViewConfiguration()
        config.userContentController.add(messages, name: "mangoNavigation")
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: config)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = web.bounds
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(web)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let paragraphs = (0..<100).map { "<p id='p\($0)'>Paragraph \($0). The traveler crossed the quiet garden and opened the old wooden gate.</p>" }.joined()
        web.loadHTMLString("<html><head><meta name='viewport' content='width=device-width, initial-scale=1'/><style>\(view.css)</style></head><body>\(paragraphs)</body></html>", baseURL: nil)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("document.querySelectorAll('p').length")) as? Int == 100, !web.isLoading { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = try await web.evaluateJavaScript(view.paginationScript)
        try await Task.sleep(for: .milliseconds(150))
        let count = try await number("mangoPager.count", web)
        XCTAssertGreaterThan(count, 3)
        _ = try await web.evaluateJavaScript("document.body.dispatchEvent(new MouseEvent('click', {bubbles:true, clientX:380, detail:1}))")
        let actual1 = try await number("mangoPager.page", web)
        XCTAssertEqual(actual1, 1)
        let actual2 = try await number("window.scrollX", web)
        XCTAssertEqual(actual2, 390, accuracy: 1)
        _ = try await web.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowLeft'}))")
        let actual3 = try await number("mangoPager.page", web)
        XCTAssertEqual(actual3, 0)
        _ = try await web.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowLeft'}))")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(messages.actions.contains("previous"))
        _ = try await web.evaluateJavaScript("mangoPager.page=mangoPager.count-1; document.dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowRight'}))")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(messages.actions.contains("next"))
        _ = try await web.evaluateJavaScript("mangoPager.fraction=0.5; mangoPager.layout()")
        try await Task.sleep(for: .milliseconds(50))
        let beforeSwipe = try await number("mangoPager.page", web)
        _ = try await web.evaluateJavaScript("""
        var start = new Touch({identifier:1,target:document.body,clientX:300,clientY:300});
        var end = new Touch({identifier:1,target:document.body,clientX:100,clientY:305});
        document.body.dispatchEvent(new TouchEvent('touchstart',{bubbles:true,touches:[start]}));
        document.body.dispatchEvent(new TouchEvent('touchend',{bubbles:true,changedTouches:[end]}));
        """)
        let afterSwipe = try await number("mangoPager.page", web)
        XCTAssertEqual(afterSwipe, beforeSwipe + 1)
        let beforeLink = try await number("mangoPager.page", web)
        _ = try await web.evaluateJavaScript("const link=document.createElement('a');link.href='#p2';document.body.appendChild(link);link.addEventListener('click',e=>e.preventDefault());link.dispatchEvent(new MouseEvent('click',{bubbles:true,clientX:380,detail:1}));link.remove()")
        let afterLink = try await number("mangoPager.page", web)
        XCTAssertEqual(beforeLink, afterLink)
        _ = try await web.evaluateJavaScript("mangoPager.fraction=0.5; mangoPager.layout()")
        view.fontScale = 1.8
        _ = try await web.evaluateJavaScript("document.querySelector('style').textContent = \(String(data: try JSONEncoder().encode(view.css), encoding: .utf8)!); mangoPager.layout()")
        try await Task.sleep(for: .milliseconds(150))
        let actual4 = try await number("mangoPager.count", web)
        XCTAssertGreaterThan(actual4, count)
        let actual5 = try await number("mangoPager.fraction", web)
        XCTAssertEqual(actual5, 0.5, accuracy: 0.1)
        _ = try await web.evaluateJavaScript("const r=document.createRange();r.selectNodeContents(document.querySelector('p'));getSelection().addRange(r)")
        let page = try await number("mangoPager.page", web)
        _ = try await web.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowRight'}))")
        let actual6 = try await number("mangoPager.page", web)
        XCTAssertEqual(actual6, page)
    }

    private func number(_ expression: String, _ web: WKWebView) async throws -> Double {
        let value = try await web.evaluateJavaScript(expression)
        return try XCTUnwrap(value as? NSNumber).doubleValue
    }
}
