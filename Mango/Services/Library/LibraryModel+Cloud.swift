import Foundation
import os
import ShelfKit

// MARK: - iCloud
//
// Your own iCloud key-value storage: positions, ratings, bookmarks, the reading log, day totals
// and cover choices, each matched across devices by the comic's file.

extension LibraryModel {
    /// Folds in anything another device wrote more recently. Positions are matched by relative
    /// path, so a book only syncs to devices that have the same file in the same place.
    func mergeFromCloud() {
        var progress = state.progress, ratings = state.ratings, ratingDates = state.ratingDates
        var bookmarks = state.bookmarks, log = state.readingLog
        if let remote = cloud.load([String: ReadingProgress].self, .progress), !remote.isEmpty {
            let merged = ProgressSync.merged(local: progress, comics: state.comics, cloud: remote)
            let count = merged.filter { progress[$0.key] != $0.value }.count
            if count > 0 { Logger.store.info("[cloud] took \(count) newer position(s) from another device") }
            progress = merged
        }
        (ratings, ratingDates) = CollectionSync.mergedRatings(local: ratings, dates: ratingDates, comics: state.comics,
                                                              cloud: cloudRatings())
        let buried = deletedBookmarks()
        bookmarks = CollectionSync.mergedBookmarks(local: bookmarks, comics: state.comics,
                                                   cloud: cloud.load([String: [Bookmark]].self, .bookmarks) ?? [:], buried: buried)
        if let remote = cloud.load([ReadingLogEntry].self, .readingLog) {
            log = CollectionSync.mergedLog(local: log, cloud: remote)
        }
        if progress != state.progress || ratings != state.ratings || ratingDates != state.ratingDates
            || bookmarks != state.bookmarks || buried != state.deletedBookmarks || log != state.readingLog {
            let removed = state.bookmarks.values.reduce(0) { $0 + $1.count } - bookmarks.values.reduce(0) { $0 + $1.count }
            if removed > 0 { Logger.store.info("[cloud] removed \(removed) bookmark(s) deleted on another device") }
            mutateState { state in
                state.progress = progress
                state.ratings = ratings
                state.ratingDates = ratingDates
                state.bookmarks = bookmarks
                state.deletedBookmarks = buried
                state.readingLog = log
            }
        }
        applySyncedCovers()
    }

    func pushToCloud() {
        let progress = cloud.load([String: ReadingProgress].self, .progress) ?? [:]
        cloud.save(ProgressSync.cloudSnapshot(local: state.progress, comics: state.comics, existingCloud: progress), .progress)
        cloud.save(CollectionSync.ratingsSnapshot(local: state.ratings, dates: state.ratingDates, comics: state.comics,
                                                  existingCloud: cloudRatings()), .ratingsV2)
        let buried = deletedBookmarks()
        let marks = cloud.load([String: [Bookmark]].self, .bookmarks) ?? [:]
        cloud.save(CollectionSync.bookmarksSnapshot(local: state.bookmarks, comics: state.comics, existingCloud: marks,
                                                    buried: buried), .bookmarks)
        cloud.save(buried, .deletedBookmarks)
        let log = cloud.load([ReadingLogEntry].self, .readingLog) ?? []
        cloud.save(CollectionSync.mergedLog(local: state.readingLog, cloud: log), .readingLog)
        let covers = cloud.load([String: CoverChoice].self, .covers) ?? [:]
        cloud.save(CoverSync.snapshot(local: state.coverChoices, cloud: covers), .covers)
        pushActivity()
    }

    /// iCloud's ratings: `ratings.v2`, or before any device wrote that, the undated v1 as the oldest.
    private func cloudRatings() -> [String: Stamped<Int>] {
        if let dated = cloud.load([String: Stamped<Int>].self, .ratingsV2) { return dated }
        return (cloud.load([String: Int].self, .ratings) ?? [:]).mapValues { Stamped($0, at: .distantPast) }
    }

    /// Deletions from here and every other device. Pruned at 180 days: every device has long
    /// seen them by then, and iCloud's store is capped near 1 MB.
    private func deletedBookmarks() -> Tombstones {
        let everywhere = state.deletedBookmarks.merging(cloud.load(Tombstones.self, .deletedBookmarks) ?? Tombstones())
        return everywhere.pruned(before: Date.now.addingTimeInterval(-180 * 86_400))
    }

    /// Covers another device chose after this one last did anything to that file: fetch a Find
    /// Cover pick from the same URL, or go back to page one. A photo pick can't travel, so it's
    /// only noted — this device keeps its own cover.
    private func applySyncedCovers() {
        guard let cloudChoices = cloud.load([String: CoverChoice].self, .covers) else { return }
        let pending = CoverSync.pending(cloud: cloudChoices, applied: state.coverChoices)
        for (key, choice) in pending {
            guard let comic = state.comics.first(where: { $0.syncKey == key }) else { continue }
            switch choice.kind {
            case .online:
                guard let url = choice.url.flatMap(URL.init(string:)) else { continue }
                Task { [weak self] in await self?.fetchSyncedCover(url, for: comic, choice: choice) }
            case .original:
                useOriginalCover(for: comic, choice: choice)
            case .device:
                mutateState { $0.coverChoices[key] = choice }
            }
        }
    }

    private func fetchSyncedCover(_ url: URL, for comic: Comic, choice: CoverChoice) async {
        do {
            let data = try await CoverSearch.download(url)
            // Still the newest choice once it's downloaded? Something newer may have landed.
            guard (state.coverChoices[comic.syncKey]?.chosenAt ?? .distantPast) < choice.chosenAt else { return }
            if await setCustomCover(data, origin: url.absoluteString, for: comic, choice: choice) {
                Logger.cover.info("[cloud] applied a cover picked on another device for \(comic.title, privacy: .public)")
            }
        } catch {
            Logger.cover.notice("[cloud] couldn't fetch a synced cover for \(comic.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
