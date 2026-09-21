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

final class ActivityStatsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func key(_ y: Int, _ m: Int, _ d: Int) -> String { DayKey.string(for: day(y, m, d), calendar: calendar) }

    func testDayKeysRoundTrip() {
        let date = day(2026, 9, 21)
        XCTAssertEqual(DayKey.string(for: date, calendar: calendar), "2026-09-21")
        XCTAssertEqual(DayKey.date(from: "2026-09-21", calendar: calendar), date)
    }

    func testStreakCountsBackFromToday() {
        let read: Set<Date> = [day(2026, 9, 19), day(2026, 9, 20), day(2026, 9, 21)]
        let streak = ActivityStats.streaks(read, today: day(2026, 9, 21), calendar: calendar)
        XCTAssertEqual(streak.current, 3)
        XCTAssertEqual(streak.longest, 3)
    }

    /// Before you've read anything today, yesterday's streak is still alive.
    func testStreakSurvivesUntilTodayIsOver() {
        let read: Set<Date> = [day(2026, 9, 19), day(2026, 9, 20)]
        XCTAssertEqual(ActivityStats.streaks(read, today: day(2026, 9, 21), calendar: calendar).current, 2)
    }

    func testMissingADayBreaksIt() {
        let read: Set<Date> = [day(2026, 9, 17), day(2026, 9, 18), day(2026, 9, 20), day(2026, 9, 21)]
        let streak = ActivityStats.streaks(read, today: day(2026, 9, 21), calendar: calendar)
        XCTAssertEqual(streak.current, 2)
        XCTAssertEqual(streak.longest, 2)
    }

    func testLongestCanBeInThePast() {
        let read: Set<Date> = [day(2026, 1, 1), day(2026, 1, 2), day(2026, 1, 3), day(2026, 1, 4), day(2026, 9, 21)]
        let streak = ActivityStats.streaks(read, today: day(2026, 9, 21), calendar: calendar)
        XCTAssertEqual(streak.current, 1)
        XCTAssertEqual(streak.longest, 4)
    }

    func testNoReadingNoStreak() {
        XCTAssertEqual(ActivityStats.streaks([], today: day(2026, 9, 21), calendar: calendar).current, 0)
    }

    func testTotalsAndPeriods() {
        let days: [String: DayActivity] = [
            key(2026, 9, 21): DayActivity(seconds: 600, pages: 30, sessions: 1),
            key(2026, 9, 2): DayActivity(seconds: 1200, pages: 40, sessions: 2),
            key(2026, 5, 1): DayActivity(seconds: 3000, pages: 90, sessions: 3),
        ]
        let stats = ActivityStats.build(days: days, sessions: [], now: day(2026, 9, 21), calendar: calendar)
        XCTAssertEqual(stats.totalSeconds, 4800, accuracy: 0.1)
        XCTAssertEqual(stats.thisMonthSeconds, 1800, accuracy: 0.1)
        XCTAssertEqual(stats.daysRead, 3)
    }

    /// The heatmap is whole weeks, zero-filled, ending today — gaps would read as missing data.
    func testHeatmapIsWholeWeeksEndingToday() throws {
        let stats = ActivityStats.build(days: [key(2026, 9, 21): DayActivity(seconds: 60)], sessions: [],
                                        now: day(2026, 9, 21), calendar: calendar)
        let last = try XCTUnwrap(stats.heatmap.last)
        XCTAssertEqual(last.date, day(2026, 9, 21))
        XCTAssertEqual(last.seconds, 60)
        XCTAssertGreaterThanOrEqual(stats.heatmap.count, (ActivityStats.heatmapWeeks - 1) * 7)
        XCTAssertEqual(calendar.component(.weekday, from: stats.heatmap[0].date), calendar.firstWeekday)
    }

    func testPaceUsesOnlyComicSessionsThatTurnedPages() throws {
        func session(_ secs: Double, _ pages: Int, novel: Bool = false) -> ReadingSession {
            ReadingSession(comicID: "c", seriesKey: "k", seriesName: "S", isNovel: novel,
                           startedAt: day(2026, 9, 21), activeSeconds: secs, pagesTurned: pages)
        }
        let stats = ActivityStats.build(days: [:], sessions: [session(600, 60), session(600, 0, novel: true)],
                                        calendar: calendar)
        XCTAssertEqual(try XCTUnwrap(stats.pagesPerMinute), 6, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(stats.averageSessionMinutes), 10, accuracy: 0.001)
    }

    func testRollUpGroupsSessionsByDay() {
        let a = ReadingSession(comicID: "c", seriesKey: "k", seriesName: "S", isNovel: false,
                               startedAt: day(2026, 9, 21), activeSeconds: 100, pagesTurned: 10)
        var b = a
        b.id = "b"
        b.activeSeconds = 50
        let days = DayKey.rollUp([a, b], calendar: calendar)
        XCTAssertEqual(days["2026-09-21"]?.seconds, 150)
        XCTAssertEqual(days["2026-09-21"]?.sessions, 2)
    }

    func testDurations() {
        XCTAssertEqual(Durations.short(0), "0m")
        XCTAssertEqual(Durations.short(20), "<1m")
        XCTAssertEqual(Durations.short(45 * 60), "45m")
        XCTAssertEqual(Durations.short(200 * 60), "3h 20m")
    }
}
