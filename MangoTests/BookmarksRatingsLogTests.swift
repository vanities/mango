import XCTest
@testable import Mango

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

    func testRatingsFollowThePathAcrossDevices() {
        let onPhone = comic("a.cbz", source: phone)
        let onPad = comic("a.cbz", source: pad)
        let cloud = CollectionSync.ratingsSnapshot(local: [onPhone.id: 4], comics: [onPhone], existingCloud: [:])
        let merged = CollectionSync.mergedRatings(local: [:], comics: [onPad], cloud: cloud)
        XCTAssertEqual(merged[onPad.id], 4)
    }

    /// A rating isn't stale the way a position is; this device's own rating stands.
    func testLocalRatingIsNotOverwritten() {
        let book = comic("a.cbz", source: phone)
        let merged = CollectionSync.mergedRatings(local: [book.id: 2], comics: [book], cloud: [book.syncKey: 5])
        XCTAssertEqual(merged[book.id], 2)
    }

    /// Bookmarks union: a spot saved on the iPad appears on the phone and nothing is lost.
    func testBookmarksUnionAcrossDevices() {
        let onPhone = comic("a.cbz", source: phone)
        let onPad = comic("a.cbz", source: pad)
        let phoneMark = Bookmark(page: 10)
        let padMark = Bookmark(page: 40)
        let cloud = CollectionSync.bookmarksSnapshot(local: [onPad.id: [padMark]], comics: [onPad], existingCloud: [:])
        let merged = CollectionSync.mergedBookmarks(local: [onPhone.id: [phoneMark]], comics: [onPhone], cloud: cloud)
        XCTAssertEqual(merged[onPhone.id]?.map(\.page), [10, 40])
    }

    func testTheSameBookmarkIsNotDuplicated() {
        let book = comic("a.cbz", source: phone)
        let mark = Bookmark(page: 10)
        let merged = CollectionSync.mergedBookmarks(local: [book.id: [mark]], comics: [book], cloud: [book.syncKey: [mark]])
        XCTAssertEqual(merged[book.id]?.count, 1)
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
        let round = try decoder.decode(LibraryState.self, from: encoder.encode(state))
        XCTAssertEqual(round.ratings["a"], 3)
        XCTAssertEqual(round.bookmarks["a"]?.first?.fraction, 0.5)
        XCTAssertEqual(round.readingLog.first?.isNovel, true)

        let old = try decoder.decode(LibraryState.self, from: Data(#"{"progress":{}}"#.utf8))
        XCTAssertTrue(old.ratings.isEmpty && old.bookmarks.isEmpty && old.readingLog.isEmpty)
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
}
