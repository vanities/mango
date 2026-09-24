import XCTest
@testable import Mango

/// Reading time is measured, not tracked by wall clock — so the measuring is what can lie.
final class SessionRecorderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    private let comic = Comic(id: "c", sourceID: UUID(), relativePath: "c.cbz", kind: .archive,
                              title: "C Vol. 1", series: "C", volume: 1, chapter: nil, author: nil,
                              year: nil, subtitle: nil, pageCount: 100, totalBytes: 1,
                              addedAt: Date(), coverID: nil)

    func testJumpDoesNotInflateReadPagesOrPace() {
        var recorder = SessionRecorder(startingAt: 0, now: at(0))
        recorder.tick(page: 1, now: at(30))
        recorder.jump(to: 90)
        recorder.tick(page: 90, now: at(31))
        XCTAssertEqual(recorder.pagesTurned, 1)
        recorder.tick(page: 91, now: at(60))
        XCTAssertEqual(recorder.pagesTurned, 2)
    }

    func testCountsTimeBetweenTurns() {
        var recorder = SessionRecorder(startingAt: 0, now: at(0))
        recorder.tick(page: 1, now: at(30))
        recorder.tick(page: 2, now: at(70))
        XCTAssertEqual(recorder.activeSeconds, 70, accuracy: 0.001)
        XCTAssertEqual(recorder.pagesTurned, 2)
    }

    /// A book left open overnight must not become eight hours of reading.
    func testLongGapsAreCapped() {
        var recorder = SessionRecorder(startingAt: 0, now: at(0))
        recorder.tick(page: 1, now: at(8 * 3600))
        XCTAssertEqual(recorder.activeSeconds, SessionRecorder.maxGap, accuracy: 0.001)
    }

    /// Time in the background doesn't count at all — not even the capped amount.
    func testBackgroundTimeDoesNotCount() {
        var recorder = SessionRecorder(startingAt: 0, now: at(0))
        recorder.tick(page: 1, now: at(20))
        recorder.pause(now: at(40))
        recorder.resume(now: at(4000))
        recorder.tick(page: 2, now: at(4010))
        XCTAssertEqual(recorder.activeSeconds, 50, accuracy: 0.001)
    }

    /// Paging back to re-read a panel and forward again isn't reading more pages. Only passing
    /// the furthest page reached counts: from page 5, back to 3, forward to 7 is 2 new pages.
    func testRereadingDoesNotCountPages() {
        var recorder = SessionRecorder(startingAt: 5, now: at(0))
        recorder.tick(page: 3, now: at(10))
        recorder.tick(page: 4, now: at(20))
        recorder.tick(page: 5, now: at(25))
        XCTAssertEqual(recorder.pagesTurned, 0)
        recorder.tick(page: 7, now: at(30))
        XCTAssertEqual(recorder.pagesTurned, 2)
    }

    func testTooShortIsNotASession() {
        var recorder = SessionRecorder(startingAt: 0, now: at(0))
        recorder.tick(page: 1, now: at(5))
        XCTAssertNil(recorder.finish(comic: comic, seriesKey: "k", now: at(8)))
    }

    func testFinishProducesTheSession() throws {
        var recorder = SessionRecorder(startingAt: 0, now: at(0))
        recorder.tick(page: 10, now: at(120))
        let session = try XCTUnwrap(recorder.finish(comic: comic, seriesKey: "comic|c", now: at(150)))
        XCTAssertEqual(session.activeSeconds, 150, accuracy: 0.001)
        XCTAssertEqual(session.pagesTurned, 10)
        XCTAssertEqual(session.seriesKey, "comic|c")
        XCTAssertEqual(session.startedAt, t0)
    }
}

// Day keys, streaks, the heatmap, pace and the between-devices merge are ShelfKit's now,
// tested there (ActivityTests).
