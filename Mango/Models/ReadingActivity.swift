import Foundation
import ShelfKit

/// Time actually spent reading, one session per book opening.
///
/// "Active" time, not wall-clock: the gap between page turns counts only up to a cap, and the
/// clock stops while the app is in the background. Otherwise leaving a book open on the
/// nightstand overnight would read as eight hours of manga.
struct ReadingSession: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var comicID: String
    var seriesKey: String
    var seriesName: String
    var isNovel: Bool
    var startedAt: Date
    var activeSeconds: Double
    /// Pages moved forward. Comics only — a novel has no pages to count.
    var pagesTurned: Int

    init(id: String = UUID().uuidString, comicID: String, seriesKey: String, seriesName: String,
         isNovel: Bool, startedAt: Date, activeSeconds: Double, pagesTurned: Int) {
        self.id = id
        self.comicID = comicID
        self.seriesKey = seriesKey
        self.seriesName = seriesName
        self.isNovel = isNovel
        self.startedAt = startedAt
        self.activeSeconds = activeSeconds
        self.pagesTurned = pagesTurned
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        comicID = try c.decodeIfPresent(String.self, forKey: .comicID) ?? ""
        seriesKey = try c.decodeIfPresent(String.self, forKey: .seriesKey) ?? ""
        seriesName = try c.decodeIfPresent(String.self, forKey: .seriesName) ?? ""
        isNovel = try c.decodeIfPresent(Bool.self, forKey: .isNovel) ?? false
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt) ?? .now
        activeSeconds = try c.decodeIfPresent(Double.self, forKey: .activeSeconds) ?? 0
        pagesTurned = try c.decodeIfPresent(Int.self, forKey: .pagesTurned) ?? 0
    }
}

/// Measures one session as it happens. A value type the reader engines own and feed with page
/// turns (or scrolls) and app-lifecycle events.
struct SessionRecorder: Sendable {
    /// The most a single gap between turns can count for. A dense page takes a minute or two;
    /// anything longer is the book lying open while you did something else.
    static let maxGap: TimeInterval = 180
    /// Shorter than this isn't a reading session — it's opening a book to check something.
    static let minimumSession: TimeInterval = 15

    private(set) var startedAt: Date
    private(set) var activeSeconds: Double = 0
    private(set) var pagesTurned = 0
    private var lastTick: Date?
    /// The furthest page reached this session. Pages only count as read when you pass it, so
    /// flipping back to re-read a panel and forward again doesn't inflate pages or pace.
    private var furthestPage: Int

    init(startingAt page: Int, now: Date = .now) {
        startedAt = now
        lastTick = now
        furthestPage = page
    }

    /// Something happened — a page turned, the text scrolled. The gap since the last event
    /// counts, capped, and reaching a page beyond anything seen yet this session counts as
    /// reading the pages in between.
    mutating func tick(page: Int, now: Date = .now) {
        if let lastTick {
            activeSeconds += min(max(0, now.timeIntervalSince(lastTick)), Self.maxGap)
        }
        if page > furthestPage {
            pagesTurned += page - furthestPage
            furthestPage = page
        }
        lastTick = now
    }

    /// The app went to the background: count what's accrued and stop the clock.
    mutating func pause(now: Date = .now) {
        if let lastTick {
            activeSeconds += min(max(0, now.timeIntervalSince(lastTick)), Self.maxGap)
        }
        lastTick = nil
    }

    /// Back in the foreground: start timing again from now, not from when it was left.
    mutating func resume(now: Date = .now) {
        if lastTick == nil { lastTick = now }
    }

    /// The finished session, or nil if it was too short to be one.
    mutating func finish(comic: Comic, seriesKey: String, now: Date = .now) -> ReadingSession? {
        pause(now: now)
        guard activeSeconds >= Self.minimumSession else { return nil }
        return ReadingSession(comicID: comic.id, seriesKey: seriesKey, seriesName: comic.displaySeries,
                              isNovel: comic.isNovel, startedAt: startedAt,
                              activeSeconds: activeSeconds, pagesTurned: comic.isNovel ? 0 : pagesTurned)
    }
}

extension ReadingSession {
    /// "2026-09-21" in the reader's own calendar — the key days are grouped and synced by.
    func dayKey(_ calendar: Calendar = .current) -> String {
        DayKey.string(for: startedAt, calendar: calendar)
    }
}

/// How ShelfKit's `ActivityStats` sees a reading session: grouped by series, counting pages.
extension ReadingSession: ActivitySession {
    var activityGroupKey: String { seriesKey }
    var activityGroupName: String { seriesName }
    var activityPages: Int { pagesTurned }
}
