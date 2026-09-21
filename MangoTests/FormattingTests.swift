import XCTest
@testable import Mango

final class FormattingTests: XCTestCase {
    func testWholeAndHalfNumbers() {
        XCTAssertEqual(Formatting.number(12), "12")
        XCTAssertEqual(Formatting.number(12.5), "12.5")
        XCTAssertEqual(Formatting.number(1), "1")
    }

    func testPagePosition() {
        XCTAssertEqual(Formatting.pagePosition(0, of: 192), "Page 1 of 192")
        XCTAssertEqual(Formatting.pagePosition(5, of: 0), "Page 6")
    }

    func testNaturalOrdering() {
        let sorted = ["page10.jpg", "page2.jpg", "page1.jpg"].sorted { $0.naturallyPrecedes($1) }
        XCTAssertEqual(sorted, ["page1.jpg", "page2.jpg", "page10.jpg"])
    }

    func testNormalizationForMatching() {
        XCTAssertEqual("JoJo's Bizarre Adventure".normalizedForMatching, "jojo s bizarre adventure")
        XCTAssertEqual("One_Punch  Man".normalizedForMatching, "one punch man")
    }

    func testComicLabels() {
        var comic = Comic(id: "x", sourceID: UUID(), relativePath: "a.cbz", kind: .archive,
                          title: "Berserk Vol. 1", series: "Berserk", volume: 1, chapter: nil,
                          author: nil, year: nil, pageCount: nil, totalBytes: 1_500_000,
                          addedAt: Date(), coverID: nil)
        XCTAssertEqual(comic.numberLabel, "Vol. 1")
        comic.volume = nil
        comic.chapter = 12.5
        XCTAssertEqual(comic.numberLabel, "Ch. 12.5")
        comic.chapter = nil
        XCTAssertNil(comic.numberLabel)
    }
}
