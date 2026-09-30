import XCTest
@testable import Mango
import ShelfKit

/// Forward and backward compatibility of the one file that holds everything the user did.
/// Losing this file loses reading positions, so these cases are load-bearing.
final class LibraryStateCompatTests: XCTestCase {
    func testLibraryToolsDecodeOlderStateAndRoundTrip() throws {
        let old = try JSONDecoder().decode(LibraryState.self, from: Data("{}".utf8))
        XCTAssertTrue(old.tools.smartShelves.isEmpty)
        XCTAssertTrue(old.tools.arrivals.isEmpty)
        var state = old
        state.tools.smartShelves = [SmartShelf(name: "Trip", rule: .downloadedUnfinished)]
        let decoded = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.tools.smartShelves.first?.name, "Trip")
        let mark = try JSONDecoder().decode(Bookmark.self, from: Data(#"{"page":1}"#.utf8))
        XCTAssertNil(mark.anchor)
        let highlight = Bookmark(page: 2, note: "Note", anchor: NovelTextAnchor(quote: "hello", offset: 100))
        let restored = try JSONDecoder().decode(Bookmark.self, from: JSONEncoder().encode(highlight))
        XCTAssertEqual(restored.anchor?.quote, "hello")
    }

    private func decode(_ json: String) throws -> LibraryState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LibraryState.self, from: Data(json.utf8))
    }

    func testEmptyDocumentDecodes() throws {
        let state = try decode("{}")
        XCTAssertTrue(state.sources.isEmpty)
        XCTAssertTrue(state.comics.isEmpty)
        XCTAssertTrue(state.progress.isEmpty)
    }

    /// The failure mode this guards against: one unknown key must not throw away the document.
    func testUnknownKeysAreIgnored() throws {
        let state = try decode(#"{"schemaVersion":1,"somethingFromTheFuture":{"a":1},"progress":{"x":{"page":3}}}"#)
        XCTAssertEqual(state.progress["x"]?.page, 3)
    }

    func testMissingKeysFallBackToDefaults() throws {
        let state = try decode(#"{"progress":{"x":{"page":3,"pageCount":10}}}"#)
        XCTAssertEqual(state.progress.count, 1)
        XCTAssertTrue(state.nasServers.isEmpty)
        XCTAssertTrue(state.overrides.isEmpty)
        XCTAssertTrue(state.seriesDirection.isEmpty)
        XCTAssertTrue(state.longStripComicIDs.isEmpty, "a library from before long-strip detection")
        XCTAssertTrue(state.seriesMode.isEmpty)
        XCTAssertTrue(state.novelChapterTitles.isEmpty, "a library from before novels' chapter names were kept")
    }

    func testRoundTrips() throws {
        var state = LibraryState()
        state.progress["a"] = ReadingProgress(page: 4, pageCount: 40)
        state.seriesDirection["berserk"] = .rightToLeft
        state.overrides["a"] = ComicOverride(series: "Berserk", volume: 2)
        state.hiddenComicIDs = ["b"]
        state.longStripComicIDs = ["w"]
        state.seriesMode["rooftop garden"] = .continuous
        state.novelChapterTitles["LN/Healer v01.epub"] = [nil, "Prologue", nil, "Chapter 1"]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let round = try decoder.decode(LibraryState.self, from: encoder.encode(state))

        XCTAssertEqual(round.progress["a"]?.page, 4)
        XCTAssertEqual(round.seriesDirection["berserk"], .rightToLeft)
        XCTAssertEqual(round.overrides["a"]?.series, "Berserk")
        XCTAssertEqual(round.hiddenComicIDs, ["b"])
        XCTAssertEqual(round.longStripComicIDs, ["w"])
        XCTAssertEqual(round.seriesMode["rooftop garden"], .continuous)
        XCTAssertEqual(round.novelChapterTitles["LN/Healer v01.epub"], [nil, "Prologue", nil, "Chapter 1"],
                       "Unnamed documents keep their place, so names stay lined up with the reading order")
    }

    // MARK: Salvage

    /// Restoring a moved-aside library must add back what's missing and never overwrite what's there.
    func testMergeRestoresOnlyMissingState() {
        var current = LibraryState()
        current.progress["a"] = ReadingProgress(page: 10, pageCount: 100)

        var old = LibraryState()
        old.progress["a"] = ReadingProgress(page: 2, pageCount: 100)
        old.progress["b"] = ReadingProgress(page: 5, pageCount: 50)
        old.nasServers = [NASServer(id: UUID(), name: "NAS", host: "192.168.1.3", share: "all",
                                    path: "manga", username: "guest", addedAt: Date())]
        old.seriesDirection["berserk"] = .leftToRight
        old.longStripComicIDs = ["w"]
        old.seriesMode["rooftop garden"] = .continuous

        current.merge(restoring: old)

        XCTAssertEqual(current.progress["a"]?.page, 10, "current must win")
        XCTAssertEqual(current.progress["b"]?.page, 5, "missing progress comes back")
        XCTAssertEqual(current.nasServers.count, 1, "the server comes back")
        XCTAssertEqual(current.seriesDirection["berserk"], .leftToRight)
        XCTAssertEqual(current.longStripComicIDs, ["w"])
        XCTAssertEqual(current.seriesMode["rooftop garden"], .continuous)
    }

    func testMergeDoesNotDuplicateTheDocumentsSource() {
        var current = LibraryState()
        current.sources = [LibrarySource(id: UUID(), kind: .appDocuments, displayName: "On My Device",
                                         bookmark: nil, addedAt: Date())]
        var old = LibraryState()
        old.sources = [LibrarySource(id: UUID(), kind: .appDocuments, displayName: "On My Device",
                                     bookmark: nil, addedAt: Date())]
        current.merge(restoring: old)
        XCTAssertEqual(current.sources.count { $0.kind == .appDocuments }, 1)
    }

    func testHasUserData() {
        var state = LibraryState()
        XCTAssertFalse(state.hasUserData)
        state.progress["a"] = ReadingProgress(page: 1, pageCount: 10)
        XCTAssertTrue(state.hasUserData)
    }
}
