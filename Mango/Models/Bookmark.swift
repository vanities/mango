import Foundation

/// A saved spot in a book. Kept in `LibraryState.bookmarks`, keyed by `Comic.id`, and synced
/// across devices by relative path.
struct Bookmark: Identifiable, Codable, Hashable, Sendable {
    var id: String
    /// A comic's page index, or a novel's chapter index.
    var page: Int
    /// For novels only: how far down that chapter, 0...1. A novel has no page numbers.
    var fraction: Double?
    var note: String
    var createdAt: Date

    init(id: String = UUID().uuidString, page: Int, fraction: Double? = nil, note: String = "",
         createdAt: Date = .now) {
        self.id = id
        self.page = page
        self.fraction = fraction
        self.note = note
        self.createdAt = createdAt
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        page = try c.decodeIfPresent(Int.self, forKey: .page) ?? 0
        fraction = try c.decodeIfPresent(Double.self, forKey: .fraction)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
    }

    func label(isNovel: Bool) -> String {
        isNovel ? "Chapter \(page + 1)" : "Page \(page + 1)"
    }
}

/// A book read outside Mango, logged by hand so Stats counts it — years of reading from before
/// the app, or a volume borrowed and returned. Library books track their own finished state.
struct ReadingLogEntry: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var title: String
    var series: String?
    var isNovel: Bool
    var finishedAt: Date
    /// 1–5 stars, or nil if unrated.
    var rating: Int?
    var pages: Int?
    var note: String?

    init(id: String = UUID().uuidString, title: String, series: String? = nil, isNovel: Bool = false,
         finishedAt: Date, rating: Int? = nil, pages: Int? = nil, note: String? = nil) {
        self.id = id
        self.title = title
        self.series = series
        self.isNovel = isNovel
        self.finishedAt = finishedAt
        self.rating = rating
        self.pages = pages
        self.note = note
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        series = try c.decodeIfPresent(String.self, forKey: .series)
        isNovel = try c.decodeIfPresent(Bool.self, forKey: .isNovel) ?? false
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt) ?? .now
        rating = try c.decodeIfPresent(Int.self, forKey: .rating)
        pages = try c.decodeIfPresent(Int.self, forKey: .pages)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }
}
