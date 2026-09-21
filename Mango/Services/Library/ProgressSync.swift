import Foundation

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
/// the reading log. Unlike positions these don't go stale — an older rating isn't wrong — so
/// they merge as unions rather than last-writer-wins, with this device winning a conflict.
enum CollectionSync {
    /// Cloud ratings for books this device has but hasn't rated.
    static func mergedRatings(local: [String: Int], comics: [Comic], cloud: [String: Int]) -> [String: Int] {
        var result = local
        for comic in comics where result[comic.id] == nil {
            if let rating = cloud[comic.syncKey] { result[comic.id] = rating }
        }
        return result
    }

    static func ratingsSnapshot(local: [String: Int], comics: [Comic], existingCloud: [String: Int]) -> [String: Int] {
        var cloud = existingCloud
        let keyByID = Dictionary(comics.map { ($0.id, $0.syncKey) }, uniquingKeysWith: { first, _ in first })
        for (id, rating) in local { if let key = keyByID[id] { cloud[key] = rating } }
        return cloud
    }

    /// Bookmarks unioned by id, so a spot saved on the iPad appears on the phone without the
    /// phone's own being lost.
    static func mergedBookmarks(local: [String: [Bookmark]], comics: [Comic],
                                cloud: [String: [Bookmark]]) -> [String: [Bookmark]] {
        var result = local
        for comic in comics {
            guard let remote = cloud[comic.syncKey], !remote.isEmpty else { continue }
            var list = result[comic.id] ?? []
            let known = Set(list.map(\.id))
            list.append(contentsOf: remote.filter { !known.contains($0.id) })
            result[comic.id] = list.sorted { ($0.page, $0.fraction ?? 0) < ($1.page, $1.fraction ?? 0) }
        }
        return result
    }

    static func bookmarksSnapshot(local: [String: [Bookmark]], comics: [Comic],
                                  existingCloud: [String: [Bookmark]]) -> [String: [Bookmark]] {
        var cloud = existingCloud
        let keyByID = Dictionary(comics.map { ($0.id, $0.syncKey) }, uniquingKeysWith: { first, _ in first })
        for (id, marks) in local {
            guard let key = keyByID[id] else { continue }
            var list = cloud[key] ?? []
            let known = Set(list.map(\.id))
            list.append(contentsOf: marks.filter { !known.contains($0.id) })
            cloud[key] = list
        }
        return cloud
    }

    static func mergedLog(local: [ReadingLogEntry], cloud: [ReadingLogEntry]) -> [ReadingLogEntry] {
        let known = Set(local.map(\.id))
        return (local + cloud.filter { !known.contains($0.id) }).sorted { $0.finishedAt > $1.finishedAt }
    }
}
