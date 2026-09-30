import Foundation

/// A light novel's chapters by the book's own names.
///
/// Mango reads a novel one document of its reading order (the spine) at a time, and used to
/// number those: "Chapter 23 of 26" on a page headed "Chapter 20". The book's table of contents
/// names the documents that start something. The ones it skips continue the named one before
/// them — the second half of a chapter split in two, an illustration inside it — and anything
/// before the first name is the beginning of the book: its cover, title page, colour plates.
/// A book that names fewer than two documents (a scan whose one entry is its "scan notes")
/// keeps the numbers.
struct NovelContents: Equatable, Sendable {
    struct Entry: Equatable, Hashable, Sendable {
        /// Where it starts in the reading order.
        var index: Int
        var title: String
    }

    static let beginning = "Beginning"

    /// The table of contents' name for each document in the reading order, nil where it has none.
    let titles: [String?]
    /// What the chapter list shows, in reading order: every named document, or every document
    /// by number.
    let entries: [Entry]
    /// Whether chapters go by the book's names rather than by number.
    let isNamed: Bool

    init(titles: [String?]) {
        self.titles = titles
        isNamed = titles.count { $0 != nil } >= 2
        if isNamed {
            // Every named document gets its own entry, even under a name used before: books do
            // mislabel ("Chapter 9" twice), and merging them would hide a chapter.
            var entries = titles.first.flatMap { $0 } == nil ? [Entry(index: 0, title: Self.beginning)] : []
            for (index, title) in titles.enumerated() {
                if let title { entries.append(Entry(index: index, title: title)) }
            }
            self.entries = entries
        } else {
            entries = titles.indices.map { Entry(index: $0, title: "Chapter \($0 + 1)") }
        }
    }

    init(spine: [EPUBSpineItem], toc: [EPUBTOCEntry]) {
        self.init(titles: EPUBParser.chapterTitles(spine: spine, toc: toc))
    }

    /// The entry the document at `index` belongs to.
    func entry(containing index: Int) -> Entry? {
        entries.last { $0.index <= index }
    }

    /// What to call the document at `index`.
    func name(of index: Int) -> String {
        entry(containing: index)?.title ?? "Chapter \(index + 1)"
    }

    /// The book's own name for the document at `index`, when its titles are known and name its
    /// chapters — for places that only have the saved titles, not the book.
    static func name(of index: Int, titles: [String?]?) -> String? {
        guard let titles else { return nil }
        let contents = NovelContents(titles: titles)
        return contents.isNamed ? contents.name(of: index) : nil
    }
}
