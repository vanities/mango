import XCTest
@testable import Mango

/// Forward and backward compatibility of the one file that holds everything the user did.
/// Losing this file loses reading positions, so these cases are load-bearing.
final class LibraryStateCompatTests: XCTestCase {
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
    }

    func testRoundTrips() throws {
        var state = LibraryState()
        state.progress["a"] = ReadingProgress(page: 4, pageCount: 40)
        state.seriesDirection["berserk"] = .rightToLeft
        state.overrides["a"] = ComicOverride(series: "Berserk", volume: 2)
        state.hiddenComicIDs = ["b"]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let round = try decoder.decode(LibraryState.self, from: encoder.encode(state))

        XCTAssertEqual(round.progress["a"]?.page, 4)
        XCTAssertEqual(round.seriesDirection["berserk"], .rightToLeft)
        XCTAssertEqual(round.overrides["a"]?.series, "Berserk")
        XCTAssertEqual(round.hiddenComicIDs, ["b"])
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

        current.merge(restoring: old)

        XCTAssertEqual(current.progress["a"]?.page, 10, "current must win")
        XCTAssertEqual(current.progress["b"]?.page, 5, "missing progress comes back")
        XCTAssertEqual(current.nasServers.count, 1, "the server comes back")
        XCTAssertEqual(current.seriesDirection["berserk"], .leftToRight)
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
