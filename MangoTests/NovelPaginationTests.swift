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
        let config = NovelWebView.chapterConfiguration()
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

    func testFractionalFacingPageWidthDoesNotCreateAnEmptySpread() async throws {
        let files = [
            "META-INF/container.xml": "<container><rootfiles><rootfile full-path='book.opf'/></rootfiles></container>",
            "book.opf": "<package><manifest><item id='ch' href='ch.xhtml' media-type='application/xhtml+xml'/></manifest><spine><itemref idref='ch'/></spine></package>",
            "ch.xhtml": "<html><body>Fixture</body></html>"
        ]
        let zip = ZipTestBuilder.make(files.map { .init(name: $0.key, data: Data($0.value.utf8), deflate: false) })
        let document = try await EPUBDocument.open(reader: DataReader(zip), displayName: "Fractional viewport")
        let view = NovelWebView(document: document, chapterPath: "ch.xhtml", fontScale: 1, dark: false,
                                paged: true, tapToTurn: true, fontFamily: "Georgia, serif", lineSpacing: 1.6,
                                margin: 22, restoreFraction: 0, onScroll: { _ in }, onTapMiddle: {},
                                onNextChapter: {}, onPreviousChapter: {}, onReachedBottom: {})
        let messages = Messages()
        let config = NovelWebView.chapterConfiguration()
        config.userContentController.add(messages, name: "mangoNavigation")
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 951, height: 635), configuration: config)
        let window = UIWindow(windowScene: try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene))
        window.frame = web.bounds
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(web)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        // WebKit's integer scrollWidth may round above the fractional CSS body width.
        // A chapter that fits must advance to the next chapter, never to a blank spread.
        let css = view.css + "body { width: calc(100vw - 0.5px) !important; }"
        web.loadHTMLString("<html><head><meta name='viewport' content='width=device-width, initial-scale=1'/><style>\(css)</style></head><body><p>The last words of this short chapter.</p></body></html>", baseURL: nil)
        for _ in 0..<100 {
            if !web.isLoading, (try? await web.evaluateJavaScript("!!document.querySelector('p')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        _ = try await web.evaluateJavaScript(view.paginationScript(startingAt: 0))
        let count = try await number("mangoPager.count", web)
        XCTAssertEqual(count, 1, "Subpixel rounding must not add a second, empty spread")
        _ = try await web.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowRight'}))")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(messages.actions.contains("next"))
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
        var widePageMargin: Double? = nil

        var body: some View {
            NovelWebView(document: document, chapterPath: "ch.xhtml", fontScale: 1, dark: false,
                         paged: true, tapToTurn: true, fontFamily: "Georgia, serif", lineSpacing: 1.6,
                         margin: 22, widePageMargin: widePageMargin, restoreFraction: fraction,
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

    func testChapterKeepsItsPlaceAcrossWideNarrowAndShortWindows() async throws {
        let saved = 0.47
        let reports = Reports()
        let (web, window) = try await hostPagedChapter(restoreFraction: saved, reports: reports, widePageMargin: 72)
        defer { window.isHidden = true }
        for size in [CGSize(width: 720, height: 640), CGSize(width: 320, height: 640),
                     CGSize(width: 640, height: 320), CGSize(width: 390, height: 700)] {
            window.frame.size = size
            window.layoutIfNeeded()
            for _ in 0..<100 {
                if abs((try await number("mangoPager.width()", web)) - size.width) < 1 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try await Task.sleep(for: .milliseconds(200))
            let width = try await number("mangoPager.width()", web)
            let count = try await number("mangoPager.count", web)
            let page = try await number("mangoPager.page", web)
            XCTAssertEqual(width, size.width, accuracy: 1)
            XCTAssertGreaterThan(count, 1)
            let columnWidth = try await number("parseFloat(getComputedStyle(document.body).columnWidth)", web)
            if size.width >= 700 && size.width > size.height {
                XCTAssertLessThan(columnWidth, size.width * 0.6, "The open reader shows two facing text pages")
                let gap = try await number("parseFloat(getComputedStyle(document.body).columnGap)", web)
                XCTAssertEqual(gap, 144, accuracy: 1, "The fold clearance applies to the gutter")
            } else {
                XCTAssertGreaterThan(columnWidth, size.width * 0.7, "The compact reader shows one text page")
            }
            let fraction = try await number("mangoPager.fraction", web)
            XCTAssertEqual(fraction, saved, accuracy: 2 / (count - 1))
            let offset = try await number("window.scrollX", web)
            XCTAssertEqual(offset, page * width, accuracy: 1)
            let before = page
            _ = try await web.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowRight'}))")
            let after = try await number("mangoPager.page", web)
            XCTAssertEqual(after, before + 1, "Turning after resize must advance one page")
            _ = try await web.evaluateJavaScript("mangoPager.fraction=\(saved); mangoPager.layout()")
        }
    }

    private func hostPagedChapter(restoreFraction: Double, reports: Reports, widePageMargin: Double? = nil) async throws -> (WKWebView, UIWindow) {
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
        window.rootViewController = UIHostingController(rootView: PagedChapterHost(document: document, fraction: restoreFraction, reports: reports, widePageMargin: widePageMargin))
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
        [CGSize(width: 390, height: 700), CGSize(width: 700, height: 390), CGSize(width: 1024, height: 768), CGSize(width: 1024, height: 1366)]
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
        let config = NovelWebView.chapterConfiguration()
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
            if endsNearBottom {
                let facing = size.width >= 900 || (size.width >= 700 && size.width > size.height)
                XCTAssertEqual(count, facing ? 1 : 2, "The final paragraph's margin must not create a blank page or spread")
            } else {
                XCTAssertGreaterThan(count, 1)
            }
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

    // MARK: The page count is the chapter's, whatever the viewport is doing

    /// Shaped like a light novel's chapter: long, a heading, and no viewport tag of its own —
    /// so it first lays out at WebKit's 980 px default page, until the reader's tag goes in.
    private func longChapter(paragraphs: Int = 150) async throws -> EPUBDocument {
        let text = (0..<paragraphs).map { "<p>Paragraph \($0). The traveler crossed the quiet garden and opened the old wooden gate.</p>" }.joined()
        let files = [
            "META-INF/container.xml": "<container><rootfiles><rootfile full-path='book.opf'/></rootfiles></container>",
            "book.opf": "<package><manifest><item id='ch' href='ch.xhtml' media-type='application/xhtml+xml'/></manifest><spine><itemref idref='ch'/></spine></package>",
            "ch.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>Twenty</title></head><body><h1>Chapter 20</h1>\(text)</body></html>"
        ]
        let zip = ZipTestBuilder.make(files.map { .init(name: $0.key, data: Data($0.value.utf8), deflate: false) })
        return try await EPUBDocument.open(reader: DataReader(zip), displayName: "Long chapter")
    }

    private let phone = CGSize(width: 402, height: 874)

    private func pagedView(_ document: EPUBDocument) -> NovelWebView {
        NovelWebView(document: document, chapterPath: "ch.xhtml", fontScale: 1, dark: true,
                     paged: true, tapToTurn: true, fontFamily: "Georgia, serif", lineSpacing: 1.6,
                     margin: 22, restoreFraction: 0, onScroll: { _ in }, onTapMiddle: {},
                     onNextChapter: {}, onPreviousChapter: {}, onReachedBottom: {})
    }

    /// A web view that loads chapters through the EPUB scheme handler, as the reader's does.
    private func chapterWebView(_ document: EPUBDocument, size: CGSize, messages: Messages,
                                atDocumentStart script: String? = nil) throws -> (WKWebView, UIWindow) {
        let config = NovelWebView.chapterConfiguration()
        config.setURLSchemeHandler(EPUBSchemeHandler(document: document), forURLScheme: EPUBSchemeHandler.scheme)
        config.userContentController.add(messages, name: "mangoNavigation")
        if let script {
            config.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        let web = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: config)
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.isScrollEnabled = false
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = web.bounds
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(web)
        window.makeKeyAndVisible()
        return (web, window)
    }

    private func waitFor(_ condition: String, in web: WKWebView) async throws {
        for _ in 0..<200 {
            if (try? await web.evaluateJavaScript(condition)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Timed out waiting for \(condition)")
    }

    /// How many pages of `width` the chapter's text actually fills, from where its last line ends.
    private func pagesOfText(_ web: WKWebView, width: CGFloat) async throws -> Int {
        let right = try await number("""
        (() => { const r = document.createRange(); r.selectNodeContents(document.body);
          return Math.max(...[...r.getClientRects()].map(x => x.right + window.scrollX)); })()
        """, web)
        return Int(((right - 1) / width).rounded(.down)) + 1
    }

    /// Taps through the chapter from its first page: every page must be shown, at a whole
    /// page's offset, before the reader moves on to the next chapter — and then exactly once.
    private func tapThrough(_ web: WKWebView, messages: Messages, pages: Int, width: CGFloat,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        messages.actions.removeAll()
        for page in 0..<pages {
            XCTAssertFalse(messages.actions.contains("next"),
                           "Left the chapter after \(page) of its \(pages) pages", file: file, line: line)
            if messages.actions.contains("next") { return }
            let offset = try await number("window.scrollX", web)
            XCTAssertEqual(offset, Double(page) * width, accuracy: 1, "Page \(page) must be shown whole", file: file, line: line)
            try await tap(at: width * 0.9, web)
        }
        XCTAssertEqual(messages.actions.filter { $0 == "next" }.count, 1,
                       "The turn past the last page moves on to the next chapter", file: file, line: line)
    }

    /// Reported on Redo of Healer's chapter 20: tap-to-turn jumped to the epilogue about halfway
    /// through. Just after the reader's styles go in, `window.innerWidth` — the *visual*
    /// viewport, which iOS updates asynchronously from the UI process — can still read WebKit's
    /// 980 px default page while the layout viewport (and every column) is already the phone's
    /// 402. A chapter measured then came out 9 pages long instead of 21, and WebKit sends no
    /// resize event when the value settles, so the count stuck.
    func testPageCountIgnoresAVisualViewportThatHasntCaughtUp() async throws {
        let document = try await longChapter()
        let messages = Messages()
        let lag = """
        (() => {
          const real = Object.getOwnPropertyDescriptor(window, 'innerWidth') || Object.getOwnPropertyDescriptor(Window.prototype, 'innerWidth');
          window.mangoTestViewportLags = true;
          Object.defineProperty(window, 'innerWidth', { configurable: true, get() { return window.mangoTestViewportLags ? 980 : real.get.call(window); } });
        })();
        """
        let (web, window) = try chapterWebView(document, size: phone, messages: messages, atDocumentStart: lag)
        defer { window.isHidden = true }
        let coordinator = pagedView(document).makeCoordinator()
        coordinator.webView = web
        web.navigationDelegate = coordinator
        defer { withExtendedLifetime(coordinator) {} }
        web.load(URLRequest(url: try XCTUnwrap(EPUBSchemeHandler.url(for: "ch.xhtml"))))
        try await waitFor("!!window.mangoPager && mangoPager.count > 1", in: web)
        // The visual viewport catches up — and, as in WebKit, nothing announces it.
        _ = try await web.evaluateJavaScript("window.mangoTestViewportLags = false")
        try await Task.sleep(for: .milliseconds(200))
        let pages = try await pagesOfText(web, width: phone.width)
        XCTAssertGreaterThan(pages, 10)
        let count = try await number("mangoPager.count", web)
        XCTAssertEqual(Int(count), pages, "The pager must count the pages the chapter fills")
        try await tapThrough(web, messages: messages, pages: pages, width: phone.width)
    }

    /// The same chapter when the viewport changes after the pager has measured: laid out at
    /// WebKit's 980 px default until the reader's viewport tag takes effect. WebKit sends no
    /// `resize` event for that — the view itself didn't change size — so the pager has to notice
    /// that its pages did.
    func testPagerFollowsAViewportTagThatTakesEffectLate() async throws {
        let document = try await longChapter()
        let messages = Messages()
        let (web, window) = try chapterWebView(document, size: phone, messages: messages)
        defer { window.isHidden = true }
        web.load(URLRequest(url: try XCTUnwrap(EPUBSchemeHandler.url(for: "ch.xhtml"))))
        try await waitFor("document.readyState === 'complete' && document.querySelectorAll('p').length === 150", in: web)
        let view = pagedView(document)
        let css = String(data: try JSONEncoder().encode(view.css), encoding: .utf8)!
        _ = try await web.evaluateJavaScript("const s = document.createElementNS('http://www.w3.org/1999/xhtml', 'style'); s.textContent = \(css); document.head.appendChild(s); true")
        _ = try await web.evaluateJavaScript(view.paginationScript(startingAt: 0))
        let wide = try await number("document.body.getBoundingClientRect().width", web)
        XCTAssertGreaterThan(wide, phone.width * 2, "Without a viewport tag the chapter lays out at WebKit's desktop width")
        _ = try await web.evaluateJavaScript("""
        const m = document.createElementNS('http://www.w3.org/1999/xhtml', 'meta');
        m.setAttribute('name', 'viewport'); m.setAttribute('content', 'width=device-width, initial-scale=1.0');
        document.head.appendChild(m); true
        """)
        try await Task.sleep(for: .milliseconds(600))
        let pages = try await pagesOfText(web, width: phone.width)
        XCTAssertGreaterThan(pages, 10)
        let count = try await number("mangoPager.count", web)
        XCTAssertEqual(Int(count), pages, "The pager must re-count once the pages are the phone's")
        try await tapThrough(web, messages: messages, pages: pages, width: phone.width)
    }

    /// Whatever else leaves the count stale (text that reflows with no event to say so), the
    /// last tap in a chapter mustn't be the one that skips the rest of it.
    func testChapterIsNotLeftWhileTextRemains() async throws {
        let document = try await longChapter(paragraphs: 60)
        let messages = Messages()
        let (web, window) = try chapterWebView(document, size: phone, messages: messages)
        defer { window.isHidden = true }
        let coordinator = pagedView(document).makeCoordinator()
        coordinator.webView = web
        web.navigationDelegate = coordinator
        defer { withExtendedLifetime(coordinator) {} }
        web.load(URLRequest(url: try XCTUnwrap(EPUBSchemeHandler.url(for: "ch.xhtml"))))
        try await waitFor("!!window.mangoPager && mangoPager.count > 1", in: web)
        try await Task.sleep(for: .milliseconds(200))
        let before = try await number("mangoPager.count", web)
        // More text arrives without a load, font or resize event.
        _ = try await web.evaluateJavaScript("""
        for (let i = 60; i < 150; i++) {
          const p = document.createElementNS('http://www.w3.org/1999/xhtml', 'p');
          p.textContent = 'Paragraph ' + i + '. The traveler crossed the quiet garden and opened the old wooden gate.';
          document.body.appendChild(p);
        }
        true
        """)
        let pages = try await pagesOfText(web, width: phone.width)
        XCTAssertGreaterThan(Double(pages), before)
        try await tapThrough(web, messages: messages, pages: pages, width: phone.width)
    }

    /// Find in this chapter scrolls to a match itself, and its keyboard resizes the visual
    /// viewport as it comes and goes — in height only. That mustn't turn back to the page the
    /// pager was on.
    func testKeyboardResizingTheVisualViewportLeavesThePageAlone() async throws {
        let document = try await longChapter()
        let messages = Messages()
        let (web, window) = try chapterWebView(document, size: phone, messages: messages)
        defer { window.isHidden = true }
        let coordinator = pagedView(document).makeCoordinator()
        coordinator.webView = web
        web.navigationDelegate = coordinator
        defer { withExtendedLifetime(coordinator) {} }
        web.load(URLRequest(url: try XCTUnwrap(EPUBSchemeHandler.url(for: "ch.xhtml"))))
        try await waitFor("!!window.mangoPager && mangoPager.count > 3", in: web)
        try await Task.sleep(for: .milliseconds(200))
        _ = try await web.evaluateJavaScript("window.scrollTo(\(phone.width * 3), 0); visualViewport.dispatchEvent(new Event('resize')); true")
        try await Task.sleep(for: .milliseconds(100))
        let offset = try await number("window.scrollX", web)
        XCTAssertEqual(offset, phone.width * 3, accuracy: 1, "The match Find scrolled to stays on screen")
    }

    // MARK: Links

    func testLinksAreSortedByWhereTheyLead() throws {
        let chapter = "OEBPS/Text/section-0001.html"
        let here = try XCTUnwrap(EPUBSchemeHandler.url(for: chapter))
        XCTAssertEqual(NovelWebView.linkTarget(here, chapterPath: chapter), .sameChapter(fragment: nil))
        let anchor = try XCTUnwrap(URL(string: here.absoluteString + "#note%201"))
        XCTAssertEqual(NovelWebView.linkTarget(anchor, chapterPath: chapter), .sameChapter(fragment: "note 1"))
        let other = try XCTUnwrap(EPUBSchemeHandler.url(for: "OEBPS/Text/section 0005.html"))
        XCTAssertEqual(NovelWebView.linkTarget(other, chapterPath: chapter), .chapter("OEBPS/Text/section 0005.html"))
        let web = try XCTUnwrap(URL(string: "https://www.gomanga.com/newsletter/"))
        XCTAssertEqual(NovelWebView.linkTarget(web, chapterPath: chapter), .external(web))
    }

    private final class Links {
        var chapters: [String] = []
        var external: [URL] = []
    }

    private struct LinkedChapterHost: View {
        let document: EPUBDocument
        let paged: Bool
        let links: Links

        var body: some View {
            NovelWebView(document: document, chapterPath: "ch1.xhtml", fontScale: 1, dark: false,
                         paged: paged, tapToTurn: true, fontFamily: "Georgia, serif", lineSpacing: 1.6,
                         margin: 22, restoreFraction: 0, onScroll: { _ in }, onTapMiddle: {},
                         onNextChapter: {}, onPreviousChapter: {}, onReachedBottom: {},
                         onOpenChapter: { links.chapters.append($0) }, onOpenExternal: { links.external.append($0) })
                .ignoresSafeArea()
        }
    }

    /// Seven Seas books open with their own contents page, translations link out to the web,
    /// and notes are anchors further down. Following any of them used to load it in place of
    /// the chapter, while the reader went on counting the old chapter as the place.
    func testLinksNeverTakeTheChapterAway() async throws {
        let text = (0..<150).map { "<p>Paragraph \($0). The traveler crossed the quiet garden and opened the old wooden gate.</p>" }.joined()
        let files = [
            "META-INF/container.xml": "<container><rootfiles><rootfile full-path='book.opf'/></rootfiles></container>",
            "book.opf": "<package><manifest><item id='a' href='ch1.xhtml' media-type='application/xhtml+xml'/><item id='b' href='ch2.xhtml' media-type='application/xhtml+xml'/></manifest><spine><itemref idref='a'/><itemref idref='b'/></spine></package>",
            "ch1.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>Contents</title></head><body><p><a id='contents' href='ch2.xhtml'>Chapter Two</a></p><p><a id='web' href='https://example.com/notes'>Notes online</a></p><p><a id='down' href='#note'>1</a></p>\(text)<p id='note'>The note.</p></body></html>",
            "ch2.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>Two</title></head><body><p>Two</p></body></html>"
        ]
        let zip = ZipTestBuilder.make(files.map { .init(name: $0.key, data: Data($0.value.utf8), deflate: false) })
        let document = try await EPUBDocument.open(reader: DataReader(zip), displayName: "Linked")
        for paged in [true, false] {
            let links = Links()
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: phone)
            window.rootViewController = UIHostingController(rootView: LinkedChapterHost(document: document, paged: paged, links: links))
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            var found: WKWebView?
            for _ in 0..<200 where found == nil {
                found = firstWebView(in: window)
                if found == nil { try await Task.sleep(for: .milliseconds(50)) }
            }
            let web = try XCTUnwrap(found, "The reader's web view never appeared")
            try await waitFor(paged ? "!!window.mangoPager && mangoPager.count > 1"
                                    : "document.readyState === 'complete' && !!document.getElementById('mango-style')", in: web)
            let stillHere = "location.pathname === '/ch1.xhtml'"

            _ = try await web.evaluateJavaScript("document.getElementById('contents').click(); true")
            for _ in 0..<40 where links.chapters.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
            XCTAssertEqual(links.chapters, ["ch2.xhtml"], "The contents page opens the chapter through the reader")
            try await Task.sleep(for: .milliseconds(200))
            let afterContents = try await web.evaluateJavaScript(stillHere) as? Bool
            XCTAssertEqual(afterContents, true, "…and the chapter on screen stays")

            _ = try await web.evaluateJavaScript("document.getElementById('web').click(); true")
            for _ in 0..<40 where links.external.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
            XCTAssertEqual(links.external, [URL(string: "https://example.com/notes")!], "A web link goes to the browser")
            try await Task.sleep(for: .milliseconds(200))
            let afterWeb = try await web.evaluateJavaScript(stillHere) as? Bool
            XCTAssertEqual(afterWeb, true, "…never into the reader")

            _ = try await web.evaluateJavaScript("document.getElementById('down').click(); true")
            try await Task.sleep(for: .milliseconds(300))
            let afterAnchor = try await web.evaluateJavaScript(stillHere) as? Bool
            XCTAssertEqual(afterAnchor, true)
            if paged {
                let count = try await number("mangoPager.count", web)
                let page = try await number("mangoPager.page", web)
                XCTAssertEqual(page, count - 1, "An anchor on the chapter's last page turns to that page")
                let offset = try await number("window.scrollX", web)
                XCTAssertEqual(offset, page * phone.width, accuracy: 1)
            } else {
                let top = try await number("document.getElementById('note').getBoundingClientRect().top", web)
                XCTAssertLessThan(abs(top), phone.height, "Scrolling reading follows the anchor itself")
            }
            XCTAssertEqual(links.chapters, ["ch2.xhtml"])
        }
    }

    private func tap(at x: CGFloat, _ web: WKWebView) async throws {
        _ = try await web.evaluateJavaScript("document.body.dispatchEvent(new MouseEvent('click', {bubbles:true, clientX:\(x), detail:1}))")
        // Let WebKit commit the native scroll between gestures, as it does between real taps.
        try await Task.sleep(for: .milliseconds(50))
    }
}
