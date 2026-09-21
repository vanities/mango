import XCTest
@testable import Mango

/// Downloading a comic creates a second `Comic` for the same file — same relative path,
/// different source, therefore a different `Comic.id`. Two things must follow from that: the
/// shelf shows it once, and the reader doesn't lose their place.
final class LibraryDedupeTests: XCTestCase {
    private let remoteSource = UUID()
    private let localSource = UUID()
    private var remoteIDs: Set<UUID> { [remoteSource] }

    private func comic(_ path: String, source: UUID) -> Comic {
        Comic(id: Comic.makeID(sourceID: source, relativePath: path), sourceID: source,
              relativePath: path, kind: .archive, title: (path as NSString).lastPathComponent,
              series: "Tower Dungeon", volume: 1, chapter: nil, author: nil, year: nil,
              subtitle: nil, pageCount: nil, totalBytes: 100, addedAt: Date(), coverID: nil)
    }

    // MARK: Which copy shows

    func testDownloadedCopyReplacesTheRemoteOne() {
        let path = "Tower Dungeon/v01.cbz"
        let visible = LibraryDedupe.visible(
            comics: [comic(path, source: remoteSource), comic(path, source: localSource)],
            remoteSourceIDs: remoteIDs, hidden: []
        )
        XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.sourceID, localSource, "the local copy is the one to open")
    }

    func testRemoteComicsWithNoLocalCopyStayVisible() {
        let visible = LibraryDedupe.visible(
            comics: [comic("a.cbz", source: remoteSource), comic("b.cbz", source: remoteSource)],
            remoteSourceIDs: remoteIDs, hidden: []
        )
        XCTAssertEqual(visible.count, 2)
    }

    /// Matching is by relative path, so a file downloaded into a different folder is genuinely
    /// a different book and both should show.
    func testDifferentPathsAreNotTwins() {
        let visible = LibraryDedupe.visible(
            comics: [comic("Tower Dungeon/v01.cbz", source: remoteSource),
                     comic("Elsewhere/v01.cbz", source: localSource)],
            remoteSourceIDs: remoteIDs, hidden: []
        )
        XCTAssertEqual(visible.count, 2)
    }

    func testHiddenComicsStayHidden() {
        let local = comic("a.cbz", source: localSource)
        let visible = LibraryDedupe.visible(comics: [local], remoteSourceIDs: remoteIDs, hidden: [local.id])
        XCTAssertTrue(visible.isEmpty)
    }

    func testDownloadedCopyIsRecognisedForBadging() {
        let path = "Tower Dungeon/v01.cbz"
        let remote = comic(path, source: remoteSource)
        let local = comic(path, source: localSource)
        let lonely = comic("only-local.cbz", source: localSource)
        XCTAssertTrue(LibraryDedupe.isDownloadedCopy(local, comics: [remote, local], remoteSourceIDs: remoteIDs))
        XCTAssertFalse(LibraryDedupe.isDownloadedCopy(lonely, comics: [remote, local, lonely], remoteSourceIDs: remoteIDs))
        XCTAssertFalse(LibraryDedupe.isDownloadedCopy(remote, comics: [remote, local], remoteSourceIDs: remoteIDs),
                       "the remote original isn't itself a download")
    }

    // MARK: Carrying the reader's place across

    private func state(withTwinsAt path: String) -> (LibraryState, Comic, Comic) {
        let remote = comic(path, source: remoteSource)
        let local = comic(path, source: localSource)
        var state = LibraryState()
        state.comics = [remote, local]
        return (state, remote, local)
    }

    /// The whole point: download a volume you're halfway through and stay halfway through it.
    func testReadingPositionFollowsTheDownload() {
        var (state, remote, local) = state(withTwinsAt: "Tower Dungeon/v01.cbz")
        state.progress[remote.id] = ReadingProgress(page: 74, pageCount: 156)

        let adopted = state.adoptStateFromRemoteTwins(remoteSourceIDs: remoteIDs)

        XCTAssertEqual(adopted, 1)
        XCTAssertEqual(state.progress[local.id]?.page, 74)
        XCTAssertEqual(state.progress[remote.id]?.page, 74, "the original is left alone")
    }

    /// Whatever the local copy already has is newer by definition.
    func testExistingLocalProgressIsNotOverwritten() {
        var (state, remote, local) = state(withTwinsAt: "a.cbz")
        state.progress[remote.id] = ReadingProgress(page: 10, pageCount: 100)
        state.progress[local.id] = ReadingProgress(page: 90, pageCount: 100)

        state.adoptStateFromRemoteTwins(remoteSourceIDs: remoteIDs)

        XCTAssertEqual(state.progress[local.id]?.page, 90)
    }

    func testCorrectionsAndChosenCoversFollowToo() {
        var (state, remote, local) = state(withTwinsAt: "a.cbz")
        state.overrides[remote.id] = ComicOverride(series: "Corrected", volume: 7)
        state.customCovers[remote.id] = "cover-abc"

        state.adoptStateFromRemoteTwins(remoteSourceIDs: remoteIDs)

        XCTAssertEqual(state.overrides[local.id]?.series, "Corrected")
        XCTAssertEqual(state.overrides[local.id]?.volume, 7)
        XCTAssertEqual(state.customCovers[local.id], "cover-abc")
    }

    /// Continue Reading points at an id; if it kept pointing at the hidden twin it would
    /// resolve to nothing.
    func testContinueReadingFollowsTheVisibleCopy() {
        var (state, remote, local) = state(withTwinsAt: "a.cbz")
        state.lastComicID = remote.id

        state.adoptStateFromRemoteTwins(remoteSourceIDs: remoteIDs)

        XCTAssertEqual(state.lastComicID, local.id)
    }

    /// Hiding something then downloading it must not bring it back.
    func testHidingCarriesToTheDownload() {
        var (state, remote, local) = state(withTwinsAt: "a.cbz")
        state.hiddenComicIDs = [remote.id]

        state.adoptStateFromRemoteTwins(remoteSourceIDs: remoteIDs)
        let visible = LibraryDedupe.visible(comics: state.comics, remoteSourceIDs: remoteIDs,
                                            hidden: state.hiddenComicIDs)

        XCTAssertTrue(state.hiddenComicIDs.contains(local.id))
        XCTAssertTrue(visible.isEmpty)
    }

    func testNothingHappensWithoutAShare() {
        var state = LibraryState()
        state.comics = [comic("a.cbz", source: localSource)]
        XCTAssertEqual(state.adoptStateFromRemoteTwins(remoteSourceIDs: []), 0)
    }

    /// A shelf shouldn't gain a duplicate volume the moment you download one.
    func testGroupingSeesOneVolumeNotTwo() {
        let path = "Tower Dungeon/v01.cbz"
        let visible = LibraryDedupe.visible(
            comics: [comic(path, source: remoteSource), comic(path, source: localSource)],
            remoteSourceIDs: remoteIDs, hidden: []
        )
        let shelves = SeriesGrouper.group(visible)
        XCTAssertEqual(shelves.count, 1)
        XCTAssertEqual(shelves[0].volumeCount, 1)
    }
}
