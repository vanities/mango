import SwiftUI

/// Opens the right reader for what this actually is. A comic is a sequence of page images;
/// a novel is reflowable text. They share a library, a NAS, and an end-of-volume card, and
/// almost nothing else.
struct ReaderRouter: View {
    let comic: Comic

    var body: some View {
        if comic.isNovel {
            NovelReaderView(comic: comic)
        } else {
            ReaderView(comic: comic)
        }
    }
}
