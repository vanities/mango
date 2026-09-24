import XCTest
@testable import Mango
import ShelfKit

final class BookmarksRatingsLogTests: XCTestCase {
    private let phone = UUID()
    private let pad = UUID()

    private func comic(_ path: String, source: UUID) -> Comic {
        Comic(id: Comic.makeID(sourceID: source, relativePath: path), sourceID: source,
              relativePath: path, kind: .archive, title: path, series: "S", volume: 1,
              chapter: nil, author: nil, year: nil, subtitle: nil, pageCount: 100,
              totalBytes: 1, addedAt: Date(), coverID: nil)
    }

    // MARK: Stats

    private func item(rating: Int?, finished: Bool = true) -> ReadingStats.Item {
        ReadingStats.Item(seriesKey: "comic|s", seriesName: "S", isNovel: false, format: "CBZ",
                          bytes: 1, isRemote: false, pageCount: 100,
                          progress: finished ? ReadingProgress(page: 99, pageCount: 100, finished: true) : nil,
                          rating: rating)
    }

    func testNovelChaptersNeverCountAsComicPages() {
        var novel = item(rating: nil)
        novel.isNovel = true
        let stats = ReadingStats.build([novel, item(rating: nil)], log: [
            ReadingLogEntry(title: "Novel", isNovel: true, finishedAt: .now, pages: 300)
        ])
        XCTAssertEqual(stats.finishedVolumes, 3)
        XCTAssertEqual(stats.pagesRead, 100)
    }

    func testAverageAndDistribution() {
        let stats = ReadingStats.build([item(rating: 5), item(rating: 4), item(rating: 4), item(rating: nil)])
        XCTAssertEqual(stats.ratedCount, 3)
        XCTAssertEqual(stats.ratingCounts, [0, 0, 0, 2, 1])
        XCTAssertEqual(try XCTUnwrap(stats.averageRating), 13.0 / 3.0, accuracy: 0.0001)
    }

    func testNoRatingsMeansNoAverage() {
        XCTAssertNil(ReadingStats.build([item(rating: nil)]).averageRating)
    }

    /// Books logged by hand count as finished reads, on their own dates, with their ratings.
    func testLoggedBooksCount() {
        let log = [
            ReadingLogEntry(title: "Borrowed", finishedAt: Date(), rating: 5, pages: 180),
            ReadingLogEntry(title: "Old one", isNovel: true, finishedAt: Date()),
        ]
        let stats = ReadingStats.build([], log: log)
        XCTAssertFalse(stats.isEmpty, "a library with only logged books still has stats")
        XCTAssertEqual(stats.loggedBooks, 2)
        XCTAssertEqual(stats.finishedVolumes, 2)
        XCTAssertEqual(stats.pagesRead, 180)
        XCTAssertEqual(stats.ratedCount, 1)
        XCTAssertEqual(stats.months.last?.finished, 2)
        XCTAssertEqual(Set(stats.byMedium.map(\.name)), ["Manga", "Novels"])
    }

    // MARK: Sync

    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testRatingsFollowThePathAcrossDevices() {
        let onPhone = comic("a.cbz", source: phone)
        let onPad = comic("a.cbz", source: pad)
        let cloud = CollectionSync.ratingsSnapshot(local: [onPhone.id: 4], dates: [onPhone.id: t0], comics: [onPhone], existingCloud: [:])
        let merged = CollectionSync.mergedRatings(local: [:], dates: [:], comics: [onPad], cloud: cloud)
        XCTAssertEqual(merged.ratings[onPad.id], 4)
    }

    /// Changing a rating on the iPad used to never reach the phone ("this device's own rating
    /// stands"), leaving the two different for good. The latest change wins now, either way.
    func testTheNewerRatingWins() {
        let book = comic("a.cbz", source: phone)
        let newer = CollectionSync.mergedRatings(local: [book.id: 2], dates: [book.id: t0], comics: [book],
                                                 cloud: [book.syncKey: Stamped(5, at: t0.addingTimeInterval(60))])
        XCTAssertEqual(newer.ratings[book.id], 5)
        let older = CollectionSync.mergedRatings(local: [book.id: 2], dates: [book.id: t0], comics: [book],
                                                 cloud: [book.syncKey: Stamped(5, at: t0.addingTimeInterval(-60))])
        XCTAssertEqual(older.ratings[book.id], 2)
    }

    /// The bug: clearing a rating came straight back from iCloud's copy.
    func testAClearedRatingStaysCleared() {
        let onPhone = comic("a.cbz", source: phone)
        let onPad = comic("a.cbz", source: pad)
        let cleared = t0.addingTimeInterval(60)
        let cloud = CollectionSync.ratingsSnapshot(local: [:], dates: [onPhone.id: cleared], comics: [onPhone],
                                                   existingCloud: [onPhone.syncKey: Stamped(4, at: t0)])
        XCTAssertEqual(cloud[onPhone.syncKey], Stamped(nil, at: cleared), "the clear goes up")
        let onThePad = CollectionSync.mergedRatings(local: [onPad.id: 4], dates: [onPad.id: t0], comics: [onPad], cloud: cloud)
        XCTAssertNil(onThePad.ratings[onPad.id], "and comes down")
        let backHere = CollectionSync.mergedRatings(local: [:], dates: [onPhone.id: cleared], comics: [onPhone], cloud: cloud)
        XCTAssertNil(backHere.ratings[onPhone.id], "and doesn't come back here")
    }

    /// Ratings from before they carried a date still sync, as the oldest of any change.
    func testUndatedRatingsStillSync() {
        let book = comic("a.cbz", source: phone)
        let filled = CollectionSync.mergedRatings(local: [:], dates: [:], comics: [book], cloud: [book.syncKey: Stamped(3, at: .distantPast)])
        XCTAssertEqual(filled.ratings[book.id], 3, "a gap is filled")
        let kept = CollectionSync.mergedRatings(local: [book.id: 5], dates: [:], comics: [book], cloud: [book.syncKey: Stamped(3, at: .distantPast)])
        XCTAssertEqual(kept.ratings[book.id], 5, "two undated: this device's stands")
        let cleared = CollectionSync.mergedRatings(local: [book.id: 5], dates: [:], comics: [book], cloud: [book.syncKey: Stamped(nil, at: t0)])
        XCTAssertNil(cleared.ratings[book.id], "a dated clear beats an undated rating")
    }

    /// Bookmarks union: a spot saved on the iPad appears on the phone and nothing is lost.
    func testBookmarksUnionAcrossDevices() {
        let onPhone = comic("a.cbz", source: phone)
        let onPad = comic("a.cbz", source: pad)
        let phoneMark = Bookmark(page: 10)
        let padMark = Bookmark(page: 40)
        let cloud = CollectionSync.bookmarksSnapshot(local: [onPad.id: [padMark]], comics: [onPad], existingCloud: [:], buried: Tombstones())
        let merged = CollectionSync.mergedBookmarks(local: [onPhone.id: [phoneMark]], comics: [onPhone], cloud: cloud, buried: Tombstones())
        XCTAssertEqual(merged[onPhone.id]?.map(\.page), [10, 40])
    }

    func testTheSameBookmarkIsNotDuplicated() {
        let book = comic("a.cbz", source: phone)
        let mark = Bookmark(page: 10)
        let merged = CollectionSync.mergedBookmarks(local: [book.id: [mark]], comics: [book], cloud: [book.syncKey: [mark]], buried: Tombstones())
        XCTAssertEqual(merged[book.id]?.count, 1)
    }

    /// The bug: a deleted bookmark came back on the next merge, because iCloud's copy still had it.
    func testADeletedBookmarkDoesNotComeBack() {
        let book = comic("a.cbz", source: phone)
        let mark = Bookmark(id: "gone", page: 10), kept = Bookmark(id: "kept", page: 20)
        var buried = Tombstones()
        buried.bury("gone", at: t0)
        let merged = CollectionSync.mergedBookmarks(local: [book.id: [kept]], comics: [book], cloud: [book.syncKey: [mark, kept]], buried: buried)
        XCTAssertEqual(merged[book.id]?.map(\.id), ["kept"])
        let cloud = CollectionSync.bookmarksSnapshot(local: [book.id: [kept]], comics: [book], existingCloud: [book.syncKey: [mark, kept]], buried: buried)
        XCTAssertEqual(cloud[book.syncKey]?.map(\.id), ["kept"], "and it leaves iCloud's copy")
    }

    func testABookmarkDeletedElsewhereGoesHere() {
        let book = comic("a.cbz", source: phone)
        var buried = Tombstones()
        buried.bury("gone", at: t0)
        let merged = CollectionSync.mergedBookmarks(local: [book.id: [Bookmark(id: "gone", page: 10)]], comics: [book], cloud: [:], buried: buried)
        XCTAssertNil(merged[book.id])
    }

    func testLogUnionsByIDNewestFirst() {
        let older = ReadingLogEntry(title: "A", finishedAt: Date(timeIntervalSince1970: 1_000))
        let newer = ReadingLogEntry(title: "B", finishedAt: Date(timeIntervalSince1970: 9_000))
        let merged = CollectionSync.mergedLog(local: [older], cloud: [newer, older])
        XCTAssertEqual(merged.map(\.title), ["B", "A"])
    }

    // MARK: Carried over on download

    func testRatingAndBookmarksFollowTheDownload() {
        let remote = comic("a.cbz", source: phone)
        let local = comic("a.cbz", source: pad)
        var state = LibraryState()
        state.comics = [remote, local]
        state.ratings[remote.id] = 5
        state.bookmarks[remote.id] = [Bookmark(page: 12, note: "the good bit")]

        state.adoptStateFromRemoteTwins(remoteSourceIDs: [phone])

        XCTAssertEqual(state.ratings[local.id], 5)
        XCTAssertEqual(state.bookmarks[local.id]?.first?.note, "the good bit")
    }

    // MARK: Persistence

    func testEverythingRoundTripsAndOldFilesStillDecode() throws {
        var state = LibraryState()
        state.ratings["a"] = 3
        state.bookmarks["a"] = [Bookmark(page: 4, fraction: 0.5, note: "n")]
        state.readingLog = [ReadingLogEntry(title: "T", isNovel: true, finishedAt: Date(), rating: 4)]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        state.ratingDates["a"] = Date(timeIntervalSinceReferenceDate: 800_000_000)
        state.deletedBookmarks.bury("gone", at: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let round = try decoder.decode(LibraryState.self, from: encoder.encode(state))
        XCTAssertEqual(round.ratingDates["a"], Date(timeIntervalSinceReferenceDate: 800_000_000))
        XCTAssertTrue(round.deletedBookmarks.contains("gone"))
        XCTAssertEqual(round.ratings["a"], 3)
        XCTAssertEqual(round.bookmarks["a"]?.first?.fraction, 0.5)
        XCTAssertEqual(round.readingLog.first?.isNovel, true)

        let old = try decoder.decode(LibraryState.self, from: Data(#"{"progress":{}}"#.utf8))
        XCTAssertTrue(old.ratings.isEmpty && old.bookmarks.isEmpty && old.readingLog.isEmpty)
        XCTAssertTrue(old.ratingDates.isEmpty && old.deletedBookmarks.isEmpty)
    }

    /// Restoring a moved-aside library must bring these back too, never duplicating.
    func testSalvageRestoresThem() {
        var current = LibraryState()
        current.bookmarks["a"] = [Bookmark(id: "keep", page: 1)]
        var old = LibraryState()
        old.ratings["a"] = 4
        old.bookmarks["a"] = [Bookmark(id: "keep", page: 1), Bookmark(id: "lost", page: 9)]
        old.readingLog = [ReadingLogEntry(id: "e", title: "T", finishedAt: Date())]
        current.merge(restoring: old)
        XCTAssertEqual(current.ratings["a"], 4)
        XCTAssertEqual(current.bookmarks["a"]?.map(\.id), ["keep", "lost"])
        XCTAssertEqual(current.readingLog.count, 1)
    }

    /// A bookmark deleted since the old file was written stays deleted when it's restored.
    func testSalvageDoesNotRestoreADeletedBookmark() {
        var current = LibraryState()
        current.deletedBookmarks.bury("gone")
        var old = LibraryState()
        old.bookmarks["a"] = [Bookmark(id: "gone", page: 3), Bookmark(id: "lost", page: 9)]
        current.merge(restoring: old)
        XCTAssertEqual(current.bookmarks["a"]?.map(\.id), ["lost"])
    }
}
