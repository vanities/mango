import CoreGraphics
import Foundation
import Observation
import SwiftUI
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
    var mode: ReaderMode { didSet { library.setMode(mode, for: comic); rebuildGroups() } }
    /// Visible on open so the way out is obvious, then it gets out of the way on its own.
    var showsControls = true

    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var loader: PageLoader?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var hideControlsTask: Task<Void, Never>?

    init(comic: Comic, library: LibraryModel, settings: AppSettings) {
        self.comic = comic
        self.library = library
        self.settings = settings
        self.direction = library.direction(for: comic)
        self.mode = library.mode(for: comic)
    }

    deinit {
        saveTask?.cancel()
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

    func open(maxPixel: Int) async {
        let sw = Stopwatch()
        isOpening = true
        openError = nil
        do {
            let archive = try await library.openArchive(comic)
            pageCount = archive.pageCount
            let prefetch = settings.prefetchCount
            loader = PageLoader(archive: archive, maxPixel: maxPixel, capacity: prefetch * 2 + 3)
            rebuildGroups()
            // Pick up where this comic was left off.
            if let saved = library.progress(for: comic), saved.page > 0, saved.page < pageCount, !saved.finished {
                groupIndex = SpreadLayout.groupIndex(containing: saved.page, in: groups)
                Logger.reader.info("[reader] resumed \(self.comic.title, privacy: .public) at page \(saved.page + 1)")
            }
            isOpening = false
            Logger.reader.info("[reader] opened \(self.comic.title, privacy: .public) pages=\(self.pageCount) in \(sw.ms, format: .fixed(precision: 0))ms")
            prefetchAround()
            keepControlsAwake()
        } catch {
            isOpening = false
            openError = error.localizedDescription
            Logger.reader.error("[reader] open failed for \(self.comic.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func close() {
        saveTask?.cancel()
        hideControlsTask?.cancel()
        persistProgress()
        let loader = self.loader
        Task { await loader?.cancelAll() }
        Logger.reader.info("[reader] closed \(self.comic.title, privacy: .public) at page \(self.currentPage + 1)")
    }

    // MARK: Pages

    func image(at index: Int) async -> CGImage? {
        guard let loader, index >= 0, index < pageCount else { return nil }
        do {
            let image = try await loader.page(at: index)
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

    /// "Forward" always means further into the book. Right-to-left flips which screen edge that is,
    /// which the view handles — this stays in page order.
    func advance() { goToGroup(groupIndex + 1) }
    func retreat() { goToGroup(groupIndex - 1) }

    func goToGroup(_ index: Int) {
        guard groups.indices.contains(index) else { return }
        groupIndex = index
    }

    func goToPage(_ page: Int) {
        goToGroup(SpreadLayout.groupIndex(containing: page, in: groups))
    }

    var isAtStart: Bool { groupIndex <= 0 }
    var isAtEnd: Bool { groupIndex >= groups.count - 1 }

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
        prefetchAround()
        scheduleSave()
        if showsControls { keepControlsAwake() }
    }

    private func prefetchAround() {
        guard let loader else { return }
        let page = currentPage
        let ahead = settings.prefetchCount
        Task { await loader.prefetch(around: page, ahead: ahead) }
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
