import Foundation

extension LibraryModel {
    /// A shelf by id, following renames — a shelf's id is its name, so a screen that's showing
    /// one when it's renamed would otherwise be left pointing at nothing.
    func shelf(id: String) -> Series? {
        var current = id
        for _ in 0..<8 {
            if let found = series.first(where: { $0.id == current }) { return found }
            guard let next = seriesRedirects[current] else { return nil }
            current = next
        }
        return nil
    }

    /// What the top of the library shows: everything part-read, most recent first.
    var continueReading: [Comic] {
        visibleComics
            .compactMap { comic -> (Comic, Date)? in
                guard let p = state.progress[comic.id], p.isStarted, !p.finished else { return nil }
                return (comic, p.updatedAt)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// The single book the "Continue" button opens.
    var lastRead: Comic? {
        guard let id = state.lastComicID else { return continueReading.first }
        return visibleComics.first { $0.id == id } ?? continueReading.first
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

    /// Built fresh from the library and progress — nothing extra is recorded to produce it.
    var stats: ReadingStats {
        let remoteSources = remoteSourceIDs
        let items = visibleComics.map { comic in
            ReadingStats.Item(
                seriesKey: SeriesGrouper.key(for: comic),
                seriesName: comic.series ?? comic.title,
                isNovel: comic.isNovel,
                format: comic.kind == .archive ? "CBZ" : comic.kind.rawValue.uppercased(),
                bytes: comic.totalBytes,
                isRemote: remoteSources.contains(comic.sourceID),
                pageCount: comic.pageCount,
                progress: state.progress[comic.id],
                rating: state.ratings[comic.id]
            )
        }
        return ReadingStats.build(items, log: state.readingLog)
    }

    var totalComics: Int { visibleComics.count }
    var totalBytes: Int64 { visibleComics.reduce(0) { $0 + $1.totalBytes } }
    var remoteSourceCount: Int { state.sources.count { $0.isRemote } }
}
