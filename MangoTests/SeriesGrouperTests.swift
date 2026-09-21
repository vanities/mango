import XCTest
@testable import Mango

final class SeriesGrouperTests: XCTestCase {
    private let sourceA = UUID()
    private let sourceB = UUID()

    private func comic(_ title: String, series: String?, volume: Double? = nil,
                       source: UUID? = nil, path: String? = nil) -> Comic {
        let sourceID = source ?? sourceA
        let relativePath = path ?? "\(title).cbz"
        return Comic(id: Comic.makeID(sourceID: sourceID, relativePath: relativePath), sourceID: sourceID,
                     relativePath: relativePath, kind: .archive, title: title, series: series,
                     volume: volume, chapter: nil, author: nil, year: nil, pageCount: nil,
                     totalBytes: 1000, addedAt: Date(), coverID: nil)
    }

    func testVolumesOfOneSeriesLandOnOneShelf() {
        let shelves = SeriesGrouper.group([
            comic("Berserk Vol. 2", series: "Berserk", volume: 2),
            comic("Berserk Vol. 10", series: "Berserk", volume: 10),
            comic("Berserk Vol. 1", series: "Berserk", volume: 1),
        ])
        XCTAssertEqual(shelves.count, 1)
        XCTAssertEqual(shelves[0].comics.map(\.volume), [1, 2, 10])
    }

    /// v2 before v10 — the thing string sorting always gets wrong.
    func testNumericOrderNotStringOrder() {
        let shelves = SeriesGrouper.group((1...12).map { comic("Naruto Vol. \($0)", series: "Naruto", volume: Double($0)) })
        XCTAssertEqual(shelves[0].comics.map(\.volume), (1...12).map(Double.init))
    }

    func testPunctuationAndCaseDoNotSplitAShelf() {
        let shelves = SeriesGrouper.group([
            comic("JoJo Vol. 1", series: "JoJo's Bizarre Adventure", volume: 1),
            comic("JoJo Vol. 2", series: "JoJos Bizarre Adventure", volume: 2),
            comic("JoJo Vol. 3", series: "jojo's bizarre adventure", volume: 3),
        ])
        XCTAssertEqual(shelves.count, 1)
        XCTAssertEqual(shelves[0].comics.count, 3)
    }

    /// The same run downloaded locally and sitting on the NAS is still one run.
    func testTheSameSeriesFromTwoSourcesMerges() {
        let shelves = SeriesGrouper.group([
            comic("Berserk Vol. 1", series: "Berserk", volume: 1, source: sourceA),
            comic("Berserk Vol. 2", series: "Berserk", volume: 2, source: sourceB),
        ])
        XCTAssertEqual(shelves.count, 1)
        XCTAssertEqual(shelves[0].volumeCount, 2)
    }

    func testStandaloneStaysOnItsOwnShelf() {
        let shelves = SeriesGrouper.group([
            comic("Akira Vol. 1", series: "Akira", volume: 1),
            comic("Nausicaa", series: nil),
        ])
        XCTAssertEqual(shelves.count, 2)
        XCTAssertTrue(shelves.contains { $0.isStandalone })
    }

    func testLongestSpellingBecomesTheShelfName() {
        let shelves = SeriesGrouper.group([
            comic("Vinland v1", series: "Vinland Saga", volume: 1),
            comic("Vinland v2", series: "Vinland Saga", volume: 2),
        ])
        XCTAssertEqual(shelves[0].name, "Vinland Saga")
    }

    // MARK: Next up

    func testNextUpPrefersSomethingAlreadyStarted() {
        let one = comic("v1", series: "Berserk", volume: 1)
        let two = comic("v2", series: "Berserk", volume: 2, path: "v2.cbz")
        let three = comic("v3", series: "Berserk", volume: 3, path: "v3.cbz")
        let shelf = SeriesGrouper.group([one, two, three])[0]
        let progress: [String: ReadingProgress] = [
            one.id: ReadingProgress(page: 40, pageCount: 40, finished: true),
            two.id: ReadingProgress(page: 12, pageCount: 200),
        ]
        XCTAssertEqual(SeriesGrouper.nextUp(in: shelf, progress: progress)?.volume, 2)
    }

    func testNextUpFallsToTheFirstUnfinished() {
        let one = comic("v1", series: "Berserk", volume: 1)
        let two = comic("v2", series: "Berserk", volume: 2, path: "v2.cbz")
        let shelf = SeriesGrouper.group([one, two])[0]
        let progress = [one.id: ReadingProgress(page: 40, pageCount: 40, finished: true)]
        XCTAssertEqual(SeriesGrouper.nextUp(in: shelf, progress: progress)?.volume, 2)
    }

    func testNextUpIsNilWhenEverythingIsRead() {
        let one = comic("v1", series: "Berserk", volume: 1)
        let shelf = SeriesGrouper.group([one])[0]
        let progress = [one.id: ReadingProgress(page: 40, pageCount: 40, finished: true)]
        XCTAssertNil(SeriesGrouper.nextUp(in: shelf, progress: progress))
    }

    /// "201 volumes" for a webtoon of 201 chapters was simply wrong.
    func testTheShelfSubtitleCountsWhatItHolds() {
        func comic(_ volume: Double?, _ chapter: Double?) -> Comic {
            Comic(id: UUID().uuidString, sourceID: UUID(), relativePath: "x", kind: .archive, title: "x", series: "S",
                  volume: volume, chapter: chapter, author: nil, year: nil, subtitle: nil, pageCount: nil,
                  totalBytes: 1, addedAt: Date(), coverID: nil)
        }
        XCTAssertEqual(Series(id: "a", name: "S", comics: [comic(1, nil), comic(2, nil)]).subtitle, "2 volumes")
        XCTAssertEqual(Series(id: "b", name: "S", comics: [comic(nil, 1), comic(nil, 2), comic(nil, 3)]).subtitle, "3 chapters")
        XCTAssertEqual(Series(id: "c", name: "S", comics: [comic(1, nil), comic(nil, 199)]).subtitle, "1 volume, 1 chapter")
        XCTAssertEqual(Series(id: "d", name: "S", comics: [comic(nil, nil)]).subtitle, "1 book")
        XCTAssertEqual(Series(id: "e", name: "S", comics: [comic(1, 4)]).subtitle, "1 volume", "a volume that names its chapter is a volume")
    }
}
