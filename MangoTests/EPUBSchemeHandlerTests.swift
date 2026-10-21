import WebKit
import XCTest
@testable import Mango

@MainActor
final class EPUBSchemeHandlerTests: XCTestCase {
    private final class Request: NSObject, WKURLSchemeTask {
        let request = URLRequest(url: EPUBSchemeHandler.url(for: "ch.xhtml")!)
        var events: [String] = []
        var onResponse: (() -> Void)?
        var onData: (() -> Void)?
        var onFinish: (() -> Void)?
        var failure: (any Error)?

        func didReceive(_ response: URLResponse) { events.append("response"); onResponse?() }
        func didReceive(_ data: Data) { events.append("data"); onData?() }
        func didFinish() { events.append("finish"); onFinish?() }
        func didFailWithError(_ error: any Error) { failure = error; events.append("failure"); onFinish?() }
    }

    private func documentBytes() -> Data {
        let files = [
            "META-INF/container.xml": "<container><rootfiles><rootfile full-path='book.opf'/></rootfiles></container>",
            "book.opf": "<package><manifest><item id='ch' href='ch.xhtml' media-type='application/xhtml+xml'/></manifest><spine><itemref idref='ch'/></spine></package>",
            "ch.xhtml": "<html><body>Chapter</body></html>"
        ]
        return ZipTestBuilder.make(files.map { .init(name: $0.key, data: Data($0.value.utf8), deflate: false) })
    }

    private func document() async throws -> EPUBDocument {
        try await EPUBDocument.open(reader: DataReader(documentBytes()), displayName: "Cancellation")
    }

    private actor UnavailableReader: RandomAccessReader {
        let bytes: Data
        var unavailable = false
        init(bytes: Data) { self.bytes = bytes }
        func length() -> Int64 { Int64(bytes.count) }
        func read(offset: Int64, count: Int) throws -> Data {
            if unavailable { throw URLError(.notConnectedToInternet) }
            return bytes.subdata(in: Int(offset)..<min(bytes.count, Int(offset) + count))
        }
        func disconnect() { unavailable = true }
    }

    func testChapterReadFailurePreservesTheActualSourceError() async throws {
        let reader = UnavailableReader(bytes: documentBytes())
        let document = try await EPUBDocument.open(reader: reader, displayName: "Unavailable source")
        await reader.disconnect()
        let handler = EPUBSchemeHandler(document: document)
        let request = Request()
        let finished = expectation(description: "Source read failed")
        request.onFinish = { finished.fulfill() }
        handler.webView(WKWebView(), start: request)
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual((request.failure as? URLError)?.code, .notConnectedToInternet,
                       "A connection failure must not become a fictitious missing chapter")
        XCTAssertEqual(request.events, ["failure"])
    }

    func testNavigationStoppedDuringResponseDoesNotReceiveDataOrFinish() async throws {
        let handler = EPUBSchemeHandler(document: try await document())
        let web = WKWebView()
        let request = Request()
        let response = expectation(description: "Response stops old chapter")
        request.onResponse = { [weak request] in
            guard let request else { return }
            handler.webView(web, stop: request)
            response.fulfill()
        }
        handler.webView(web, start: request)
        await fulfillment(of: [response], timeout: 5)
        XCTAssertEqual(request.events, ["response"], "WebKit raises an exception if a stopped chapter request receives more callbacks")
    }

    func testNavigationStoppedDuringDataDoesNotFinish() async throws {
        let handler = EPUBSchemeHandler(document: try await document())
        let web = WKWebView()
        let request = Request()
        let data = expectation(description: "Data stops old chapter")
        request.onData = { [weak request] in
            guard let request else { return }
            handler.webView(web, stop: request)
            data.fulfill()
        }
        handler.webView(web, start: request)
        await fulfillment(of: [data], timeout: 5)
        XCTAssertEqual(request.events, ["response", "data"])
    }

    func testUninterruptedChapterReceivesResponseDataAndFinish() async throws {
        let handler = EPUBSchemeHandler(document: try await document())
        let request = Request()
        let finished = expectation(description: "Finished")
        request.onFinish = { finished.fulfill() }
        handler.webView(WKWebView(), start: request)
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(request.events, ["response", "data", "finish"])
    }

    func testChapterStoppedBeforeReadCompletesReceivesNoCallbacks() async throws {
        let handler = EPUBSchemeHandler(document: try await document())
        let web = WKWebView()
        let request = Request()
        handler.webView(web, start: request)
        handler.webView(web, stop: request)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(request.events.isEmpty)
    }
}
