import XCTest
@testable import Mango

final class PortableBackupTests: XCTestCase {
    private func item(_ source: UUID, path: String = "Book/one.cbz", bytes: Int64 = 1000) -> Comic {
        Comic(id: Comic.makeID(sourceID: source, relativePath: path), sourceID: source, relativePath: path,
              kind: .archive, title: "Test", series: "Test", volume: 1, totalBytes: bytes, addedAt: .now)
    }
    func testRestoreMatchesNewSourceIdentityAndKeepsCurrentProgress() {
        let oldItem = item(UUID()), currentItem = item(UUID())
        var old = LibraryState(comics: [oldItem]), current = LibraryState(comics: [currentItem])
        old.progress[oldItem.id] = ReadingProgress(page: 4, pageCount: 20)
        current.progress[currentItem.id] = ReadingProgress(page: 12, pageCount: 20)
        old.bookmarks[oldItem.id] = [Bookmark(id: "mark", page: 3, note: "Saved")]
        current.restorePortable(old)
        XCTAssertEqual(current.progress[currentItem.id]?.page, 12)
        XCTAssertEqual(current.bookmarks[currentItem.id]?.first?.id, "mark")
        XCTAssertNil(current.progress[oldItem.id])
        current.progress[currentItem.id] = nil
        current.restorePortable(old)
        XCTAssertEqual(current.progress[currentItem.id]?.page, 4)
        XCTAssertEqual(current.bookmarks[currentItem.id]?.count, 1)
    }
    func testRestoreDoesNotResurrectDeletedBookmarksOrMatchChangedFiles() {
        let oldItem = item(UUID()), currentItem = item(UUID())
        var old = LibraryState(comics: [oldItem]), current = LibraryState(comics: [currentItem])
        old.bookmarks[oldItem.id] = [Bookmark(id: "mark", page: 3, note: "Saved")]
        current.deletedBookmarks.bury("mark")
        current.restorePortable(old)
        XCTAssertTrue(current.bookmarks[currentItem.id]?.isEmpty ?? true)
        let changed = LibraryState(comics: [item(UUID(), bytes: 2000)])
        XCTAssertTrue(changed.portableMatches(old).isEmpty)
    }
    func testSamePathInUnrelatedSourcesIsAmbiguous() {
        let oldItem = item(UUID())
        let old = LibraryState(comics: [oldItem])
        let current = LibraryState(comics: [item(UUID()), item(UUID())])
        XCTAssertTrue(current.portableMatches(old).isEmpty)
    }
}
