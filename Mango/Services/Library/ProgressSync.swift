import Foundation
import ShelfKit

/// Merge rules for syncing reading positions across devices, kept apart from the iCloud
/// transport so they can be tested without iCloud.
///
/// Positions travel keyed by `Comic.syncKey` — the relative path — rather than `Comic.id`,
/// which embeds a per-install source UUID and so is different on every device. Conflicts are
/// last-writer-wins on `updatedAt`: whichever device you last read on is where you are.
enum ProgressSync {
    private static func isNewer(_ candidate: ReadingProgress, than existing: ReadingProgress?) -> Bool {
        guard let existing else { return true }
        return candidate.updatedAt > existing.updatedAt
    }

    /// Local positions with any newer cloud entries folded in. A cloud entry updates every
    /// local comic sharing its key — which includes a downloaded copy and its remote twin.
    static func merged(local: [String: ReadingProgress], comics: [Comic],
                       cloud: [String: ReadingProgress]) -> [String: ReadingProgress] {
        guard !cloud.isEmpty else { return local }
        var result = local
        var idsByKey: [String: [String]] = [:]
        for comic in comics { idsByKey[comic.syncKey, default: []].append(comic.id) }
        for (key, cloudEntry) in cloud {
            guard let ids = idsByKey[key] else { continue }
            for id in ids where isNewer(cloudEntry, than: result[id]) {
                result[id] = cloudEntry
            }
        }
        return result
    }

    /// What to write back: the existing cloud with local entries laid over it wherever local is
    /// newer. Entries for books this device doesn't have are kept, so an iPad with half the
    /// library can't erase the iPhone's positions for the other half.
    static func cloudSnapshot(local: [String: ReadingProgress], comics: [Comic],
                              existingCloud: [String: ReadingProgress]) -> [String: ReadingProgress] {
        var cloud = existingCloud
        var keyByID: [String: String] = [:]
        for comic in comics { keyByID[comic.id] = comic.syncKey }
        for (id, entry) in local {
            guard let key = keyByID[id] else { continue }
            if isNewer(entry, than: cloud[key]) { cloud[key] = entry }
        }
        return cloud
    }
}

/// Merge rules for the smaller things that follow you between devices: ratings, bookmarks and
/// the reading log (ShelfKit's `UnionSync`, `Tombstones` and `LatestWins` underneath).
///
/// A plain union brought back whatever was deleted or cleared — the other device still had it.
/// So bookmarks union *minus* the ones deleted anywhere, and a rating is whichever device set or
/// cleared it last.
enum CollectionSync {
    /// Per file, the latest set or clear of its rating. A rating from before ratings carried a
    /// date counts as the oldest, so any dated change beats it.
    static func mergedRatings(local: [String: Int], dates: [String: Date], comics: [Comic],
                              cloud: [String: Stamped<Int>]) -> (ratings: [String: Int], dates: [String: Date]) {
        var ratings = local, stamps = dates
        for comic in comics {
            guard let remote = cloud[comic.syncKey] else { continue }
            // Never rated or cleared here: take iCloud's, dated or not. Otherwise only a newer one.
            let touchedHere = stamps[comic.id] != nil || ratings[comic.id] != nil
            guard !touchedHere || remote.at > (stamps[comic.id] ?? .distantPast) else { continue }
            ratings[comic.id] = remote.value
            if remote.at > .distantPast { stamps[comic.id] = remote.at }
        }
        return (ratings, stamps)
    }

    /// What to write back: every rating this device set or cleared, wherever it's the newer.
    static func ratingsSnapshot(local: [String: Int], dates: [String: Date], comics: [Comic],
                                existingCloud: [String: Stamped<Int>]) -> [String: Stamped<Int>] {
        var mine: [String: Stamped<Int>] = [:]
        for comic in comics where local[comic.id] != nil || dates[comic.id] != nil {
            let stamped = Stamped(local[comic.id], at: dates[comic.id] ?? .distantPast)
            if stamped.at >= (mine[comic.syncKey]?.at ?? .distantPast) { mine[comic.syncKey] = stamped }
        }
        return LatestWins.merge(existingCloud, mine)
    }

    /// Bookmarks unioned by id — a spot saved on the iPad appears on the phone without the
    /// phone's own being lost — minus any deleted on either.
    static func mergedBookmarks(local: [String: [Bookmark]], comics: [Comic],
                                cloud: [String: [Bookmark]], buried: Tombstones) -> [String: [Bookmark]] {
        var result = local
        for comic in comics {
            guard let remote = cloud[comic.syncKey], !remote.isEmpty else { continue }
            result[comic.id] = UnionSync.merge(result[comic.id] ?? [], remote, without: buried)
        }
        for (id, list) in result {
            let kept = list.filter { !buried.contains($0.id) }.sorted { ($0.page, $0.fraction ?? 0) < ($1.page, $1.fraction ?? 0) }
            result[id] = kept.isEmpty ? nil : kept
        }
        return result
    }

    static func bookmarksSnapshot(local: [String: [Bookmark]], comics: [Comic],
                                  existingCloud: [String: [Bookmark]], buried: Tombstones) -> [String: [Bookmark]] {
        var cloud = existingCloud.mapValues { $0.filter { !buried.contains($0.id) } }.filter { !$0.value.isEmpty }
        let keyByID = Dictionary(comics.map { ($0.id, $0.syncKey) }, uniquingKeysWith: { first, _ in first })
        for (id, marks) in local {
            guard let key = keyByID[id] else { continue }
            let merged = UnionSync.merge(cloud[key] ?? [], marks, without: buried)
            cloud[key] = merged.isEmpty ? nil : merged
        }
        return cloud
    }

    static func mergedLog(local: [ReadingLogEntry], cloud: [ReadingLogEntry]) -> [ReadingLogEntry] {
        let known = Set(local.map(\.id))
        return (local + cloud.filter { !known.contains($0.id) }).sorted { $0.finishedAt > $1.finishedAt }
    }
}
