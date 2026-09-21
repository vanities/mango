import Foundation

/// Time, streaks, pace and habits — everything Stats can say about *how* you read rather than
/// what you finished. Built from day totals (which include your other devices) and this
/// device's own sessions (for the per-series and time-of-day detail).
struct ActivityStats: Equatable, Sendable {
    struct Day: Equatable, Identifiable, Sendable {
        var id: Date { date }
        var date: Date
        var seconds: Double
        var pages: Int
    }

    struct Bucket: Equatable, Identifiable, Sendable {
        var id: String { name }
        var name: String
        var seconds: Double
    }

    var totalSeconds: Double = 0
    var thisWeekSeconds: Double = 0
    var thisMonthSeconds: Double = 0
    var currentStreak = 0
    var longestStreak = 0
    var daysRead = 0
    /// Every day of the last `heatmapWeeks` weeks, oldest first, Sunday-aligned, zero-filled.
    var heatmap: [Day] = []
    /// Pages a minute, from comic sessions that actually turned pages.
    var pagesPerMinute: Double?
    var averageSessionMinutes: Double?
    var timeOfDay: [Bucket] = []
    var topSeriesByTime: [Bucket] = []

    var hasActivity: Bool { totalSeconds > 0 }

    static let heatmapWeeks = 17

    static func build(days: [String: DayActivity], sessions: [ReadingSession], now: Date = .now,
                      calendar: Calendar = .current) -> ActivityStats {
        var stats = ActivityStats()
        let dated: [(Date, DayActivity)] = days.compactMap { key, value in
            DayKey.date(from: key, calendar: calendar).map { ($0, value) }
        }
        let today = calendar.startOfDay(for: now)

        stats.totalSeconds = dated.reduce(0) { $0 + $1.1.seconds }
        stats.daysRead = dated.count { $0.1.seconds > 0 }
        if let week = calendar.dateInterval(of: .weekOfYear, for: now) {
            stats.thisWeekSeconds = dated.filter { week.contains($0.0) }.reduce(0) { $0 + $1.1.seconds }
        }
        if let month = calendar.dateInterval(of: .month, for: now) {
            stats.thisMonthSeconds = dated.filter { month.contains($0.0) }.reduce(0) { $0 + $1.1.seconds }
        }

        (stats.currentStreak, stats.longestStreak) = streaks(
            Set(dated.filter { $0.1.seconds > 0 }.map { calendar.startOfDay(for: $0.0) }),
            today: today, calendar: calendar)

        stats.heatmap = heatmap(dated, today: today, calendar: calendar)

        // Pace from comic sessions that genuinely turned pages; a novel has no pages.
        let paced = sessions.filter { !$0.isNovel && $0.pagesTurned > 0 && $0.activeSeconds > 0 }
        let pacedMinutes = paced.reduce(0) { $0 + $1.activeSeconds } / 60
        if pacedMinutes > 0 {
            stats.pagesPerMinute = Double(paced.reduce(0) { $0 + $1.pagesTurned }) / pacedMinutes
        }
        if !sessions.isEmpty {
            stats.averageSessionMinutes = sessions.reduce(0) { $0 + $1.activeSeconds } / Double(sessions.count) / 60
        }

        stats.timeOfDay = timeOfDay(sessions, calendar: calendar)

        var bySeries: [String: (name: String, seconds: Double)] = [:]
        for session in sessions {
            var entry = bySeries[session.seriesKey] ?? (session.seriesName, 0)
            entry.seconds += session.activeSeconds
            bySeries[session.seriesKey] = entry
        }
        stats.topSeriesByTime = bySeries.values
            .map { Bucket(name: $0.name, seconds: $0.seconds) }
            .sorted { $0.seconds > $1.seconds }
            .prefix(5)
            .map { $0 }
        return stats
    }

    /// The current streak counts today *or* yesterday as its end, so it doesn't read as broken
    /// first thing in the morning before you've picked a book up.
    static func streaks(_ readDays: Set<Date>, today: Date, calendar: Calendar) -> (current: Int, longest: Int) {
        guard !readDays.isEmpty else { return (0, 0) }
        var longest = 0
        var run = 0
        var previous: Date?
        for day in readDays.sorted() {
            if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == day {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = day
        }

        var current = 0
        var cursor = readDays.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today)
        while let day = cursor, readDays.contains(day) {
            current += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: day)
        }
        return (current, longest)
    }

    private static func heatmap(_ dated: [(Date, DayActivity)], today: Date, calendar: Calendar) -> [Day] {
        var byDay: [Date: DayActivity] = [:]
        for (date, value) in dated { byDay[calendar.startOfDay(for: date)] = value }
        // Start on the first day of the week, heatmapWeeks back, so columns line up as weeks.
        guard let thisWeekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start,
              let start = calendar.date(byAdding: .weekOfYear, value: -(heatmapWeeks - 1), to: thisWeekStart)
        else { return [] }
        var days: [Day] = []
        var cursor = start
        while cursor <= today {
            let value = byDay[cursor]
            days.append(Day(date: cursor, seconds: value?.seconds ?? 0, pages: value?.pages ?? 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    private static func timeOfDay(_ sessions: [ReadingSession], calendar: Calendar) -> [Bucket] {
        var totals: [String: Double] = ["Morning": 0, "Afternoon": 0, "Evening": 0, "Night": 0]
        for session in sessions {
            let hour = calendar.component(.hour, from: session.startedAt)
            let name = switch hour {
            case 5..<12: "Morning"
            case 12..<17: "Afternoon"
            case 17..<22: "Evening"
            default: "Night"
            }
            totals[name, default: 0] += session.activeSeconds
        }
        return ["Morning", "Afternoon", "Evening", "Night"].map { Bucket(name: $0, seconds: totals[$0] ?? 0) }
    }
}

enum Durations {
    /// "3h 20m", "45m", "under a minute".
    static func short(_ seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        guard minutes > 0 else { return seconds > 0 ? "<1m" : "0m" }
        let hours = minutes / 60
        return hours > 0 ? "\(hours)h \(minutes % 60)m" : "\(minutes)m"
    }
}
