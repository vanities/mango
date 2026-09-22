import XCTest
import ShelfKit
@testable import Mango

/// A comic on this device twice is found by what's in it, not what it's called.
final class DuplicateFinderTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "DuplicateFinderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func write(_ bytes: Int, seed: UInt8, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<bytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }).write(to: url)
    }

    private func comic(_ path: String, added: TimeInterval, bytes: Int64 = 100) -> Comic {
        Comic(id: "s|\(path)", sourceID: UUID(), relativePath: path, kind: .archive, title: path, series: nil, volume: 1,
              chapter: nil, author: nil, year: nil, subtitle: nil, summary: nil, pageCount: nil, totalBytes: bytes,
              addedAt: Date(timeIntervalSinceReferenceDate: added), coverID: nil)
    }

    func testTheSameFileUnderAnotherNameMatches() throws {
        let dir = try tempDir()
        try write(700_000, seed: 1, to: dir.appending(path: "Akira v01.cbz"))
        try write(700_000, seed: 1, to: dir.appending(path: "Copies/akira-1 (copy).cbz"))
        try write(700_000, seed: 2, to: dir.appending(path: "Akira v02.cbz"))
        let a = try DuplicateFinder.fingerprint(of: dir.appending(path: "Akira v01.cbz"))
        XCTAssertEqual(a, try DuplicateFinder.fingerprint(of: dir.appending(path: "Copies/akira-1 (copy).cbz")))
        XCTAssertNotEqual(a, try DuplicateFinder.fingerprint(of: dir.appending(path: "Akira v02.cbz")), "different content")
    }

    /// A small file is hashed whole, so a one-byte difference counts.
    func testSmallFilesDifferingByOneByteDoNotMatch() throws {
        let dir = try tempDir()
        try Data([1, 2, 3]).write(to: dir.appending(path: "a.pdf"))
        try Data([1, 2, 4]).write(to: dir.appending(path: "b.pdf"))
        XCTAssertNotEqual(try DuplicateFinder.fingerprint(of: dir.appending(path: "a.pdf")),
                          try DuplicateFinder.fingerprint(of: dir.appending(path: "b.pdf")))
    }

    func testFolderComicsMatchByTheirPages() throws {
        let dir = try tempDir()
        for folder in ["One", "Two"] {
            try write(1_000, seed: 1, to: dir.appending(path: "\(folder)/001.jpg"))
            try write(2_000, seed: 2, to: dir.appending(path: "\(folder)/002.jpg"))
        }
        try write(1_000, seed: 1, to: dir.appending(path: "Three/001.jpg"))
        let one = try DuplicateFinder.fingerprint(of: dir.appending(path: "One"))
        XCTAssertEqual(one, try DuplicateFinder.fingerprint(of: dir.appending(path: "Two")))
        XCTAssertNotEqual(one, try DuplicateFinder.fingerprint(of: dir.appending(path: "Three")))
        XCTAssertEqual(one.size, 3_000)
    }

    /// The check that caught a real bug: Documents' URL ends in "/", and adding another refused
    /// every file in it.
    func testInsideAFolderWithOrWithoutItsTrailingSlash() {
        let target = URL(filePath: "/var/app/Documents/Copies/a.cbz")
        XCTAssertTrue(target.isInside(URL(filePath: "/var/app/Documents/", directoryHint: .isDirectory)))
        XCTAssertTrue(target.isInside(URL(filePath: "/var/app/Documents", directoryHint: .notDirectory)))
        XCTAssertFalse(URL(filePath: "/var/app/Documents 2/a.cbz").isInside(URL(filePath: "/var/app/Documents")), "a sibling that shares the name")
        XCTAssertFalse(URL(filePath: "/var/app/Documents/../secret.cbz").isInside(URL(filePath: "/var/app/Documents")), "no climbing out")
        XCTAssertFalse(URL(filePath: "/var/app/Documents/", directoryHint: .isDirectory).isInside(URL(filePath: "/var/app/Documents")), "not the folder itself")
    }

    func testSetsKeepTheOldestFirstAndCountWhatCouldGo() {
        let print = ComicFingerprint(size: 100, digest: "x")
        let newer = comic("b.cbz", added: 200, bytes: 100), older = comic("a.cbz", added: 100, bytes: 100)
        let alone = comic("c.cbz", added: 50)
        let sets = DuplicateFinder.sets(of: [(newer, print), (older, print), (alone, ComicFingerprint(size: 5, digest: "y"))])
        XCTAssertEqual(sets.count, 1, "a comic on its own isn't a duplicate")
        XCTAssertEqual(sets[0].copies.map(\.relativePath), ["a.cbz", "b.cbz"])
        XCTAssertEqual(sets[0].wastedBytes, 100)
    }
}
