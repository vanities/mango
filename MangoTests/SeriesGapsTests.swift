import XCTest
@testable import Mango

final class SeriesGapsTests: XCTestCase {
    private func comic(_ volume: Double, name: String = "Test", chapter: Double? = nil) -> Comic {
        let source = UUID(), path = "\(name) v\(volume).cbz"
        return Comic(id: Comic.makeID(sourceID: source, relativePath: path), sourceID: source, relativePath: path,
                     kind: .archive, title: name, series: "Test", volume: volume, chapter: chapter,
                     totalBytes: 100, addedAt: .now)
    }
    func testInternalGapButNoGuessAboutEarlierOrFutureVolumes() {
        XCTAssertEqual(SeriesGaps.missing(in: [comic(2), comic(3), comic(5)]), [4])
    }
    func testOmnibusAndChapterNumberingDoNotProduceFalseAlarms() {
        XCTAssertTrue(SeriesGaps.missing(in: [comic(1, name: "Omnibus"), comic(3)]).isEmpty)
        XCTAssertTrue(SeriesGaps.missing(in: [comic(1, chapter: 1), comic(3, chapter: 3)]).isEmpty)
        XCTAssertTrue(SeriesGaps.missing(in: [comic(1), comic(1.5), comic(2)]).isEmpty)
    }
}
