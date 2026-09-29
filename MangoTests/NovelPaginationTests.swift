import SwiftUI
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
        _ = try await web.evaluateJavaScript(view.paginationScript(startingAt: 0))
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

    private final class Reports {
        var fractions: [Double] = []
    }

    /// The reader feeds every reported position back in as the place to restore to, so the
    /// host does the same: a wrong report while opening changes where the chapter lands.
    private struct PagedChapterHost: View {
        let document: EPUBDocument
        @State var fraction: Double
        let reports: Reports

        var body: some View {
            NovelWebView(document: document, chapterPath: "ch.xhtml", fontScale: 1, dark: false,
                         paged: true, tapToTurn: true, fontFamily: "Georgia, serif", lineSpacing: 1.6,
                         margin: 22, restoreFraction: fraction,
                         onScroll: { fraction = $0; reports.fractions.append($0) },
                         onTapMiddle: {}, onNextChapter: {}, onPreviousChapter: {}, onReachedBottom: {})
                .ignoresSafeArea()
        }
    }

    /// Reopening a book in page mode must land on the page it was closed on. This goes through
    /// the reader's own path: SwiftUI hosts the view, the chapter comes from the EPUB scheme
    /// handler without a viewport tag (as EPUB chapters usually are), and the reader's styles
    /// and pager are injected once it has loaded.
    func testPagedChapterReopensWhereItWasLeft() async throws {
        for saved in [0.6, 0.25] {
            let reports = Reports()
            let (web, window) = try await hostPagedChapter(restoreFraction: saved, reports: reports)
            defer { window.isHidden = true }
            let count = try await number("mangoPager.count", web)
            XCTAssertGreaterThan(count, 5)
            let page = try await number("mangoPager.page", web)
            XCTAssertEqual(page, (saved * (count - 1)).rounded(), accuracy: 1,
                           "Saved at \(saved) of \(Int(count)) pages, but reopened on page \(Int(page)); reports \(reports.fractions)")
            let offset = try await number("window.scrollX", web)
            XCTAssertEqual(offset, page * 390, accuracy: 1, "The page shown must be the pager's page")
            XCTAssertEqual(try XCTUnwrap(reports.fractions.last), saved, accuracy: 1.5 / (count - 1))
            // Every report is saved as the book's progress, so a stray 0 while the chapter loads
            // would overwrite the place the reader left, even if the page shown ends up right.
            XCTAssertGreaterThan(reports.fractions.min() ?? 0, saved / 2,
                                 "Progress reported while opening must not fall back to the start: \(reports.fractions)")
        }
    }

    private func hostPagedChapter(restoreFraction: Double, reports: Reports) async throws -> (WKWebView, UIWindow) {
        let paragraphs = (0..<150).map { "<p>Paragraph \($0). The traveler crossed the quiet garden and opened the old wooden gate.</p>" }.joined()
        let files = [
            "META-INF/container.xml": "<container><rootfiles><rootfile full-path='book.opf'/></rootfiles></container>",
            "book.opf": "<package><manifest><item id='ch' href='ch.xhtml' media-type='application/xhtml+xml'/></manifest><spine><itemref idref='ch'/></spine></package>",
            "ch.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>One</title></head><body>\(paragraphs)</body></html>"
        ]
        let zip = ZipTestBuilder.make(files.map { .init(name: $0.key, data: Data($0.value.utf8), deflate: false) })
        let document = try await EPUBDocument.open(reader: DataReader(zip), displayName: "Resume")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = UIHostingController(rootView: PagedChapterHost(document: document, fraction: restoreFraction, reports: reports))
        window.makeKeyAndVisible()
        var found: WKWebView?
        // Wait for the chapter itself to be paginated — not just for a pager to exist.
        for _ in 0..<200 {
            found = found ?? firstWebView(in: window)
            if let found, (try? await found.evaluateJavaScript("document.querySelectorAll('p').length === 150 && !!window.mangoPager && mangoPager.count > 1")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let web = try XCTUnwrap(found, "The reader's web view never appeared")
        // Fonts and the viewport settle after the first layout; give them time.
        try await Task.sleep(for: .milliseconds(800))
        return (web, window)
    }

    private func firstWebView(in view: UIView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for subview in view.subviews {
            if let web = firstWebView(in: subview) { return web }
        }
        return nil
    }

    func testIllustratedPrologueAtPhoneAndTabletSizes() async throws {
        // Same portrait proportions as the reported prologue, with invented text and art.
        let image = illustration(width: 1127, height: 1600)
        for size in pageSizes {
            try await checkIllustratedChapter(images: "<img src='\(image)'/>", size: size)
        }
    }

    func testConsecutiveIllustrationsAtPhoneAndTabletSizes() async throws {
        let portrait = illustration(width: 1127, height: 1600)
        let landscape = illustration(width: 1600, height: 1127)
        let tall = illustration(width: 600, height: 2400)
        let images = "<img src='\(portrait)'/><img src='\(landscape)'/><img src='\(tall)'/>"
        for size in pageSizes {
            try await checkIllustratedChapter(images: images, size: size)
        }
    }

    func testFinalParagraphMarginDoesNotAddABlankPage() async throws {
        let image = illustration(width: 1127, height: 1600)
        for size in pageSizes {
            try await checkIllustratedChapter(images: "<img src='\(image)'/>", size: size, endsNearBottom: true)
        }
    }

    private var pageSizes: [CGSize] {
        [CGSize(width: 390, height: 700), CGSize(width: 700, height: 390), CGSize(width: 1024, height: 768)]
    }

    private func illustration(width: CGFloat, height: CGFloat) -> String {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).jpegData(withCompressionQuality: 0.5) { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return "data:image/jpeg;base64," + data.base64EncodedString()
    }

    private func checkIllustratedChapter(images: String, size: CGSize, endsNearBottom: Bool = false) async throws {
        let files = [
            "META-INF/container.xml": "<container><rootfiles><rootfile full-path='book.opf'/></rootfiles></container>",
            "book.opf": "<package><manifest><item id='ch' href='ch.xhtml' media-type='application/xhtml+xml'/></manifest><spine><itemref idref='ch'/></spine></package>",
            "ch.xhtml": "<html><body>Fixture</body></html>"
        ]
        let zip = ZipTestBuilder.make(files.map { .init(name: $0.key, data: Data($0.value.utf8), deflate: false) })
        let document = try await EPUBDocument.open(reader: DataReader(zip), displayName: "Illustrated prologue")
        var view = NovelWebView(document: document, chapterPath: "ch.xhtml", fontScale: 1, dark: false,
                                paged: true, tapToTurn: true, fontFamily: "Georgia, serif", lineSpacing: 1.6,
                                margin: 22, restoreFraction: 0, onScroll: { _ in }, onTapMiddle: {},
                                onNextChapter: {}, onPreviousChapter: {}, onReachedBottom: {})
        let messages = Messages()
        let config = WKWebViewConfiguration()
        config.userContentController.add(messages, name: "mangoNavigation")
        let web = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: config)
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.isScrollEnabled = false
        let coordinator = view.makeCoordinator()
        coordinator.webView = web
        web.navigationDelegate = coordinator
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = web.bounds
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(web)
        window.makeKeyAndVisible()
        defer { window.isHidden = true; withExtendedLifetime(coordinator) {} }
        let paragraphs = (0..<40).map { "<p id='p\($0)'>Paragraph \($0). The traveler crossed the quiet garden and opened the old wooden gate.</p>" }
        let body = endsNearBottom
            ? "<div style='break-after:column'>\(images)</div><p id='p39' style='margin-top:0;height:calc(100vh - 133px)'>The last words of the prologue.</p>"
            : paragraphs.prefix(25).joined() + images + paragraphs.suffix(15).joined()
        // Apply the reader style after navigation, exactly as a real EPUB chapter is loaded.
        web.loadHTMLString("<html><head></head><body>\(body)</body></html>", baseURL: nil)
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("!!window.mangoPager && [...document.images].every(i => i.complete && i.naturalWidth > 0)")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        var normalPageCount: Int?
        for scale in (endsNearBottom ? [1.0] : [1.0, 1.8, 1.0]) {
            view.fontScale = scale
            coordinator.parent = view
            coordinator.applyStyle()
            try await Task.sleep(for: .milliseconds(150))
            let fits = try await web.evaluateJavaScript("""
            [...document.images].every(image => {
              const rect = image.getBoundingClientRect();
              return rect.width <= innerWidth - 44 && rect.height <= innerHeight - 128 &&
                Math.abs(rect.width / rect.height - image.naturalWidth / image.naturalHeight) < 0.01;
            })
            """) as? Bool
            XCTAssertEqual(fits, true, "Illustrations must stay whole and proportional at \(size), font \(scale)")
            _ = try await web.evaluateJavaScript("mangoPager.fraction=0; mangoPager.layout()")
            try await Task.sleep(for: .milliseconds(50))
            messages.actions.removeAll()
            let count = Int(try await number("mangoPager.count", web))
            XCTAssertGreaterThan(count, 1)
            if endsNearBottom { XCTAssertEqual(count, 2, "The final paragraph's margin must not create a third, blank page") }
            if scale == 1 {
                if let normalPageCount { XCTAssertEqual(count, normalPageCount, "Shrinking the font must remove the extra pages") }
                normalPageCount = count
            } else if let normalPageCount {
                XCTAssertGreaterThan(count, normalPageCount)
            }
            for page in 0..<count {
                let offset = try await number("window.scrollX", web)
                XCTAssertEqual(offset, Double(page) * size.width, accuracy: 1, "Tap must land on a whole column")
                if page == count - 1 {
                    let lastTextRight = try await number("document.getElementById('p39').getBoundingClientRect().right", web)
                    XCTAssertLessThanOrEqual(lastTextRight, size.width)
                    XCTAssertGreaterThan(lastTextRight, 0)
                }
                try await tap(at: size.width * 0.9, web)
            }
            XCTAssertEqual(messages.actions.filter { $0 == "next" }.count, 1)
            for page in (0..<count).reversed() {
                let offset = try await number("window.scrollX", web)
                XCTAssertEqual(offset, Double(page) * size.width, accuracy: 1)
                try await tap(at: size.width * 0.1, web)
            }
            XCTAssertEqual(messages.actions.filter { $0 == "previous" }.count, 1)
        }
    }

    private func tap(at x: CGFloat, _ web: WKWebView) async throws {
        _ = try await web.evaluateJavaScript("document.body.dispatchEvent(new MouseEvent('click', {bubbles:true, clientX:\(x), detail:1}))")
        // Let WebKit commit the native scroll between gestures, as it does between real taps.
        try await Task.sleep(for: .milliseconds(50))
    }
}
