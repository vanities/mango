import UIKit
import XCTest
@testable import Mango

@MainActor
final class ScreenAwakeTests: XCTestCase {
    func testOneHolderLettingGoLeavesTheScreenOnForTheOther() {
        var written: [Bool] = []
        let awake = ScreenAwake { written.append($0) }
        awake.hold("reader", true)
        awake.hold("transfers", true)
        awake.hold("transfers", false)
        XCTAssertEqual(written.last, true, "A finished transfer must not let an open book's screen sleep")
        awake.release("reader")
        XCTAssertEqual(written.last, false)
    }

    func testTurningTheSettingOffLetsTheScreenSleep() {
        var written: [Bool] = []
        let awake = ScreenAwake { written.append($0) }
        awake.hold("reader", true)
        awake.hold("reader", false)
        XCTAssertEqual(written, [true, false])
    }

    /// The phone dimmed and locked mid-chapter on 2026-10-26: SpringBoard logged Mango's scene
    /// as not asking to keep the screen on while the reader was open. The transfer queue wrote
    /// its own answer every time the app became active, and with nothing to transfer it was no.
    func testTransferQueueComingBackToTheForegroundKeepsAnOpenBookAwake() throws {
        let (library, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        // Observers run in the order they were added. At launch ScreenAwake's comes first (the
        // queue's own first check creates it), so the queue's answer is the last word.
        _ = ScreenAwake.shared
        let transfers = TransferManager(library: library, store: LibraryStore(directory: root.appending(path: "queue")),
                                        registersBackgroundTasks: false)
        XCTAssertFalse(transfers.isTransferring)

        ScreenAwake.shared.hold("test reader", true)
        defer { ScreenAwake.shared.release("test reader") }
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled)
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, "Coming back to the app switched an open book's keep-awake off")
    }

    /// The same clash without leaving the app: a download finishing while a book is open.
    func testTransferFinishingWhileABookIsOpenKeepsItAwake() async throws {
        let (library, root) = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = LibrarySource(id: UUID(), kind: .folder, displayName: "Generated move fixture", addedAt: .now)
        let relative = "ScreenAwake-\(UUID().uuidString).cbz"
        let bytes = ZipTestBuilder.make([.init(name: "001.png", data: Data(repeating: 1, count: 1024), deflate: false)])
        try bytes.write(to: root.appending(path: relative))
        let comic = Comic(id: Comic.makeID(sourceID: source.id, relativePath: relative), sourceID: source.id,
                          relativePath: relative, kind: .archive, title: "Awake", series: nil, volume: nil, chapter: nil,
                          author: nil, year: nil, subtitle: nil, pageCount: 1, totalBytes: Int64(bytes.count), addedAt: .now)
        library.mutateState {
            $0.sources.append(source)
            $0.comics = [comic]
        }
        library.roots[source.id] = root
        let transfers = TransferManager(library: library, store: LibraryStore(directory: root.appending(path: "queue")),
                                        registersBackgroundTasks: false)
        let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: relative)
        defer { try? FileManager.default.removeItem(at: destination) }

        ScreenAwake.shared.hold("test reader", true)
        defer { ScreenAwake.shared.release("test reader") }
        transfers.move(comic)
        for _ in 0..<300 where transfers.isTransferring {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(transfers.jobs.first?.state, .done)
        XCTAssertTrue(UIApplication.shared.isIdleTimerDisabled, "A finished transfer switched an open book's keep-awake off")
    }

    private func makeLibrary() throws -> (LibraryModel, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "ScreenAwake-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let library = LibraryModel(store: LibraryStore(directory: root.appending(path: "state")),
                                   covers: CoverStore(directory: root.appending(path: "covers"), customDirectory: root.appending(path: "custom")),
                                   settings: AppSettings(defaults: defaults))
        return (library, root)
    }
}
