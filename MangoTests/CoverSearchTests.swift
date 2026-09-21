import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Mango

/// Find Cover and the picked-cover bookkeeping. The JSON below has the shape of real responses
/// from each API (fetched 2026-09-21), trimmed to what the parsers read.
final class CoverSearchTests: XCTestCase {
    // MARK: MangaDex

    private let mangaDexSearch = Data("""
    {"result":"ok","data":[
      {"id":"801513ba","attributes":{"title":{"ja-ro":"Berserk"},"altTitles":[{"ja":"ベルセルク"},{"en":"Berserk"}]},
       "relationships":[{"type":"author","id":"a1"},{"type":"cover_art","id":"c1","attributes":{"fileName":"main.jpg","volume":"43"}}]},
      {"id":"b00acc54","attributes":{"title":{"en":"VRMMO Chronicles of a Solo Cleric"},"altTitles":[]},"relationships":[]}
    ]}
    """.utf8)

    private let mangaDexCovers = Data("""
    {"result":"ok","data":[
      {"attributes":{"volume":"1","fileName":"v1-uk.jpg","locale":"uk"}},
      {"attributes":{"volume":"1","fileName":"v1-ja.jpg","locale":"ja"}},
      {"attributes":{"volume":"2","fileName":"v2-ja.jpg","locale":"ja"}},
      {"attributes":{"volume":"2","fileName":"v2-it.jpg","locale":"it"}},
      {"attributes":{"volume":"3","fileName":"v3-en.jpg","locale":"en"}},
      {"attributes":{"volume":null,"fileName":"extra.jpg","locale":"ja"}}
    ]}
    """.utf8)

    func testMangaDexSearchPrefersAnEnglishTitleAndKeepsTheMainCover() {
        let series = CoverSearch.mangaDexSeries(from: mangaDexSearch)
        XCTAssertEqual(series.count, 2)
        XCTAssertEqual(series[0].id, "801513ba")
        XCTAssertEqual(series[0].title, "Berserk")
        XCTAssertEqual(series[0].mainCoverFile, "main.jpg")
        XCTAssertEqual(series[0].mainCoverVolume, 43)
        XCTAssertEqual(Set(series[0].names), ["Berserk", "ベルセルク"])
        XCTAssertNil(series[1].mainCoverFile)
        let main = CoverSearch.mangaDexMainCover(series[0])
        XCTAssertEqual(main?.fullURL.absoluteString, "https://uploads.mangadex.org/covers/801513ba/main.jpg")
        XCTAssertEqual(main?.thumbnailURL.absoluteString, "https://uploads.mangadex.org/covers/801513ba/main.jpg.512.jpg")
        XCTAssertEqual(main?.isSeriesCover, true)
    }

    /// Every language of the wanted volume; only Japanese and English for the rest.
    func testMangaDexCoversKeepTheWantedVolumeInEveryLanguage() {
        let series = CoverSearch.MangaDexSeries(id: "m", title: "Berserk")
        let covers = CoverSearch.mangaDexCovers(from: mangaDexCovers, series: series, volume: 2)
        let files = covers.map(\.fullURL.lastPathComponent)
        XCTAssertEqual(Array(files.prefix(2)), ["v2-ja.jpg", "v2-it.jpg"], "the wanted volume first, all languages")
        XCTAssertFalse(files.contains("v1-uk.jpg"), "other volumes only in Japanese or English")
        XCTAssertTrue(files.contains("v1-ja.jpg"))
        XCTAssertEqual(covers.first?.language, "ja")
        XCTAssertEqual(covers.first?.title, "Berserk Vol. 2")
    }

    func testMangaDexNearbyVolumesAreCapped() {
        let many = (1...60).map { #"{"attributes":{"volume":"\#($0)","fileName":"v\#($0).jpg","locale":"ja"}}"# }
        let data = Data(#"{"data":[\#(many.joined(separator: ","))]}"#.utf8)
        let covers = CoverSearch.mangaDexCovers(from: data, series: .init(id: "m", title: "S"), volume: 30, nearby: 4)
        XCTAssertEqual(covers.count, 5, "the wanted volume and its four nearest")
        XCTAssertEqual(covers.first?.volume, 30)
        XCTAssertEqual(Set(covers.compactMap(\.volume)), [28, 29, 30, 31, 32])
    }

    // MARK: AniList

    private func aniList(format: String) -> Data {
        Data("""
        {"data":{"Page":{"media":[{"id":105398,"format":"\(format)","title":{"romaji":"Na Honjaman Level Up","english":"Solo Leveling"},
          "coverImage":{"extraLarge":"https://s4.anilist.co/xl.jpg","large":"https://s4.anilist.co/l.jpg"},"startDate":{"year":2018},
          "staff":{"edges":[{"role":"Art","node":{"name":{"full":"Seong-Rak Jang"}}},{"role":"Story (chs 1-92)","node":{"name":{"full":"So-Ryeong Gi"}}}]}}]}}}
        """.utf8)
    }

    func testAniListGivesASeriesCoverWithYearAndWriter() {
        let covers = CoverSearch.aniListCovers(from: aniList(format: "MANGA"), isNovel: false)
        XCTAssertEqual(covers.count, 1)
        XCTAssertEqual(covers[0].title, "Solo Leveling")
        XCTAssertEqual(covers[0].detail, "2018 · So-Ryeong Gi", "the story credit, not the artist")
        XCTAssertEqual(covers[0].fullURL.absoluteString, "https://s4.anilist.co/xl.jpg")
        XCTAssertTrue(covers[0].isSeriesCover)
    }

    /// AniList files light novels under MANGA; each shelf gets its own kind.
    func testAniListKeepsNovelsAndMangaApart() {
        XCTAssertTrue(CoverSearch.aniListCovers(from: aniList(format: "NOVEL"), isNovel: false).isEmpty)
        XCTAssertEqual(CoverSearch.aniListCovers(from: aniList(format: "NOVEL"), isNovel: true).count, 1)
        XCTAssertTrue(CoverSearch.aniListCovers(from: aniList(format: "MANGA"), isNovel: true).isEmpty)
    }

    // MARK: Apple Books

    private let appleBooks = Data("""
    {"resultCount":3,"results":[
      {"trackId":1,"trackName":"Berserk Volume 1","artistName":"Kentaro Miura","artworkUrl100":"https://is1.mzstatic.com/a/100x100bb.jpg","genres":["Manga","Books","Comics & Graphic Novels"]},
      {"trackId":2,"trackName":"Dragon Guard Berserkers: Volume 1","artistName":"Julia Mills","artworkUrl100":"https://is1.mzstatic.com/b/100x100bb.jpg","genres":["Fantasy","Books","Romance"]},
      {"trackId":3,"trackName":"Berserk Volume 41","artistName":"Kentaro Miura","artworkUrl100":"https://is1.mzstatic.com/c/100x100bb.jpg","genres":["Manga","Books"]}
    ]}
    """.utf8)

    func testAppleBooksKeepsOnlyComicsForAComicAndReadsTheVolume() {
        let covers = CoverSearch.appleBooksCovers(from: appleBooks, isNovel: false)
        XCTAssertEqual(covers.map(\.title), ["Berserk Volume 1", "Berserk Volume 41"], "not the paranormal romance")
        XCTAssertEqual(covers.map(\.volume), [1, 41])
        XCTAssertEqual(covers[0].fullURL.absoluteString, "https://is1.mzstatic.com/a/1200x1200bb.jpg")
        XCTAssertEqual(covers[0].thumbnailURL.absoluteString, "https://is1.mzstatic.com/a/400x400bb.jpg")
        XCTAssertEqual(CoverSearch.appleBooksCovers(from: appleBooks, isNovel: true).count, 3, "novels aren't filtered by genre")
    }

    func testVolumeNumbersInRetailTitles() {
        XCTAssertEqual(CoverSearch.volumeNumber(in: "Berserk Volume 41"), 41)
        XCTAssertEqual(CoverSearch.volumeNumber(in: "Solo Leveling, Vol. 3 (comic)"), 3)
        XCTAssertEqual(CoverSearch.volumeNumber(in: "Mushoku Tensei: Jobless Reincarnation (Light Novel) Vol. 10"), 10)
        XCTAssertNil(CoverSearch.volumeNumber(in: "Goodnight Punpun Omnibus"))
    }

    func testGarbageResponsesGiveNothingRatherThanCrash() {
        let junk = Data("<html>rate limited</html>".utf8)
        XCTAssertTrue(CoverSearch.mangaDexSeries(from: junk).isEmpty)
        XCTAssertTrue(CoverSearch.aniListCovers(from: junk, isNovel: false).isEmpty)
        XCTAssertTrue(CoverSearch.appleBooksCovers(from: junk, isNovel: false).isEmpty)
    }

    // MARK: Relevance

    /// AniList answers "Solo Leveling" with "The Privilege of the Second Life is Power Leveling"
    /// too. A result has to contain every word searched for, in any of its titles.
    func testOnlyResultsNamingWhatWasSearchedAreKept() {
        XCTAssertTrue(CoverSearch.isRelevant(["Solo Leveling"], to: "Solo Leveling"))
        XCTAssertTrue(CoverSearch.isRelevant(["Solo Leveling: Ragnarok"], to: "solo leveling"), "a sequel names it")
        XCTAssertFalse(CoverSearch.isRelevant(["The Privilege of the Second Life is Power Leveling"], to: "Solo Leveling"))
        XCTAssertTrue(CoverSearch.isRelevant(["Parasyte", "Kiseijuu"], to: "Kiseijuu"), "any of its titles")
        XCTAssertTrue(CoverSearch.isRelevant(["Pokémon Adventures"], to: "Pokemon"), "accents don't matter")
        XCTAssertTrue(CoverSearch.isRelevant(["JoJo's Bizarre Adventure Part 5: Golden Wind"], to: "JoJo's Bizarre Adventure"))
    }

    func testAniListDropsResultsThatDontMatch() {
        let covers = CoverSearch.aniListCovers(from: aniList(format: "MANGA"), isNovel: false, query: "Berserk")
        XCTAssertTrue(covers.isEmpty)
        XCTAssertEqual(CoverSearch.aniListCovers(from: aniList(format: "MANGA"), isNovel: false, query: "na honjaman").count, 1,
                       "the romaji title counts")
    }

    /// A whole series wants its original and English covers, not volume one in every language.
    func testASeriesSearchKeepsJapaneseAndEnglishCoversOnly() {
        let covers = CoverSearch.mangaDexCovers(from: mangaDexCovers, series: .init(id: "m", title: "Berserk"), volume: nil)
        XCTAssertFalse(covers.contains { $0.language == "uk" || $0.language == "it" })
        XCTAssertEqual(covers.first?.fullURL.lastPathComponent, "v1-ja.jpg")
    }

    // MARK: Ranking

    private func candidate(_ name: String, _ source: CoverSource, volume: Double? = nil, language: String? = nil,
                           series: Bool = false) -> CoverCandidate {
        let url = URL(string: "https://example.com/\(name).jpg")!
        return CoverCandidate(title: name, volume: volume, detail: nil, language: language, thumbnailURL: url,
                              fullURL: url, source: source, isSeriesCover: series)
    }

    func testRankingPutsTheWantedVolumeFirstInThePreferredEditions() {
        let pool = [
            candidate("anilist", .aniList, series: true),
            candidate("apple-v3", .appleBooks, volume: 3),
            candidate("md-v1-ja", .mangaDex, volume: 1, language: "ja"),
            candidate("md-v3-it", .mangaDex, volume: 3, language: "it"),
            candidate("md-v3-en", .mangaDex, volume: 3, language: "en"),
            candidate("md-v3-ja", .mangaDex, volume: 3, language: "ja"),
        ]
        let ranked = CoverSearch.rank(pool, for: CoverQuery(title: "Berserk", volume: 3))
        XCTAssertEqual(ranked.map(\.title), ["md-v3-ja", "md-v3-en", "apple-v3", "md-v3-it", "anilist", "md-v1-ja"])
    }

    func testRankingForASeriesPutsSeriesCoversThenVolumeOne() {
        let pool = [
            candidate("md-v5", .mangaDex, volume: 5, language: "ja"),
            candidate("md-v1", .mangaDex, volume: 1, language: "ja"),
            candidate("anilist", .aniList, series: true),
            candidate("md-main", .mangaDex, series: true),
        ]
        let ranked = CoverSearch.rank(pool, for: CoverQuery(title: "Berserk"))
        XCTAssertEqual(ranked.map(\.title), ["md-main", "anilist", "md-v1", "md-v5"])
    }

    func testRankingDropsTheSameImageFoundTwice() {
        let twice = [candidate("same", .mangaDex, volume: 1, language: "ja"), candidate("same", .mangaDex, series: true)]
        XCTAssertEqual(CoverSearch.rank(twice, for: CoverQuery(title: "S")).count, 1)
    }

    // MARK: Cover ids and storage

    /// Swift's `Hasher` is seeded per launch; a filename can't be. FNV-1a of "abc" is fixed.
    func testCoverIDsAreStableAcrossLaunches() {
        XCTAssertEqual(CoverStore.stableHex("abc"), "e71fa2190541574b")
        let comic = makeComic("Berserk/Berserk v01.cbz")
        XCTAssertEqual(CoverStore.coverID(for: comic), CoverStore.stableHex(comic.id))
    }

    func testPickedCoversAreKeptOutOfCaches() throws {
        let (store, caches, support) = try makeStore()
        let comic = makeComic("Berserk/Berserk v01.cbz")
        let picked = CoverStore.customID(for: comic, origin: "https://example.com/a.jpg")
        XCTAssertTrue(CoverStore.isCustom(picked))
        XCTAssertEqual(store.url(for: picked).deletingLastPathComponent().standardizedFileURL, support.standardizedFileURL)
        XCTAssertEqual(store.url(for: CoverStore.coverID(for: comic)).deletingLastPathComponent().standardizedFileURL,
                       caches.standardizedFileURL)
        XCTAssertNotEqual(picked, CoverStore.customID(for: comic, origin: "https://example.com/b.jpg"), "a new picture, a new id")
    }

    func testAPickedImageMustBeAnImage() throws {
        let (store, _, _) = try makeStore()
        XCTAssertFalse(store.storeCustom(imageData: Data("not a picture".utf8), as: "custom-x"))
        XCTAssertTrue(store.storeCustom(imageData: png(width: 1600, height: 2400), as: "custom-y"))
        let saved = try XCTUnwrap(store.load("custom-y"))
        XCTAssertLessThanOrEqual(max(saved.width, saved.height), CoverStore.maxPixel, "loaded at thumbnail size")
    }

    func testTheSweepKeepsWhatsReferencedAndEveryPickedCover() throws {
        let (store, _, _) = try makeStore()
        let image = try XCTUnwrap(ImageDecoder.downsample(png(width: 60, height: 90), maxPixel: 90))
        for id in ["keep", "orphan", "custom-mine"] { XCTAssertTrue(store.store(image, as: id)) }
        XCTAssertEqual(store.removeUnreferenced(keeping: ["keep"]), 1)
        XCTAssertTrue(store.exists("keep"))
        XCTAssertFalse(store.exists("orphan"))
        XCTAssertTrue(store.exists("custom-mine"))
    }

    // MARK: State

    func testAPickedCoverGoesOnEveryCopyAndComesOffAgain() {
        let nas = makeComic("Berserk/Berserk v01.cbz", source: UUID())
        let local = makeComic("Berserk/Berserk v01.cbz", source: UUID())
        let other = makeComic("Berserk/Berserk v02.cbz", source: nas.sourceID)
        var state = LibraryState()
        state.comics = [nas, local, other]
        XCTAssertEqual(Set(state.copies(of: nas).map(\.id)), [nas.id, local.id], "same file on the NAS and downloaded")

        XCTAssertNil(state.installCustomCover("custom-1", for: nas.id))
        XCTAssertEqual(state.comics[0].coverID, "custom-1")
        XCTAssertEqual(state.installCustomCover("custom-2", for: nas.id), "custom-1", "the replaced file can go")

        XCTAssertEqual(state.removeCustomCover(for: nas.id, original: "page-one"), "custom-2")
        XCTAssertEqual(state.comics[0].coverID, "page-one")
        XCTAssertNil(state.customCovers[nas.id])
        XCTAssertNil(state.removeCustomCover(for: other.id, original: nil), "nothing to remove")
    }

    /// A rename would otherwise silently reset the shelf's reading direction and layout.
    func testRenamingAShelfCarriesItsSettings() {
        let one = makeComic("Part 5/Volume 47 - The Golden Heart.zip", series: "Part 5 - Vento Aureo")
        let two = makeComic("Part 5/Volume 48 - His Dream.zip", series: "Part 5 - Vento Aureo", author: "Hirohiko Araki")
        var state = LibraryState()
        state.comics = [one, two]
        state.seriesDirection[SeriesGrouper.key(forName: "Part 5 - Vento Aureo")] = .rightToLeft
        state.seriesMode[SeriesGrouper.key(forName: "Part 5 - Vento Aureo")] = .continuous

        state.renameSeries([one.id, two.id], from: "Part 5 - Vento Aureo",
                           to: "JoJo's Bizarre Adventure Part 5: Golden Wind", author: "Araki")

        XCTAssertTrue(state.comics.allSatisfy { $0.series == "JoJo's Bizarre Adventure Part 5: Golden Wind" })
        let newKey = SeriesGrouper.key(forName: "JoJo's Bizarre Adventure Part 5: Golden Wind")
        XCTAssertEqual(state.seriesDirection[newKey], .rightToLeft)
        XCTAssertEqual(state.seriesMode[newKey], .continuous)
        XCTAssertNil(state.seriesDirection[SeriesGrouper.key(forName: "Part 5 - Vento Aureo")])
        XCTAssertEqual(state.comics[0].author, "Araki", "an unknown author is filled in")
        XCTAssertEqual(state.comics[1].author, "Hirohiko Araki", "a known one is never overwritten")
        XCTAssertEqual(state.overrides[one.id]?.series, "JoJo's Bizarre Adventure Part 5: Golden Wind", "survives a rescan")
    }

    // MARK: Look Up Series

    /// AniList finds nothing for "Goodnight Punpun Omnibus" and the right series for
    /// "Goodnight Punpun" — edition words have to come off for a second try.
    func testLookupTriesTheNameThenWithoutEditionWords() {
        XCTAssertEqual(SeriesLookup.searchTerms(for: "Goodnight Punpun Omnibus"), ["Goodnight Punpun Omnibus", "Goodnight Punpun"])
        XCTAssertEqual(SeriesLookup.searchTerms(for: "JoJo's Bizarre Adventure Part 4 - Diamond is Unbreakable Full Color"),
                       ["JoJo's Bizarre Adventure Part 4 - Diamond is Unbreakable Full Color",
                        "JoJo's Bizarre Adventure Part 4 - Diamond is Unbreakable"])
        XCTAssertEqual(SeriesLookup.searchTerms(for: "BLAME! Master Edition"), ["BLAME! Master Edition", "BLAME!"])
        XCTAssertEqual(SeriesLookup.searchTerms(for: "Berserk"), ["Berserk"], "nothing to strip, one try")
    }

    private let aniListVento = Data("""
    {"data":{"Page":{"media":[
      {"id":1706,"format":"MANGA","title":{"romaji":"JoJo no Kimyou na Bouken: Ougon no Kaze","english":"JoJo's Bizarre Adventure Part 5: Golden Wind"},
       "coverImage":{"extraLarge":"https://s4.anilist.co/xl.jpg","large":"https://s4.anilist.co/l.jpg"},"startDate":{"year":1995},
       "staff":{"edges":[{"role":"Story & Art","node":{"name":{"full":"Hirohiko Araki"}}},{"role":"Translator","node":{"name":{"full":"Evan Galloway"}}}]}},
      {"id":2,"format":"NOVEL","title":{"romaji":"Purple Haze Feedback","english":null},"coverImage":null,"startDate":{"year":2011},"staff":{"edges":[]}}
    ]}}}
    """.utf8)

    func testLookupMatchesCarryTheEnglishTitleYearAndWriter() {
        let matches = SeriesLookup.parseMatches(from: aniListVento, isNovel: false)
        XCTAssertEqual(matches.count, 1, "the novel belongs on the other shelf")
        XCTAssertEqual(matches[0].title, "JoJo's Bizarre Adventure Part 5: Golden Wind")
        XCTAssertEqual(matches[0].originalTitle, "JoJo no Kimyou na Bouken: Ougon no Kaze")
        XCTAssertEqual(matches[0].year, 1995)
        XCTAssertEqual(matches[0].author, "Hirohiko Araki")
        XCTAssertEqual(matches[0].coverURL?.absoluteString, "https://s4.anilist.co/xl.jpg")
        let novels = SeriesLookup.parseMatches(from: aniListVento, isNovel: true)
        XCTAssertEqual(novels.map(\.title), ["Purple Haze Feedback"], "romaji when there's no English title")
        XCTAssertNil(novels[0].originalTitle)
    }

    func testTheAuthorIsTheWriterNeverTheTranslator() {
        XCTAssertEqual(SeriesLookup.author(from: [("Translator", "Evan Galloway"), ("Story & Art", "Hirohiko Araki")]), "Hirohiko Araki")
        XCTAssertEqual(SeriesLookup.author(from: [("Art", "Seong-Rak Jang"), ("Story (chs 1-92)", "So-Ryeong Gi")]), "So-Ryeong Gi",
                       "story beats art")
        XCTAssertEqual(SeriesLookup.author(from: [("Original Creator", "Chugong"), ("Art", "DUBU")]), "Chugong")
        XCTAssertEqual(SeriesLookup.author(from: [("Art", "Tooru Fujisawa")]), "Tooru Fujisawa")
        XCTAssertNil(SeriesLookup.author(from: [("Translator", "A"), ("Lettering", "B")]))
        XCTAssertNil(SeriesLookup.author(from: []))
    }

    // MARK: Helpers

    private func makeComic(_ path: String, source: UUID = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!,
                           series: String? = "Berserk", author: String? = nil) -> Comic {
        Comic(id: Comic.makeID(sourceID: source, relativePath: path), sourceID: source, relativePath: path, kind: .archive,
              title: (path as NSString).lastPathComponent, series: series, volume: 1, chapter: nil, author: author,
              year: nil, subtitle: nil, pageCount: nil, totalBytes: 1, addedAt: Date(), coverID: nil)
    }

    private func makeStore() throws -> (CoverStore, URL, URL) {
        let base = FileManager.default.temporaryDirectory.appending(path: "mango-covers-\(UUID().uuidString)")
        let caches = base.appending(path: "Caches"), support = base.appending(path: "Support")
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return (CoverStore(directory: caches, customDirectory: support), caches, support)
    }

    private func png(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return out as Data
    }
}
