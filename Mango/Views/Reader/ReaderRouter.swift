import SwiftUI

/// Opens the right reader for what this actually is. A comic is a sequence of page images;
/// a novel is reflowable text. They share a library, a NAS, and an end-of-volume card, and
/// almost nothing else.
struct ReaderRouter: View {
    let comic: Comic
    var startAt: Bookmark?
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss

    private var activeComic: Comic {
        guard let current = library.state.comics.first(where: { $0.id == library.state.lastComicID }),
              SeriesGrouper.key(for: current) == SeriesGrouper.key(for: comic) else { return comic }
        return current
    }

    var body: some View {
        Group {
            if library.isConcealed(activeComic) {
                ContentUnavailableView {
                    Label("Hidden Title", systemImage: "eye.slash")
                } description: {
                    Text("Unlock hidden titles from the library to continue reading.")
                } actions: {
                    Button("Back to Library") { dismiss() }
                }
            } else if comic.isNovel {
                NovelReaderView(comic: comic, startAt: startAt)
            } else {
                ReaderView(comic: comic, startAt: startAt)
            }
        }
        .onChange(of: library.isConcealed(activeComic)) { _, concealed in
            if concealed { dismiss() }
        }
    }
}
