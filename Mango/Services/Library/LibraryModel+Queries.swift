import Foundation

extension LibraryModel {
    /// What the top of the library shows: everything part-read, most recent first.
    var continueReading: [Comic] {
        state.comics
            .compactMap { comic -> (Comic, Date)? in
                guard let p = state.progress[comic.id], p.isStarted, !p.finished else { return nil }
                guard !state.hiddenComicIDs.contains(comic.id) else { return nil }
                return (comic, p.updatedAt)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// The single book the "Continue" button opens.
    var lastRead: Comic? {
        guard let id = state.lastComicID else { return continueReading.first }
        return state.comics.first { $0.id == id } ?? continueReading.first
    }

    /// The next volume to read in a run — the one already started, else the first unfinished.
    func nextUp(in series: Series) -> Comic? {
        SeriesGrouper.nextUp(in: series, progress: state.progress)
    }

    /// The volume after this one in its own series, in reading order. Nil when it's the last
    /// one — which is exactly when the reader should stop rather than wrap around.
    func nextInSeries(after comic: Comic) -> Comic? {
        let key = SeriesGrouper.key(for: comic)
        guard let shelf = series.first(where: { $0.id == key }),
              let index = shelf.comics.firstIndex(where: { $0.id == comic.id }),
              index + 1 < shelf.comics.count
        else { return nil }
        return shelf.comics[index + 1]
    }

    func isFinished(_ series: Series) -> Bool {
        !series.comics.isEmpty && series.comics.allSatisfy { state.progress[$0.id]?.finished == true }
    }

    /// How far through a run the reader is, counting finished volumes.
    func finishedCount(in series: Series) -> Int {
        series.comics.count { state.progress[$0.id]?.finished == true }
    }

    /// Manga and light novels are separate shelves and separate tabs.
    func series(for medium: Medium) -> [Series] {
        sortedSeries.filter { medium == .novels ? $0.isNovel : !$0.isNovel }
    }

    var hasNovels: Bool { series.contains(where: \.isNovel) }
    var hasComics: Bool { series.contains { !$0.isNovel } }

    var sortedSeries: [Series] {
        let shelves = settings.showFinished ? series : series.filter { !isFinished($0) }
        switch settings.librarySort {
        case .title:
            return shelves.sorted { $0.name.naturallyPrecedes($1.name) }
        case .recent:
            return shelves.sorted { lhs, rhs in
                let l = lhs.comics.map(\.addedAt).max() ?? .distantPast
                let r = rhs.comics.map(\.addedAt).max() ?? .distantPast
                return l > r
            }
        case .lastRead:
            return shelves.sorted { lhs, rhs in
                lastReadDate(lhs) > lastReadDate(rhs)
            }
        }
    }

    private func lastReadDate(_ series: Series) -> Date {
        series.comics.compactMap { state.progress[$0.id]?.updatedAt }.max() ?? .distantPast
    }

    func search(_ query: String, in medium: Medium) -> [Series] {
        let needle = query.normalizedForMatching
        let shelves = series(for: medium)
        guard !needle.isEmpty else { return shelves }
        return shelves.filter { shelf in
            shelf.name.normalizedForMatching.contains(needle)
                || shelf.comics.contains { $0.title.normalizedForMatching.contains(needle) }
        }
    }

    var totalComics: Int { state.comics.count }
    var totalBytes: Int64 { state.comics.reduce(0) { $0 + $1.totalBytes } }
    var remoteSourceCount: Int { state.sources.count { $0.isRemote } }
}
