import XCTest
@testable import Mango

/// The filename is the metadata, so these are the cases that decide whether the shelf looks
/// right. Every pattern here is one that shows up in a real library.
final class NameParserTests: XCTestCase {
    private func parse(_ name: String, folder: String? = nil) -> ParsedName {
        NameParser.parse(fileName: name, folderName: folder)
    }

    func testDigitalReleaseWithVolumeAndYear() {
        let result = parse("Berserk v01 (2003) (Digital) (LuCaZ).cbz")
        XCTAssertEqual(result.series, "Berserk")
        XCTAssertEqual(result.volume, 1)
        XCTAssertEqual(result.year, 2003)
        XCTAssertNil(result.chapter)
    }

    func testScanlationChapterWithVolumeInParens() {
        let result = parse("[Group] Oyasumi Punpun - c001 (v01) [Pub].cbz")
        XCTAssertEqual(result.series, "Oyasumi Punpun")
        XCTAssertEqual(result.volume, 1)
        XCTAssertEqual(result.chapter, 1)
    }

    func testSpelledOutVolume() {
        let result = parse("Attack on Titan - Volume 34 [End].cbz")
        XCTAssertEqual(result.series, "Attack on Titan")
        XCTAssertEqual(result.volume, 34)
    }

    func testAbbreviatedVolumeAndChapter() {
        let result = parse("Chainsaw Man - Vol. 1 Ch. 4.cbz")
        XCTAssertEqual(result.series, "Chainsaw Man")
        XCTAssertEqual(result.volume, 1)
        XCTAssertEqual(result.chapter, 4)
    }

    func testHalfChapter() {
        let result = parse("Vinland Saga - c012.5.cbz")
        XCTAssertEqual(result.series, "Vinland Saga")
        XCTAssertEqual(result.chapter, 12.5)
    }

    func testIssueNumberBecomesVolume() {
        let result = parse("Saga #045 (2018).cbz")
        XCTAssertEqual(result.series, "Saga")
        XCTAssertEqual(result.volume, 45)
        XCTAssertEqual(result.year, 2018)
    }

    func testBareTrailingNumberIsAVolume() {
        let result = parse("Akira 001.cbz")
        XCTAssertEqual(result.series, "Akira")
        XCTAssertEqual(result.volume, 1)
    }

    /// "Blade Runner 2049" must not lose its year to the bare-number rule.
    func testTrailingYearIsNotAVolume() {
        let result = parse("Blade Runner 2049.cbz")
        XCTAssertEqual(result.series, "Blade Runner 2049")
        XCTAssertNil(result.volume)
    }

    func testUnderscoresBecomeSpaces() {
        let result = parse("One_Punch_Man_v12.cbz")
        XCTAssertEqual(result.series, "One Punch Man")
        XCTAssertEqual(result.volume, 12)
    }

    /// A series whose name starts with a letter the volume regex cares about.
    func testSeriesStartingWithVIsNotAVolumeMarker() {
        let result = parse("V for Vendetta.cbz")
        XCTAssertEqual(result.series, "V for Vendetta")
        XCTAssertNil(result.volume)
    }

    func testFolderSuppliesSeriesWhenFilenameIsJustANumber() {
        let result = parse("v03.cbz", folder: "Vagabond")
        XCTAssertEqual(result.series, "Vagabond")
        XCTAssertEqual(result.volume, 3)
    }

    /// A fuller folder name wins over a truncated one in the file.
    func testLongerFolderNameWins() {
        let result = parse("Vinland v02.cbz", folder: "Vinland Saga")
        XCTAssertEqual(result.series, "Vinland Saga")
        XCTAssertEqual(result.volume, 2)
    }

    /// But a file that says more than the folder keeps its own name.
    func testFileNameSurvivesAGenericFolder() {
        let result = parse("Monster v05.cbz", folder: "Manga")
        XCTAssertEqual(result.series, "Monster")
        XCTAssertEqual(result.volume, 5)
    }

    func testStandaloneHasNoNumbers() {
        let result = parse("Nausicaa of the Valley of the Wind.cbz")
        XCTAssertEqual(result.series, "Nausicaa of the Valley of the Wind")
        XCTAssertNil(result.volume)
        XCTAssertNil(result.chapter)
    }

    func testTitleIsHumanReadable() {
        XCTAssertEqual(parse("Berserk v01 (2003).cbz").title, "Berserk Vol. 1")
        XCTAssertEqual(parse("Vinland Saga - c012.5.cbz").title, "Vinland Saga Ch. 12.5")
        XCTAssertEqual(parse("Akira.cbz").title, "Akira")
    }

    func testPDFAndFolderNamesParseTheSameWay() {
        XCTAssertEqual(parse("Lone Wolf and Cub v07.pdf").volume, 7)
        XCTAssertEqual(parse("Lone Wolf and Cub v07").volume, 7)
    }
}

/// Cases taken verbatim from a real folder on the NAS: Tower Dungeon ships bound volumes and
/// loose chapters side by side, from several scanlators, with inconsistent numbering.
final class RealFolderNameParserTests: XCTestCase {
    private let folder = "Tower Dungeon (Digital)"

    private let files = [
        "Tower Dungeon v01 (2025) (Digital) (lft-DCP).cbz",
        "Tower Dungeon v02 (2025) (Digital) (lft-DCP).cbz",
        "Tower Dungeon v03 (2025) (Digital) (Kaos + lfp-DCP).cbz",
        "Tower Dungeon v04 (2026) (Digital) (Rillant).cbz",
        "Tower Dungeon v05 (2026) (Digital) (Rillant) (f).cbz",
        "Tower Dungeon c020 (2025) (Digital) (Aquila).cbz",
        "Tower Dungeon c021 (2025) (Digital) (Aquila).cbz",
        "Tower Dungeon c022 (2025) (Digital) (Aquila).cbz",
        "Tower Dungeon c023 (2026) (Digital) (Aquila).cbz",
        "Tower Dungeon c024 (2026) (Digital) (Rillant).cbz",
        "Tower Dungeon c025 (2026) (Digital) (Aquila).cbz",
        "Tower Dungeon c026 (2026) (Digital) (Aleph).cbz",
        "Tower Dungeon 027 (2026) (Digital) (Aleph).cbz",
        "Tower Dungeon 028 (2026) (Digital) (Aleph).cbz",
    ]

    private func parsed() -> [ParsedName] {
        NameParser.parseGroup(files.map { ($0, folder) })
    }

    /// "(Digital)" in the folder name must not end up in the shelf name.
    func testFolderReleaseTagIsStripped() {
        XCTAssertEqual(Set(parsed().compactMap(\.series)), ["Tower Dungeon"])
    }

    func testVolumesAndChaptersAreToldApart() {
        let results = parsed()
        XCTAssertEqual(results[0...4].compactMap(\.volume), [1, 2, 3, 4, 5])
        XCTAssertTrue(results[0...4].allSatisfy { $0.chapter == nil })
        XCTAssertEqual(results[5...11].compactMap(\.chapter), [20, 21, 22, 23, 24, 25, 26])
    }

    /// The point of `parseGroup`: a bare "027" alongside v01–v05 and c020–c026 is chapter 27,
    /// not volume 27. Parsed on its own it would be a volume.
    func testBareNumbersBecomeChaptersNextToRealVolumes() {
        let results = parsed()
        XCTAssertEqual(results[12].chapter, 27)
        XCTAssertNil(results[12].volume)
        XCTAssertEqual(results[13].chapter, 28)
        XCTAssertNil(results[13].volume)
        XCTAssertEqual(results[12].title, "Tower Dungeon Ch. 27")
    }

    func testParsedAloneABareNumberIsStillAVolume() {
        let alone = NameParser.parse(fileName: "Tower Dungeon 027 (2026) (Digital) (Aleph).cbz", folderName: folder)
        XCTAssertEqual(alone.volume, 27)
        XCTAssertTrue(alone.volumeIsInferred)
    }

    /// Without explicit chapters in the folder, a bare number stays a volume — a run of
    /// "Akira 001..006" must not be reinterpreted.
    func testBareNumbersStayVolumesWithoutChapterEvidence() {
        let names = (1...6).map { (String(format: "Akira %03d.cbz", $0), "Akira") }
        let results = NameParser.parseGroup(names)
        XCTAssertEqual(results.compactMap(\.volume), [1, 2, 3, 4, 5, 6])
        XCTAssertTrue(results.allSatisfy { $0.chapter == nil })
    }

    func testTrailingQualityTagIsIgnored() {
        let five = parsed()[4]
        XCTAssertEqual(five.volume, 5)
        XCTAssertEqual(five.series, "Tower Dungeon")
    }

    func testYearsComeThrough() {
        XCTAssertEqual(parsed()[0].year, 2025)
        XCTAssertEqual(parsed()[4].year, 2026)
    }

    /// Everything lands on one shelf, volumes first then chapters.
    func testTheWholeFolderIsOneSeries() {
        let source = UUID()
        let comics = zip(files, parsed()).map { file, name in
            Comic(id: Comic.makeID(sourceID: source, relativePath: file), sourceID: source,
                  relativePath: file, kind: .archive, title: name.title, series: name.series,
                  volume: name.volume, chapter: name.chapter, author: nil, year: name.year,
                  pageCount: nil, totalBytes: 1, addedAt: Date(), coverID: nil)
        }
        let shelves = SeriesGrouper.group(comics)
        XCTAssertEqual(shelves.count, 1)
        XCTAssertEqual(shelves[0].name, "Tower Dungeon")
        XCTAssertEqual(shelves[0].volumeCount, 14)
        XCTAssertEqual(shelves[0].comics.prefix(5).compactMap(\.volume), [1, 2, 3, 4, 5])
        XCTAssertEqual(shelves[0].comics.dropFirst(5).compactMap(\.chapter), Array(20...28).map(Double.init))
    }
}

/// "Series - c001 - Episode Title" is a real pattern (Pepper&Carrot ships exactly this), and
/// getting it wrong puts every chapter on its own shelf.
final class SeriesSubtitleParsingTests: XCTestCase {
    private func parse(_ name: String, folder: String? = nil) -> ParsedName {
        NameParser.parse(fileName: name, folderName: folder)
    }

    func testEpisodeTitleDoesNotBecomePartOfTheSeries() {
        let result = parse("Pepper and Carrot - c001 - Potion of Flight (Digital) (CC-BY).cbz")
        XCTAssertEqual(result.series, "Pepper and Carrot")
        XCTAssertEqual(result.chapter, 1)
        XCTAssertEqual(result.subtitle, "Potion of Flight")
    }

    func testEveryEpisodeLandsOnOneShelf() {
        let files = [
            "Pepper and Carrot - c001 - Potion of Flight (Digital) (CC-BY).cbz",
            "Pepper and Carrot - c002 - Rainbow potions (Digital) (CC-BY).cbz",
            "Pepper and Carrot - c010 - Summer Special (Digital) (CC-BY).cbz",
        ]
        let parsed = NameParser.parseGroup(files.map { ($0, "Pepper and Carrot") })
        XCTAssertEqual(Set(parsed.compactMap(\.series)), ["Pepper and Carrot"])
        XCTAssertEqual(parsed.compactMap(\.chapter), [1, 2, 10])
    }

    func testVolumeWithATitle() {
        let result = parse("Lone Wolf and Cub - v07 - Cloud Dragon Wind Tiger.cbz")
        XCTAssertEqual(result.series, "Lone Wolf and Cub")
        XCTAssertEqual(result.volume, 7)
        XCTAssertEqual(result.subtitle, "Cloud Dragon Wind Tiger")
    }

    /// A dash in the series name itself must survive when no number sits between the parts.
    func testDashInSeriesNameIsKept() {
        let result = parse("Mushoku Tensei - Jobless Reincarnation v03.cbz")
        XCTAssertEqual(result.series, "Mushoku Tensei - Jobless Reincarnation")
        XCTAssertEqual(result.volume, 3)
        XCTAssertNil(result.subtitle)
    }

    func testTrailingTagsAreNotASubtitle() {
        let result = parse("Berserk v01 (2003) (Digital) (LuCaZ).cbz")
        XCTAssertEqual(result.series, "Berserk")
        XCTAssertNil(result.subtitle)
    }

    func testVolumeAndChapterTogetherStillHaveNoSubtitle() {
        let result = parse("Chainsaw Man - Vol. 1 Ch. 4.cbz")
        XCTAssertEqual(result.series, "Chainsaw Man")
        XCTAssertEqual(result.volume, 1)
        XCTAssertEqual(result.chapter, 4)
        XCTAssertNil(result.subtitle)
    }

    func testBracketedGroupTagsStillStripped() {
        let result = parse("[Scans] Oyasumi Punpun - c001 (v01) [Pub].cbz")
        XCTAssertEqual(result.series, "Oyasumi Punpun")
        XCTAssertEqual(result.volume, 1)
        XCTAssertEqual(result.chapter, 1)
    }
}
