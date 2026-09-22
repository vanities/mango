import Foundation
import ShelfKit

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
    /// Whole shelves the user hid, by shelf id (`SeriesGrouper.key`) — so a volume that arrives
    /// later is hidden too.
    var hiddenSeries: Set<String> = []
    /// Stacks the user chose: shelf id → group name, or "" to keep a shelf out of any stack.
    var seriesGroups: [String: String] = [:]
    /// Lists of your own across the library.
    var readingLists: [ReadingList] = []
    /// The cover choice each file last had applied here (picked here, or synced in), by `syncKey`.
    var coverChoices: [String: CoverChoice] = [:]
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
    /// Comic ID → when its rating was last set or cleared, so the latest change wins across
    /// devices — a cleared rating included. Ratings from before this carry none (the oldest).
    var ratingDates: [String: Date] = [:]
    /// Bookmarks deleted here or on another device, by id, so a merge can't bring them back.
    var deletedBookmarks = Tombstones()
    /// Books read outside the app, so Stats can count them.
    var readingLog: [ReadingLogEntry] = []
    /// This device's reading sessions. Local detail; only day totals travel to other devices.
    var sessions: [ReadingSession] = []
    /// Comics detected as long strips (webtoon / manhwa). Kept apart from `overrides` because
    /// it's a detection, not something the user chose — their choice still wins.
    var longStripComicIDs: Set<String> = []
    /// Layout chosen for a whole series, keyed like `seriesDirection`. A webtoon sliced into short
    /// pages is never detected, so picking a layout once has to hold for every chapter.
    var seriesMode: [String: ReaderMode] = [:]

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
        for (key, value) in old.ratingDates where ratingDates[key] == nil { ratingDates[key] = value }
        deletedBookmarks = deletedBookmarks.merging(old.deletedBookmarks)
        for (key, oldList) in old.bookmarks {
            var list = bookmarks[key] ?? []
            let known = Set(list.map(\.id))
            list.append(contentsOf: oldList.filter { !known.contains($0.id) && !deletedBookmarks.contains($0.id) })
            bookmarks[key] = list.sorted { $0.page < $1.page }
        }
        let logIDs = Set(readingLog.map(\.id))
        readingLog.append(contentsOf: old.readingLog.filter { !logIDs.contains($0.id) })
        let sessionIDs = Set(sessions.map(\.id))
        sessions.append(contentsOf: old.sessions.filter { !sessionIDs.contains($0.id) })
        hiddenComicIDs.formUnion(old.hiddenComicIDs)
        hiddenSeries.formUnion(old.hiddenSeries)
        for (key, value) in old.seriesGroups where seriesGroups[key] == nil { seriesGroups[key] = value }
        let listIDs = Set(readingLists.map(\.id))
        readingLists.append(contentsOf: old.readingLists.filter { !listIDs.contains($0.id) })
        for (key, value) in old.coverChoices where coverChoices[key] == nil { coverChoices[key] = value }
        longStripComicIDs.formUnion(old.longStripComicIDs)
        for (key, value) in old.seriesMode where seriesMode[key] == nil { seriesMode[key] = value }
        if lastComicID == nil { lastComicID = old.lastComicID }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sources, comics, progress, hiddenComicIDs, lastComicID, nasServers,
             customCovers, overrides, seriesDirection, comicInfo, bookmarks, ratings, readingLog, sessions,
             longStripComicIDs, seriesMode, hiddenSeries, seriesGroups, readingLists, coverChoices,
             ratingDates, deletedBookmarks
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
        sessions = try c.decodeIfPresent([ReadingSession].self, forKey: .sessions) ?? []
        longStripComicIDs = try c.decodeIfPresent(Set<String>.self, forKey: .longStripComicIDs) ?? []
        seriesMode = try c.decodeIfPresent([String: ReaderMode].self, forKey: .seriesMode) ?? [:]
        hiddenSeries = try c.decodeIfPresent(Set<String>.self, forKey: .hiddenSeries) ?? []
        seriesGroups = try c.decodeIfPresent([String: String].self, forKey: .seriesGroups) ?? [:]
        readingLists = try c.decodeIfPresent([ReadingList].self, forKey: .readingLists) ?? []
        coverChoices = try c.decodeIfPresent([String: CoverChoice].self, forKey: .coverChoices) ?? [:]
        ratingDates = try c.decodeIfPresent([String: Date].self, forKey: .ratingDates) ?? [:]
        deletedBookmarks = try c.decodeIfPresent(Tombstones.self, forKey: .deletedBookmarks) ?? Tombstones()
    }
}

// MARK: Layout

extension LibraryState {
    /// The layout a book opens in: a choice made for this book, else for its series, else a
    /// long-strip detection, else the app default.
    func mode(for comic: Comic, defaultMode: ReaderMode) -> ReaderMode {
        if let chosen = overrides[comic.id]?.mode { return chosen }
        if let key = Self.seriesKey(comic), let chosen = seriesMode[key] { return chosen }
        if longStripComicIDs.contains(comic.id) { return .continuous }
        return defaultMode
    }

    /// Whether the user picked a layout for this book or its series — if so, detection stays out.
    func hasChosenMode(for comic: Comic) -> Bool {
        overrides[comic.id]?.mode != nil || Self.seriesKey(comic).flatMap { seriesMode[$0] } != nil
    }

    /// Records a layout picked while reading, for the whole series when the book has one — the
    /// same way reading direction works.
    mutating func chooseMode(_ mode: ReaderMode, for comic: Comic) {
        if let key = Self.seriesKey(comic) {
            seriesMode[key] = mode
            overrides[comic.id]?.mode = nil
        } else {
            var override = overrides[comic.id] ?? ComicOverride()
            override.mode = mode
            overrides[comic.id] = override
        }
    }

    private static func seriesKey(_ comic: Comic) -> String? {
        comic.series.map { SeriesGrouper.key(forName: $0) }
    }
}

// MARK: Picked covers

extension LibraryState {
    /// A comic and every other copy of it — the NAS original and its download share a `syncKey`,
    /// and a cover picked for one belongs on both.
    func copies(of comic: Comic) -> [Comic] {
        let group = comics.filter { $0.syncKey == comic.syncKey }
        return group.isEmpty ? [comic] : group
    }

    /// Points a comic at a picked cover. Returns the picked cover it replaces, whose file can go.
    mutating func installCustomCover(_ coverID: String, for comicID: String) -> String? {
        let previous = customCovers[comicID]
        customCovers[comicID] = coverID
        if let index = comics.firstIndex(where: { $0.id == comicID }) { comics[index].coverID = coverID }
        return previous == coverID ? nil : previous
    }

    /// Back to the cover from page one — `original`, or none until the backfill makes it.
    /// Returns the picked cover's id, whose file can go.
    mutating func removeCustomCover(for comicID: String, original: String?) -> String? {
        guard let previous = customCovers.removeValue(forKey: comicID) else { return nil }
        if let index = comics.firstIndex(where: { $0.id == comicID }) { comics[index].coverID = original }
        return previous
    }

    /// Renames a whole shelf — every comic in it gets the new series name — and carries its
    /// per-series settings over, or reading direction and layout would silently reset.
    mutating func renameSeries(_ comicIDs: [String], from oldName: String, to newName: String, author: String?) {
        let oldKey = SeriesGrouper.key(forName: oldName), newKey = SeriesGrouper.key(forName: newName)
        for id in comicIDs {
            var override = overrides[id] ?? ComicOverride()
            override.series = newName
            if let author, !author.isEmpty, (comics.first { $0.id == id }?.author ?? "").isEmpty {
                override.author = author
            }
            overrides[id] = override
            if let index = comics.firstIndex(where: { $0.id == id }) { comics[index] = override.applied(to: comics[index]) }
        }
        if oldKey != newKey {
            if let direction = seriesDirection.removeValue(forKey: oldKey), seriesDirection[newKey] == nil {
                seriesDirection[newKey] = direction
            }
            if let mode = seriesMode.removeValue(forKey: oldKey), seriesMode[newKey] == nil { seriesMode[newKey] = mode }
            for medium in ["comic|", "novel|"] {
                if let group = seriesGroups.removeValue(forKey: medium + oldKey) { seriesGroups[medium + newKey] = group }
            }
        }
    }
}

// MARK: Downloads

extension LibraryState {
    /// Progress for a comic and every other copy of it: reading the NAS copy while its download
    /// lands, then opening the download, mustn't lose the pages read in between.
    mutating func setProgress(_ entry: ReadingProgress?, forCopiesOf comic: Comic) {
        for copy in copies(of: comic) { progress[copy.id] = entry }
    }

    /// Before a download is deleted, everything done to it goes back to the NAS copy it came
    /// from — the newer progress, bookmarks from both, rating, corrections, detection — so the
    /// comic carries on from the NAS as though it never left. Then the download leaves the library.
    mutating func returnState(from localID: String, to remoteID: String) {
        if let local = progress[localID], local.updatedAt >= (progress[remoteID]?.updatedAt ?? .distantPast) {
            progress[remoteID] = local
        }
        if let marks = bookmarks[localID] {
            var merged = bookmarks[remoteID] ?? []
            let known = Set(merged.map(\.id))
            merged.append(contentsOf: marks.filter { !known.contains($0.id) })
            bookmarks[remoteID] = merged.sorted { $0.page < $1.page }
        }
        if let rating = ratings[localID] { ratings[remoteID] = rating }
        if let rated = ratingDates[localID] { ratingDates[remoteID] = max(rated, ratingDates[remoteID] ?? .distantPast) }
        if overrides[remoteID] == nil, let override = overrides[localID] { overrides[remoteID] = override }
        if customCovers[remoteID] == nil, let cover = customCovers[localID] { customCovers[remoteID] = cover }
        if hiddenComicIDs.contains(localID) { hiddenComicIDs.insert(remoteID) }
        if longStripComicIDs.contains(localID) { longStripComicIDs.insert(remoteID) }
        if lastComicID == localID { lastComicID = remoteID }

        progress[localID] = nil
        bookmarks[localID] = nil
        ratings[localID] = nil
        ratingDates[localID] = nil
        overrides[localID] = nil
        customCovers[localID] = nil
        hiddenComicIDs.remove(localID)
        longStripComicIDs.remove(localID)
        comics.removeAll { $0.id == localID }
    }
}
