import SwiftUI
import WebKit
import XCTest
@testable import Mango

@MainActor
final class NovelChapterTransitionTests: XCTestCase {
    @Observable fileprivate final class Reading {
        var chapter = 0
        var turns = 0
        var fractions: [Double] = []
    }

    private struct Reader: View {
        let document: EPUBDocument
        let reading: Reading
        var paged = true
        var body: some View {
            let chapter = reading.chapter
            return NovelWebView(document: document, chapterPath: document.spine[chapter % document.chapterCount].path,
                         fontScale: 1, dark: false, paged: paged, tapToTurn: true,
                         fontFamily: "Georgia, serif", lineSpacing: 1.6, margin: 22,
                         restoreFraction: 0, isCurrentChapter: { reading.chapter == chapter }, onScroll: { reading.fractions.append($0) },
                         onTapMiddle: {}, onNextChapter: {
                             reading.turns += 1
                             reading.chapter += 1
                         }, onPreviousChapter: {
                             reading.turns += 1
                             reading.chapter += 1
                         }, onReachedBottom: {})
                .id(reading.chapter)
                .ignoresSafeArea()
        }
    }

    func testRapidBoundaryTurnsReplaceExactlyOneChapterAndReleaseOldViews() async throws {
        let document = try await transitionDocument()
        try await exerciseTransitions(document: document)
    }

    func testPagedChapterRecoversItsPositionAfterWebContentProcessTermination() async throws {
#if targetEnvironment(simulator)
        let reading = Reading()
        let document = try await transitionDocument()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = UIHostingController(rootView: Reader(document: document, reading: reading))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let web = try await readyWeb(in: window, path: "ch0.xhtml")
        _ = try await web.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowRight'})); null;")
        let pageFraction = try await web.evaluateJavaScript("mangoPager.fraction")
        let expectedFraction = try XCTUnwrap(pageFraction as? Double)
        XCTAssertGreaterThan(expectedFraction, 0)
        XCTAssertLessThan(expectedFraction, 1)
        for _ in 0..<100 {
            if reading.fractions.last.map({ abs($0 - expectedFraction) < 0.001 }) == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try XCTUnwrap(reading.fractions.last), expectedFraction, accuracy: 0.001)
        let oldPID = try await WebContentProcessProbe.terminate(web)
        var restored = false
        for _ in 0..<400 {
            let ready = (try? await web.evaluateJavaScript("!!window.mangoPager")) as? Bool == true
            let newPID = web.value(forKey: "_webProcessIdentifier") as? Int ?? 0
            if WebContentProcessProbe.hasExited(oldPID), newPID > 0, newPID != oldPID, ready {
                restored = true
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(restored, "A terminated WebContent process must restore the chapter's pager")
        guard restored else { return }
        let restoredFraction = try await web.evaluateJavaScript("mangoPager.fraction") as? Double ?? -1
        XCTAssertEqual(restoredFraction, expectedFraction, accuracy: 0.001)
        XCTAssertEqual(reading.chapter, 0, "Recovery must not turn a chapter")
        XCTAssertEqual(reading.turns, 0)
#else
        throw XCTSkip("The process-termination probe is confined to simulators")
#endif
    }

    func testScrollingChapterRecoversItsPositionAfterWebContentProcessTermination() async throws {
        try await exerciseScrollingRecovery(document: transitionDocument())
    }

    func testScrollingChapterWaitsForDelayedLayoutAfterProcessTermination() async throws {
        try await exerciseScrollingRecovery(document: transitionDocument(delayedLayout: true))
    }

    private func exerciseScrollingRecovery(document: EPUBDocument) async throws {
#if targetEnvironment(simulator)
        let reading = Reading()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = UIHostingController(rootView: Reader(document: document, reading: reading, paged: false))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        let layoutDeadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < layoutDeadline {
            if let web = findWeb(in: window),
               (web.navigationDelegate as? NovelWebView.Coordinator)?.chapterLoaded == true,
               web.scrollView.contentSize.height > web.scrollView.bounds.height * 2 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let web = try XCTUnwrap(findWeb(in: window))
        let scroll = web.scrollView
        let reachable = scroll.contentSize.height - scroll.bounds.height
        XCTAssertGreaterThan(reachable, 0)
        scroll.setContentOffset(CGPoint(x: 0, y: reachable * 0.55), animated: false)
        for _ in 0..<100 {
            if reading.fractions.last.map({ abs($0 - 0.55) < 0.01 }) == true { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(try XCTUnwrap(reading.fractions.last), 0.55, accuracy: 0.01)
        let reportsBeforeTermination = reading.fractions.count
        let oldNavigation = try XCTUnwrap((web.navigationDelegate as? NovelWebView.Coordinator)?.activeNavigation)
        _ = try await web.evaluateJavaScript("window.mangoRecoverySentinel = true")
        let oldPID = try await WebContentProcessProbe.terminate(web)
        var restored = false
        for _ in 0..<400 {
            // Prove the old process exited and a fresh document/navigation responds.
            // The private current-PID getter can return zero for an idle restored page.
            let documentReady = (try? await web.evaluateJavaScript("document.readyState === 'complete' && !window.mangoRecoverySentinel && getComputedStyle(document.body).display !== 'none'")) as? Bool == true
            let oldProcessExited = WebContentProcessProbe.hasExited(oldPID)
            if oldProcessExited,
               documentReady,
               (web.navigationDelegate as? NovelWebView.Coordinator)?.activeNavigation !== oldNavigation,
               (web.navigationDelegate as? NovelWebView.Coordinator)?.chapterLoaded == true,
               scroll.contentSize.height > scroll.bounds.height * 2,
               abs(scroll.contentOffset.y / (scroll.contentSize.height - scroll.bounds.height) - 0.55) < 0.01 {
                restored = true
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        var recoveryState = ""
        if !restored {
            let dom = try? await web.evaluateJavaScript("JSON.stringify({y:scrollY,height:document.documentElement.scrollHeight,viewport:innerHeight,display:getComputedStyle(document.body).display,sentinel:!!window.mangoRecoverySentinel})")
            recoveryState = "oldPID=\(oldPID) exited=\(WebContentProcessProbe.hasExited(oldPID)) navChanged=\((web.navigationDelegate as? NovelWebView.Coordinator)?.activeNavigation !== oldNavigation) loaded=\((web.navigationDelegate as? NovelWebView.Coordinator)?.chapterLoaded == true) offset=\(scroll.contentOffset.y) size=\(scroll.contentSize) bounds=\(scroll.bounds) dom=\(String(describing: dom))"
        }
        XCTAssertTrue(restored, "A scrolling chapter must recover its position after the real process is terminated; \(recoveryState)")
        XCTAssertEqual(try XCTUnwrap(reading.fractions.last), 0.55, accuracy: 0.01)
        XCTAssertFalse(reading.fractions.dropFirst(reportsBeforeTermination).contains { $0 < 0.54 },
                       "Empty-page callbacks during recovery must not publish a false reading position")
        XCTAssertEqual(reading.turns, 0)
#else
        throw XCTSkip("The process-termination probe is confined to simulators")
#endif
    }

    private func transitionDocument(delayedLayout: Bool = false) async throws -> EPUBDocument {
        let paragraphs = (0..<40).map { "<p>Paragraph \($0). The traveler crossed the quiet garden.</p>" }.joined()
        let layout = delayedLayout ? "<style>body { display: none; }</style><script>setTimeout(function() { document.body.style.display = 'block'; }, 800);</script>" : ""
        let files = [
            "META-INF/container.xml": "<container><rootfiles><rootfile full-path='book.opf'/></rootfiles></container>",
            "book.opf": "<package><manifest><item id='a' href='ch0.xhtml' media-type='application/xhtml+xml'/><item id='b' href='ch1.xhtml' media-type='application/xhtml+xml'/></manifest><spine><itemref idref='a'/><itemref idref='b'/></spine></package>",
            "ch0.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>Chapter</title>\(layout)</head><body>\(paragraphs)</body></html>",
            "ch1.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>Chapter</title></head><body>\(paragraphs)</body></html>"
        ]
        let bytes = ZipTestBuilder.make(files.map { .init(name: $0.key, data: Data($0.value.utf8), deflate: false) })
        return try await EPUBDocument.open(reader: DataReader(bytes), displayName: "Chapter transitions")
    }

    func testOnlyTheCurrentMainDocumentFailureReachesTheReader() async throws {
        let reading = Reading()
        var failures: [String] = []
        let surface = NovelWebView(document: try await transitionDocument(), chapterPath: "ch0.xhtml",
                                   fontScale: 1, dark: false, paged: true, tapToTurn: true,
                                   fontFamily: "Georgia, serif", lineSpacing: 1.6, margin: 22,
                                   restoreFraction: 0, isCurrentChapter: { reading.chapter == 0 },
                                   onScroll: { _ in }, onTapMiddle: {}, onNextChapter: {}, onPreviousChapter: {},
                                   onReachedBottom: {}, onLoadFailure: { failures.append($0) })
        let coordinator = surface.makeCoordinator()
        let web = WKWebView()
        defer { web.stopLoading() }
        let previous = try XCTUnwrap(web.loadHTMLString("<p>Old chapter</p>", baseURL: nil))
        let current = try XCTUnwrap(web.loadHTMLString("<p>Current chapter</p>", baseURL: nil))
        coordinator.activeNavigation = current
        coordinator.webView = web
        coordinator.chapterLoaded = true
        coordinator.webView(web, didFailProvisionalNavigation: previous, withError: URLError(.notConnectedToInternet))
        coordinator.webView(web, didFailProvisionalNavigation: current, withError: URLError(.cancelled))
        let missingImage = URLError(.fileDoesNotExist, userInfo: [NSURLErrorFailingURLErrorKey: EPUBSchemeHandler.url(for: "missing.png")!])
        coordinator.webView(web, didFail: current, withError: missingImage)
        XCTAssertTrue(failures.isEmpty, "Old, cancelled and subresource failures must not replace readable prose")
        XCTAssertTrue(coordinator.chapterLoaded)
        coordinator.webView(web, didFail: current, withError: URLError(.notConnectedToInternet))
        XCTAssertEqual(failures.count, 1)
        XCTAssertFalse(coordinator.chapterLoaded)
        reading.chapter = 1
        coordinator.webViewWebContentProcessDidTerminate(web)
        XCTAssertTrue(coordinator.activeNavigation === current, "A retired chapter must not start recovery")
        coordinator.webView(web, didFailProvisionalNavigation: current, withError: URLError(.notConnectedToInternet))
        XCTAssertEqual(failures.count, 1, "A late failure must not interrupt a newer chapter")
        reading.chapter = 0
        NovelWebView.dismantleUIView(web, coordinator: coordinator)
        coordinator.webViewWebContentProcessDidTerminate(web)
        XCTAssertNil(coordinator.activeNavigation, "A closed reader must not start recovery")
        coordinator.webView(web, didFail: current, withError: URLError(.notConnectedToInternet))
        XCTAssertEqual(failures.count, 1, "Closed readers must ignore outstanding failures")
    }

    private func exerciseTransitions(document: EPUBDocument, steps: Int = 30, startingAt: Int = 0) async throws {
        let reading = Reading()
        reading.chapter = startingAt
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = UIHostingController(rootView: Reader(document: document, reading: reading))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        var retired: [WeakWeb] = []
        for step in 0..<steps {
            let chapter = reading.chapter
            let web = try await readyWeb(in: window, path: document.spine[chapter % document.chapterCount].path)
            retired.append(WeakWeb(web))
            let forward = step.isMultiple(of: 2)
            let turnEvent = step.isMultiple(of: 3)
                ? "document.body.dispatchEvent(new MouseEvent('click', {bubbles:true, clientX:\(forward ? 380 : 1), detail:1}))"
                : "document.dispatchEvent(new KeyboardEvent('keydown', {key:'\(forward ? "ArrowRight" : "ArrowLeft")'}))"
            _ = try await web.evaluateJavaScript("""
            mangoPager.page = \(forward ? "mangoPager.count - 1" : "0");
            for (let i = 0; i < 20; i++) {
              \(turnEvent);
              window.webkit.messageHandlers.mangoNavigation.postMessage({action:'progress', fraction:0.9});
            }
            // Return a bridgeable value, rather than the message port's last result.
            null;
            """)
            for _ in 0..<100 {
                if reading.chapter != chapter { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(reading.chapter, chapter + 1, "One old chapter must issue only one transition")
            guard reading.chapter == chapter + 1 else { return }
            _ = try await readyWeb(in: window, path: document.spine[reading.chapter % document.chapterCount].path, excluding: web)
        }
        // A new WKWebView is created per chapter in the real reader. Old views must go away.
        for _ in 0..<100 {
            if retired.allSatisfy({ $0.value == nil }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(reading.turns, steps)
        XCTAssertFalse(reading.fractions.contains(0.9), "Queued progress from an old chapter must not overwrite the new chapter's place")
        XCTAssertTrue(retired.allSatisfy { $0.value == nil }, "Retired chapter web views must be released")
    }

    private final class WeakWeb {
        weak var value: WKWebView?
        init(_ value: WKWebView) { self.value = value }
    }

    private func readyWeb(in window: UIWindow, path: String, excluding old: WKWebView? = nil) async throws -> WKWebView {
        // Initial WebContent/GPU startup is slower on a cold hosted simulator. This
        // readiness budget is separate from the process-recovery assertions below.
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            if let web = findWeb(in: window), web !== old, web.url.map({ EPUBSchemeHandler.path(from: $0) }) == path,
               (try? await web.evaluateJavaScript("!!window.mangoPager && mangoPager.count >= 1")) as? Bool == true {
                return web
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let web = findWeb(in: window)
        throw XCTUnwrapFailure.missingChapter("expected=\(path) actual=\(web?.url?.absoluteString ?? "none") loading=\(web?.isLoading.description ?? "none") frame=\(String(describing: web?.frame))")
    }

    private enum XCTUnwrapFailure: Error { case missingChapter(String) }

    private func findWeb(in view: UIView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { self.findWeb(in: $0) }.first
    }
}
