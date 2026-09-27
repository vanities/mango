import Foundation
import ShelfKit

extension LibraryModel {
    var toolItems: [LibraryToolItem] {
        let pace = activityStats.pagesPerMinute
        return visibleComics.map { comic in
            let entry = progress(for: comic)
            var remaining: Double?
            if !comic.isNovel, let pace, pace > 0, let count = comic.pageCount, count > 0 {
                remaining = Double(max(0, count - (entry?.page ?? 0))) / pace * 60
            }
            return LibraryToolItem(id: comic.syncKey, title: comic.title, detail: comic.displaySeries, bytes: comic.totalBytes,
                             isLocal: !comic.isRemote(in: self), started: entry != nil, finished: entry?.finished ?? false,
                             lastOpened: entry?.updatedAt, remainingSeconds: remaining)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    var tripGroups: [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for list in state.readingLists {
            let comics = entries(of: list).flatMap { entry -> [Comic] in
                switch entry {
                case .volume(let comic): [comic]
                case .series(let series): series.comics
                case .missing: []
                }
            }
            result["\(list.name) · \(list.id.uuidString.prefix(4))"] = Set(comics.map(\.syncKey))
        }
        result["Continue reading"] = Set(continueReading.map(\.syncKey))
        var next: Set<String> = []
        for comic in continueReading {
            var current = comic
            for _ in 0..<3 {
                guard let following = nextInSeries(after: current), next.insert(following.syncKey).inserted else { break }
                current = following
            }
        }
        result["Next three in each series"] = next
        return result
    }
    func checkOffline(key: String) async -> OfflineReadiness {
        guard let comic = visibleComics.first(where: { $0.syncKey == key }) else { return .unavailable }
        if comic.isRemote(in: self) { return .needsDownload }
        guard let source = state.sources.first(where: { $0.id == comic.sourceID }), let root = root(for: source) else { return .unavailable }
        let url = source.kind == .file ? root : root.appending(path: comic.relativePath)
        let managed = source.kind == .appDocuments
        let bytes = nasCopy(of: comic)?.totalBytes ?? comic.totalBytes
        return await Task.detached(priority: .utility) {
            comic.kind == .folder ? OfflineReadiness.checkImageFolder(url, managedCopy: managed, expectedBytes: bytes)
                : OfflineReadiness.check(files: [.init(url: url, expectedBytes: bytes)], managedCopy: managed)
        }.value
    }
}
