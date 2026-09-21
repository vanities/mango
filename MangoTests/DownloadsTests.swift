import XCTest
@testable import Mango

/// Downloading a volume to read it, then removing it after: the comic has to carry on from the
/// NAS as though it never left.
final class DownloadsTests: XCTestCase {
    private let nasSource = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
    private let phoneSource = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!

    private func comic(_ path: String, on source: UUID) -> Comic {
        Comic(id: Comic.makeID(sourceID: source, relativePath: path), sourceID: source, relativePath: path, kind: .archive,
              title: "Vol. 1", series: "Solo Leveling", volume: nil, chapter: 1, author: nil, year: nil, subtitle: nil,
              pageCount: 22, totalBytes: 10_000_000, addedAt: Date(), coverID: nil)
    }

    /// Reading the NAS copy while its download lands, then opening the download, must not lose
    /// the pages read in between — progress is written for every copy.
    func testProgressIsWrittenForEveryCopy() {
        let nas = comic("Solo Leveling/Solo Leveling 001.cbz", on: nasSource)
        let phone = comic("Solo Leveling/Solo Leveling 001.cbz", on: phoneSource)
        let other = comic("Solo Leveling/Solo Leveling 002.cbz", on: nasSource)
        var state = LibraryState()
        state.comics = [nas, phone, other]
        state.setProgress(ReadingProgress(page: 7, pageCount: 22), forCopiesOf: nas)
        XCTAssertEqual(state.progress[phone.id]?.page, 7)
        XCTAssertEqual(state.progress[nas.id]?.page, 7)
        XCTAssertNil(state.progress[other.id])
    }

    func testRemovingADownloadHandsEverythingBackToTheNASCopy() {
        let nas = comic("Solo Leveling/Solo Leveling 001.cbz", on: nasSource)
        let phone = comic("Solo Leveling/Solo Leveling 001.cbz", on: phoneSource)
        var state = LibraryState()
        state.comics = [nas, phone]
        var old = ReadingProgress(page: 2, pageCount: 22)
        old.updatedAt = Date(timeIntervalSince1970: 1_000)
        var newer = ReadingProgress(page: 21, pageCount: 22)
        newer.updatedAt = Date(timeIntervalSince1970: 2_000)
        newer.finished = true
        state.progress[nas.id] = old
        state.progress[phone.id] = newer
        state.bookmarks[nas.id] = [Bookmark(page: 1)]
        state.bookmarks[phone.id] = [Bookmark(page: 12)]
        state.ratings[phone.id] = 5
        state.overrides[phone.id] = ComicOverride(title: "Awakening")
        state.lastComicID = phone.id
        state.longStripComicIDs = [phone.id]

        state.returnState(from: phone.id, to: nas.id)

        XCTAssertEqual(state.comics.map(\.id), [nas.id], "the download is gone from the library")
        XCTAssertEqual(state.progress[nas.id]?.page, 21, "the newer progress wins")
        XCTAssertEqual(state.progress[nas.id]?.finished, true)
        XCTAssertEqual(Set(state.bookmarks[nas.id]?.map(\.page) ?? []), [1, 12], "bookmarks from both")
        XCTAssertEqual(state.ratings[nas.id], 5)
        XCTAssertEqual(state.overrides[nas.id]?.title, "Awakening")
        XCTAssertEqual(state.lastComicID, nas.id, "Continue Reading follows it")
        XCTAssertTrue(state.longStripComicIDs.contains(nas.id))
        XCTAssertNil(state.progress[phone.id])
        XCTAssertNil(state.ratings[phone.id])
    }

    /// The NAS copy was read further than the download (on another device, say): it keeps its own.
    func testNewerProgressOnTheNASCopyIsKept() {
        let nas = comic("S/1.cbz", on: nasSource), phone = comic("S/1.cbz", on: phoneSource)
        var state = LibraryState()
        state.comics = [nas, phone]
        var nasProgress = ReadingProgress(page: 20, pageCount: 22)
        nasProgress.updatedAt = Date(timeIntervalSince1970: 3_000)
        var phoneProgress = ReadingProgress(page: 4, pageCount: 22)
        phoneProgress.updatedAt = Date(timeIntervalSince1970: 1_000)
        state.progress[nas.id] = nasProgress
        state.progress[phone.id] = phoneProgress
        state.returnState(from: phone.id, to: nas.id)
        XCTAssertEqual(state.progress[nas.id]?.page, 20)
    }
}
