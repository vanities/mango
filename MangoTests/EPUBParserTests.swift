import XCTest
@testable import Mango

/// The EPUB structure is two indirections deep — container.xml points at the OPF, the OPF's
/// spine points at manifest ids, and the manifest holds the hrefs — so every one of these is
/// a place a book can silently come out empty.
final class EPUBParserTests: XCTestCase {
    private let container = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
    </container>
    """

    /// Shaped like the Seven Seas books actually on the NAS: EPUB 2, namespaced Dublin Core,
    /// cover declared with <meta name="cover">.
    private let opf = """
    <?xml version="1.0" encoding="utf-8"?>
    <package version="2.0" unique-identifier="BookId" xmlns="http://www.idpf.org/2007/opf">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
        <dc:title>Mushoku Tensei: Jobless Reincarnation Vol. 1</dc:title>
        <dc:creator opf:role="aut">Rifujin na Magonote</dc:creator>
        <dc:language>en</dc:language>
        <meta name="cover" content="cover-img" />
      </metadata>
      <manifest>
        <item id="cover-img" href="Images/CoverDesign.jpg" media-type="image/jpeg"/>
        <item id="css" href="Styles/main.css" media-type="text/css"/>
        <item id="CoverPage_html" href="Text/CoverPage.html" media-type="application/xhtml+xml"/>
        <item id="s1" href="Text/section-0001.html" media-type="application/xhtml+xml"/>
        <item id="s2" href="Text/section-0002.html" media-type="application/xhtml+xml"/>
        <item id="ads" href="Text/ads.html" media-type="application/xhtml+xml"/>
      </manifest>
      <spine toc="ncx">
        <itemref idref="CoverPage_html"/>
        <itemref idref="s1"/>
        <itemref idref="s2"/>
        <itemref idref="ads" linear="no"/>
      </spine>
    </package>
    """

    private func parsed() -> EPUBPackage {
        EPUBParser.parsePackage(Data(opf.utf8), opfPath: "OEBPS/content.opf")
    }

    func testContainerPointsAtThePackage() throws {
        XCTAssertEqual(try EPUBParser.parseContainer(Data(container.utf8)), "OEBPS/content.opf")
    }

    func testMissingRootfileThrows() {
        let bad = "<?xml version=\"1.0\"?><container><rootfiles/></container>"
        XCTAssertThrowsError(try EPUBParser.parseContainer(Data(bad.utf8)))
    }

    func testMetadataComesThroughNamespaced() {
        let package = parsed()
        XCTAssertEqual(package.title, "Mushoku Tensei: Jobless Reincarnation Vol. 1")
        XCTAssertEqual(package.creator, "Rifujin na Magonote")
        XCTAssertEqual(package.language, "en")
    }

    /// Spine ids have to be resolved through the manifest, and the resulting paths are
    /// relative to the OPF's own directory, not the zip root.
    func testSpineResolvesToPathsInsideTheZip() {
        XCTAssertEqual(parsed().spine.map(\.path), [
            "OEBPS/Text/CoverPage.html",
            "OEBPS/Text/section-0001.html",
            "OEBPS/Text/section-0002.html",
        ])
    }

    /// linear="no" is how a book marks ads and colophons as not part of the read.
    func testNonLinearItemsAreLeftOut() {
        XCTAssertFalse(parsed().spine.contains { $0.path.hasSuffix("ads.html") })
    }

    /// Stylesheets and images are in the manifest but are not chapters.
    func testOnlyDocumentsAreInTheSpine() {
        XCTAssertFalse(parsed().spine.contains { $0.path.hasSuffix(".css") })
        XCTAssertEqual(parsed().spine.count, 3)
    }

    func testCoverFoundViaTheEPUB2MetaTag() {
        XCTAssertEqual(parsed().coverPath, "OEBPS/Images/CoverDesign.jpg")
    }

    func testCoverFoundViaTheEPUB3Property() {
        let epub3 = """
        <package version="3.0" xmlns="http://www.idpf.org/2007/opf">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>X</dc:title></metadata>
          <manifest>
            <item id="c" href="img/cover.png" media-type="image/png" properties="cover-image"/>
            <item id="a" href="a.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="a"/></spine>
        </package>
        """
        let package = EPUBParser.parsePackage(Data(epub3.utf8), opfPath: "content.opf")
        XCTAssertEqual(package.coverPath, "img/cover.png")
        XCTAssertEqual(package.spine.first?.path, "a.xhtml")
    }

    // MARK: Path resolution

    func testRelativePathsResolveAgainstTheOPFDirectory() {
        XCTAssertEqual(EPUBParser.resolve("Text/a.html", against: "OEBPS"), "OEBPS/Text/a.html")
        XCTAssertEqual(EPUBParser.resolve("a.html", against: ""), "a.html")
    }

    func testParentTraversalCollapses() {
        XCTAssertEqual(EPUBParser.resolve("../Images/x.jpg", against: "OEBPS/Text"), "OEBPS/Images/x.jpg")
        XCTAssertEqual(EPUBParser.resolve("./a.html", against: "OEBPS"), "OEBPS/a.html")
    }

    /// Hrefs are URL-escaped; zip entry names are not.
    func testPercentEncodingIsUndone() {
        XCTAssertEqual(EPUBParser.resolve("Text/Chapter%201.html", against: "OEBPS"), "OEBPS/Chapter 1.html".replacingOccurrences(of: "OEBPS/", with: "OEBPS/Text/"))
    }

    /// A link into the middle of a document must still resolve to the document.
    func testFragmentsAreStripped() {
        XCTAssertEqual(EPUBParser.resolve("Text/a.html#part2", against: "OEBPS"), "OEBPS/Text/a.html")
    }

    // MARK: Scheme handler URLs

    func testSchemeURLRoundTrips() throws {
        let path = "OEBPS/Text/section-0005.html"
        let url = try XCTUnwrap(EPUBSchemeHandler.url(for: path))
        XCTAssertEqual(url.scheme, EPUBSchemeHandler.scheme)
        XCTAssertEqual(EPUBSchemeHandler.path(from: url), path)
    }

    func testSchemeURLHandlesSpaces() throws {
        let path = "OEBPS/Text/Chapter 1.html"
        let url = try XCTUnwrap(EPUBSchemeHandler.url(for: path))
        XCTAssertEqual(EPUBSchemeHandler.path(from: url), path)
    }
}

/// A novel's position is a chapter plus how far down it, and the overall percentage has to
/// weight chapters by length or a long chapter 2 reads as "5% done" for an hour.
final class NovelProgressTests: XCTestCase {
    func testChapterFractionIsStoredAndRestored() throws {
        var progress = ReadingProgress(page: 3, pageCount: 21)
        progress.fractionInChapter = 0.42
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let round = try decoder.decode(ReadingProgress.self, from: encoder.encode(progress))
        XCTAssertEqual(round.page, 3)
        XCTAssertEqual(round.fractionInChapter, 0.42, accuracy: 0.0001)
    }

    /// Files written before novels existed must still decode.
    func testOlderProgressHasNoChapterFraction() throws {
        let json = Data(#"{"page":2,"pageCount":10}"#.utf8)
        let progress = try JSONDecoder().decode(ReadingProgress.self, from: json)
        XCTAssertEqual(progress.fractionInChapter, 0)
    }

    func testNovelLabelCountsChapters() {
        XCTAssertEqual(ReadingProgress(page: 5, pageCount: 21).novelLabel, "Chapter 6 of 21")
        XCTAssertEqual(ReadingProgress(page: 20, pageCount: 21, finished: true).novelLabel, "Finished")
    }
}

/// Manga and light novels of the same series must not share a shelf.
final class MediumSeparationTests: XCTestCase {
    private func make(_ title: String, kind: Comic.Kind) -> Comic {
        Comic(id: "\(kind.rawValue)-\(title)", sourceID: UUID(), relativePath: "\(title).x", kind: kind,
              title: title, series: "Mushoku Tensei", volume: 1, chapter: nil, author: nil,
              year: nil, subtitle: nil, pageCount: nil, totalBytes: 1, addedAt: Date(), coverID: nil)
    }

    func testSameSeriesInTwoMediaGivesTwoShelves() {
        let shelves = SeriesGrouper.group([make("manga v1", kind: .archive), make("novel v1", kind: .epub)])
        XCTAssertEqual(shelves.count, 2)
        XCTAssertEqual(shelves.count { $0.isNovel }, 1)
        XCTAssertEqual(shelves.count { !$0.isNovel }, 1)
    }

    func testVolumesOfOneMediumStillMerge() {
        var second = make("novel v2", kind: .epub)
        second.volume = 2
        let shelves = SeriesGrouper.group([make("novel v1", kind: .epub), second])
        XCTAssertEqual(shelves.count, 1)
        XCTAssertTrue(shelves[0].isNovel)
    }
}

/// Stats are derived, not tracked, so the derivation is the thing that can be wrong.
final class ReadingStatsTests: XCTestCase {
    private func item(_ series: String, finished: Bool = false, page: Int = 0, pages: Int = 100,
                      novel: Bool = false, remote: Bool = false, bytes: Int64 = 1000,
                      updated: Date = Date()) -> ReadingStats.Item {
        var progress: ReadingProgress?
        if finished || page > 0 {
            progress = ReadingProgress(page: finished ? pages - 1 : page, pageCount: pages,
                                       updatedAt: updated, finished: finished)
        }
        return ReadingStats.Item(seriesKey: (novel ? "novel|" : "comic|") + series, seriesName: series,
                                 isNovel: novel, format: novel ? "EPUB" : "CBZ", bytes: bytes,
                                 isRemote: remote, pageCount: pages, progress: progress)
    }

    func testEmptyLibrary() {
        let stats = ReadingStats.build([])
        XCTAssertTrue(stats.isEmpty)
        XCTAssertFalse(stats.hasReadAnything)
    }

    func testCountsSplitThreeWays() {
        let stats = ReadingStats.build([
            item("A", finished: true), item("A", page: 30), item("A"),
        ])
        XCTAssertEqual(stats.finishedVolumes, 1)
        XCTAssertEqual(stats.inProgressVolumes, 1)
        XCTAssertEqual(stats.unreadVolumes, 1)
        XCTAssertEqual(stats.totalVolumes, 3)
    }

    /// A finished book counts all its pages; an open one counts only as far as you've read.
    func testPagesRead() {
        let stats = ReadingStats.build([
            item("A", finished: true, pages: 100),
            item("B", page: 30, pages: 200),
            item("C"),
        ])
        XCTAssertEqual(stats.pagesRead, 130)
    }

    func testSeriesCompletionNeedsEveryVolume() {
        let done = ReadingStats.build([item("A", finished: true), item("A", finished: true)])
        XCTAssertEqual(done.finishedSeries, 1)
        XCTAssertEqual(done.startedSeries, 0)

        let partial = ReadingStats.build([item("A", finished: true), item("A")])
        XCTAssertEqual(partial.finishedSeries, 0)
        XCTAssertEqual(partial.startedSeries, 1)
    }

    /// Manga and novels of the same name are different series here too.
    func testMediaAreCountedSeparately() {
        let stats = ReadingStats.build([item("Mushoku Tensei"), item("Mushoku Tensei", novel: true)])
        XCTAssertEqual(stats.totalSeries, 2)
        XCTAssertEqual(Set(stats.byMedium.map(\.name)), ["Manga", "Novels"])
    }

    func testStorageSplitsLocalAndRemote() {
        let stats = ReadingStats.build([
            item("A", remote: true, bytes: 300),
            item("B", remote: false, bytes: 200),
        ])
        XCTAssertEqual(stats.remoteBytes, 300)
        XCTAssertEqual(stats.localBytes, 200)
        XCTAssertEqual(stats.totalBytes, 500)
    }

    /// Twelve buckets, zero-filled — a gap in a bar chart reads as missing data, not a quiet month.
    func testTwelveMonthsAlwaysPresent() {
        let stats = ReadingStats.build([item("A", finished: true)])
        XCTAssertEqual(stats.months.count, 12)
        XCTAssertEqual(stats.months.last?.finished, 1, "a book finished now lands in the last bucket")
        XCTAssertEqual(stats.months.dropLast().reduce(0) { $0 + $1.finished }, 0)
    }

    func testOldFinishesFallOutOfTheChartButStillCount() throws {
        let calendar = Calendar(identifier: .gregorian)
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 20)))
        let longAgo = try XCTUnwrap(calendar.date(from: DateComponents(year: 2020, month: 1, day: 5)))
        let stats = ReadingStats.build([item("A", finished: true, updated: longAgo)], now: now, calendar: calendar)
        XCTAssertEqual(stats.finishedVolumes, 1)
        XCTAssertEqual(stats.months.reduce(0) { $0 + $1.finished }, 0)
        XCTAssertEqual(stats.thisYear, 0)
        XCTAssertNil(stats.bestMonth)
    }

    func testTopSeriesOnlyListsWhatYouFinished() {
        let stats = ReadingStats.build([
            item("A", finished: true), item("A", finished: true),
            item("B", finished: true),
            item("C"),
        ])
        XCTAssertEqual(stats.topSeries.map(\.name), ["A", "B"])
        XCTAssertEqual(stats.topSeries.first?.count, 2)
    }
}

/// Panning a zoomed page. The two axes genuinely want different answers — sideways reads like
/// a pager, up-and-down like scrolling a document — so the signs are independent, and getting
/// one of them backwards is exactly the bug this guards.
final class PanAxesTests: XCTestCase {
    func testRetainedZoomKeepsRelativePositionAcrossViewportsAndClampsEdges() {
        let zoom = PageZoom(scale: 2, x: 0.25, y: -0.4)
        XCTAssertEqual(zoom.offset(in: CGSize(width: 400, height: 800)), CGSize(width: 100, height: -320))
        XCTAssertEqual(zoom.offset(in: CGSize(width: 800, height: 400)), CGSize(width: 200, height: -160))
        XCTAssertEqual(PageZoom(scale: 1, x: 1, y: 1).offset(in: CGSize(width: 400, height: 800)), .zero)
        XCTAssertEqual(PageZoom(scale: 2, x: 9, y: -9).offset(in: CGSize(width: 400, height: 800)), CGSize(width: 200, height: -400))
    }

    private let committed = CGSize(width: 10, height: 20)

    func testMovesViewGoesAgainstTheFinger() {
        let axes = PanAxes(horizontal: .movesView, vertical: .movesView)
        let offset = axes.offset(from: .zero, translation: CGSize(width: 30, height: 40))
        XCTAssertEqual(offset.width, -30)
        XCTAssertEqual(offset.height, -40)
    }

    func testMovesPageFollowsTheFinger() {
        let axes = PanAxes(horizontal: .movesPage, vertical: .movesPage)
        let offset = axes.offset(from: .zero, translation: CGSize(width: 30, height: 40))
        XCTAssertEqual(offset.width, 30)
        XCTAssertEqual(offset.height, 40)
    }

    /// The whole reason this is two settings: one axis inverted, the other not.
    func testAxesAreIndependent() {
        let axes = PanAxes(horizontal: .movesView, vertical: .movesPage)
        let offset = axes.offset(from: .zero, translation: CGSize(width: 30, height: 40))
        XCTAssertEqual(offset.width, -30, "sideways moves the view")
        XCTAssertEqual(offset.height, 40, "up and down moves the page")
    }

    func testTheDefaultIsSidewaysViewDownwardsPage() {
        XCTAssertEqual(PanAxes.standard.horizontal, .movesView)
        XCTAssertEqual(PanAxes.standard.vertical, .movesPage)
    }

    /// Dragging continues from wherever the last drag left off.
    func testOffsetAccumulates() {
        let offset = PanAxes.standard.offset(from: committed, translation: CGSize(width: 5, height: 5))
        XCTAssertEqual(offset.width, 10 - 5)
        XCTAssertEqual(offset.height, 20 + 5)
    }

    func testNoTranslationLeavesTheOffsetAlone() {
        let offset = PanAxes.standard.offset(from: committed, translation: .zero)
        XCTAssertEqual(offset, committed)
    }
}
