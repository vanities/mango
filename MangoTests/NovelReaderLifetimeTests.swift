import SwiftUI
import WebKit
import XCTest
@testable import Mango

@MainActor
final class NovelReaderLifetimeTests: XCTestCase {
    private final class WeakLibrary {
        weak var value: LibraryModel?
        init(_ value: LibraryModel) { self.value = value }
    }

    private final class WeakWeb {
        weak var value: WKWebView?
        init(_ value: WKWebView?) { self.value = value }
    }

    func testClosingReaderReleasesItsSessionAndLibrary() async throws {
        let (window, library, folder, suite) = try await openReader()
        defer {
            window.rootViewController = nil
            window.isHidden = true
            try? FileManager.default.removeItem(at: folder)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let web = WeakWeb(findWeb(in: window))
        XCTAssertNotNil(web.value)
        window.rootViewController = nil
        window.isHidden = true
        for _ in 0..<600 {
            if library.value == nil && web.value == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(web.value, "The closed screen must release its web view")
        XCTAssertNil(library.value, "Its engine's callbacks must not retain the reader's State and library")
    }

    func testRepeatedProcessRecoveryKeepsTheCurrentChapterAndWidgetPosition() async throws {
#if targetEnvironment(simulator)
        let (window, reference, folder, suite) = try await openReader()
        defer {
            window.rootViewController = nil
            window.isHidden = true
            try? FileManager.default.removeItem(at: folder)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let library = try XCTUnwrap(reference.value)
        let comic = try XCTUnwrap(library.state.comics.first)
        let first = try XCTUnwrap(findWeb(in: window))
        _ = try await first.evaluateJavaScript("""
        mangoPager.page = mangoPager.count - 1;
        document.dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowRight'}));
        null;
        """)
        var current: WKWebView?
        for _ in 0..<300 {
            if let web = findWeb(in: window), web !== first, web.url?.lastPathComponent == "next.xhtml",
               (try? await web.evaluateJavaScript("!!window.mangoPager")) as? Bool == true {
                current = web
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let web = try XCTUnwrap(current, "The real reader must advance to its second chapter")
        _ = try await web.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowRight'})); null;")
        let reported = try await web.evaluateJavaScript("mangoPager.fraction")
        let fraction = try XCTUnwrap(reported as? Double)
        XCTAssertGreaterThan(fraction, 0)
        XCTAssertLessThan(fraction, 1)
        let coordinator = try XCTUnwrap(web.navigationDelegate as? NovelWebView.Coordinator)
        for _ in 0..<100 {
            if abs(coordinator.pendingRestore - fraction) < 0.001 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(coordinator.pendingRestore, fraction, accuracy: 0.001)
        let terminate = NSSelectorFromString("_killWebContentProcess")
        guard web.responds(to: terminate) else {
            XCTFail("This runtime must support the real process-termination probe")
            return
        }
        for _ in 0..<3 {
            let oldPID = try XCTUnwrap(web.value(forKey: "_webProcessIdentifier") as? Int)
            XCTAssertGreaterThan(oldPID, 0)
            web.perform(terminate)
            var restored = false
            for _ in 0..<400 {
                let newPID = web.value(forKey: "_webProcessIdentifier") as? Int ?? 0
                if newPID > 0, newPID != oldPID,
                   (try? await web.evaluateJavaScript("!!window.mangoPager")) as? Bool == true {
                    restored = true
                    break
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTAssertTrue(restored, "Every real process replacement must restore the reader")
            guard restored else { return }
            let restoredFraction = try await web.evaluateJavaScript("mangoPager.fraction") as? Double ?? -1
            XCTAssertEqual(restoredFraction, fraction, accuracy: 0.001)
            NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
            let progress = try XCTUnwrap(library.progress(for: comic))
            XCTAssertEqual(progress.page, 1)
            XCTAssertEqual(progress.fractionInChapter, fraction, accuracy: 0.001)
            let snapshot = try XCTUnwrap(SharedReading.read())
            XCTAssertEqual(snapshot.comicID, comic.id)
            XCTAssertEqual(snapshot.positionLabel, "Chapter 2 of 2")
            XCTAssertEqual(snapshot.fraction, progress.fraction, accuracy: 0.001)
        }
        // The restored pager must still accept a real turn, rather than only rendering text.
        let oldPage = try await web.evaluateJavaScript("mangoPager.page") as? Int ?? -1
        _ = try await web.evaluateJavaScript("document.dispatchEvent(new KeyboardEvent('keydown', {key:'ArrowLeft'})); null;")
        let newPage = try await web.evaluateJavaScript("mangoPager.page") as? Int ?? -1
        XCTAssertEqual(newPage, oldPage - 1)
#else
        throw XCTSkip("The process-termination probe is confined to simulators")
#endif
    }

    private func openReader() async throws -> (UIWindow, WeakLibrary, URL, String) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ReaderLifetime-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let paragraphs = (0..<30).map { "<p>Paragraph \($0). The traveler crossed the quiet garden.</p>" }.joined()
        let files = [
            "META-INF/container.xml": "<container><rootfiles><rootfile full-path='book.opf'/></rootfiles></container>",
            "book.opf": "<package><manifest><item id='ch' href='ch.xhtml' media-type='application/xhtml+xml'/><item id='next' href='next.xhtml' media-type='application/xhtml+xml'/></manifest><spine><itemref idref='ch'/><itemref idref='next'/></spine></package>",
            "ch.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>Chapter</title></head><body>\(paragraphs)</body></html>",
            "next.xhtml": "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>Next chapter</title></head><body>\(paragraphs)</body></html>"
        ]
        let data = ZipTestBuilder.make(files.map { .init(name: $0.key, data: Data($0.value.utf8), deflate: false) })
        let relativePath = "Lifetime.epub"
        try data.write(to: folder.appending(path: relativePath))
        let suite = UUID().uuidString
        let settings = AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        settings.novelPaged = true
        let library = LibraryModel(store: LibraryStore(directory: folder.appending(path: "state")),
                                   covers: CoverStore(directory: folder.appending(path: "covers"), customDirectory: folder.appending(path: "custom")),
                                   settings: settings)
        let source = LibrarySource(id: UUID(), kind: .folder, displayName: "Generated lifetime fixture", addedAt: .now)
        let comic = Comic(id: Comic.makeID(sourceID: source.id, relativePath: relativePath), sourceID: source.id,
                          relativePath: relativePath, kind: .epub, title: "Lifetime fixture", series: nil, volume: nil, chapter: nil,
                          author: nil, year: nil, subtitle: nil, pageCount: 1, totalBytes: Int64(data.count), addedAt: .now)
        library.mutateState { $0.sources.append(source); $0.comics = [comic] }
        library.roots[source.id] = folder
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.rootViewController = UIHostingController(rootView: NovelReaderView(comic: comic).environment(library).environment(settings))
        window.makeKeyAndVisible()
        for _ in 0..<300 {
            if let web = findWeb(in: window), (try? await web.evaluateJavaScript("!!window.mangoPager")) as? Bool == true {
                return (window, WeakLibrary(library), folder, suite)
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Reader did not finish opening its generated EPUB")
        return (window, WeakLibrary(library), folder, suite)
    }

    private func findWeb(in view: UIView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { self.findWeb(in: $0) }.first
    }
}
