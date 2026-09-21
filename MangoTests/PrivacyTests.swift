import XCTest
@testable import Mango

/// Hidden shelves and the app lock.
final class PrivacyTests: XCTestCase {
    private func comic(_ path: String, series: String?, kind: Comic.Kind = .archive) -> Comic {
        let source = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
        return Comic(id: Comic.makeID(sourceID: source, relativePath: path), sourceID: source, relativePath: path,
                     kind: kind, title: (path as NSString).lastPathComponent, series: series, volume: 1, chapter: nil,
                     author: nil, year: nil, subtitle: nil, pageCount: nil, totalBytes: 1, addedAt: Date(), coverID: nil)
    }

    /// Hiding a series hides the shelf, not a list of files: a volume added later stays hidden.
    func testAHiddenSeriesStaysHiddenAsItGrows() {
        let v1 = comic("Onani/v01.cbz", series: "Onani Master Kurosawa")
        let v2 = comic("Onani/v02.cbz", series: "Onani Master Kurosawa")
        let other = comic("Berserk/v01.cbz", series: "Berserk")
        let hidden: Set<String> = [SeriesGrouper.key(for: v1)]
        let visible = LibraryDedupe.visible(comics: [v1, v2, other], remoteSourceIDs: [], hidden: [], hiddenSeries: hidden)
        XCTAssertEqual(visible.map(\.id), [other.id])
    }

    /// Manga and novels of one name are different shelves; hiding one leaves the other.
    func testHidingTheMangaLeavesTheNovels() {
        let manga = comic("MT/v01.cbz", series: "Mushoku Tensei")
        let novel = comic("MT LN/v01.epub", series: "Mushoku Tensei", kind: .epub)
        let visible = LibraryDedupe.visible(comics: [manga, novel], remoteSourceIDs: [], hidden: [],
                                            hiddenSeries: [SeriesGrouper.key(for: manga)])
        XCTAssertEqual(visible.map(\.id), [novel.id])
    }

    func testTheLockHonoursItsGracePeriod() {
        let away = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(AppLock.shouldLock(mode: .off, backgroundedAt: away, now: away.addingTimeInterval(3600)))
        XCTAssertTrue(AppLock.shouldLock(mode: .immediately, backgroundedAt: away, now: away.addingTimeInterval(1)))
        XCTAssertFalse(AppLock.shouldLock(mode: .afterOneMinute, backgroundedAt: away, now: away.addingTimeInterval(59)))
        XCTAssertTrue(AppLock.shouldLock(mode: .afterOneMinute, backgroundedAt: away, now: away.addingTimeInterval(61)))
        XCTAssertFalse(AppLock.shouldLock(mode: .afterFifteenMinutes, backgroundedAt: away, now: away.addingTimeInterval(600)))
        XCTAssertTrue(AppLock.shouldLock(mode: .immediately, backgroundedAt: nil, now: away), "never unlocked: locked")
    }

    func testHiddenSeriesSurviveOldFilesAndSalvage() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode(LibraryState.self, from: Data("{}".utf8))
        XCTAssertTrue(old.hiddenSeries.isEmpty)
        var current = LibraryState()
        var salvaged = LibraryState()
        salvaged.hiddenSeries = ["comic|onani master kurosawa"]
        current.merge(restoring: salvaged)
        XCTAssertEqual(current.hiddenSeries, ["comic|onani master kurosawa"])
    }
}
