import Foundation

extension LibraryModel {
    /// Opening a reader selects the current book even when its saved page doesn't change.
    /// Cover backfill also opens archives, so this belongs to explicit reader sessions.
    func beginReading(_ comic: Comic, pageCount: Int) {
        noteHiddenActivity()
        mutateState { state in
            var entry = state.progress[comic.id] ?? ReadingProgress()
            if entry.finished { entry = ReadingProgress() }
            entry.pageCount = pageCount
            entry.updatedAt = .now
            state.setProgress(entry, forCopiesOf: comic)
            state.lastComicID = comic.id
        }
    }
}
