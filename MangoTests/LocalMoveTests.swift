import XCTest
@testable import Mango

/// Moving into Mango deletes the original, so every way it can go wrong must leave the
/// original where it was.
final class LocalMoveTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "LocalMoveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func write(_ bytes: Int, _ seed: UInt8, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &+ Int(seed)) }).write(to: url)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

    private func run(_ files: [LocalMove.File], emptied: URL? = nil, cancel: Bool = false) throws {
        try LocalMove.run(files, emptiedFolder: emptied, progress: { _ in }, isCancelled: { cancel })
    }

    func testAMoveCopiesChecksAndThenRemovesTheOriginal() throws {
        let dir = try tempDir()
        let from = dir.appending(path: "Picked/Akira/Akira v01.cbz"), to = dir.appending(path: "Mango/Akira/Akira v01.cbz")
        try write(9_000_000, 3, from)   // more than two chunks
        let original = try Data(contentsOf: from)
        try run([.init(source: from, destination: to, size: 9_000_000)])
        XCTAssertFalse(exists(from))
        XCTAssertEqual(try Data(contentsOf: to), original, "every byte")
        XCTAssertFalse(exists(to.appendingPathExtension("part")))
    }

    func testTheSameFileAlreadyThereIsNotCopiedAgain() throws {
        let dir = try tempDir()
        let from = dir.appending(path: "Picked/a.cbz"), to = dir.appending(path: "Mango/a.cbz")
        try write(1_000, 1, from)
        try write(1_000, 1, to)
        try run([.init(source: from, destination: to, size: 1_000)])
        XCTAssertFalse(exists(from), "the duplicate collapses into the one already there")
        XCTAssertTrue(exists(to))
    }

    func testADifferentFileThereIsNeverOverwritten() throws {
        let dir = try tempDir()
        let from = dir.appending(path: "Picked/a.cbz"), to = dir.appending(path: "Mango/a.cbz")
        try write(1_000, 1, from)
        try write(500, 9, to)
        XCTAssertThrowsError(try run([.init(source: from, destination: to, size: 1_000)]))
        XCTAssertTrue(exists(from), "the original stays")
        XCTAssertEqual(try Data(contentsOf: to).count, 500, "and so does what was there")
    }

    func testCancellingKeepsTheOriginal() throws {
        let dir = try tempDir()
        let from = dir.appending(path: "Picked/a.cbz"), to = dir.appending(path: "Mango/a.cbz")
        try write(1_000, 1, from)
        XCTAssertThrowsError(try run([.init(source: from, destination: to, size: 1_000)], cancel: true))
        XCTAssertTrue(exists(from))
        XCTAssertFalse(exists(to))
    }

    /// A folder of pages moves whole, and the folder it leaves empty goes too.
    func testAFolderComicMovesEveryPage() throws {
        let dir = try tempDir()
        let folder = dir.appending(path: "Picked/Loose")
        var files: [LocalMove.File] = []
        for page in ["001.jpg", "002.jpg"] {
            try write(2_000, 4, folder.appending(path: page))
            files.append(.init(source: folder.appending(path: page), destination: dir.appending(path: "Mango/Loose/\(page)"), size: 2_000))
        }
        try run(files, emptied: folder)
        XCTAssertFalse(exists(folder))
        XCTAssertTrue(exists(dir.appending(path: "Mango/Loose/002.jpg")))
    }

    /// If the size is wrong the original must not be touched (a one-byte short file here).
    func testAShortCopyKeepsTheOriginal() throws {
        let dir = try tempDir()
        let from = dir.appending(path: "Picked/a.cbz"), to = dir.appending(path: "Mango/a.cbz")
        try write(1_000, 1, from)
        XCTAssertThrowsError(try run([.init(source: from, destination: to, size: 1_001)]))
        XCTAssertTrue(exists(from))
        XCTAssertFalse(exists(to))
    }
}
