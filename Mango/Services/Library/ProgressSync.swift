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
