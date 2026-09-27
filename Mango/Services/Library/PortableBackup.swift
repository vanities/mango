import Foundation
import ShelfKit

extension LibraryState {
    /// Only unique path matches are eligible; a colliding title or path is never guessed.
    func portableMatches(_ old: LibraryState) -> [(String, String)] {
        let current = Dictionary(grouping: comics, by: \.syncKey)
        let previous = Dictionary(grouping: old.comics, by: \.syncKey)
        return previous.flatMap { key, copies -> [(String, String)] in
            guard let destinations = current[key], validPortableCopies(destinations), old.validPortableCopies(copies) else { return [] }
            // Copies must describe the same size and format before state can follow them.
            let sizes = Set((copies + destinations).map(\.totalBytes))
            guard sizes.count == 1, !sizes.contains(0) else { return [] }
            let chosen = copies.sorted { (old.progress[$0.id]?.updatedAt ?? .distantPast) > (old.progress[$1.id]?.updatedAt ?? .distantPast) }.first!
            return destinations.map { (chosen.id, $0.id) }
        }
    }
    private func validPortableCopies(_ items: [Comic]) -> Bool {
        guard items.count > 1 else { return true }
        guard items.count == 2 else { return false }
        let kinds = items.compactMap { item in sources.first(where: { $0.id == item.sourceID })?.kind }
        return kinds.contains(.appDocuments) && kinds.contains(.smb) && items[0].kind == items[1].kind
    }
    mutating func restorePortable(_ old: LibraryState) {
        deletedBookmarks = deletedBookmarks.merging(old.deletedBookmarks)
        for (from, to) in portableMatches(old) {
            if progress[to] == nil { progress[to] = old.progress[from] }
            if overrides[to] == nil { overrides[to] = old.overrides[from] }
            if customCovers[to] == nil, let book = comics.first(where: { $0.id == to }), coverChoices[book.syncKey] == nil { customCovers[to] = old.customCovers[from] }
            if ratings[to] == nil, ratingDates[to] == nil { ratings[to] = old.ratings[from] }
            if ratingDates[to] == nil { ratingDates[to] = old.ratingDates[from] }
            if comicInfo[to] == nil { comicInfo[to] = old.comicInfo[from] }
            let known = Set((bookmarks[to] ?? []).map(\.id))
            let incoming = (old.bookmarks[from] ?? []).filter { !known.contains($0.id) && !deletedBookmarks.contains($0.id) }
            bookmarks[to] = ((bookmarks[to] ?? []) + incoming).filter { !deletedBookmarks.contains($0.id) }.sorted { ($0.page, $0.fraction ?? 0) < ($1.page, $1.fraction ?? 0) }
        }
        let knownLists = Set(readingLists.map(\.id))
        readingLists.append(contentsOf: old.readingLists.filter { !knownLists.contains($0.id) })
        let knownLogs = Set(readingLog.map(\.id))
        readingLog.append(contentsOf: old.readingLog.filter { !knownLogs.contains($0.id) })
        let knownShelves = Set(tools.smartShelves.map(\.id))
        tools.smartShelves.append(contentsOf: old.tools.smartShelves.filter { !knownShelves.contains($0.id) })
    }
}
