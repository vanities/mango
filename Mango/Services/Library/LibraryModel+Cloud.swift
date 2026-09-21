import Foundation
import os

// MARK: - iCloud
//
// Your own iCloud key-value storage: positions, ratings, bookmarks, the reading log, day totals
// and cover choices, each matched across devices by the comic's file.

extension LibraryModel {
    /// Folds in anything another device wrote more recently. Positions are matched by relative
    /// path, so a book only syncs to devices that have the same file in the same place.
    func mergeFromCloud() {
        var progress = state.progress, ratings = state.ratings, bookmarks = state.bookmarks, log = state.readingLog
        if let remote = cloud.load([String: ReadingProgress].self, .progress), !remote.isEmpty {
            let merged = ProgressSync.merged(local: progress, comics: state.comics, cloud: remote)
            let count = merged.filter { progress[$0.key] != $0.value }.count
            if count > 0 { Logger.store.info("[cloud] took \(count) newer position(s) from another device") }
            progress = merged
        }
        if let remote = cloud.load([String: Int].self, .ratings) {
            ratings = CollectionSync.mergedRatings(local: ratings, comics: state.comics, cloud: remote)
        }
        if let remote = cloud.load([String: [Bookmark]].self, .bookmarks) {
            bookmarks = CollectionSync.mergedBookmarks(local: bookmarks, comics: state.comics, cloud: remote)
        }
        if let remote = cloud.load([ReadingLogEntry].self, .readingLog) {
            log = CollectionSync.mergedLog(local: log, cloud: remote)
        }
        if progress != state.progress || ratings != state.ratings || bookmarks != state.bookmarks || log != state.readingLog {
            mutateState { state in
                state.progress = progress
                state.ratings = ratings
                state.bookmarks = bookmarks
                state.readingLog = log
            }
        }
        applySyncedCovers()
    }

    func pushToCloud() {
        let progress = cloud.load([String: ReadingProgress].self, .progress) ?? [:]
        cloud.save(ProgressSync.cloudSnapshot(local: state.progress, comics: state.comics, existingCloud: progress), .progress)
        let ratings = cloud.load([String: Int].self, .ratings) ?? [:]
        cloud.save(CollectionSync.ratingsSnapshot(local: state.ratings, comics: state.comics, existingCloud: ratings), .ratings)
        let marks = cloud.load([String: [Bookmark]].self, .bookmarks) ?? [:]
        cloud.save(CollectionSync.bookmarksSnapshot(local: state.bookmarks, comics: state.comics, existingCloud: marks), .bookmarks)
        let log = cloud.load([ReadingLogEntry].self, .readingLog) ?? []
        cloud.save(CollectionSync.mergedLog(local: state.readingLog, cloud: log), .readingLog)
        let covers = cloud.load([String: CoverChoice].self, .covers) ?? [:]
        cloud.save(CoverSync.snapshot(local: state.coverChoices, cloud: covers), .covers)
        pushActivity()
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
