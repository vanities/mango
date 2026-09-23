import XCTest
import ShelfKit
@testable import Mango

@MainActor
final class LibraryArrivalsTests: XCTestCase {
    func testOpenedFileIsScannedInPlaceAndReopeningReusesSource() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Opened.cbz")
        try Data([0]).write(to: url)
        let model = makeModel(in: folder)
        model.addOpenedFile(url)
        await waitForScan(model)
        let comic = try XCTUnwrap(model.requestedComic)
        guard case .local(let location) = model.location(for: comic) else { return XCTFail("Missing local file") }
        XCTAssertTrue(location.isSameFile(as: url))
        let sourceCount = model.state.sources.count
        model.requestedComic = nil
        model.addOpenedFile(url)
        await waitForScan(model)
        XCTAssertEqual(model.state.sources.count, sourceCount)
        XCTAssertEqual(model.requestedComic?.id, comic.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testLocalRefreshPreservesUnscannedSourcesAndProgress() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appending(path: "First.cbz")
        let second = folder.appending(path: "Second.cbz")
        try Data([0]).write(to: first)
        try Data([0]).write(to: second)
        let model = makeModel(in: folder)
        model.addOpenedFile(first)
        await waitForScan(model)
        let comic = try XCTUnwrap(model.requestedComic)
        model.recordProgress(3, pageCount: 10, for: comic)
        model.addOpenedFile(second)
        await waitForScan(model)
        XCTAssertEqual(model.state.comics.count, 2)
        XCTAssertEqual(model.progress(for: comic)?.page, 3)
        XCTAssertNotEqual(model.state.comics[0].syncKey, model.state.comics[1].syncKey)
    }

    private func makeModel(in folder: URL) -> LibraryModel {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        return LibraryModel(store: LibraryStore(directory: folder.appending(path: "State")),
                            covers: CoverStore(directory: folder.appending(path: "Covers"),
                                               customDirectory: folder.appending(path: "Custom")),
                            settings: AppSettings(defaults: defaults))
    }

    private func waitForScan(_ model: LibraryModel) async {
        for _ in 0..<200 {
            await Task.yield()
            if model.pendingOpen == nil, !model.isScanning { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Opened file never reached the shelf")
    }
}
