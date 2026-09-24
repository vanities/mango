import Foundation

extension LibraryModel {
    func updateBookmarkNote(_ mark: Bookmark, in comic: Comic, note: String) {
        guard let index = state.bookmarks[comic.id]?.firstIndex(where: { $0.id == mark.id }) else { return }
        // Bookmarks union by ID across devices. Replace and tombstone the old ID so an old
        // note on another device cannot win the union and undo this edit.
        mutateState { state in
            state.deletedBookmarks.bury(mark.id)
            state.bookmarks[comic.id]?[index] = Bookmark(page: mark.page, fraction: mark.fraction, note: note)
        }
    }
}
