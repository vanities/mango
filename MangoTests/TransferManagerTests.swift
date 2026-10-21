import XCTest
@testable import Mango

@MainActor
final class TransferManagerTests: XCTestCase {
    func testRetryOfCancelledMoveCanFinishAndPreservesReadingState() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "TransferRetry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = LibraryModel(store: LibraryStore(directory: root.appending(path: "state")),
                                   covers: CoverStore(directory: root.appending(path: "covers"), customDirectory: root.appending(path: "custom")),
                                   settings: AppSettings(defaults: defaults))
        let source = LibrarySource(id: UUID(), kind: .folder, displayName: "Generated move fixture", addedAt: .now)
        let relative = "TransferRetry-\(UUID().uuidString).cbz"
        let original = root.appending(path: relative)
        let bytes = ZipTestBuilder.make([.init(name: "001.png", data: Data(repeating: 1, count: 1024), deflate: false)])
        try bytes.write(to: original)
        let comic = Comic(id: Comic.makeID(sourceID: source.id, relativePath: relative), sourceID: source.id,
                          relativePath: relative, kind: .archive, title: "Retry", series: nil, volume: nil, chapter: nil,
                          author: nil, year: nil, subtitle: nil, pageCount: 8, totalBytes: Int64(bytes.count), addedAt: .now)
        library.mutateState {
            $0.sources.append(source)
            $0.comics = [comic]
            $0.progress[comic.id] = ReadingProgress(page: 3, pageCount: 8)
        }
        library.roots[source.id] = root
        let manager = TransferManager(library: library, store: LibraryStore(directory: root.appending(path: "queue")), registersBackgroundTasks: false)
        let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: relative)
        defer { try? FileManager.default.removeItem(at: destination) }
        manager.move(comic)
        let job = try XCTUnwrap(manager.jobs.first)
        manager.cancel(job.id)
        // Cancellation happens before the worker starts. Let its detached copy finish unwinding.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(manager.jobs.first?.state, .cancelled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        manager.retry(job.id)
        for _ in 0..<200 where manager.jobs.first?.isActive == true {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(manager.jobs.first?.state, .done, "Retry must clear the previous attempt's cancellation")
        guard manager.jobs.first?.state == .done else { return }
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        let localSource = try XCTUnwrap(library.state.sources.first { $0.kind == .appDocuments })
        let movedID = Comic.makeID(sourceID: localSource.id, relativePath: relative)
        XCTAssertEqual(library.state.progress[movedID]?.page, 3)
    }
}
