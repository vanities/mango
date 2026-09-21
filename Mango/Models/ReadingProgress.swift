import Foundation

/// Where the reader left off in one comic. Keyed by `Comic.id` in `LibraryState.progress`.
struct ReadingProgress: Codable, Hashable, Sendable {
    /// Zero-based index of the page last shown.
    var page: Int
    /// Page count at the time it was written — 0 when the archive hasn't been opened yet.
    var pageCount: Int
    var updatedAt: Date
    /// Set explicitly when the last page is reached, or by hand. Not inferred from `page`,
    /// because "stopped on the last page" and "finished it" are different things to a reader.
    var finished: Bool
    /// For reflowable books only: how far down the current chapter, 0...1. A comic's page
    /// index is exact, but a novel's position depends on font size and screen, so `page`
    /// holds the chapter and this holds the rest.
    var fractionInChapter: Double

    init(page: Int = 0, pageCount: Int = 0, updatedAt: Date = Date(), finished: Bool = false,
         fractionInChapter: Double = 0) {
        self.page = page
        self.pageCount = pageCount
        self.updatedAt = updatedAt
        self.finished = finished
        self.fractionInChapter = fractionInChapter
    }

    /// 0...1 through the book. A one-page book is either unread (0) or done (1).
    var fraction: Double {
        guard pageCount > 1 else { return finished ? 1 : 0 }
        return min(1, max(0, Double(page) / Double(pageCount - 1)))
    }

    var isStarted: Bool { page > 0 || finished }

    /// "Page 14 of 192" / "Finished".
    var label: String {
        finished ? "Finished" : Formatting.pagePosition(page, of: pageCount)
    }

    /// The same thing for a reflowable book, where `page` is a chapter.
    var novelLabel: String {
        if finished { return "Finished" }
        return pageCount > 0 ? "Chapter \(page + 1) of \(pageCount)" : "Chapter \(page + 1)"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        page = try c.decodeIfPresent(Int.self, forKey: .page) ?? 0
        pageCount = try c.decodeIfPresent(Int.self, forKey: .pageCount) ?? 0
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? false
        fractionInChapter = try c.decodeIfPresent(Double.self, forKey: .fractionInChapter) ?? 0
    }
}
