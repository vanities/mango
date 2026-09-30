import XCTest
import ShelfKit
@testable import Mango

/// A light novel's chapters by the book's own names. Mango used to number the documents of the
/// reading order, so the reader said "Chapter 23 of 26" on a page headed "Chapter 20".
final class NovelContentsTests: XCTestCase {
    // MARK: Finding the table of contents

    func testTheNCXIsFoundFromTheSpine() {
        let opf = """
        <package version="2.0" xmlns="http://www.idpf.org/2007/opf">
          <manifest>
            <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="a" href="Text/a.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine toc="ncx"><itemref idref="a"/></spine>
        </package>
        """
        let package = EPUBParser.parsePackage(Data(opf.utf8), opfPath: "OEBPS/content.opf")
        XCTAssertEqual(package.ncxPath, "OEBPS/toc.ncx")
        XCTAssertNil(package.navPath)
    }

    func testTheNCXIsFoundByTypeWhenTheSpineDoesntSay() {
        let opf = """
        <package version="2.0" xmlns="http://www.idpf.org/2007/opf">
          <manifest>
            <item id="contents" href="contents.ncx" media-type="application/x-dtbncx+xml"/>
            <item id="a" href="a.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="a"/></spine>
        </package>
        """
        XCTAssertEqual(EPUBParser.parsePackage(Data(opf.utf8), opfPath: "content.opf").ncxPath, "contents.ncx")
    }

    func testTheEPUB3NavigationDocumentIsFound() {
        let opf = """
        <package version="3.0" xmlns="http://www.idpf.org/2007/opf">
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="scripted nav"/>
            <item id="a" href="a.xhtml" media-type="application/xhtml+xml"/>
          </manifest>
          <spine><itemref idref="a"/></spine>
        </package>
        """
        XCTAssertEqual(EPUBParser.parsePackage(Data(opf.utf8), opfPath: "EPUB/package.opf").navPath, "EPUB/nav.xhtml")
    }

    // MARK: Reading it

    /// Shaped like the Seven Seas NCX: parts holding chapters, a page list, labels with line breaks.
    func testNCXPointsAreReadInOrderWithNestedPointsFlattened() {
        let ncx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
          <docTitle><text>Redundant Reincarnation Vol. 1</text></docTitle>
          <navMap>
            <navPoint id="p1" playOrder="1">
              <navLabel><text>Color Gallery</text></navLabel>
              <content src="Text/section-0002.html"/>
            </navPoint>
            <navPoint id="p2" playOrder="2">
              <navLabel><text>Norn’s
                Wedding</text></navLabel>
              <content src="Text/section-0007.html"/>
              <navPoint id="p3" playOrder="3">
                <navLabel><text>Chapter 1: Norn’s Betrothal (Part 1)</text></navLabel>
                <content src="Text/section-0008.html#ch1"/>
              </navPoint>
            </navPoint>
            <navPoint id="p4" playOrder="4">
              <navLabel><text></text></navLabel>
              <content src="Text/section-0010.html"/>
            </navPoint>
          </navMap>
          <pageList><pageTarget id="pg1" type="normal" value="1">
            <navLabel><text>1</text></navLabel><content src="Text/section-0008.html#page1"/>
          </pageTarget></pageList>
        </ncx>
        """
        let entries = EPUBParser.parseNCX(Data(ncx.utf8), ncxPath: "OEBPS/toc.ncx")
        XCTAssertEqual(entries, [
            EPUBTOCEntry(title: "Color Gallery", path: "OEBPS/Text/section-0002.html"),
            EPUBTOCEntry(title: "Norn’s Wedding", path: "OEBPS/Text/section-0007.html"),
            EPUBTOCEntry(title: "Chapter 1: Norn’s Betrothal (Part 1)", path: "OEBPS/Text/section-0008.html"),
        ], "Nameless points and the page list are not chapters")
    }

    /// EPUB 3: the nav marked as the table of contents, not the landmarks beside it — and HTML
    /// entities, which XMLParser can't read without the DTD, don't cut the list short.
    func testNavReadsTheTableOfContentsThroughHTMLEntities() {
        let nav = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
        <body>
          <nav epub:type="landmarks"><ol><li><a epub:type="cover" href="Text/cover.xhtml">Cover</a></li></ol></nav>
          <nav epub:type="toc" id="toc"><h1>Contents</h1>
            <ol>
              <li><a href="Text/wake1.xhtml">Wake&nbsp;One: The <span>Dormire</span> Crew</a>
                <ol><li><a href="Text/ch1.xhtml#start">This Is Not a Pipe</a></li></ol></li>
              <li><a href="Text/ch2.xhtml">Joanna&rsquo;s Story &amp; More</a></li>
              <li><span>Unlinked heading</span></li>
            </ol>
          </nav>
        </body>
        </html>
        """
        let entries = EPUBParser.parseNav(Data(nav.utf8), navPath: "EPUB/nav.xhtml")
        XCTAssertEqual(entries.map(\.title), ["Wake One: The Dormire Crew", "This Is Not a Pipe", "Joanna’s Story & More"])
        XCTAssertEqual(entries.map(\.path), ["EPUB/Text/wake1.xhtml", "EPUB/Text/ch1.xhtml", "EPUB/Text/ch2.xhtml"])
    }

    func testANavThatDoesntSayWhichItIsFallsBackToTheFirst() {
        let nav = """
        <html xmlns="http://www.w3.org/1999/xhtml"><body>
          <nav><ol><li><a href="one.xhtml">One</a></li><li><a href="two.xhtml">Two</a></li></ol></nav>
          <nav><ol><li><a href="index.xhtml">Index</a></li></ol></nav>
        </body></html>
        """
        XCTAssertEqual(EPUBParser.parseNav(Data(nav.utf8), navPath: "nav.xhtml").map(\.title), ["One", "Two"])
    }

    func testTheFirstEntryIntoADocumentNamesIt() {
        let spine = ["a", "b", "c"].map { EPUBSpineItem(id: $0, path: "Text/\($0).xhtml", mediaType: "application/xhtml+xml") }
        let toc = [
            EPUBTOCEntry(title: "Part One", path: "Text/a.xhtml"),
            EPUBTOCEntry(title: "Chapter 1", path: "Text/a.xhtml"),
            EPUBTOCEntry(title: "Notes", path: "Text/notes.xhtml"),
            EPUBTOCEntry(title: "Chapter 2", path: "Text/c.xhtml"),
        ]
        XCTAssertEqual(EPUBParser.chapterTitles(spine: spine, toc: toc), ["Part One", nil, "Chapter 2"])
    }

    // MARK: Naming places in the book

    /// Redo of Healer v1: a cover the contents skip, then every chapter named, and a bonus
    /// illustration page after the epilogue that it skips too.
    private let redoOfHealer: [String?] = [nil, "Illustrations", "Prologue"] + (1...20).map { "Chapter \($0)" }
        + ["Epilogue", nil, "Bonus Textless Illustrations"]

    func testChaptersGoByTheBooksNames() {
        let contents = NovelContents(titles: redoOfHealer)
        XCTAssertTrue(contents.isNamed)
        XCTAssertEqual(contents.name(of: 22), "Chapter 20", "The 23rd document is the book's chapter 20")
        XCTAssertEqual(contents.entries.first, NovelContents.Entry(index: 0, title: "Beginning"))
        XCTAssertEqual(contents.entries.map(\.title).suffix(3), ["Chapter 20", "Epilogue", "Bonus Textless Illustrations"])
        XCTAssertEqual(contents.entries.count, 25, "Every named document, plus the beginning")
    }

    /// Seven Seas books leave about half their documents unnamed: split chapters and pictures.
    func testUnnamedDocumentsContinueTheChapterBeforeThem() {
        let contents = NovelContents(titles: [nil, "Table of Contents", "Color Gallery", nil, nil, "Chapter 1", nil, "Chapter 2"])
        XCTAssertEqual(contents.name(of: 0), "Beginning")
        XCTAssertEqual(contents.name(of: 4), "Color Gallery")
        XCTAssertEqual(contents.name(of: 6), "Chapter 1")
        XCTAssertEqual(contents.entry(containing: 6), NovelContents.Entry(index: 5, title: "Chapter 1"))
        XCTAssertEqual(contents.entries.map(\.index), [0, 1, 2, 5, 7])
    }

    /// v8 names its chapter 10 "Chapter 9" as well. Merging the two would hide a chapter.
    func testARepeatedNameIsStillItsOwnEntry() {
        let contents = NovelContents(titles: ["Chapter 8", "Chapter 9", "Chapter 9", "Chapter 11"])
        XCTAssertEqual(contents.entries.map(\.index), [0, 1, 2, 3])
    }

    /// A scan whose only entry is its "scan notes" would otherwise name the whole book after it.
    func testABookThatNamesFewerThanTwoDocumentsKeepsNumbers() {
        for titles: [String?] in [[nil, nil, "eVersion 3.0 - click for scan notes", nil], [nil, nil, nil], []] {
            let contents = NovelContents(titles: titles)
            XCTAssertFalse(contents.isNamed)
            XCTAssertEqual(contents.entries.map(\.title), titles.indices.map { "Chapter \($0 + 1)" })
            if !titles.isEmpty { XCTAssertEqual(contents.name(of: 2), "Chapter 3") }
        }
    }

    func testTheLibrarySaysWhereYouAreByName() {
        XCTAssertEqual(ReadingProgress(page: 22, pageCount: 26).novelLabel(titles: redoOfHealer), "Chapter 20")
        XCTAssertEqual(ReadingProgress(page: 22, pageCount: 26).novelLabel(titles: nil), "Chapter 23 of 26",
                       "A book not opened here since names were kept is still numbered")
        XCTAssertEqual(ReadingProgress(page: 22, pageCount: 26, finished: true).novelLabel(titles: redoOfHealer), "Finished")
        XCTAssertEqual(NovelContents.name(of: 24, titles: redoOfHealer), "Epilogue")
        XCTAssertNil(NovelContents.name(of: 1, titles: [nil, "Scan notes", nil]))
    }

    // MARK: Through the reader

    /// The reader's engine opens the book from disk, reads its contents, names the place, and
    /// keeps the names so the library can use them.
    @MainActor
    func testTheReaderNamesChaptersAndTheLibraryKeepsTheNames() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let chapters = ["cover", "illustrations", "ch1", "ch1-part2", "ch2"]
        let manifest = chapters.map { "<item id='\($0)' href='Text/\($0).xhtml' media-type='application/xhtml+xml'/>" }.joined()
        let spine = chapters.map { "<itemref idref='\($0)'/>" }.joined()
        let ncx = """
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap>
          <navPoint id="a"><navLabel><text>Illustrations</text></navLabel><content src="Text/illustrations.xhtml"/></navPoint>
          <navPoint id="b"><navLabel><text>Chapter 1</text></navLabel><content src="Text/ch1.xhtml"/></navPoint>
          <navPoint id="c"><navLabel><text>Chapter 2</text></navLabel><content src="Text/ch2.xhtml"/></navPoint>
        </navMap></ncx>
        """
        var files = [
            "META-INF/container.xml": "<container><rootfiles><rootfile full-path='OEBPS/content.opf'/></rootfiles></container>",
            "OEBPS/content.opf": "<package><manifest><item id='ncx' href='toc.ncx' media-type='application/x-dtbncx+xml'/>\(manifest)</manifest><spine toc='ncx'>\(spine)</spine></package>",
            "OEBPS/toc.ncx": ncx,
        ]
        for chapter in chapters { files["OEBPS/Text/\(chapter).xhtml"] = "<html><body><p>\(chapter)</p></body></html>" }
        let url = folder.appending(path: "Healer v01.epub")
        try ZipTestBuilder.make(files.map { .init(name: $0.key, data: Data($0.value.utf8), deflate: true) }).write(to: url)

        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let settings = AppSettings(defaults: defaults)
        let library = LibraryModel(store: LibraryStore(directory: folder.appending(path: "State")),
                                   covers: CoverStore(directory: folder.appending(path: "Covers"),
                                                      customDirectory: folder.appending(path: "Custom")),
                                   settings: settings)
        library.addOpenedFile(url)
        for _ in 0..<200 where library.requestedComic == nil || library.isScanning {
            try await Task.sleep(for: .milliseconds(10))
        }
        let comic = try XCTUnwrap(library.requestedComic)
        XCTAssertTrue(comic.isNovel)

        let engine = NovelEngine(comic: comic, library: library, settings: settings)
        await engine.open()
        defer { engine.close() }
        XCTAssertEqual(engine.contents.entries.map(\.title), ["Beginning", "Illustrations", "Chapter 1", "Chapter 2"])
        engine.goToChapter(3)
        XCTAssertTrue(engine.positionLabel.hasPrefix("Chapter 1 · "), "The second half of chapter 1 is still chapter 1: \(engine.positionLabel)")
        XCTAssertEqual(engine.contents.entry(containing: engine.chapterIndex)?.index, 2, "The list marks chapter 1 as where you are")

        XCTAssertEqual(library.chapterTitles(for: comic), [nil, "Illustrations", "Chapter 1", nil, "Chapter 2"])
        library.recordNovelProgress(chapter: 4, chapterCount: 5, fraction: 0.5, for: comic)
        let progress = try XCTUnwrap(library.progress(for: comic))
        XCTAssertEqual(library.novelPositionLabel(progress, in: comic), "Chapter 2")
    }
}
