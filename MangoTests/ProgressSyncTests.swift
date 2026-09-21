import XCTest
@testable import Mango

/// Cross-device sync. Positions travel by relative path, not by id (ids embed a per-install
/// UUID), and the last device you read on wins.
final class ProgressSyncTests: XCTestCase {
    private let iphone = UUID()
    private let ipad = UUID()

    private func comic(_ path: String, source: UUID) -> Comic {
        Comic(id: Comic.makeID(sourceID: source, relativePath: path), sourceID: source,
              relativePath: path, kind: .archive, title: path, series: nil, volume: nil,
              chapter: nil, author: nil, year: nil, subtitle: nil, pageCount: nil,
              totalBytes: 1, addedAt: Date(), coverID: nil)
    }

    private func at(_ page: Int, _ minutesAgo: Double) -> ReadingProgress {
        ReadingProgress(page: page, pageCount: 200, updatedAt: Date().addingTimeInterval(-minutesAgo * 60))
    }

    // MARK: Pulling from the cloud

    func testNewerCloudPositionWins() {
        let book = comic("Tower Dungeon/v01.cbz", source: iphone)
        let merged = ProgressSync.merged(local: [book.id: at(10, 60)], comics: [book],
                                         cloud: [book.syncKey: at(80, 1)])
        XCTAssertEqual(merged[book.id]?.page, 80)
    }

    func testOlderCloudPositionLoses() {
        let book = comic("a.cbz", source: iphone)
        let merged = ProgressSync.merged(local: [book.id: at(80, 1)], comics: [book],
                                         cloud: [book.syncKey: at(10, 60)])
        XCTAssertEqual(merged[book.id]?.page, 80)
    }

    /// The same file under a different source id on this device still picks it up.
    func testMatchesByPathNotByID() {
        let here = comic("Tower Dungeon/v01.cbz", source: iphone)
        let merged = ProgressSync.merged(local: [:], comics: [here], cloud: [here.syncKey: at(42, 1)])
        XCTAssertEqual(merged[here.id]?.page, 42)
    }

    /// A downloaded copy and its remote twin share a path, so both get the position.
    func testUpdatesEveryCopySharingThePath() {
        let remote = comic("a.cbz", source: iphone)
        let local = comic("a.cbz", source: ipad)
        let merged = ProgressSync.merged(local: [:], comics: [remote, local], cloud: [remote.syncKey: at(5, 1)])
        XCTAssertEqual(merged[remote.id]?.page, 5)
        XCTAssertEqual(merged[local.id]?.page, 5)
    }

    func testCloudEntriesForBooksThisDeviceLacksAreIgnored() {
        let book = comic("a.cbz", source: iphone)
        let merged = ProgressSync.merged(local: [:], comics: [book], cloud: ["somewhere/else.cbz": at(9, 1)])
        XCTAssertTrue(merged.isEmpty)
    }

    func testPathMatchingIgnoresCase() {
        let book = comic("Tower Dungeon/V01.CBZ", source: iphone)
        let merged = ProgressSync.merged(local: [:], comics: [book], cloud: ["tower dungeon/v01.cbz": at(3, 1)])
        XCTAssertEqual(merged[book.id]?.page, 3)
    }

    // MARK: Pushing to the cloud

    func testSnapshotTakesNewerLocal() {
        let book = comic("a.cbz", source: iphone)
        let snapshot = ProgressSync.cloudSnapshot(local: [book.id: at(90, 1)], comics: [book],
                                                  existingCloud: [book.syncKey: at(10, 60)])
        XCTAssertEqual(snapshot[book.syncKey]?.page, 90)
    }

    func testSnapshotKeepsNewerCloud() {
        let book = comic("a.cbz", source: iphone)
        let snapshot = ProgressSync.cloudSnapshot(local: [book.id: at(10, 60)], comics: [book],
                                                  existingCloud: [book.syncKey: at(90, 1)])
        XCTAssertEqual(snapshot[book.syncKey]?.page, 90)
    }

    /// An iPad with half the library must not erase the iPhone's positions for the other half.
    func testSnapshotPreservesBooksThisDeviceDoesNotHave() {
        let book = comic("a.cbz", source: ipad)
        let snapshot = ProgressSync.cloudSnapshot(local: [book.id: at(1, 1)], comics: [book],
                                                  existingCloud: ["only/on/iphone.cbz": at(50, 5)])
        XCTAssertEqual(snapshot["only/on/iphone.cbz"]?.page, 50)
        XCTAssertEqual(snapshot[book.syncKey]?.page, 1)
    }

    /// The round trip: read on one device, open the other, carry on.
    func testRoundTripBetweenTwoDevices() {
        let onPhone = comic("Series/v02.cbz", source: iphone)
        let onPad = comic("Series/v02.cbz", source: ipad)
        let pushed = ProgressSync.cloudSnapshot(local: [onPhone.id: at(120, 1)], comics: [onPhone], existingCloud: [:])
        let pulled = ProgressSync.merged(local: [onPad.id: at(4, 600)], comics: [onPad], cloud: pushed)
        XCTAssertEqual(pulled[onPad.id]?.page, 120)
    }
}
