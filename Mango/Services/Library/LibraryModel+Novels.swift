import Foundation
import os

extension LibraryModel {
    /// Keeps a novel's chapter names from its table of contents, for places that only have the
    /// saved state: the library's cards, the widget, bookmark search.
    func rememberChapterTitles(_ titles: [String?], for comic: Comic) {
        guard !titles.isEmpty, state.novelChapterTitles[comic.syncKey] != titles else { return }
        Logger.library.info("[library] chapter names for \(comic.title, privacy: .public): \(titles.count { $0 != nil }) of \(titles.count) documents named")
        mutateState { $0.novelChapterTitles[comic.syncKey] = titles }
    }

    func chapterTitles(for comic: Comic) -> [String?]? { state.novelChapterTitles[comic.syncKey] }

    /// Where a novel's reader is, by the book's own chapter names once it's been opened here.
    func novelPositionLabel(_ progress: ReadingProgress, in comic: Comic) -> String {
        progress.novelLabel(titles: chapterTitles(for: comic))
    }
}
