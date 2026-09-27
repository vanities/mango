import Foundation

extension LibraryModel {
    func addHighlight(_ anchor: NovelTextAnchor, page: Int, fraction: Double, note: String, to comic: Comic) {
        guard !anchor.quote.isEmpty, anchor.quote.utf16.count <= 10000, anchor.offset >= 0 else { return }
        mutateState { state in
            var marks = state.bookmarks[comic.id] ?? []
            guard !marks.contains(where: { $0.page == page && $0.anchor == anchor }) else { return }
            marks.append(Bookmark(page: page, fraction: fraction, note: note, anchor: anchor))
            state.bookmarks[comic.id] = marks
        }
    }

    func updateBookmarkNote(_ mark: Bookmark, in comic: Comic, note: String) {
        guard let index = state.bookmarks[comic.id]?.firstIndex(where: { $0.id == mark.id }) else { return }
        // Bookmarks union by ID across devices. Replace and tombstone the old ID so an old
        // note on another device cannot win the union and undo this edit.
        mutateState { state in
            state.deletedBookmarks.bury(mark.id)
            state.bookmarks[comic.id]?[index] = Bookmark(page: mark.page, fraction: mark.fraction, note: note, anchor: mark.anchor)
        }
    }
}
