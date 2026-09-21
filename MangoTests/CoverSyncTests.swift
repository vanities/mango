import XCTest
@testable import Mango

/// A cover picked on the iPhone shows up on the iPad: synced by where it came from.
final class CoverSyncTests: XCTestCase {
    private func choice(_ kind: CoverChoice.Kind, _ url: String? = nil, at seconds: TimeInterval) -> CoverChoice {
        CoverChoice(kind: kind, url: url, chosenAt: Date(timeIntervalSince1970: seconds))
    }

    func testANewerChoiceFromAnotherDeviceIsApplied() {
        let cloud = ["berserk/v01.cbz": choice(.online, "https://example.com/a.jpg", at: 200)]
        let local = ["berserk/v01.cbz": choice(.original, at: 100)]
        XCTAssertEqual(CoverSync.pending(cloud: cloud, applied: local), cloud)
    }

    func testAnOlderOrSameChoiceIsNot() {
        let same = ["k": choice(.online, "https://example.com/a.jpg", at: 200)]
        XCTAssertTrue(CoverSync.pending(cloud: same, applied: same).isEmpty)
        let older = ["k": choice(.original, at: 50)]
        XCTAssertTrue(CoverSync.pending(cloud: older, applied: same).isEmpty)
    }

    func testPushingKeepsTheNewestOfEach() {
        let cloud = ["a": choice(.online, "https://x/1.jpg", at: 100), "b": choice(.original, at: 300)]
        let local = ["a": choice(.online, "https://x/2.jpg", at: 200), "b": choice(.online, "https://x/3.jpg", at: 250)]
        let pushed = CoverSync.snapshot(local: local, cloud: cloud)
        XCTAssertEqual(pushed["a"]?.url, "https://x/2.jpg", "this device's newer pick")
        XCTAssertEqual(pushed["b"]?.kind, .original, "the other device's newer undo")
    }

    /// A photo can't travel through iCloud key-value storage; other devices keep their own cover.
    func testAPhotoPickIsRecordedButNotFetched() {
        let cloud = ["k": choice(.device, at: 500)]
        XCTAssertEqual(CoverSync.pending(cloud: cloud, applied: [:]), cloud, "still pending, so it's recorded")
        XCTAssertNil(CoverSync.pending(cloud: cloud, applied: [:])["k"]?.url)
    }

    func testChoicesDecodeFromOlderLibraries() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertTrue(try decoder.decode(LibraryState.self, from: Data("{}".utf8)).coverChoices.isEmpty)
    }
}
