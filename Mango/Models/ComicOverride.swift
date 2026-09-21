import Foundation

/// User corrections to what the scanner guessed, and per-comic reader preferences.
/// Keyed by `Comic.id` and merged over the scanned comic on every rescan.
struct ComicOverride: Codable, Hashable, Sendable {
    var title: String?
    var series: String?
    var volume: Double?
    var chapter: Double?
    var author: String?
    var year: Int?
    /// Overrides `AppSettings.defaultDirection` — a western trade in an otherwise-manga library.
    var direction: ReadingDirection?
    var mode: ReaderMode?

    var isEmpty: Bool {
        title == nil && series == nil && volume == nil && chapter == nil
            && author == nil && year == nil && direction == nil && mode == nil
    }

    init(title: String? = nil, series: String? = nil, volume: Double? = nil, chapter: Double? = nil,
         author: String? = nil, year: Int? = nil, direction: ReadingDirection? = nil, mode: ReaderMode? = nil) {
        self.title = title
        self.series = series
        self.volume = volume
        self.chapter = chapter
        self.author = author
        self.year = year
        self.direction = direction
        self.mode = mode
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        series = try c.decodeIfPresent(String.self, forKey: .series)
        volume = try c.decodeIfPresent(Double.self, forKey: .volume)
        chapter = try c.decodeIfPresent(Double.self, forKey: .chapter)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        direction = try c.decodeIfPresent(ReadingDirection.self, forKey: .direction)
        mode = try c.decodeIfPresent(ReaderMode.self, forKey: .mode)
    }

    /// Applies the non-nil fields over a freshly scanned comic.
    func applied(to comic: Comic) -> Comic {
        var out = comic
        if let title { out.title = title }
        if let series { out.series = series }
        if let volume { out.volume = volume }
        if let chapter { out.chapter = chapter }
        if let author { out.author = author }
        if let year { out.year = year }
        return out
    }
}
