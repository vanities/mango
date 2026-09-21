import Foundation
import os

// MARK: - Picked covers
//
// Covers from Find Cover or the user's own images. The image lives in CoverStore's custom
// directory (Application Support — it can't be rebuilt from page one), the choice in
// `state.customCovers`, and it's applied to every copy of the comic.

extension LibraryModel {
    func hasCustomCover(_ comic: Comic) -> Bool { state.customCovers[comic.id] != nil }

    /// Applies a picked image to a comic and its other copies. `origin` identifies the picture
    /// (the URL it came from, or a fingerprint of a photo) so a new pick gets a new id.
    func setCustomCover(_ data: Data, origin: String, for comic: Comic) async -> Bool {
        let sw = Stopwatch()
        let store = covers
        var installed: [(comicID: String, coverID: String)] = []
        for copy in state.copies(of: comic) {
            let coverID = CoverStore.customID(for: copy, origin: origin)
            let stored = await Task.detached(priority: .userInitiated) { store.storeCustom(imageData: data, as: coverID) }.value
            if stored { installed.append((copy.id, coverID)) }
        }
        guard !installed.isEmpty else {
            Logger.cover.error("[covers] picked image unusable for \(comic.title, privacy: .public) (\(data.count)B)")
            return false
        }
        var replaced: [String] = []
        mutateState { state in
            for (comicID, coverID) in installed {
                if let old = state.installCustomCover(coverID, for: comicID) { replaced.append(old) }
            }
        }
        for old in replaced { store.delete(old) }
        Logger.cover.info("[covers] picked cover for \(comic.title, privacy: .public) copies=\(installed.count) replaced=\(replaced.count) in \(sw.ms, format: .fixed(precision: 0))ms")
        return true
    }

    /// Drops a comic's picked cover (on every copy) and goes back to its page one.
    func useOriginalCover(for comic: Comic) {
        let store = covers
        var removed: [String] = []
        mutateState { state in
            for copy in state.copies(of: comic) {
                let original = CoverStore.coverID(for: copy)
                if let old = state.removeCustomCover(for: copy.id, original: store.exists(original) ? original : nil) {
                    removed.append(old)
                }
            }
        }
        for old in removed { store.delete(old) }
        Logger.cover.info("[covers] back to the original cover for \(comic.title, privacy: .public) removed=\(removed.count)")
        // A copy whose page-one cover was never made gets it from the backfill.
        startCoverBackfill()
    }

    /// Renames a shelf with a tidied name (and fills in an author where none is known).
    func renameSeries(_ series: Series, to newName: String, author: String?) {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        mutateState { state in
            state.renameSeries(series.comics.map(\.id), from: series.name, to: name, author: author)
        }
        if let moved = series.comics.first.flatMap({ comic in self.series.first { $0.comics.contains { $0.id == comic.id } } }),
           moved.id != series.id {
            seriesRedirects[series.id] = moved.id
        }
        Logger.library.info("[library] renamed \"\(series.name, privacy: .public)\" → \"\(name, privacy: .public)\" comics=\(series.comics.count) author=\(author ?? "-", privacy: .public)")
    }
}
