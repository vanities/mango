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

    // MARK: A real NAS (2026-09-21)
    //
    // Every name below is from Adam's library. Before these, its 814 files made 104 shelves.

    /// "Volume 01 - Enter Josuke Higashikata": nothing before the number, so the filename has
    /// no series in it at all — the folder does. Taking the first words as the series gave every
    /// JoJo volume its own shelf, named after its episode title.
    func testANameThatStartsWithTheNumberTakesItsSeriesFromTheFolder() {
        let folder = "JoJo's Bizarre Adventure Part 4 - Diamond is Unbreakable Full Color"
        let result = parse("Volume 01 - Enter Josuke Higashikata.zip", folder: folder)
        XCTAssertEqual(result.series, folder)
        XCTAssertEqual(result.volume, 1)
        XCTAssertEqual(result.subtitle, "Enter Josuke Higashikata")

        let vento = parse("Volume 47 - The Golden Heart.zip", folder: "Part 5 - Vento Aureo (Black and White Scans)")
        XCTAssertEqual(vento.series, "Part 5 - Vento Aureo")
        XCTAssertEqual(vento.volume, 47)
        XCTAssertEqual(vento.subtitle, "The Golden Heart")
    }

    /// A webtoon published as bare-numbered chapters, some with an episode title after the
    /// number. "180 - Epilogue 01" used to become series "Solo Leveling 180 - Epilogue", Vol. 1.
    func testAWebtoonsBareNumbersAreChaptersAndKeepTheirTitles() {
        let folder = "Solo Leveling [Webtoon] (2020-2023) (Digital) (LuCaZ)"
        let names = [
            "Solo Leveling 000 - Prologue (2020) (Digital) (LuCaZ).cbz",
            "Solo Leveling 001 (2020) (Digital) (LuCaZ).cbz",
            "Solo Leveling 002 (2020) (Digital) (LuCaZ).cbz",
            "Solo Leveling 179 - Finale (2023) (Digital) (LuCaZ).cbz",
            "Solo Leveling 180 - Epilogue 01 (2023) (Digital) (LuCaZ).cbz",
        ]
        let results = NameParser.parseGroup(names.map { ($0, folder) })
        XCTAssertTrue(results.allSatisfy { $0.series == "Solo Leveling" }, "\(results.map(\.series))")
        XCTAssertEqual(results.map(\.chapter), [0, 1, 2, 179, 180])
        XCTAssertTrue(results.allSatisfy { $0.volume == nil })
        XCTAssertEqual(results.map(\.subtitle), ["Prologue", nil, nil, "Finale", "Epilogue 01"])
        XCTAssertEqual(results[1].title, "Solo Leveling Ch. 1")
    }

    /// Volumes as "v01" beside the chapters since the last volume as bare numbers — how 1r0n
    /// and LuCaZ ship ongoing series. A bare number far past the last volume is a chapter.
    func testBareNumbersFarPastTheLastVolumeAreChapters() {
        func group(_ names: [String], _ folder: String) -> [ParsedName] {
            NameParser.parseGroup(names.map { ($0, folder) })
        }
        let chainsaw = group(["Chainsaw Man v01 (2020) (Digital) (1r0n).cbz",
                              "Chainsaw Man v21 (2026) (Digital) (Rillant).cbz",
                              "Chainsaw Man 199 (2025) (Digital) (1r0n).cbz",
                              "Chainsaw Man 223 (2025) (Digital) (1r0n).cbz"], "Chainsaw Man (Digital)")
        XCTAssertEqual(chainsaw.map(\.volume), [1, 21, nil, nil])
        XCTAssertEqual(chainsaw.map(\.chapter), [nil, nil, 199, 223])

        let onePiece = group(["One Piece v001 (2003) (Digital) (1r0n).cbz",
                              "One Piece v111 (2026) (Digital) (1r0n).cbz",
                              "One Piece 1134 (2024) (Digital) (1r0n).cbz"], "One Piece (Digital) (1r0n)")
        XCTAssertEqual(onePiece.map(\.chapter), [nil, nil, 1134])

        let witch = group(["Witch Hat Atelier v14 (2026) (Digital) (LuCaZ).cbz",
                           "Witch Hat Atelier 082 (2024) (Digital) (LuCaZ).cbz"], "Witch Hat Atelier (Digital) (LuCaZ)")
        XCTAssertEqual(witch.map(\.chapter), [nil, 82])
    }

    /// Just past the last volume is still ambiguous — "Series 011" after v01–v10 is more likely
    /// a volume someone named inconsistently than chapter 11.
    func testABareNumberJustPastTheLastVolumeStaysAVolume() {
        let names = (1...10).map { (String(format: "Series v%02d.cbz", $0), "Series") } + [("Series 011.cbz", "Series")]
        let results = NameParser.parseGroup(names)
        XCTAssertEqual(results.last?.volume, 11)
        XCTAssertNil(results.last?.chapter)
    }

    func testVolumeAndChapterRangesDoNotLeaveASubtitle() {
        let homunculus = parse("Homunculus v01-02 (2023) (Digital) (LuCaZ).cbz", folder: "Homunculus (2023-2024) (Digital) (LuCaZ)")
        XCTAssertEqual(homunculus.volume, 1)
        XCTAssertNil(homunculus.subtitle)

        let tasogare = parse("Tasogare Otome x Amnesia - c00-02 (v01) [DBR-Scans, Meow Scans, Maigo].cbz",
                             folder: "Tasogare Otome x Amnesia")
        XCTAssertEqual(tasogare.series, "Tasogare Otome x Amnesia")
        XCTAssertNil(tasogare.chapter, "a range of chapters with a volume is that volume")
        XCTAssertEqual(tasogare.volume, 1)
        XCTAssertNil(tasogare.subtitle)
        XCTAssertEqual(tasogare.title, "Tasogare Otome x Amnesia Vol. 1")
    }

    func testQualityTagsAreNotSubtitles() {
        let result = parse("GTO Volume 01 HQ [E353B350].zip", folder: "GTO")
        XCTAssertEqual(result.series, "GTO")
        XCTAssertEqual(result.volume, 1)
        XCTAssertNil(result.subtitle)
    }

    /// Folders are what people keep tidy — including their capitals.
    func testTheFoldersSpellingWinsWhenTheNamesMatch() {
        let result = parse("[thetsuuyaku.blogspot.com]_the_voynich_hotel_vol01_(complete).zip", folder: "The Voynich Hotel")
        XCTAssertEqual(result.series, "The Voynich Hotel")
        XCTAssertEqual(result.volume, 1)
    }

    /// A side story named "<Series> - <Title>" in the series' own folder belongs on that shelf.
    func testASideStoryInTheSeriesFolderJoinsTheShelf() {
        let folder = "Mushoku Tensei - Jobless Reincarnation [Seven Seas] [LuCaZ]"
        let result = parse("Mushoku Tensei - Jobless Reincarnation - A Journey of Two Lifetimes [Seven Seas] [LuCaZ].epub",
                           folder: folder)
        XCTAssertEqual(result.series, "Mushoku Tensei - Jobless Reincarnation")
        XCTAssertEqual(result.subtitle, "A Journey of Two Lifetimes")
    }

    /// "Part 4 - Diamond is Unbreakable" is a part of a series, not volume 4 with a title.
    func testAPartNumberIsNotAVolume() {
        let result = parse("JoJo's Bizarre Adventure Part 4 - Diamond is Unbreakable.cbz")
        XCTAssertNil(result.volume)
        XCTAssertEqual(result.series, "JoJo's Bizarre Adventure Part 4 - Diamond is Unbreakable")
    }

    // MARK: The NAS after converting its RAR/7z (2026-09-21)

    /// "v01_ch03" is chapter 3 of volume 1 — a chapter. Three of them all titled "Vol. 1" is
    /// what the shelf showed. The volume is kept, for order.
    func testAChapterThatNamesItsVolumeIsAChapter() {
        let names = ["[Hidoi]_Onani_Master_Kurosawa_v01_ch03.cbz", "[Hidoi]_Onani_Master_Kurosawa_v01_ch04.cbz",
                     "[Hidoi]_Onani_Master_Kurosawa_v02_ch11.cbz", "[EE]-Onani Master Kurosawa 28.cbz",
                     "[EE]-Onani Master Kurosawa 30v2.cbz"]
        let results = NameParser.parseGroup(names.map { ($0, "Onani Master Kurosawa") })
        XCTAssertTrue(results.allSatisfy { $0.series == "Onani Master Kurosawa" }, "\(results.map(\.series))")
        XCTAssertEqual(results.map(\.chapter), [3, 4, 11, 28, 30])
        XCTAssertEqual(results[0].volume, 1)
        XCTAssertEqual(results[0].title, "Onani Master Kurosawa Ch. 3")
    }

    /// "30v2" and "- v2" are the release's second version, not numbers or titles.
    func testVersionSuffixesAreDropped() {
        let akira = parse("Akira - Volume 05 [B&W] [MangaReactor] - v2.cbz", folder: "Akira")
        XCTAssertEqual(akira.series, "Akira")
        XCTAssertEqual(akira.volume, 5)
        XCTAssertNil(akira.subtitle)
        XCTAssertEqual(parse("Tower Dungeon - c030v2.cbz").chapter, 30)
    }

    func testResolutionAndLanguageTagsAreNotTitles() {
        let yotsuba = parse("Yotsuba&!_v01[senfgurke2]4400h.cbz", folder: "Yotsuba&! [Scans]")
        XCTAssertEqual(yotsuba.series, "Yotsuba&!")
        XCTAssertEqual(yotsuba.volume, 1)
        XCTAssertNil(yotsuba.subtitle)
        let stone = parse("Stone Ocean Volume 01 English (Official color manga).cbz",
                          folder: "Stone Ocean English (Official color manga)")
        XCTAssertEqual(stone.series, "Stone Ocean", "the folder's language tag doesn't win either")
        XCTAssertEqual(stone.volume, 1)
        XCTAssertNil(stone.subtitle)
    }

    func testABareRangeIsOneNumber() {
        let manual = parse("GantZ_Manual_1-31.cbz", folder: "Part 1")
        XCTAssertEqual(manual.series, "GantZ Manual")
        XCTAssertEqual(manual.volume, 1)
    }
}

