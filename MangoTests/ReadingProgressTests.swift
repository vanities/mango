import XCTest
@testable import Mango

final class ReadingProgressTests: XCTestCase {
    func testFractionAcrossABook() {
        XCTAssertEqual(ReadingProgress(page: 0, pageCount: 101).fraction, 0, accuracy: 0.001)
        XCTAssertEqual(ReadingProgress(page: 50, pageCount: 101).fraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(ReadingProgress(page: 100, pageCount: 101).fraction, 1, accuracy: 0.001)
    }

    /// Page count is unknown until the archive is opened; that must not divide by zero.
    func testUnknownPageCount() {
        XCTAssertEqual(ReadingProgress(page: 0, pageCount: 0).fraction, 0)
        XCTAssertEqual(ReadingProgress(page: 5, pageCount: 0).fraction, 0)
    }

    func testSinglePageBook() {
        XCTAssertEqual(ReadingProgress(page: 0, pageCount: 1).fraction, 0)
        XCTAssertEqual(ReadingProgress(page: 0, pageCount: 1, finished: true).fraction, 1)
    }

    func testStartedMeansStarted() {
        XCTAssertFalse(ReadingProgress().isStarted)
        XCTAssertTrue(ReadingProgress(page: 1, pageCount: 10).isStarted)
        XCTAssertTrue(ReadingProgress(page: 0, pageCount: 10, finished: true).isStarted)
    }

    func testLabels() {
        XCTAssertEqual(ReadingProgress(page: 13, pageCount: 192).label, "Page 14 of 192")
        XCTAssertEqual(ReadingProgress(page: 191, pageCount: 192, finished: true).label, "Finished")
    }

    /// A build that adds a field still has to read what the last one wrote.
    func testDecodesAPartialDocument() throws {
        let json = Data(#"{"page":7}"#.utf8)
        let progress = try JSONDecoder().decode(ReadingProgress.self, from: json)
        XCTAssertEqual(progress.page, 7)
        XCTAssertEqual(progress.pageCount, 0)
        XCTAssertFalse(progress.finished)
    }
}
