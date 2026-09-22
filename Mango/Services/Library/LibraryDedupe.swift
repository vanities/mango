import Foundation

/// Reconciling a downloaded copy with the one still on the share.
///
/// Pulling a volume local produces a second `Comic` — same file, same relative path, different
/// source, therefore a different `Comic.id`. Left alone that means the shelf shows it twice and
/// the reader's position silently resets, because progress is keyed by id. Pure functions so
/// both behaviours are testable without a library on disk.
enum LibraryDedupe {
    /// Drops hidden comics, and drops a remote comic once a local copy of the same file exists.
    /// The local one wins: it opens instantly and works off the network.
    static func visible(comics: [Comic], remoteSourceIDs: Set<UUID>, hidden: Set<String>,
                        hiddenSeries: Set<String> = []) -> [Comic] {
        let localKeys = Set(comics.filter { !remoteSourceIDs.contains($0.sourceID) }.map(\.syncKey))
        return comics.filter { comic in
            guard !hidden.contains(comic.id) else { return false }
            guard hiddenSeries.isEmpty || !hiddenSeries.contains(SeriesGrouper.key(for: comic)) else { return false }
            guard remoteSourceIDs.contains(comic.sourceID) else { return true }
            return !localKeys.contains(comic.syncKey)
        }
    }

    /// True when this local comic is a downloaded copy of something on a share — used to badge
    /// it, since after deduplication the remote twin is no longer on screen to compare against.
    static func isDownloadedCopy(_ comic: Comic, comics: [Comic], remoteSourceIDs: Set<UUID>) -> Bool {
        guard !remoteSourceIDs.contains(comic.sourceID) else { return false }
        return comics.contains { remoteSourceIDs.contains($0.sourceID) && $0.syncKey == comic.syncKey }
    }
}

extension LibraryState {
    /// Copies everything the user did on a remote comic onto its downloaded twin. Only ever
    /// fills gaps — anything the local copy already has is newer by definition. Returns how
    /// many reading positions were carried across, for the log.
    @discardableResult
    mutating func adoptStateFromRemoteTwins(remoteSourceIDs: Set<UUID>) -> Int {
        let remoteByKey = Dictionary(
            comics.filter { remoteSourceIDs.contains($0.sourceID) }.map { ($0.syncKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        guard !remoteByKey.isEmpty else { return 0 }

        var adopted = 0
        for local in comics where !remoteSourceIDs.contains(local.sourceID) {
            guard let twin = remoteByKey[local.syncKey] else { continue }
            if progress[local.id] == nil, let carried = progress[twin.id] {
                progress[local.id] = carried
                adopted += 1
            }
            if overrides[local.id] == nil, let override = overrides[twin.id] {
                overrides[local.id] = override
            }
            if customCovers[local.id] == nil, let cover = customCovers[twin.id] {
                customCovers[local.id] = cover
            }
            if ratings[local.id] == nil, let rating = ratings[twin.id] {
                ratings[local.id] = rating
                ratingDates[local.id] = ratingDates[twin.id]
            }
            if bookmarks[local.id] == nil, let marks = bookmarks[twin.id] {
                bookmarks[local.id] = marks
            }
            // Hiding a remote twin must hide its download too, or it reappears.
            if hiddenComicIDs.contains(twin.id) { hiddenComicIDs.insert(local.id) }
            if longStripComicIDs.contains(twin.id) { longStripComicIDs.insert(local.id) }
            // Continue Reading has to follow the copy that's actually on screen.
            if lastComicID == twin.id { lastComicID = local.id }
        }
        return adopted
    }
}
