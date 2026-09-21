import XCTest
@testable import Mango

/// Your own lists across the library — "Up next", "JoJo in order", a to-read pile.
final class ReadingListTests: XCTestCase {
    func testAddingIsIdempotentAndOrderIsKept() {
        var state = LibraryState()
        let id = state.createList(named: "Up next")
        state.addToList(id, .series("comic|berserk"))
        state.addToList(id, .volume("berserk/berserk v02.cbz"))
        state.addToList(id, .series("comic|berserk"))
        XCTAssertEqual(state.readingLists.first?.items, [.series("comic|berserk"), .volume("berserk/berserk v02.cbz")])
    }

    func testMovingAndRemoving() {
        var state = LibraryState()
        let id = state.createList(named: "JoJo in order")
        for n in 1...3 { state.addToList(id, .series("comic|part \(n)")) }
        state.moveInList(id, from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(state.readingLists[0].items.first, .series("comic|part 3"))
        state.removeFromList(id, .series("comic|part 1"))
        XCTAssertEqual(state.readingLists[0].items, [.series("comic|part 3"), .series("comic|part 2")])
        state.deleteList(id)
        XCTAssertTrue(state.readingLists.isEmpty)
    }

    /// A volume is listed by its file, so a download or a rescan doesn't drop it.
    func testAVolumeEntryFindsEveryCopyOfTheFile() {
        let source = UUID()
        let comic = Comic(id: Comic.makeID(sourceID: source, relativePath: "Berserk/Berserk v02.cbz"), sourceID: source,
                          relativePath: "Berserk/Berserk v02.cbz", kind: .archive, title: "Vol. 2", series: "Berserk",
                          volume: 2, chapter: nil, author: nil, year: nil, subtitle: nil, pageCount: nil, totalBytes: 1,
                          addedAt: Date(), coverID: nil)
        XCTAssertEqual(ReadingList.Item.volume(comic.syncKey), ReadingList.Item(comic))
    }

    func testListsDecodeFromOlderLibraries() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertTrue(try decoder.decode(LibraryState.self, from: Data("{}".utf8)).readingLists.isEmpty)
        var state = LibraryState()
        let id = state.createList(named: "Up next")
        state.addToList(id, .series("comic|berserk"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let round = try decoder.decode(LibraryState.self, from: encoder.encode(state))
        XCTAssertEqual(round.readingLists.first?.name, "Up next")
        XCTAssertEqual(round.readingLists.first?.items, [.series("comic|berserk")])
    }
}
