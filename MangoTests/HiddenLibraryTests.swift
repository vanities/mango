import XCTest
@testable import Mango

@MainActor
final class HiddenLibraryTests: XCTestCase {
    private var directory: URL!
    private var model: LibraryModel!
    private var manga: Comic!
    private var novel: Comic!
    private var publicBook: Comic!
    private var authentication: HiddenAuthenticationStub!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        authentication = HiddenAuthenticationStub()
        manga = book("Private Manga/v01.cbz", series: "Private Manga")
        novel = book("Private Novel/v01.epub", series: "Private Novel", kind: .epub)
        publicBook = book("Garden/v01.cbz", series: "Garden")
        model = makeModel()
        model.mutateState { state in
            state.comics = [manga, novel, publicBook]
            for comic in state.comics {
                state.progress[comic.id] = ReadingProgress(page: 2, pageCount: 10)
            }
            state.lastComicID = manga.id
        }
    }

    override func tearDown() async throws {
        model.lockHiddenItems()
        model.hiddenSceneChanged(to: .active)
        model = nil
        authentication = nil
        try? FileManager.default.removeItem(at: directory)
    }

    func testBulkHideAndSessionUnlockPreserveFlagsAndProgress() async {
        let ids = Set([SeriesGrouper.key(for: manga), SeriesGrouper.key(for: novel)])
        model.hideSeries(ids: ids)
        XCTAssertEqual(model.visibleComics.map(\.id), [publicBook.id])
        XCTAssertEqual(model.continueReading.map(\.id), [publicBook.id])
        XCTAssertEqual(model.series.map(\.name), ["Garden"])
        let unlocked = await model.unlockHiddenItems()
        XCTAssertTrue(unlocked)
        XCTAssertEqual(Set(model.visibleComics.map(\.id)), Set([manga.id, novel.id, publicBook.id]))
        XCTAssertEqual(Set(model.continueReading.map(\.id)), Set([manga.id, novel.id, publicBook.id]))
        XCTAssertEqual(model.state.hiddenSeries, ids)
        XCTAssertEqual(model.progress(for: manga)?.page, 2)
        XCTAssertEqual(model.progress(for: novel)?.page, 2)
        XCTAssertEqual(model.search("Private", in: .manga).count, 1)
        XCTAssertEqual(model.search("Private", in: .novels).count, 1)
        model.lockHiddenItems()
        XCTAssertTrue(model.search("Private", in: .manga).isEmpty)
        XCTAssertTrue(model.search("Private", in: .novels).isEmpty)
        XCTAssertEqual(model.state.hiddenSeries, ids)
    }

    func testBackgroundLocksButInactiveAuthenticationDoesNot() async {
        model.hideSeries(ids: [SeriesGrouper.key(for: manga)])
        _ = await model.unlockHiddenItems()
        model.hiddenSceneChanged(to: .inactive)
        XCTAssertTrue(model.hiddenSession.isUnlocked)
        model.hiddenSceneChanged(to: .background)
        XCTAssertFalse(model.hiddenSession.isUnlocked)
        model.hiddenSceneChanged(to: .active)
        XCTAssertFalse(model.hiddenSession.isUnlocked)
        XCTAssertFalse(model.continueReading.contains { $0.id == manga.id })
    }

    func testHiddenUnlockRequiresAuthenticationWithAppLockOff() async {
        XCTAssertEqual(model.settings.lockMode, .off)
        model.hideSeries(ids: [SeriesGrouper.key(for: manga), SeriesGrouper.key(for: novel)])
        authentication.allowed = false
        let denied = await model.unlockHiddenItems()
        XCTAssertFalse(denied)
        XCTAssertEqual(authentication.reasons.count, 1)
        XCTAssertFalse(model.hiddenSession.isUnlocked)
        XCTAssertEqual(model.visibleComics.map(\.id), [publicBook.id])
        XCTAssertEqual(model.continueReading.map(\.id), [publicBook.id])
        authentication.allowed = true
        let approved = await model.unlockHiddenItems()
        XCTAssertTrue(approved)
        XCTAssertEqual(authentication.reasons.count, 2)
        XCTAssertTrue(model.hiddenSession.isUnlocked)
        XCTAssertTrue(model.visibleComics.contains { $0.id == manga.id })
        XCTAssertTrue(model.visibleComics.contains { $0.id == novel.id })
    }

    func testBackgroundingDuringAuthenticationRejectsTheStaleUnlock() async {
        model.hideSeries(ids: [SeriesGrouper.key(for: manga)])
        authentication.beforeResult = { [weak model] in model?.hiddenSceneChanged(to: .background) }
        let approved = await model.unlockHiddenItems()
        XCTAssertFalse(approved)
        model.hiddenSceneChanged(to: .active)
        XCTAssertFalse(model.hiddenSession.isUnlocked)
        XCTAssertEqual(model.visibleComics.map(\.id), [novel.id, publicBook.id])
        authentication.beforeResult = nil
        let freshApproval = await model.unlockHiddenItems()
        XCTAssertTrue(freshApproval)
    }

    func testIdleExpiryClearsAQueuedPrivateReader() async {
        model.hideSeries(ids: [SeriesGrouper.key(for: manga)])
        _ = await model.unlockHiddenItems()
        model.requestedComic = manga
        model.noteHiddenActivity(at: Date.now.addingTimeInterval(10_801))
        XCTAssertFalse(model.hiddenSession.isUnlocked)
        XCTAssertNil(model.requestedComic)
        XCTAssertFalse(model.visibleComics.contains { $0.id == manga.id })
    }

    func testWidgetAndSiriCandidatesStayPublicWhileUnlocked() async {
        model.hideSeries(ids: [SeriesGrouper.key(for: manga), SeriesGrouper.key(for: novel)])
        _ = await model.unlockHiddenItems()
        XCTAssertEqual(model.lastRead?.id, manga.id)
        XCTAssertEqual(model.publicLastRead?.id, publicBook.id)
        XCTAssertEqual(model.publicContinueReading.map(\.id), [publicBook.id])
        XCTAssertEqual(model.publicComics.map(\.id), [publicBook.id])
        model.handleDeepLink(LibraryModel.deepLink(for: manga)!)
        XCTAssertNil(model.requestedComic)
        model.handleDeepLink(URL(string: "mango://continue")!)
        XCTAssertEqual(model.requestedComic?.id, publicBook.id)
    }

    func testRelaunchStartsLockedAndNewVolumesStayHidden() async {
        model.hideSeries(ids: [SeriesGrouper.key(for: manga)])
        _ = await model.unlockHiddenItems()
        let next = book("Private Manga/v02.cbz", series: "Private Manga")
        model.mutateState { $0.comics.append(next) }
        XCTAssertTrue(model.visibleComics.contains { $0.id == next.id })
        let relaunched = makeModel()
        XCTAssertFalse(relaunched.hiddenSession.isUnlocked)
        XCTAssertFalse(relaunched.visibleComics.contains { $0.id == manga.id || $0.id == next.id })
        XCTAssertEqual(relaunched.progress(for: manga)?.page, 2)
        XCTAssertEqual(relaunched.state.hiddenSeries, model.state.hiddenSeries)
    }

    func testIndividualVolumeUnlockDoesNotPermanentlyUnhide() async {
        model.setHidden(true, for: novel)
        XCTAssertFalse(model.visibleComics.contains { $0.id == novel.id })
        _ = await model.unlockHiddenItems()
        XCTAssertTrue(model.visibleComics.contains { $0.id == novel.id })
        XCTAssertTrue(model.state.hiddenComicIDs.contains(novel.id))
        model.lockHiddenItems()
        XCTAssertFalse(model.visibleComics.contains { $0.id == novel.id })
    }

    func testHidingAnotherTitleRelocksAnUnlockedSession() async {
        model.setHidden(true, for: novel)
        _ = await model.unlockHiddenItems()
        model.setSeriesHidden(true, SeriesGrouper.group([manga])[0])
        XCTAssertFalse(model.hiddenSession.isUnlocked)
        XCTAssertEqual(model.visibleComics.map(\.id), [publicBook.id])
        _ = await model.unlockHiddenItems()
        model.setHidden(true, for: publicBook)
        XCTAssertFalse(model.hiddenSession.isUnlocked)
        XCTAssertTrue(model.visibleComics.isEmpty)
    }

    func testMetadataEditsCannotRevealAHiddenTitle() async {
        model.hideSeries(ids: [SeriesGrouper.key(for: manga), SeriesGrouper.key(for: novel)])
        _ = await model.unlockHiddenItems()
        model.setOverride(ComicOverride(series: "New Manga Name"), for: manga)
        model.renameSeries(SeriesGrouper.group([novel])[0], to: "New Novel Name", author: nil)
        model.lockHiddenItems()
        XCTAssertEqual(model.visibleComics.map(\.id), [publicBook.id])
        XCTAssertTrue(model.state.hiddenComicIDs.contains(manga.id))
        let changedNovel = model.state.comics.first { $0.id == novel.id }!
        XCTAssertTrue(model.state.hiddenSeries.contains(SeriesGrouper.key(for: changedNovel)))
        XCTAssertEqual(model.hiddenShelves.count, model.state.hiddenSeries.count)
        model.mutateState { $0.comics.append(book("Private Novel/v02.epub", series: "Private Novel", kind: .epub)) }
        XCTAssertEqual(model.visibleComics.map(\.id), [publicBook.id])
    }

    private func makeModel() -> LibraryModel {
        LibraryModel(store: LibraryStore(directory: directory.appending(path: "State")),
                     covers: CoverStore(directory: directory.appending(path: "Covers"),
                                        customDirectory: directory.appending(path: "Custom")),
                     settings: AppSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                     hiddenAuthenticator: { [authentication = authentication!] reason in
                         await authentication.authenticate(reason: reason)
                     })
    }

    private func book(_ path: String, series: String, kind: Comic.Kind = .archive) -> Comic {
        let source = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
        return Comic(id: Comic.makeID(sourceID: source, relativePath: path), sourceID: source, relativePath: path,
                     kind: kind, title: (path as NSString).lastPathComponent, series: series, volume: 1, chapter: nil,
                     author: nil, year: nil, subtitle: nil, pageCount: 10, totalBytes: 1, addedAt: Date(), coverID: "fixture")
    }
}

@MainActor
private final class HiddenAuthenticationStub {
    var allowed = true
    var reasons: [String] = []
    var beforeResult: (() -> Void)?

    func authenticate(reason: String) async -> Bool {
        reasons.append(reason)
        beforeResult?()
        return allowed
    }
}
