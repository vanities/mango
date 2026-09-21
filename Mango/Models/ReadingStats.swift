import Foundation

/// Everything the Stats tab shows, derived from data Mango already keeps.
///
/// Nothing here is tracked specially: it's the library plus `ReadingProgress`. A volume's
/// "finished" date is the last time its progress changed, which is the best available answer
/// — re-opening a finished book moves it, and that's a fair trade for not logging anything.
struct ReadingStats: Equatable, Sendable {
    struct Month: Equatable, Identifiable, Sendable {
        var id: Date { start }
        var start: Date
        var finished: Int
        var label: String
    }

    struct Bucket: Equatable, Identifiable, Sendable {
        var id: String { name }
        var name: String
        var count: Int
    }

    var finishedVolumes = 0
    var inProgressVolumes = 0
    var unreadVolumes = 0
    var totalVolumes = 0
    /// Pages actually turned: every page of a finished comic plus where you are in the rest.
    var pagesRead = 0
    var finishedSeries = 0
    var startedSeries = 0
    var totalSeries = 0
    var thisYear = 0
    var bestMonth: Month?
    /// Last 12 months, oldest first, gaps filled with zeroes so the chart has an even axis.
    var months: [Month] = []
    var byFormat: [Bucket] = []
    var byMedium: [Bucket] = []
    var topSeries: [Bucket] = []
    var localBytes: Int64 = 0
    var remoteBytes: Int64 = 0

    var isEmpty: Bool { totalVolumes == 0 }
    var hasReadAnything: Bool { finishedVolumes > 0 || pagesRead > 0 }
    var totalBytes: Int64 { localBytes + remoteBytes }

    struct Item: Sendable {
        var seriesKey: String
        var seriesName: String
        var isNovel: Bool
        var format: String
        var bytes: Int64
        var isRemote: Bool
        var pageCount: Int?
        var progress: ReadingProgress?
    }

    static func build(_ items: [Item], now: Date = .now,
                      calendar: Calendar = Calendar(identifier: .gregorian)) -> ReadingStats {
        var stats = ReadingStats()
        stats.totalVolumes = items.count

        var perSeries: [String: (name: String, total: Int, finished: Int, started: Int)] = [:]
        var formatCounts: [String: Int] = [:]
        var mediumCounts: [String: Int] = [:]
        var finishDates: [Date] = []

        for item in items {
            let progress = item.progress
            let finished = progress?.finished == true
            let started = progress?.isStarted == true && !finished

            if finished {
                stats.finishedVolumes += 1
            } else if started {
                stats.inProgressVolumes += 1
            } else {
                stats.unreadVolumes += 1
            }

            // A finished comic counts every page; an open one counts as far as you've got.
            if finished {
                stats.pagesRead += item.pageCount ?? progress?.pageCount ?? 0
            } else if let progress, progress.isStarted {
                stats.pagesRead += progress.page
            }

            if finished, let date = progress?.updatedAt { finishDates.append(date) }

            formatCounts[item.format, default: 0] += 1
            mediumCounts[item.isNovel ? "Novels" : "Manga", default: 0] += 1
            if item.isRemote { stats.remoteBytes += item.bytes } else { stats.localBytes += item.bytes }

            var entry = perSeries[item.seriesKey] ?? (item.seriesName, 0, 0, 0)
            entry.name = item.seriesName
            entry.total += 1
            if finished { entry.finished += 1 }
            if finished || started { entry.started += 1 }
            perSeries[item.seriesKey] = entry
        }

        stats.totalSeries = perSeries.count
        stats.finishedSeries = perSeries.values.count { $0.total > 0 && $0.finished == $0.total }
        stats.startedSeries = perSeries.values.count { $0.started > 0 && $0.finished < $0.total }

        let currentYear = calendar.component(.year, from: now)
        stats.thisYear = finishDates.count { calendar.component(.year, from: $0) == currentYear }

        stats.months = monthBuckets(finishDates, now: now, calendar: calendar)
        stats.bestMonth = stats.months.max { $0.finished < $1.finished }.flatMap { $0.finished > 0 ? $0 : nil }

        stats.byFormat = formatCounts.map { Bucket(name: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
        stats.byMedium = mediumCounts.map { Bucket(name: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
        stats.topSeries = perSeries.values
            .filter { $0.finished > 0 }
            .map { Bucket(name: $0.name, count: $0.finished) }
            .sorted { ($0.count, $1.name) > ($1.count, $0.name) }
            .prefix(6)
            .map { $0 }
        return stats
    }

    /// The last 12 months including this one, zero-filled — a bar chart with holes in it
    /// reads as missing data rather than a quiet month.
    private static func monthBuckets(_ dates: [Date], now: Date, calendar: Calendar) -> [Month] {
        guard let thisMonth = calendar.dateInterval(of: .month, for: now)?.start else { return [] }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.setLocalizedDateFormatFromTemplate("MMM")

        var counts: [Date: Int] = [:]
        for date in dates {
            guard let start = calendar.dateInterval(of: .month, for: date)?.start else { continue }
            counts[start, default: 0] += 1
        }
        return (0..<12).reversed().compactMap { offset in
            guard let start = calendar.date(byAdding: .month, value: -offset, to: thisMonth) else { return nil }
            return Month(start: start, finished: counts[start] ?? 0, label: formatter.string(from: start))
        }
    }
}
