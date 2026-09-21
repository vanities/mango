import XCTest
@testable import Mango

/// Scanning against real files in a temp directory — the layouts a comics folder actually has.
final class LibraryScannerTests: XCTestCase {
    private var root: URL!
    private let source = LibrarySource(id: UUID(), kind: .folder, displayName: "Test",
                                       bookmark: nil, addedAt: Date())

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "mango-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, bytes: Int = 16) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0, count: bytes).write(to: url)
    }

    func testFindsArchivesInNestedFolders() throws {
        try write("Berserk/Berserk v01.cbz")
        try write("Berserk/Berserk v02.cbz")
        try write("Akira/Akira v01.cbz")
        let result = LibraryScanner.scanLocal(source: source, root: root)
        XCTAssertEqual(result.comics.count, 3)
        XCTAssertEqual(Set(result.comics.compactMap(\.series)), ["Berserk", "Akira"])
    }

    func testPDFsCountAsComics() throws {
        try write("Lone Wolf and Cub v01.pdf")
        let result = LibraryScanner.scanLocal(source: source, root: root)
        XCTAssertEqual(result.comics.count, 1)
        XCTAssertEqual(result.comics[0].kind, .pdf)
    }

    /// An unzipped volume — a folder of loose pages — is one comic, not none.
    func testFolderOfLoosePagesIsOneComic() throws {
        for page in 1...12 { try write("Vagabond v03/\(String(format: "%03d", page)).jpg") }
        let result = LibraryScanner.scanLocal(source: source, root: root)
        XCTAssertEqual(result.comics.count, 1)
        XCTAssertEqual(result.comics[0].kind, .folder)
        XCTAssertEqual(result.comics[0].volume, 3)
    }

    /// Two loose images in a series folder is a stray cover, not a volume.
    func testAFewStrayImagesAreNotAComic() throws {
        try write("Series/cover.jpg")
        try write("Series/back.jpg")
        try write("Series/Series v01.cbz")
        let result = LibraryScanner.scanLocal(source: source, root: root)
        XCTAssertEqual(result.comics.count, 1)
        XCTAssertEqual(result.comics[0].kind, .archive)
    }

    func testSkipsJunkFiles() throws {
        try write("Series/.DS_Store")
        try write("Series/__MACOSX/._x.cbz")
        try write("Series/Series v01.cbz")
        let result = LibraryScanner.scanLocal(source: source, root: root)
        XCTAssertEqual(result.comics.count, 1)
    }

    /// `.cbr` is RAR: no free decoder, so it must not show up as something the app can open.
    func testCBRIsNotPickedUp() throws {
        try write("Series/Series v01.cbr")
        let result = LibraryScanner.scanLocal(source: source, root: root)
        XCTAssertTrue(result.comics.isEmpty)
    }

    func testIDsAreStableAcrossScans() throws {
        try write("Berserk/Berserk v01.cbz")
        let first = LibraryScanner.scanLocal(source: source, root: root)
        let second = LibraryScanner.scanLocal(source: source, root: root)
        XCTAssertEqual(first.comics.map(\.id), second.comics.map(\.id))
    }

    func testRelativePathsAreRelativeToTheRoot() throws {
        try write("Manga/Berserk/Berserk v01.cbz")
        let result = LibraryScanner.scanLocal(source: source, root: root)
        XCTAssertEqual(result.comics[0].relativePath, "Manga/Berserk/Berserk v01.cbz")
    }

    func testFolderNameSuppliesTheSeries() throws {
        try write("Vinland Saga/v01.cbz")
        let result = LibraryScanner.scanLocal(source: source, root: root)
        XCTAssertEqual(result.comics[0].series, "Vinland Saga")
        XCTAssertEqual(result.comics[0].volume, 1)
    }
}
