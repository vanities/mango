import CoreGraphics
import Foundation
import Observation
import SwiftUI
import UIKit
import os

/// Drives one reading session: opens the archive, hands pages to the view, remembers where you
/// got to.
///
/// Page images are *not* held in observable state — the view asks for one page at a time and the
/// loader caches a handful. Keeping every decoded page in an `@Observable` dict is how a reader
/// ends up holding 300 MB of bitmaps.
@MainActor @Observable
final class ReaderEngine {
    let comic: Comic

    private(set) var pageCount = 0
    private(set) var isOpening = true
    private(set) var openError: String?
    /// Which page group (page or spread) is on screen.
    var groupIndex = 0 { didSet { onGroupChanged() } }
    private(set) var groups: [[Int]] = []
    private(set) var widePages: Set<Int> = []

    var direction: ReadingDirection { didSet { library.setDirection(direction, for: comic, wholeSeries: true) } }
    /// Layout in use. Setting it here doesn't save anything — `chooseMode` is for the user's
    /// own choice; detection sets this directly so it never masquerades as one.
    var mode: ReaderMode {
        didSet {
            guard mode != oldValue else { return }
            Logger.reader.info("[reader] layout \(oldValue.rawValue, privacy: .public) → \(self.mode.rawValue, privacy: .public)")
            rebuildGroups()
        }
    }
    /// Visible on open so the way out is obvious, then it gets out of the way on its own.
    var showsControls = true

    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var loader: PageLoader?
    /// Screen geometry, for sizing decodes: longest edge for a page, width for a strip.
    @ObservationIgnored private var screenPixels = CGSize(width: 1200, height: 2600)

    private var sizing: PageSizing {
        switch mode {
        case .paged:
            // Headroom so a pinch-zoom doesn't go soft straight away; capped in ImageDecoder.
            .fitScreen(maxPixel: Int(max(screenPixels.width, screenPixels.height) * 1.5))
        case .continuous:
            // A strip spans the full width, so decode to the screen's longer edge: sharp in
            // either orientation without re-decoding on rotation. In practice the source width
            // is the limit — strips are 800–1200px wide and are never upscaled.
            .fitWidth(pixels: Int(max(screenPixels.width, screenPixels.height)))
        }
    }

    /// Crop margins applies to pages shown whole; a strip's margins are part of its flow.
    var cropsMargins: Bool { settings.cropMargins && mode == .paged }

    /// A small copy of a page for the page grid.
    func thumbnail(at index: Int) async -> CGImage? {
        guard let loader, index >= 0, index < pageCount else { return nil }
        return await loader.thumbnail(at: index)
    }

    /// An arrow key: the page to that side, whichever way this book reads.
    func turn(towardsLeft: Bool) {
        let forward = towardsLeft == (direction == .rightToLeft)
        if forward { advance() } else { retreat() }
        Logger.reader.debug("[reader] key turn \(towardsLeft ? "left" : "right", privacy: .public) → page \(self.currentPage + 1)")
    }

    /// The user picked a layout in settings. Saved for this book, and it beats detection.
    func chooseMode(_ newMode: ReaderMode) {
        mode = newMode
        library.setMode(newMode, for: comic)
        if newMode == .continuous { startSizeSurvey(around: currentPage) }
        prefetchAround()
    }

    /// Height over width of each page decoded so far. A strip is laid out from these, so a page
    /// that scrolled away and came back — its bitmap long since dropped — keeps its height
    /// instead of collapsing to a placeholder and yanking everything below it.
    @ObservationIgnored private var pageAspects: [Int: Double] = [:]
    @ObservationIgnored private var lastAspect: Double?

    /// A page's shape if it's known, else the last page's — strips keep one width, so it's a far
    /// better guess than a fixed placeholder height.
    func aspectRatio(of index: Int) -> Double? {
        pageAspects[index] ?? lastAspect
    }

    @ObservationIgnored private var sizeSurvey: Task<Void, Never>?

    /// A strip is laid out from every page's real height before its pages load — otherwise a
    /// page arriving shoves everything below it, and a book reopened at page 30 lands inside
    /// page 29 once that one fills in. The pages around where reading starts are sized before the
    /// first layout (the loader already has most of them from detection).
    private func sizePagesNear(_ start: Int, loader: PageLoader) async {
        let sw = Stopwatch()
        let near = max(0, start - 2)..<min(pageCount, start + 3)
        for index in near {
            await noteSize(of: index, from: loader)
        }
        Logger.reader.info("[strip] sized pages \(near.lowerBound + 1)–\(near.upperBound) in \(sw.ms, format: .fixed(precision: 1))ms")
    }

    /// …and the rest in the background, nearest first, one header read each.
    private func startSizeSurvey(around start: Int) {
        guard sizeSurvey == nil, let loader else { return }
        let count = pageCount
        sizeSurvey = Task { [weak self] in
            let sw = Stopwatch()
            let order = (0..<count).sorted { abs($0 - start) < abs($1 - start) }
            for index in order {
                guard !Task.isCancelled, let self else { return }
                await self.noteSize(of: index, from: loader)
            }
            Logger.reader.info("[strip] sized all \(count) pages in \(sw.ms, format: .fixed(precision: 0))ms")
        }
    }

    private func noteSize(of index: Int, from loader: PageLoader) async {
        guard pageAspects[index] == nil,
              let size = await loader.pageSize(at: index), size.width > 0 else { return }
        pageAspects[index] = size.height / size.width
        if lastAspect == nil { lastAspect = pageAspects[index] }
    }
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var hideControlsTask: Task<Void, Never>?
    @ObservationIgnored private var recorder: SessionRecorder?
    @ObservationIgnored private var lifecycleObservers: [any NSObjectProtocol] = []
    @ObservationIgnored private var sessionClosed = false

    init(comic: Comic, library: LibraryModel, settings: AppSettings) {
        self.comic = comic
        self.library = library
        self.settings = settings
        self.direction = library.direction(for: comic)
        self.mode = library.mode(for: comic)
    }

    deinit {
        saveTask?.cancel()
        sizeSurvey?.cancel()
        hideControlsTask?.cancel()
    }

    // MARK: Chrome

    /// Shows the controls and restarts the countdown to hiding them. Called on open and on
    /// every control interaction, so the chrome never vanishes mid-drag.
    func keepControlsAwake(for seconds: Double = 4.5) {
        showsControls = true
        hideControlsTask?.cancel()
        hideControlsTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.25)) { self?.showsControls = false }
        }
    }

    func toggleControls() {
        hideControlsTask?.cancel()
        if showsControls {
            withAnimation(.smooth(duration: 0.25)) { showsControls = false }
        } else {
            keepControlsAwake()
        }
    }

    /// The page the reader is actually looking at — the first of the group.
    var currentPage: Int { groups.indices.contains(groupIndex) ? (groups[groupIndex].first ?? 0) : 0 }

    var progressFraction: Double {
        pageCount > 1 ? Double(currentPage) / Double(pageCount - 1) : 0
    }

    var positionLabel: String { Formatting.pagePosition(currentPage, of: pageCount) }

    // MARK: Opening

    func open(screenPixels: CGSize) async {
        let sw = Stopwatch()
        isOpening = true
        openError = nil
        self.screenPixels = screenPixels
        do {
            let archive = try await library.openArchive(comic)
            pageCount = archive.pageCount
            let loader = PageLoader(archive: archive, capacity: settings.prefetchCount * 2 + 3)
            self.loader = loader
            let startPage = resumePage()
            // Long strips read as one vertical scroll. Decide before the first page is drawn so a
            // webtoon never flashes up as a sliver in paged mode first. It costs an ordinary book
            // nothing: the page it checks is the one about to be drawn, and the bytes are reused.
            // Your own choice for this book always wins; a known strip is already continuous.
            if !library.hasChosenMode(for: comic), mode == .paged,
               await loader.looksLikeLongStrip(from: startPage) {
                library.markLongStrip(comic)
                mode = .continuous
            }
            rebuildGroups()
            if startPage > 0 {
                groupIndex = SpreadLayout.groupIndex(containing: startPage, in: groups)
                Logger.reader.info("[reader] resumed \(self.comic.title, privacy: .public) at page \(startPage + 1)")
            }
            if mode == .continuous {
                await sizePagesNear(startPage, loader: loader)
                startSizeSurvey(around: startPage)
            }
            isOpening = false
            Logger.reader.info("[reader] opened \(self.comic.title, privacy: .public) pages=\(self.pageCount) in \(sw.ms, format: .fixed(precision: 0))ms")
            prefetchAround()
            keepControlsAwake()
            beginSession(at: currentPage)
        } catch {
            isOpening = false
            openError = error.localizedDescription
            Logger.reader.error("[reader] open failed for \(self.comic.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Where this comic was left off, if that's somewhere worth resuming.
    private func resumePage() -> Int {
        guard let saved = library.progress(for: comic), saved.page > 0, saved.page < pageCount, !saved.finished else {
            return 0
        }
        return saved.page
    }

    func close() {
        saveTask?.cancel()
        sizeSurvey?.cancel()
        hideControlsTask?.cancel()
        endSession()
        persistProgress()
        library.publishWidgetSnapshot()
        let loader = self.loader
        Task { await loader?.cancelAll() }
        Logger.reader.info("[reader] closed \(self.comic.title, privacy: .public) at page \(self.currentPage + 1)")
    }

    // MARK: Pages

    func image(at index: Int) async -> CGImage? {
        guard let loader, index >= 0, index < pageCount else { return nil }
        do {
            let image = try await loader.page(at: index, sizing: sizing, trim: cropsMargins)
            let aspect = Double(image.height) / Double(max(1, image.width))
            pageAspects[index] = aspect
            lastAspect = aspect
            let wide = await loader.widePages
            if wide != widePages {
                widePages = wide
                rebuildGroups()
            }
            return image
        } catch {
            Logger.reader.error("[reader] page \(index + 1) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Bookmarks

    var bookmarks: [Bookmark] { library.bookmarks(for: comic) }

    var isCurrentPageBookmarked: Bool {
        guard groups.indices.contains(groupIndex) else { return false }
        let visible = Set(groups[groupIndex])
        return bookmarks.contains { visible.contains($0.page) }
    }

    /// Marks the page on screen, or unmarks it if it's already marked. With a spread showing,
    /// either page counts as "this spot".
    func toggleBookmark() {
        guard groups.indices.contains(groupIndex) else { return }
        let visible = Set(groups[groupIndex])
        if let existing = bookmarks.first(where: { visible.contains($0.page) }) {
            library.removeBookmark(existing, from: comic)
        } else {
            library.addBookmark(page: currentPage, to: comic)
        }
        keepControlsAwake()
    }

    func removeBookmark(_ bookmark: Bookmark) {
        library.removeBookmark(bookmark, from: comic)
    }

    /// The page's name inside the container, for the "this page wouldn't open" message.
    func pageName(at index: Int) -> String {
        loader?.pageName(at: index) ?? "page \(index + 1)"
    }

    func handleMemoryWarning() {
        let loader = self.loader
        let page = currentPage
        Task { await loader?.purge(keeping: page) }
    }

    // MARK: Navigation

    /// Set when the reader tries to go past the last page. The view turns this into "open the
    /// next volume", or an end-of-series card when there isn't one.
    private(set) var reachedEnd = false
    /// Called once when the reader tries to turn past the last page.
    @ObservationIgnored var onReachedEnd: (@MainActor () -> Void)?

    /// "Forward" always means further into the book. Right-to-left flips which screen edge that is,
    /// which the view handles — this stays in page order.
    func advance() {
        guard !isAtEnd else {
            notifyReachedEnd()
            return
        }
        goToGroup(groupIndex + 1)
    }

    /// Fires once per opened volume, whether the reader tapped past the last page or swiped
    /// into the trailing slot.
    func notifyReachedEnd() {
        guard !reachedEnd, !isOpening, pageCount > 0 else { return }
        Logger.reader.info("[reader] reached the end of \(self.comic.title, privacy: .public)")
        reachedEnd = true
        onReachedEnd?()
    }
    func retreat() { goToGroup(groupIndex - 1) }

    /// Bumped by every move that isn't the reader scrolling — the slider, a bookmark, a tap — so
    /// a continuous strip knows to scroll there itself. Its own scrolling reports through
    /// `readingPage(_:)` instead, which leaves this alone: a strip that took its own reports as
    /// jumps would chase them, and did (open at page 2 → 1 → 2 → 1).
    private(set) var jumpCount = 0

    func goToGroup(_ index: Int) {
        guard groups.indices.contains(index) else { return }
        groupIndex = index
        jumpCount += 1
    }

    func goToPage(_ page: Int) {
        goToGroup(SpreadLayout.groupIndex(containing: page, in: groups))
    }

    /// The strip saying which page is under its reading line. Moves the position without asking
    /// anything to scroll — the strip is already there.
    func readingPage(_ page: Int) {
        let index = SpreadLayout.groupIndex(containing: page, in: groups)
        guard groups.indices.contains(index), index != groupIndex else { return }
        groupIndex = index
    }

    var isAtStart: Bool { groupIndex <= 0 }
    var isAtEnd: Bool { groupIndex >= groups.count - 1 }

    // MARK: Session timing

    /// Starts timing a session. Leaving the app commits what's accrued rather than just pausing:
    /// on iOS people rarely tap Close — they swipe home, and the system may kill the app before
    /// they're back, which would otherwise lose the whole session.
    private func beginSession(at page: Int) {
        recorder = SessionRecorder(startingAt: page)
        guard lifecycleObservers.isEmpty else { return }
        lifecycleObservers = [
            NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.commitSession() }
            },
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restartSession() }
            },
        ]
    }

    /// Records whatever this sitting amounts to and stops timing.
    private func commitSession() {
        guard var recorder else { return }
        self.recorder = nil
        if let session = recorder.finish(comic: comic, seriesKey: SeriesGrouper.key(for: comic)) {
            library.recordSession(session)
        }
    }

    /// Back in the app with the book still open: a new sitting starts now.
    private func restartSession() {
        guard recorder == nil, !sessionClosed else { return }
        recorder = SessionRecorder(startingAt: currentPage)
    }

    private func endSession() {
        sessionClosed = true
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        lifecycleObservers = []
        commitSession()
    }

    // MARK: Internals

    private func rebuildGroups() {
        let page = currentPage
        let spreads = mode == .paged && spreadsEnabled
        groups = SpreadLayout.groups(pageCount: pageCount, wide: widePages, enabled: spreads)
        groupIndex = SpreadLayout.groupIndex(containing: page, in: groups)
    }

    /// Spreads only make sense when the screen is wider than it is tall. The view keeps this in
    /// sync as the device rotates.
    var isLandscape = false { didSet { if isLandscape != oldValue { rebuildGroups() } } }

    private var spreadsEnabled: Bool {
        switch settings.spreadMode {
        case .always: true
        case .never: false
        case .auto: isLandscape
        }
    }

    private func onGroupChanged() {
        recorder?.tick(page: currentPage)
        prefetchAround()
        scheduleSave()
        if showsControls { keepControlsAwake() }
    }

    private func prefetchAround() {
        guard let loader else { return }
        let page = currentPage
        let ahead = settings.prefetchCount
        let sizing = self.sizing
        let trim = cropsMargins
        Task { await loader.prefetch(around: page, ahead: ahead, sizing: sizing, trim: trim) }
    }

    /// Writing the library JSON on every page turn would hammer the disk during a fast read.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.persistProgress()
        }
    }

    private func persistProgress() {
        guard pageCount > 0 else { return }
        library.recordProgress(currentPage, pageCount: pageCount, for: comic)
    }
}
