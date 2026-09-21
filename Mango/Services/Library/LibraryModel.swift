import CoreGraphics
import Foundation
import Observation
import WidgetKit
import os

/// The one source of truth the UI reads from.
///
/// The library is *derived*: every scan rebuilds `comics` from what's on disk and on the share.
/// Everything the user did — where they are in a book, corrections, chosen covers — lives in
/// `state` keyed by the stable `Comic.id`, so a rescan never destroys it.
@MainActor @Observable
final class LibraryModel {
    private(set) var state: LibraryState
    private(set) var series: [Series] = []
    private(set) var isScanning = false
    /// Set by Siri, Shortcuts or a widget tap; the library view opens it and clears it.
    var requestedComic: Comic?
    private(set) var scanStatus: String?
    var lastError: String?

    @ObservationIgnored let store: LibraryStore
    @ObservationIgnored let covers: CoverStore
    @ObservationIgnored let settings: AppSettings

    /// Resolved security-scoped roots, held for the app's lifetime so scanning and reading can
    /// both reach the files. The scope is released in `removeSource`.
    @ObservationIgnored private var roots: [UUID: URL] = [:]
    @ObservationIgnored private var scopedURLs: [UUID: URL] = [:]
    @ObservationIgnored private var clients: [UUID: NASClient] = [:]
    @ObservationIgnored private var coverTask: Task<Void, Never>?
    @ObservationIgnored private let cloud = CloudSync()

    init(store: LibraryStore = LibraryStore(), covers: CoverStore = CoverStore(), settings: AppSettings) {
        self.store = store
        self.covers = covers
        self.settings = settings
        self.state = store.loadLibrary()
        ensureDocumentsSource()
        cloud.onExternalChange = { [weak self] in self?.mergeFromCloud() }
        cloud.start()
        mergeFromCloud()
        rebuildSeries()
        Logger.library.info("[library] loaded sources=\(self.state.sources.count) comics=\(self.state.comics.count) progress=\(self.state.progress.count)")
    }

    // MARK: Sources

    /// "Mango's folder in Files" — always present, never removable.
    private func ensureDocumentsSource() {
        guard !state.sources.contains(where: { $0.kind == .appDocuments }) else { return }
        state.sources.insert(LibrarySource(id: UUID(), kind: .appDocuments, displayName: "On My Device",
                                           bookmark: nil, addedAt: Date()), at: 0)
        save()
    }

    func addFolderSource(_ url: URL) {
        do {
            let bookmark = try BookmarkStore.makeBookmark(for: url)
            let source = LibrarySource(id: UUID(), kind: .folder, displayName: url.lastPathComponent,
                                       bookmark: bookmark, addedAt: Date())
            state.sources.append(source)
            save()
            Logger.library.info("[library] added folder source \(source.displayName, privacy: .public)")
            Task { await scan() }
        } catch {
            lastError = error.localizedDescription
            Logger.library.error("[library] couldn't bookmark \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func removeSource(_ source: LibrarySource) {
        guard source.isRemovable else { return }
        if let url = scopedURLs[source.id] {
            url.stopAccessingSecurityScopedResource()
            scopedURLs[source.id] = nil
        }
        roots[source.id] = nil
        state.sources.removeAll { $0.id == source.id }
        state.comics.removeAll { $0.sourceID == source.id }
        save()
        rebuildSeries()
        Logger.library.info("[library] removed source \(source.displayName, privacy: .public)")
    }

    /// The on-disk root for a source, starting security-scoped access the first time.
    func root(for source: LibrarySource) -> URL? {
        if let cached = roots[source.id] { return cached }
        switch source.kind {
        case .appDocuments:
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            roots[source.id] = url
            return url
        case .folder, .file:
            guard let bookmark = source.bookmark else { return nil }
            do {
                let resolved = try BookmarkStore.resolveAndStartAccess(bookmark)
                roots[source.id] = resolved.url
                if resolved.didStartAccess { scopedURLs[source.id] = resolved.url }
                return resolved.url
            } catch {
                Logger.library.error("[library] stale bookmark for \(source.displayName, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        case .smb:
            return nil
        }
    }

    // MARK: NAS

    func addServer(_ server: NASServer, password: String) {
        try? KeychainStore.set(password, for: server.id.uuidString)
        state.nasServers.append(server)
        let source = LibrarySource(id: UUID(), kind: .smb, displayName: server.name, bookmark: nil,
                                   addedAt: Date(), serverID: server.id)
        state.sources.append(source)
        save()
        Logger.nas.info("[nas] added server \(server.name, privacy: .public) at \(server.displayLocation, privacy: .public)")
        Task { await scan() }
    }

    func removeServer(_ server: NASServer) {
        KeychainStore.delete(server.id.uuidString)
        let sources = state.sources.filter { $0.serverID == server.id }
        for source in sources {
            state.comics.removeAll { $0.sourceID == source.id }
        }
        state.sources.removeAll { $0.serverID == server.id }
        state.nasServers.removeAll { $0.id == server.id }
        clients[server.id] = nil
        save()
        rebuildSeries()
    }

    func client(for serverID: UUID) -> NASClient? {
        if let existing = clients[serverID] { return existing }
        guard let server = state.nasServers.first(where: { $0.id == serverID }),
              let password = KeychainStore.get(server.id.uuidString)
        else {
            Logger.nas.error("[nas] no stored credential for server \(serverID.uuidString, privacy: .public)")
            return nil
        }
        guard let client = try? NASClient(server: server, password: password) else { return nil }
        clients[serverID] = client
        return client
    }

    // MARK: Scanning

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false; scanStatus = nil }
        let sw = Stopwatch()

        var found: [Comic] = []
        for index in state.sources.indices {
            let source = state.sources[index]
            // Demo mode photographs a generated library: skip shares and picked folders so
            // nobody's real shelf ends up in a screenshot. Their sources stay configured.
            if settings.demoMode, source.kind != .appDocuments { continue }
            scanStatus = "Scanning \(source.displayName)…"
            var result = LibraryScanner.Result()

            switch source.kind {
            case .appDocuments, .folder, .file:
                guard let root = root(for: source) else {
                    state.sources[index].lastError = "Couldn't reach this folder any more."
                    continue
                }
                result = await Task.detached(priority: .userInitiated) {
                    LibraryScanner.scanLocal(source: source, root: root)
                }.value
            case .smb:
                guard let serverID = source.serverID, let client = client(for: serverID) else {
                    state.sources[index].lastError = "No saved credentials for this server."
                    continue
                }
                result = await LibraryScanner.scanRemote(source: source, client: client)
            }

            state.sources[index].lastScanAt = Date()
            state.sources[index].lastScanBookCount = result.comics.count
            state.sources[index].lastScanFileCount = result.fileCount
            state.sources[index].lastError = result.error
            found.append(contentsOf: result.comics)
        }

        // Carry forward everything the user set, and keep page counts already discovered so a
        // rescan doesn't make every book claim it has no pages again.
        let previous = Dictionary(state.comics.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        state.comics = found.map { comic in
            var merged = comic
            if let old = previous[comic.id] {
                merged.pageCount = old.pageCount
                merged.coverID = old.coverID
                merged.addedAt = old.addedAt
            }
            // Precedence: filename guess < what the archive says about itself < what the user
            // typed. ComicInfo is only known once an archive has been opened, so it's kept in
            // the state and reapplied here, since a scan never opens anything.
            if let info = state.comicInfo[comic.id] {
                merged = info.applied(to: merged)
            }
            if let override = state.overrides[comic.id] {
                merged = override.applied(to: merged)
            }
            if let custom = state.customCovers[comic.id] {
                merged.coverID = custom
            }
            return merged
        }
        adoptStateFromRemoteTwins()
        mergeFromCloud()
        save()
        rebuildSeries()
        Logger.library.info("[library] scan complete: \(self.state.comics.count) comics, \(self.series.count) series in \(sw.seconds, format: .fixed(precision: 2))s")
        startCoverBackfill()
    }

    /// Source ids that live on a share rather than on this device.
    var remoteSourceIDs: Set<UUID> {
        Set(state.sources.filter(\.isRemote).map(\.id))
    }

    /// What the user should actually see: a downloaded copy replaces its remote twin.
    var visibleComics: [Comic] {
        LibraryDedupe.visible(comics: state.comics, remoteSourceIDs: remoteSourceIDs, hidden: state.hiddenComicIDs)
    }

    /// True when this comic is a local copy of something that also lives on a share.
    func isDownloadedCopy(_ comic: Comic) -> Bool {
        LibraryDedupe.isDownloadedCopy(comic, comics: state.comics, remoteSourceIDs: remoteSourceIDs)
    }

    private func rebuildSeries() {
        series = SeriesGrouper.group(visibleComics)
    }

    private func adoptStateFromRemoteTwins() {
        let adopted = state.adoptStateFromRemoteTwins(remoteSourceIDs: remoteSourceIDs)
        if adopted > 0 {
            Logger.library.info("[library] carried the reading position to \(adopted) downloaded copy/copies")
        }
    }

    // MARK: Opening

    /// Resolves where a comic's bytes live. Local files need the source's security scope, which
    /// `root(for:)` is already holding.
    func location(for comic: Comic) -> ComicLocation? {
        guard let source = state.sources.first(where: { $0.id == comic.sourceID }) else { return nil }
        switch source.kind {
        case .appDocuments, .folder, .file:
            guard let root = root(for: source) else { return nil }
            return .local(root.appending(path: comic.relativePath))
        case .smb:
            guard let serverID = source.serverID, let client = client(for: serverID) else { return nil }
            return .remote(client: client, relativePath: comic.relativePath, size: comic.totalBytes)
        }
    }

    /// Opens a reflowable book. Same zip machinery as a comic, different reader on top.
    func openNovel(_ comic: Comic) async throws -> EPUBDocument {
        guard let location = location(for: comic) else { throw ArchiveError.noPages(comic.title) }
        let reader: any RandomAccessReader
        switch location {
        case .local(let url):
            reader = LocalFileReader(url: url)
        case .remote(let client, let path, let size):
            reader = RemoteFileReader(client: client, relativePath: path, knownLength: size)
        }
        let document = try await EPUBDocument.open(reader: reader, displayName: comic.title)
        noteOpened(comic, pageCount: document.chapterCount)
        await ensureNovelCover(for: comic, using: document)
        return document
    }

    private func ensureNovelCover(for comic: Comic, using document: EPUBDocument) async {
        let coverID = state.customCovers[comic.id] ?? CoverStore.coverID(for: comic)
        guard !covers.exists(coverID) else {
            setCoverID(coverID, for: comic)
            return
        }
        guard let image = await document.coverImage(maxPixel: CoverStore.maxPixel) else { return }
        if covers.store(image, as: coverID) { setCoverID(coverID, for: comic) }
    }

    func recordNovelProgress(chapter: Int, chapterCount: Int, fraction: Double, for comic: Comic) {
        var entry = state.progress[comic.id] ?? ReadingProgress()
        guard entry.page != chapter || abs(entry.fractionInChapter - fraction) > 0.005 else { return }
        entry.page = chapter
        entry.pageCount = chapterCount
        entry.fractionInChapter = fraction
        entry.updatedAt = Date()
        state.progress[comic.id] = entry
        state.lastComicID = comic.id
        save()
    }

    func openArchive(_ comic: Comic) async throws -> any ComicArchive {
        guard let location = location(for: comic) else {
            throw ArchiveError.noPages(comic.title)
        }
        let archive = try await ArchiveOpener.open(comic, at: location)
        noteOpened(comic, pageCount: archive.pageCount)
        await absorbComicInfo(for: comic, from: archive)
        await ensureCover(for: comic, using: archive)
        return archive
    }

    /// Reads the archive's ComicInfo.xml the first time it's opened and folds it in. Rescans
    /// never open archives, so it's kept in the state and reapplied from there.
    private func absorbComicInfo(for comic: Comic, from archive: any ComicArchive) async {
        guard state.comicInfo[comic.id] == nil, let info = await archive.comicInfo() else { return }
        state.comicInfo[comic.id] = info
        if let index = state.comics.firstIndex(where: { $0.id == comic.id }) {
            var updated = info.applied(to: state.comics[index])
            if let override = state.overrides[comic.id] { updated = override.applied(to: updated) }
            state.comics[index] = updated
        }
        Logger.archive.info("[comicinfo] \(comic.title, privacy: .public): series=\(info.series ?? "-", privacy: .public) vol=\(info.volume.map { Formatting.number($0) } ?? "-", privacy: .public) manga=\(info.manga?.rawValue ?? "-", privacy: .public)")
        save()
        rebuildSeries()
    }

    /// First open is when we learn how many pages a comic actually has.
    private func noteOpened(_ comic: Comic, pageCount: Int) {
        guard let index = state.comics.firstIndex(where: { $0.id == comic.id }) else { return }
        if state.comics[index].pageCount != pageCount {
            state.comics[index].pageCount = pageCount
            save()
            rebuildSeries()
        }
    }

    private func ensureCover(for comic: Comic, using archive: any ComicArchive) async {
        let coverID = state.customCovers[comic.id] ?? CoverStore.coverID(for: comic)
        guard !covers.exists(coverID) else {
            setCoverID(coverID, for: comic)
            return
        }
        if await covers.extractCover(from: archive, as: coverID) {
            setCoverID(coverID, for: comic)
        }
    }

    private func setCoverID(_ coverID: String, for comic: Comic) {
        guard let index = state.comics.firstIndex(where: { $0.id == comic.id }),
              state.comics[index].coverID != coverID else { return }
        state.comics[index].coverID = coverID
        save()
        rebuildSeries()
    }

    private(set) var coversRemaining = 0

    /// Fills in every missing cover in the background, a batch at a time, so the grid populates
    /// progressively instead of stalling behind a few hundred archive opens. Cheap even for a
    /// remote library: a cover is the archive index plus page one, not the whole volume.
    func startCoverBackfill() {
        coverTask?.cancel()
        coverTask = Task { [weak self] in
            await self?.backfillCovers()
        }
    }

    func backfillCovers(batchSize: Int = 6) async {
        var done = 0
        let sw = Stopwatch()
        while !Task.isCancelled {
            let visible = visibleComics
            let missing = Array(visible.filter { $0.coverID == nil }.prefix(batchSize))
            coversRemaining = visible.count { $0.coverID == nil }
            guard !missing.isEmpty else { break }

            for comic in missing {
                if Task.isCancelled { break }
                guard let location = location(for: comic) else {
                    // Nothing to read it from — mark it so the loop doesn't spin on it forever.
                    markCoverAttempted(comic)
                    continue
                }
                if comic.isNovel {
                    guard let document = try? await openNovel(comic) else {
                        markCoverAttempted(comic)
                        continue
                    }
                    _ = document
                    if state.comics.first(where: { $0.id == comic.id })?.coverID == nil {
                        markCoverAttempted(comic)
                    }
                    done += 1
                    continue
                }
                guard let archive = try? await ArchiveOpener.open(comic, at: location) else {
                    markCoverAttempted(comic)
                    continue
                }
                noteOpened(comic, pageCount: archive.pageCount)
                await absorbComicInfo(for: comic, from: archive)
                await ensureCover(for: comic, using: archive)
                if state.comics.first(where: { $0.id == comic.id })?.coverID == nil {
                    markCoverAttempted(comic)
                }
                done += 1
            }
            // Let the UI breathe between batches; over SMB this also keeps one archive open at
            // a time rather than hammering the share.
            await Task.yield()
        }
        coversRemaining = 0
        if done > 0 {
            Logger.cover.info("[cover] backfill finished: \(done) cover(s) in \(sw.seconds, format: .fixed(precision: 1))s")
        }
    }

    /// Records a cover id for a comic whose page one couldn't be read, so the backfill loop
    /// makes progress instead of retrying the same broken file forever. A rescan clears it.
    private func markCoverAttempted(_ comic: Comic) {
        guard let index = state.comics.firstIndex(where: { $0.id == comic.id }) else { return }
        state.comics[index].coverID = CoverStore.coverID(for: comic)
        Logger.cover.notice("[cover] no cover for \(comic.title, privacy: .public) — not retrying until rescan")
    }

    // MARK: Progress

    func progress(for comic: Comic) -> ReadingProgress? { state.progress[comic.id] }

    func recordProgress(_ page: Int, pageCount: Int, for comic: Comic) {
        var entry = state.progress[comic.id] ?? ReadingProgress()
        guard entry.page != page || entry.pageCount != pageCount else { return }
        entry.page = page
        entry.pageCount = pageCount
        entry.updatedAt = Date()
        if page >= pageCount - 1, pageCount > 0 { entry.finished = true }
        state.progress[comic.id] = entry
        state.lastComicID = comic.id
        save()
    }

    func setFinished(_ finished: Bool, for comic: Comic) {
        var entry = state.progress[comic.id] ?? ReadingProgress()
        entry.finished = finished
        entry.updatedAt = Date()
        if finished, entry.pageCount > 0 { entry.page = entry.pageCount - 1 }
        if !finished { entry.page = 0 }
        state.progress[comic.id] = entry
        save()
    }

    func resetProgress(for comic: Comic) {
        state.progress[comic.id] = nil
        save()
    }

    // MARK: Reader preferences

    /// Per-comic override, else the series-wide choice, else the app default. Manga is RTL, so
    /// setting it once on volume 1 should carry to volume 2 without asking again.
    func direction(for comic: Comic) -> ReadingDirection {
        if let specific = state.overrides[comic.id]?.direction { return specific }
        if let key = comic.series.map({ SeriesGrouper.key(forName: $0) }), let shelf = state.seriesDirection[key] {
            return shelf
        }
        // The archive saying "YesAndRightToLeft" beats a global default someone set once.
        if let fromFile = state.comicInfo[comic.id]?.manga?.direction { return fromFile }
        return settings.defaultDirection
    }

    func setDirection(_ direction: ReadingDirection, for comic: Comic, wholeSeries: Bool) {
        if wholeSeries, let key = comic.series.map({ SeriesGrouper.key(forName: $0) }) {
            state.seriesDirection[key] = direction
            state.overrides[comic.id]?.direction = nil
        } else {
            var override = state.overrides[comic.id] ?? ComicOverride()
            override.direction = direction
            state.overrides[comic.id] = override
        }
        save()
    }

    func mode(for comic: Comic) -> ReaderMode {
        state.overrides[comic.id]?.mode ?? settings.defaultMode
    }

    func setMode(_ mode: ReaderMode, for comic: Comic) {
        var override = state.overrides[comic.id] ?? ComicOverride()
        override.mode = mode
        state.overrides[comic.id] = override
        save()
    }

    func setOverride(_ override: ComicOverride, for comic: Comic) {
        if override.isEmpty {
            state.overrides[comic.id] = nil
        } else {
            state.overrides[comic.id] = override
        }
        if let index = state.comics.firstIndex(where: { $0.id == comic.id }) {
            state.comics[index] = override.applied(to: state.comics[index])
        }
        save()
        rebuildSeries()
    }

    func setHidden(_ hidden: Bool, for comic: Comic) {
        if hidden { state.hiddenComicIDs.insert(comic.id) } else { state.hiddenComicIDs.remove(comic.id) }
        save()
        rebuildSeries()
    }

    // MARK: Persistence

    private func save() {
        do {
            try store.saveLibrary(state)
        } catch {
            Logger.store.error("[store] save failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
        pushToCloud()
    }

    // MARK: iCloud

    /// Folds in anything another device wrote more recently. Positions are matched by relative
    /// path, so a book only syncs to devices that have the same file in the same place.
    private func mergeFromCloud() {
        var changed = false
        if let remote = cloud.load([String: ReadingProgress].self, .progress), !remote.isEmpty {
            let merged = ProgressSync.merged(local: state.progress, comics: state.comics, cloud: remote)
            if merged != state.progress {
                let count = merged.filter { state.progress[$0.key] != $0.value }.count
                state.progress = merged
                changed = true
                Logger.store.info("[cloud] took \(count) newer position(s) from another device")
            }
        }
        if let remote = cloud.load([String: Int].self, .ratings) {
            let merged = CollectionSync.mergedRatings(local: state.ratings, comics: state.comics, cloud: remote)
            if merged != state.ratings { state.ratings = merged; changed = true }
        }
        if let remote = cloud.load([String: [Bookmark]].self, .bookmarks) {
            let merged = CollectionSync.mergedBookmarks(local: state.bookmarks, comics: state.comics, cloud: remote)
            if merged != state.bookmarks { state.bookmarks = merged; changed = true }
        }
        if let remote = cloud.load([ReadingLogEntry].self, .readingLog) {
            let merged = CollectionSync.mergedLog(local: state.readingLog, cloud: remote)
            if merged != state.readingLog { state.readingLog = merged; changed = true }
        }
        guard changed else { return }
        try? store.saveLibrary(state)
        rebuildSeries()
    }

    private func pushToCloud() {
        let progress = cloud.load([String: ReadingProgress].self, .progress) ?? [:]
        cloud.save(ProgressSync.cloudSnapshot(local: state.progress, comics: state.comics, existingCloud: progress), .progress)
        let ratings = cloud.load([String: Int].self, .ratings) ?? [:]
        cloud.save(CollectionSync.ratingsSnapshot(local: state.ratings, comics: state.comics, existingCloud: ratings), .ratings)
        let marks = cloud.load([String: [Bookmark]].self, .bookmarks) ?? [:]
        cloud.save(CollectionSync.bookmarksSnapshot(local: state.bookmarks, comics: state.comics, existingCloud: marks), .bookmarks)
        let log = cloud.load([ReadingLogEntry].self, .readingLog) ?? []
        cloud.save(CollectionSync.mergedLog(local: state.readingLog, cloud: log), .readingLog)
        pushActivity()
    }

    // MARK: Opening from outside the app

    static let deepLinkScheme = "mango"

    static func deepLink(for comic: Comic) -> URL? {
        var components = URLComponents()
        components.scheme = deepLinkScheme
        components.host = "open"
        components.path = "/" + comic.id
        return components.url
    }

    /// `mango://open/<comic id>`, or `mango://continue` for whatever you were last reading.
    func handleDeepLink(_ url: URL) {
        guard url.scheme == Self.deepLinkScheme else { return }
        Logger.ui.info("[deeplink] \(url.absoluteString, privacy: .public)")
        switch url.host {
        case "continue":
            requestedComic = lastRead
        case "open":
            let id = String(url.path.dropFirst()).removingPercentEncoding ?? String(url.path.dropFirst())
            requestedComic = visibleComics.first { $0.id == id }
        default:
            break
        }
    }

    func comic(id: String) -> Comic? { visibleComics.first { $0.id == id } }

    // MARK: Reading activity

    /// Keeps the session log bounded: two years of detail is plenty for Stats, and the file
    /// is loaded on every launch.
    private static let sessionRetention: TimeInterval = 730 * 86_400

    func recordSession(_ session: ReadingSession) {
        state.sessions.append(session)
        let cutoff = Date().addingTimeInterval(-Self.sessionRetention)
        state.sessions.removeAll { $0.startedAt < cutoff }
        Logger.library.info("[activity] \(Durations.short(session.activeSeconds), privacy: .public) in \(session.seriesName, privacy: .public), \(session.pagesTurned) pages")
        save()
    }

    /// Day totals from every device: this one's live sessions plus the other devices' slots.
    var allDayActivity: [String: DayActivity] {
        var days = DayKey.rollUp(state.sessions)
        let others = cloud.load([String: [String: DayActivity]].self, .activity) ?? [:]
        for (device, deviceDays) in others where device != settings.deviceID {
            for (key, value) in deviceDays {
                var day = days[key] ?? DayActivity()
                day.seconds += value.seconds
                day.pages += value.pages
                day.sessions += value.sessions
                days[key] = day
            }
        }
        return days
    }

    var activityStats: ActivityStats {
        ActivityStats.build(days: allDayActivity, sessions: state.sessions)
    }

    private func pushActivity() {
        var all = cloud.load([String: [String: DayActivity]].self, .activity) ?? [:]
        let cutoff = DayKey.string(for: Date().addingTimeInterval(-Self.sessionRetention))
        all[settings.deviceID] = DayKey.rollUp(state.sessions).filter { $0.key >= cutoff }
        cloud.save(all, .activity)
    }

    // MARK: Widget

    /// Hands the widget what you're reading. Called when a book closes rather than on every
    /// page turn: the widget is what you look at when you're *not* in the app.
    func publishWidgetSnapshot() {
        guard let comic = lastRead else {
            SharedReading.write(nil)
            SharedReading.writeCover(nil)
            WidgetCenter.shared.reloadTimelines(ofKind: "ContinueReading")
            return
        }
        let progress = state.progress[comic.id]
        SharedReading.write(ReadingSnapshot(
            comicID: comic.id,
            title: [comic.numberLabel, comic.subtitle].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? comic.title,
            series: comic.displaySeries,
            positionLabel: progress.map { comic.isNovel ? $0.novelLabel : $0.label } ?? "Not started",
            fraction: progress?.fraction ?? 0,
            isNovel: comic.isNovel,
            updatedAt: progress?.updatedAt ?? .now
        ))
        if let coverID = comic.coverID {
            SharedReading.writeCover(try? Data(contentsOf: covers.url(for: coverID)))
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "ContinueReading")
        Logger.ui.info("[widget] published \(comic.title, privacy: .public)")
    }

    // MARK: Bookmarks, ratings, reading log

    func bookmarks(for comic: Comic) -> [Bookmark] { state.bookmarks[comic.id] ?? [] }

    func addBookmark(page: Int, fraction: Double? = nil, note: String = "", to comic: Comic) {
        var list = state.bookmarks[comic.id] ?? []
        // One mark per spot: tapping twice on the same page shouldn't make two.
        guard !list.contains(where: { $0.page == page && abs(($0.fraction ?? 0) - (fraction ?? 0)) < 0.02 }) else { return }
        list.append(Bookmark(page: page, fraction: fraction, note: note))
        state.bookmarks[comic.id] = list.sorted { ($0.page, $0.fraction ?? 0) < ($1.page, $1.fraction ?? 0) }
        Logger.library.info("[bookmark] added at \(page + 1) in \(comic.title, privacy: .public)")
        save()
    }

    func removeBookmark(_ bookmark: Bookmark, from comic: Comic) {
        state.bookmarks[comic.id]?.removeAll { $0.id == bookmark.id }
        if state.bookmarks[comic.id]?.isEmpty == true { state.bookmarks[comic.id] = nil }
        save()
    }

    func rating(for comic: Comic) -> Int? { state.ratings[comic.id] }

    func setRating(_ stars: Int?, for comic: Comic) {
        if let stars, (1...5).contains(stars) {
            state.ratings[comic.id] = stars
        } else {
            state.ratings[comic.id] = nil
        }
        save()
    }

    func logBook(_ entry: ReadingLogEntry) {
        state.readingLog.removeAll { $0.id == entry.id }
        state.readingLog.append(entry)
        state.readingLog.sort { $0.finishedAt > $1.finishedAt }
        save()
    }

    func removeLogEntry(_ entry: ReadingLogEntry) {
        state.readingLog.removeAll { $0.id == entry.id }
        save()
    }
}
