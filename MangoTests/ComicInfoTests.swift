import XCTest
@testable import Mango

final class ComicInfoTests: XCTestCase {
    /// Verbatim from the one archive on the NAS that ships ComicInfo.xml (Mushoku Tensei v17).
    private let real = """
    <?xml version='1.0' encoding='utf-8'?>
    <ComicInfo xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns:xsd="http://www.w3.org/2001/XMLSchema">
        <Series>Mushoku Tensei: Jobless Reincarnation</Series>
        <Number />
        <Web>https://www.amazon.com/dp/B0C7SG2N1B</Web>
        <Summary>Sylphiette and Rudeus spent many long years apart, but fate has finally brought them back together, this time as lovers.</Summary>
        <Notes>Scraped metadata from Amazon [ASINB0C7SG2N1B], [RELDATE:2023-08-08]</Notes>
        <Publisher>Seven Seas</Publisher>
        <PageCount>174</PageCount>
        <LanguageISO>EN</LanguageISO>
        <Year>2023</Year>
        <Month>10</Month>
    </ComicInfo>
    """

    private func comic(series: String?, volume: Double? = nil, chapter: Double? = nil) -> Comic {
        Comic(id: "x", sourceID: UUID(), relativePath: "x.cbz", kind: .archive,
              title: series ?? "x", series: series, volume: volume, chapter: chapter, author: nil,
              year: nil, subtitle: nil, pageCount: nil, totalBytes: 1, addedAt: Date(), coverID: nil)
    }

    // MARK: Parsing

    func testParsesTheRealFile() throws {
        let info = try XCTUnwrap(ComicInfoParser.parse(Data(real.utf8)))
        XCTAssertEqual(info.series, "Mushoku Tensei: Jobless Reincarnation")
        XCTAssertEqual(info.year, 2023)
        XCTAssertEqual(info.pageCount, 174)
        XCTAssertEqual(info.languageISO, "EN")
        XCTAssertTrue(info.summary?.hasPrefix("Sylphiette and Rudeus") == true)
    }

    /// `<Number />` is empty in the real file; an empty tag must not become a value.
    func testEmptyElementsAreIgnored() throws {
        let info = try XCTUnwrap(ComicInfoParser.parse(Data(real.utf8)))
        XCTAssertNil(info.number)
        XCTAssertNil(info.volume)
        XCTAssertNil(info.manga)
    }

    func testMangaFlagSetsDirection() throws {
        let rtl = try XCTUnwrap(ComicInfoParser.parse(Data("<ComicInfo><Series>A</Series><Manga>YesAndRightToLeft</Manga></ComicInfo>".utf8)))
        XCTAssertEqual(rtl.manga?.direction, .rightToLeft)
        let western = try XCTUnwrap(ComicInfoParser.parse(Data("<ComicInfo><Series>A</Series><Manga>No</Manga></ComicInfo>".utf8)))
        XCTAssertEqual(western.manga?.direction, .leftToRight)
    }

    /// Plain "Yes" says it's manga but not which way it reads, so it mustn't pick a direction.
    func testPlainYesDoesNotChooseADirection() throws {
        let info = try XCTUnwrap(ComicInfoParser.parse(Data("<ComicInfo><Series>A</Series><Manga>Yes</Manga></ComicInfo>".utf8)))
        XCTAssertNil(info.manga?.direction)
    }

    func testEntitiesInSummariesDecode() throws {
        let xml = "<ComicInfo><Series>A</Series><Summary>Tom &amp; Jerry &lt;3</Summary></ComicInfo>"
        XCTAssertEqual(try XCTUnwrap(ComicInfoParser.parse(Data(xml.utf8))).summary, "Tom & Jerry <3")
    }

    /// The page list is nested elements with attributes — nothing to take from it.
    func testPageListIsIgnored() throws {
        let xml = "<ComicInfo><Series>A</Series><Pages><Page Image=\"0\" Type=\"FrontCover\"/></Pages></ComicInfo>"
        XCTAssertEqual(try XCTUnwrap(ComicInfoParser.parse(Data(xml.utf8))).series, "A")
    }

    func testAnEmptyDocumentIsNil() {
        XCTAssertNil(ComicInfoParser.parse(Data("<ComicInfo></ComicInfo>".utf8)))
        XCTAssertNil(ComicInfoParser.parse(Data("not xml".utf8)))
    }

    func testFilenameMatchIsCaseInsensitive() {
        XCTAssertTrue(ComicInfoParser.isComicInfo("ComicInfo.xml"))
        XCTAssertTrue(ComicInfoParser.isComicInfo("comicinfo.XML"))
        XCTAssertTrue(ComicInfoParser.isComicInfo("Some Folder/ComicInfo.xml"))
        XCTAssertFalse(ComicInfoParser.isComicInfo("ComicInfo.xml.bak"))
    }

    // MARK: Applying

    func testSeriesFromTheFileBeatsTheFilename() {
        let info = ComicInfo(series: "Mushoku Tensei: Jobless Reincarnation")
        let out = info.applied(to: comic(series: "Mushoku Tensei - Jobless Reincarnation", volume: 17))
        XCTAssertEqual(out.series, "Mushoku Tensei: Jobless Reincarnation")
        XCTAssertEqual(out.volume, 17, "the filename's volume survives when the file has none")
    }

    /// The real file names the series with a colon where the folder has a dash. They must
    /// still land on the same shelf, or v17 would split off from v1–v16.
    func testColonAndDashSpellingsStillShareAShelf() {
        let fromFile = ComicInfo(series: "Mushoku Tensei: Jobless Reincarnation").applied(
            to: comic(series: "Mushoku Tensei - Jobless Reincarnation", volume: 17))
        let fromName = comic(series: "Mushoku Tensei - Jobless Reincarnation", volume: 16)
        XCTAssertEqual(SeriesGrouper.key(for: fromFile), SeriesGrouper.key(for: fromName))
    }

    func testVolumeWriterYearAndSummaryApply() {
        let info = ComicInfo(series: "S", volume: 4, summary: "Blurb", writer: "Someone", year: 2021)
        let out = info.applied(to: comic(series: "S"))
        XCTAssertEqual(out.volume, 4)
        XCTAssertEqual(out.author, "Someone")
        XCTAssertEqual(out.year, 2021)
        XCTAssertEqual(out.summary, "Blurb")
        XCTAssertEqual(out.title, "S Vol. 4")
    }

    /// `<Number>` means issue in one tagger and volume in the next; the filename's chapter is
    /// the more reliable of the two, so it stays.
    func testNumberDoesNotOverrideTheFilenamesChapter() {
        let out = ComicInfo(series: "S", number: "99").applied(to: comic(series: "S", chapter: 12))
        XCTAssertEqual(out.chapter, 12)
    }

    /// Your own corrections always win over the file.
    func testUserOverridesStillBeatComicInfo() {
        let fromFile = ComicInfo(series: "From File", volume: 3).applied(to: comic(series: "Name"))
        let corrected = ComicOverride(series: "Mine").applied(to: fromFile)
        XCTAssertEqual(corrected.series, "Mine")
        XCTAssertEqual(corrected.volume, 3)
    }

    func testStoredComicInfoRoundTripsThroughTheLibraryFile() throws {
        var state = LibraryState()
        state.comicInfo["a"] = ComicInfo(series: "S", volume: 2, manga: .yesAndRightToLeft)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let round = try decoder.decode(LibraryState.self, from: encoder.encode(state))
        XCTAssertEqual(round.comicInfo["a"]?.manga, .yesAndRightToLeft)
        XCTAssertEqual(round.comicInfo["a"]?.volume, 2)
    }
}
