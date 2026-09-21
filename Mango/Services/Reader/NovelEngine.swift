import Foundation
import Observation
import SwiftUI
import os

/// Drives one light-novel reading session.
///
/// The comic reader counts pages; a reflowable book has none — the "page" depends on the font
/// size and the screen. Position is therefore a chapter plus how far down it you are, and the
/// overall percentage weights chapters by their byte size, because chapter 3 of 40 is not 7.5%
/// of a book when chapter 3 is the prologue.
@MainActor @Observable
final class NovelEngine {
    let comic: Comic

    private(set) var isOpening = true
    private(set) var openError: String?
    private(set) var chapters: [EPUBSpineItem] = []
    private(set) var bookTitle: String?
    private(set) var author: String?

    var chapterIndex = 0 { didSet { onChapterChanged() } }
    /// 0...1 down the current chapter, reported by the web view as it scrolls.
    var scrollFraction: Double = 0 { didSet { scheduleSave() } }
    var showsControls = true
    private(set) var reachedEnd = false
    @ObservationIgnored var onReachedEnd: (@MainActor () -> Void)?

    @ObservationIgnored private(set) var document: EPUBDocument?
    @ObservationIgnored private var weights: [Double] = []
    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    init(comic: Comic, library: LibraryModel, settings: AppSettings) {
        self.comic = comic
        self.library = library
        self.settings = settings
    }

    deinit {
        saveTask?.cancel()
        hideTask?.cancel()
    }

    var chapterCount: Int { chapters.count }
    var isAtStart: Bool { chapterIndex <= 0 && scrollFraction <= 0.01 }
    var isAtLastChapter: Bool { chapterIndex >= chapters.count - 1 }

    /// Weighted percentage through the whole book.
    var progressFraction: Double {
        guard !weights.isEmpty, chapters.indices.contains(chapterIndex) else { return 0 }
        let before = weights.prefix(chapterIndex).reduce(0, +)
        return min(1, max(0, before + weights[chapterIndex] * scrollFraction))
    }

    var positionLabel: String {
        guard chapterCount > 0 else { return "" }
        return "Chapter \(chapterIndex + 1) of \(chapterCount) · \(Int(progressFraction * 100))%"
    }

    var currentChapter: EPUBSpineItem? {
        chapters.indices.contains(chapterIndex) ? chapters[chapterIndex] : nil
    }

    // MARK: Opening

    func open() async {
        let sw = Stopwatch()
        isOpening = true
        openError = nil
        do {
            let document = try await library.openNovel(comic)
            self.document = document
            chapters = document.spine
            bookTitle = document.package.title
            author = document.package.creator
            weights = await document.chapterWeights()

            // Resume: page holds the chapter, and the fraction rides along in the override.
            if let saved = library.progress(for: comic), saved.isStarted, !saved.finished,
               saved.page < chapters.count {
                chapterIndex = saved.page
                scrollFraction = saved.fractionInChapter
            }
            isOpening = false
            Logger.reader.info("[novel] opened \(self.comic.title, privacy: .public) chapters=\(self.chapters.count) in \(sw.ms, format: .fixed(precision: 0))ms")
            keepControlsAwake()
        } catch {
            isOpening = false
            openError = error.localizedDescription
            Logger.reader.error("[novel] open failed for \(self.comic.title, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func close() {
        saveTask?.cancel()
        hideTask?.cancel()
        persist()
        library.publishWidgetSnapshot()
        Logger.reader.info("[novel] closed \(self.comic.title, privacy: .public) at chapter \(self.chapterIndex + 1)")
    }

    // MARK: Navigation

    func nextChapter() {
        guard !isAtLastChapter else {
            notifyReachedEnd()
            return
        }
        // A bookmark jump's landing point applies to that one load only; turning the chapter
        // afterwards must start at the top, not wherever the bookmark was.
        pendingJumpFraction = 0
        scrollFraction = 0
        chapterIndex += 1
    }

    func previousChapter() {
        guard chapterIndex > 0 else { return }
        pendingJumpFraction = 0
        scrollFraction = 0
        chapterIndex -= 1
    }

    func goToChapter(_ index: Int) {
        guard chapters.indices.contains(index), index != chapterIndex else { return }
        pendingJumpFraction = 0
        scrollFraction = 0
        chapterIndex = index
    }

    func notifyReachedEnd() {
        guard !reachedEnd, !isOpening, !chapters.isEmpty else { return }
        Logger.reader.info("[novel] reached the end of \(self.comic.title, privacy: .public)")
        reachedEnd = true
        onReachedEnd?()
    }

    // MARK: Bookmarks

    var bookmarks: [Bookmark] { library.bookmarks(for: comic) }

    var isHereBookmarked: Bool {
        bookmarks.contains { $0.page == chapterIndex && abs(($0.fraction ?? 0) - scrollFraction) < 0.02 }
    }

    func toggleBookmark() {
        if let here = bookmarks.first(where: { $0.page == chapterIndex && abs(($0.fraction ?? 0) - scrollFraction) < 0.02 }) {
            library.removeBookmark(here, from: comic)
        } else {
            library.addBookmark(page: chapterIndex, fraction: scrollFraction, to: comic)
        }
        keepControlsAwake()
    }

    func go(to bookmark: Bookmark) {
        guard chapters.indices.contains(bookmark.page) else { return }
        pendingJumpFraction = bookmark.fraction ?? 0
        if chapterIndex == bookmark.page {
            scrollFraction = pendingJumpFraction
        } else {
            chapterIndex = bookmark.page
        }
    }

    func removeBookmark(_ bookmark: Bookmark) {
        library.removeBookmark(bookmark, from: comic)
    }

    /// Where to land in a chapter being jumped to from a bookmark, handed to the web view once.
    var pendingJumpFraction: Double = 0

    // MARK: Chrome

    func keepControlsAwake(for seconds: Double = 4.5) {
        showsControls = true
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth(duration: 0.25)) { self?.showsControls = false }
        }
    }

    func toggleControls() {
        hideTask?.cancel()
        if showsControls {
            withAnimation(.smooth(duration: 0.25)) { showsControls = false }
        } else {
            keepControlsAwake()
        }
    }

    // MARK: Internals

    private func onChapterChanged() {
        if showsControls { keepControlsAwake() }
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.persist()
        }
    }

    private func persist() {
        guard !chapters.isEmpty else { return }
        library.recordNovelProgress(chapter: chapterIndex, chapterCount: chapters.count,
                                    fraction: scrollFraction, for: comic)
    }
}
