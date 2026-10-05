import SwiftUI
import ShelfKit

struct BookmarkSearchView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var editing: Result?
    @State private var note = ""
    @State private var showsNoteEditor = false
    @State private var selected: Result?

    private struct Result: Identifiable {
        let book: Comic
        let mark: Bookmark
        /// A novel's chapter by the book's own name once it's been opened here ("Chapter 20"),
        /// else by number.
        let location: String
        var id: String { "\(book.id)|\(mark.id)" }
    }
    private var results: [Result] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return library.visibleComics.flatMap { book in
            library.bookmarks(for: book).map { mark in
                let name = book.isNovel ? NovelContents.name(of: mark.page, titles: library.chapterTitles(for: book)) : nil
                return Result(book: book, mark: mark, location: name ?? mark.label(isNovel: book.isNovel))
            }
        }.filter { result in
            let text = [result.book.title, result.book.series ?? "", result.book.author ?? "", result.mark.note, result.mark.anchor?.quote ?? "", result.location].joined(separator: " ")
            return words.allSatisfy { text.localizedStandardContains($0) }
        }.sorted { $0.mark.createdAt > $1.mark.createdAt }
    }
    var body: some View {
        NavigationStack {
            List(results) { result in
                Button {
                    selected = result
                } label: {
                    BookmarkSearchRow(title: result.book.title, note: result.mark.note.isEmpty ? (result.mark.anchor?.quote ?? "") : result.mark.note, location: result.location)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Edit note", systemImage: "square.and.pencil") {
                        editing = result
                        note = result.mark.note
                        showsNoteEditor = true
                    }
                }
            }
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No bookmarks yet" : "No matching bookmarks", systemImage: "bookmark",
                                           description: Text("Save a spot while reading, then find it here by title or note. Touch and hold a bookmark to edit its note."))
                }
            }
            .alert("Bookmark note", isPresented: $showsNoteEditor) {
                TextField("Note", text: $note)
                Button("Save") {
                    if let editing { library.updateBookmarkNote(editing.mark, in: editing.book, note: note) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .searchable(text: $query, prompt: "Titles, bookmarks, notes")
            .navigationTitle("Bookmarks & notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fullScreenCover(item: $selected) { result in ReaderRouter(comic: result.book, startAt: result.mark) }
            .onChange(of: library.hiddenSession.isUnlocked) { _, unlocked in
                if !unlocked, let editing, library.isHidden(editing.book) {
                    self.editing = nil
                    note = ""
                    showsNoteEditor = false
                }
            }
        }
    }
}
