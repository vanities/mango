import Foundation

/// Everything Mango persists about the library, in one JSON document.
///
/// Decoding is lenient on purpose: every field falls back to its default when the key is
/// missing, so a build that adds a field can still read the file the previous build wrote.
/// (Synthesized `Codable` does *not* do this — a missing key fails the whole document, which
/// in Earmark once cost a test library its NAS server and progress.)
struct LibraryState: Codable, Sendable {
    var schemaVersion = 1
    var sources: [LibrarySource] = []
    var comics: [Comic] = []
    var progress: [String: ReadingProgress] = [:]
    var hiddenComicIDs: Set<String> = []
    var lastComicID: String?
    var nasServers: [NASServer] = []
    /// Comic ID → cover ID chosen by the user. Survives rescans.
    var customCovers: [String: String] = [:]
    /// Comic ID → user corrections and per-comic reader preferences. Survives rescans.
    var overrides: [String: ComicOverride] = [:]
    /// Normalized series name → reading direction for the whole run, so setting it once on
    /// volume 1 carries to volume 2.
    var seriesDirection: [String: ReadingDirection] = [:]
    /// Comic ID → the ComicInfo.xml read out of its archive. Scans never open archives, so this
    /// is how that metadata survives a rescan.
    var comicInfo: [String: ComicInfo] = [:]
    /// Comic ID → saved spots in it.
    var bookmarks: [String: [Bookmark]] = [:]
    /// Comic ID → 1–5 stars. Kept apart from progress on purpose: rating a book shouldn't
    /// count as reading it and reshuffle Continue Reading.
    var ratings: [String: Int] = [:]
    /// Books read outside the app, so Stats can count them.
    var readingLog: [ReadingLogEntry] = []

    init(sources: [LibrarySource] = [], comics: [Comic] = [], progress: [String: ReadingProgress] = [:],
         hiddenComicIDs: Set<String> = [], lastComicID: String? = nil, nasServers: [NASServer] = [],
         customCovers: [String: String] = [:], overrides: [String: ComicOverride] = [:],
         seriesDirection: [String: ReadingDirection] = [:]) {
        self.sources = sources
        self.comics = comics
        self.progress = progress
        self.hiddenComicIDs = hiddenComicIDs
        self.lastComicID = lastComicID
        self.nasServers = nasServers
        self.customCovers = customCovers
        self.overrides = overrides
        self.seriesDirection = seriesDirection
    }

    /// User state worth protecting: anything beyond the always-present Documents source.
    var hasUserData: Bool {
        !progress.isEmpty || !nasServers.isEmpty || !customCovers.isEmpty || !overrides.isEmpty
            || !bookmarks.isEmpty || !ratings.isEmpty || !readingLog.isEmpty
            || sources.contains { $0.kind != .appDocuments }
    }

    /// Adds back user state from a library that an older build moved aside (see `LibraryStore`).
    /// `self` always wins on conflicts — it is the current, freshly-scanned library — so this only
    /// ever *restores* things the current file is missing. Comics are intentionally not merged:
    /// they are rederived by the next scan once their source is back.
    mutating func merge(restoring old: LibraryState) {
        // The Documents source is a singleton created fresh on each install (its id differs), so it
        // is never restored — only real added sources (a folder or a NAS share) can go missing.
        let sourceIDs = Set(sources.map(\.id))
        sources.append(contentsOf: old.sources.filter { $0.kind != .appDocuments && !sourceIDs.contains($0.id) })
        let serverIDs = Set(nasServers.map(\.id))
        nasServers.append(contentsOf: old.nasServers.filter { !serverIDs.contains($0.id) })
        for (key, value) in old.progress where progress[key] == nil { progress[key] = value }
        for (key, value) in old.customCovers where customCovers[key] == nil { customCovers[key] = value }
        for (key, value) in old.overrides where overrides[key] == nil { overrides[key] = value }
        for (key, value) in old.seriesDirection where seriesDirection[key] == nil { seriesDirection[key] = value }
        for (key, value) in old.ratings where ratings[key] == nil { ratings[key] = value }
        for (key, oldList) in old.bookmarks {
            var list = bookmarks[key] ?? []
            let known = Set(list.map(\.id))
            list.append(contentsOf: oldList.filter { !known.contains($0.id) })
            bookmarks[key] = list.sorted { $0.page < $1.page }
        }
        let logIDs = Set(readingLog.map(\.id))
        readingLog.append(contentsOf: old.readingLog.filter { !logIDs.contains($0.id) })
        hiddenComicIDs.formUnion(old.hiddenComicIDs)
        if lastComicID == nil { lastComicID = old.lastComicID }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sources, comics, progress, hiddenComicIDs, lastComicID, nasServers,
             customCovers, overrides, seriesDirection, comicInfo, bookmarks, ratings, readingLog
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        sources = try c.decodeIfPresent([LibrarySource].self, forKey: .sources) ?? []
        comics = try c.decodeIfPresent([Comic].self, forKey: .comics) ?? []
        progress = try c.decodeIfPresent([String: ReadingProgress].self, forKey: .progress) ?? [:]
        hiddenComicIDs = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenComicIDs) ?? []
        lastComicID = try c.decodeIfPresent(String.self, forKey: .lastComicID)
        nasServers = try c.decodeIfPresent([NASServer].self, forKey: .nasServers) ?? []
        customCovers = try c.decodeIfPresent([String: String].self, forKey: .customCovers) ?? [:]
        overrides = try c.decodeIfPresent([String: ComicOverride].self, forKey: .overrides) ?? [:]
        seriesDirection = try c.decodeIfPresent([String: ReadingDirection].self, forKey: .seriesDirection) ?? [:]
        comicInfo = try c.decodeIfPresent([String: ComicInfo].self, forKey: .comicInfo) ?? [:]
        bookmarks = try c.decodeIfPresent([String: [Bookmark]].self, forKey: .bookmarks) ?? [:]
        ratings = try c.decodeIfPresent([String: Int].self, forKey: .ratings) ?? [:]
        readingLog = try c.decodeIfPresent([ReadingLogEntry].self, forKey: .readingLog) ?? []
    }
}
