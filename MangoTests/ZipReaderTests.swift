import XCTest
@testable import Mango

/// Proves the zip reader against bytes it didn't produce, including the thing that makes
/// NAS reading work: finding the index from the tail and fetching one entry by range.
final class ZipReaderTests: XCTestCase {
    private func page(_ gray: UInt8) -> Data { ZipTestBuilder.pngPixel(gray: gray) }

    func testReadsStoredEntries() async throws {
        let payload = Data("hello mango".utf8)
        let zip = ZipTestBuilder.make([.init(name: "001.txt", data: payload, deflate: false)])
        let entries = try await ZipReader.readCentralDirectory(DataReader(zip))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].name, "001.txt")
        XCTAssertEqual(entries[0].method, 0)
        let out = try await ZipReader.read(entries[0], from: DataReader(zip))
        XCTAssertEqual(out, payload)
    }

    func testReadsDeflatedEntries() async throws {
        // Repetitive so it actually compresses rather than being stored.
        let payload = Data(String(repeating: "panel ", count: 500).utf8)
        let zip = ZipTestBuilder.make([.init(name: "002.txt", data: payload, deflate: true)])
        let entries = try await ZipReader.readCentralDirectory(DataReader(zip))
        XCTAssertEqual(entries[0].method, 8)
        XCTAssertLessThan(entries[0].compressedSize, entries[0].uncompressedSize)
        let out = try await ZipReader.read(entries[0], from: DataReader(zip))
        XCTAssertEqual(out, payload)
    }

    func testMixedMethodsInOneArchive() async throws {
        let stored = Data("stored".utf8)
        let deflated = Data(String(repeating: "x", count: 400).utf8)
        let zip = ZipTestBuilder.make([
            .init(name: "a.txt", data: stored, deflate: false),
            .init(name: "b.txt", data: deflated, deflate: true),
        ])
        let entries = try await ZipReader.readCentralDirectory(DataReader(zip))
        XCTAssertEqual(entries.count, 2)
        let first = try await ZipReader.read(entries[0], from: DataReader(zip))
        let second = try await ZipReader.read(entries[1], from: DataReader(zip))
        XCTAssertEqual(first, stored)
        XCTAssertEqual(second, deflated)
    }

    func testRejectsSomethingThatIsNotAZip() async {
        let reader = DataReader(Data(repeating: 0x41, count: 5000))
        do {
            _ = try await ZipReader.readCentralDirectory(reader)
            XCTFail("expected notAZip")
        } catch {
            XCTAssertTrue(error is ZipError)
        }
    }

    // MARK: As a comic

    func testOpensAsAComicAndOrdersPagesNaturally() async throws {
        let zip = ZipTestBuilder.make([
            .init(name: "page10.png", data: page(10), deflate: false),
            .init(name: "page2.png", data: page(20), deflate: false),
            .init(name: "page1.png", data: page(30), deflate: false),
        ])
        let archive = try await ZipComicArchive.open(reader: DataReader(zip), displayName: "Test")
        XCTAssertEqual(archive.pageCount, 3)
        XCTAssertEqual((0..<3).map { archive.pageName(at: $0) }, ["page1.png", "page2.png", "page10.png"])
    }

    func testSkipsMacOSJunkAndNonImages() async throws {
        let zip = ZipTestBuilder.make([
            .init(name: "__MACOSX/._001.png", data: page(1), deflate: false),
            .init(name: ".DS_Store", data: Data([0, 1, 2]), deflate: false),
            .init(name: "ComicInfo.xml", data: Data("<xml/>".utf8), deflate: false),
            .init(name: "001.png", data: page(120), deflate: false),
            .init(name: "002.png", data: page(200), deflate: false),
        ])
        let archive = try await ZipComicArchive.open(reader: DataReader(zip), displayName: "Test")
        XCTAssertEqual(archive.pageCount, 2)
        XCTAssertEqual(archive.pageName(at: 0), "001.png")
    }

    func testAnArchiveWithNoImagesFails() async {
        let zip = ZipTestBuilder.make([.init(name: "readme.txt", data: Data("hi".utf8), deflate: false)])
        do {
            _ = try await ZipComicArchive.open(reader: DataReader(zip), displayName: "Empty")
            XCTFail("expected noPages")
        } catch {
            XCTAssertTrue(error is ArchiveError)
        }
    }

    func testPagesDecodeToImages() async throws {
        let zip = ZipTestBuilder.make([
            .init(name: "001.png", data: ZipTestBuilder.pngPixel(width: 64, height: 96), deflate: true),
        ])
        let archive = try await ZipComicArchive.open(reader: DataReader(zip), displayName: "Test")
        let image = try await archive.page(at: 0, maxPixel: 64)
        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)
    }

    /// The property the NAS path depends on: opening a comic touches only the tail and the
    /// index, and reading one page touches only that page's bytes — never the whole file.
    func testOpeningReadsOnlyTheTailNotTheWholeFile() async throws {
        let bigPage = ZipTestBuilder.pngPixel(width: 400, height: 600)
        let zip = ZipTestBuilder.make((1...20).map {
            .init(name: String(format: "%03d.png", $0), data: bigPage, deflate: false)
        })
        let counting = CountingReader(DataReader(zip))
        let archive = try await ZipComicArchive.open(reader: counting, displayName: "Big")
        XCTAssertEqual(archive.pageCount, 20)
        let readToOpen = await counting.bytesRead
        XCTAssertLessThan(readToOpen, zip.count / 2, "opening should not pull the whole archive")

        _ = try await archive.pageData(at: 0)
        let readAfterOnePage = await counting.bytesRead
        XCTAssertLessThan(readAfterOnePage, zip.count, "one page should not pull every page")
    }
}
