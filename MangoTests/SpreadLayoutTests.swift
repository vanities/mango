import XCTest
@testable import Mango

final class SpreadLayoutTests: XCTestCase {
    func testSpreadsOffGivesOnePagePerGroup() {
        let groups = SpreadLayout.groups(pageCount: 5, enabled: false)
        XCTAssertEqual(groups, [[0], [1], [2], [3], [4]])
    }

    /// A physical book: the cover alone, then pages pair up.
    func testCoverStandsAloneThenPagesPair() {
        let groups = SpreadLayout.groups(pageCount: 7, enabled: true)
        XCTAssertEqual(groups, [[0], [1, 2], [3, 4], [5, 6]])
    }

    func testOddTailGetsItsOwnGroup() {
        let groups = SpreadLayout.groups(pageCount: 6, enabled: true)
        XCTAssertEqual(groups, [[0], [1, 2], [3, 4], [5]])
    }

    /// A double-page spread is one wide image; pairing it would cut the art in half.
    func testWidePageBreaksThePairing() {
        let groups = SpreadLayout.groups(pageCount: 7, wide: [3], enabled: true)
        XCTAssertEqual(groups, [[0], [1, 2], [3], [4, 5], [6]])
    }

    func testTwoWidePagesInARow() {
        let groups = SpreadLayout.groups(pageCount: 6, wide: [2, 3], enabled: true)
        XCTAssertEqual(groups, [[0], [1], [2], [3], [4, 5]])
    }

    func testEmptyComic() {
        XCTAssertEqual(SpreadLayout.groups(pageCount: 0, enabled: true), [])
    }

    func testFindingTheGroupForASavedPage() {
        let groups = SpreadLayout.groups(pageCount: 7, enabled: true)
        XCTAssertEqual(SpreadLayout.groupIndex(containing: 0, in: groups), 0)
        XCTAssertEqual(SpreadLayout.groupIndex(containing: 4, in: groups), 2)
        XCTAssertEqual(SpreadLayout.groupIndex(containing: 6, in: groups), 3)
    }

    /// Rotating the device must not lose your place.
    func testPositionSurvivesTurningSpreadsOn() {
        let single = SpreadLayout.groups(pageCount: 20, enabled: false)
        let page = single[9][0]
        let paired = SpreadLayout.groups(pageCount: 20, enabled: true)
        let index = SpreadLayout.groupIndex(containing: page, in: paired)
        XCTAssertTrue(paired[index].contains(9))
    }
}
