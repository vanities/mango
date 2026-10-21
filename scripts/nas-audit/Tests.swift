import SwiftUI
import ShelfKit
import WebKit
import XCTest
@testable import Mango

@MainActor
final class MangoNASAuditTests: XCTestCase {
    @Observable fileprivate final class Reading {
        var chapter = 0
        var turns = 0
        var fractions: [Double] = []
    }

    private struct Reader: View {
        let document: EPUBDocument
        let reading: Reading
        var body: some View {
            let chapter = reading.chapter
            return NovelWebView(document: document, chapterPath: document.spine[chapter % document.chapterCount].path,
                         fontScale: 0.8, dark: true, paged: true, tapToTurn: true,
                         fontFamily: "Georgia, serif", lineSpacing: 1.6, margin: 22,
                         restoreFraction: 0, isCurrentChapter: { reading.chapter == chapter }, onScroll: { reading.fractions.append($0) },
                         onTapMiddle: {}, onNextChapter: {
                             reading.turns += 1
                             reading.chapter += 1
                         }, onPreviousChapter: {
                             reading.turns += 1
                             reading.chapter += 1
                         }, onReachedBottom: {})
                .id(reading.chapter)
                .ignoresSafeArea()
        }
    }

    @MainActor private final class BackgroundTask {
        var expiration: (@Sendable () -> Void)?
        var completions: [Bool] = []
        lazy var execution = TransferBackgroundExecution(
            setExpirationHandler: { [weak self] in self?.expiration = $0 },
            complete: { [weak self] in self?.completions.append($0) })
        func expire() { expiration?() }
    }

    private func client() throws -> NASClient {
        try NASClient(server: NASServer(id: UUID(), name: "Local fixtures", host: "127.0.0.1", port: 1445,
                                       share: "AUDIT", path: "", username: "audit", addedAt: .now), password: "local-fixture-only")
    }

    func testPagedChaptersOverActualSMB() async throws {
        let client = try client()
        try await client.connect()
        let document = try await EPUBDocument.open(reader: RemoteFileReader(client: client, relativePath: "Audit Novel v01.epub"), displayName: "SMB fixture")
        XCTAssertEqual(document.chapterCount, 24)
        try await exerciseTransitions(document: document, steps: 100)
        await client.disconnect()
    }

    func testSMBDownloadCancelRetryAndRemoval() async throws {
        let client = try client()
        try await client.connect()
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Keep temporary state until the test host exits: cover backfills can finish later.
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = LibraryModel(store: LibraryStore(directory: root.appending(path: "state")),
                                   covers: CoverStore(directory: root.appending(path: "covers"), customDirectory: root.appending(path: "custom")),
                                   settings: AppSettings(defaults: defaults))
        let source = LibrarySource(id: UUID(), kind: .smb, displayName: "Local fixture SMB", addedAt: .now, serverID: client.server.id)
        let path = "Audit Comic v01.cbz"
        let size = try await client.fileSize(path)
        let comic = Comic(id: Comic.makeID(sourceID: source.id, relativePath: path), sourceID: source.id,
                          relativePath: path, kind: .archive, title: "Audit Comic", series: nil, volume: nil, chapter: nil,
                          author: nil, year: nil, subtitle: nil, pageCount: 8, totalBytes: size, addedAt: .now)
        library.mutateState { $0.sources.append(source); $0.nasServers.append(client.server); $0.comics = [comic] }
        library.clients[client.server.id] = client
        let manager = TransferManager(library: library, store: LibraryStore(directory: root.appending(path: "queue")), registersBackgroundTasks: false)
        let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: path)
        let partial = destination.appendingPathExtension("part")
        guard !FileManager.default.fileExists(atPath: destination.path), !FileManager.default.fileExists(atPath: partial.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        defer { try? FileManager.default.removeItem(at: destination); try? FileManager.default.removeItem(at: partial) }
        manager.download(comic)
        for _ in 0..<1000 where manager.jobs.first?.doneBytes == 0 { try await Task.sleep(for: .milliseconds(10)) }
        let id = try XCTUnwrap(manager.jobs.first?.id)
        manager.cancel(id)
        for _ in 0..<1000 where manager.jobs.first?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(manager.jobs.first?.state, .cancelled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let partialBytes = try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        XCTAssertGreaterThan(partialBytes, 0)
        XCTAssertLessThan(Int64(partialBytes), size)
        manager.retry(id)
        for _ in 0..<3000 where manager.jobs.first?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(manager.jobs.first?.state, .done, manager.jobs.first?.error ?? "")
        XCTAssertEqual(Int64(try Data(contentsOf: destination).count), size)
        for _ in 0..<1000 where library.isScanning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(library.downloadedCopy(of: comic))
        library.recordNovelProgress(chapter: 3, chapterCount: 8, fraction: 0.4, for: comic)
        XCTAssertEqual(library.removeDownload(of: comic), size)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(library.progress(for: comic)?.page, 3)
        await client.disconnect()
        let reconnected = try await client.fileSize(path)
        XCTAssertEqual(reconnected, size)
        await client.disconnect()
    }

    func testUnavailableRemoteFolderIsFailedNotSuccessful() async throws {
        for folder in ["Missing folder", "Empty pages"] {
            let client = try client()
            try await client.connect()
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            // Keep temporary state until the test host exits: cover backfills can finish later.
            let suite = UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let library = LibraryModel(store: LibraryStore(directory: root.appending(path: "state")), settings: AppSettings(defaults: defaults))
            let source = LibrarySource(id: UUID(), kind: .smb, displayName: "Local fixture SMB", addedAt: .now, serverID: client.server.id)
            let comic = Comic(id: Comic.makeID(sourceID: source.id, relativePath: folder), sourceID: source.id,
                              relativePath: folder, kind: .folder, title: "Missing fixture", series: nil, volume: nil, chapter: nil,
                              author: nil, year: nil, subtitle: nil, pageCount: 8, totalBytes: 8000, addedAt: .now)
            library.mutateState { $0.sources.append(source); $0.nasServers.append(client.server); $0.comics = [comic] }
            library.clients[client.server.id] = client
            let manager = TransferManager(library: library, store: LibraryStore(directory: root.appending(path: "queue")), registersBackgroundTasks: false)
            manager.download(comic)
            for _ in 0..<1000 where manager.jobs.first?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(manager.jobs.first?.state, .failed, "An unavailable directory must not be reported as downloaded")
            XCTAssertNotNil(manager.jobs.first?.error)
            await client.disconnect()
        }
    }

    func testServiceLossKeepsDownloadPartialAndRetryReconnects() async throws {
        let service = try FixtureServiceControl()
        try await service.setRunning(true)
        do {
            let client = try client()
            try await client.connect()
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            let suite = UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let library = LibraryModel(store: LibraryStore(directory: root.appending(path: "state")),
                                       covers: CoverStore(directory: root.appending(path: "covers"), customDirectory: root.appending(path: "custom")),
                                       settings: AppSettings(defaults: defaults))
            let source = LibrarySource(id: UUID(), kind: .smb, displayName: "Local fixture SMB", addedAt: .now, serverID: client.server.id)
            let path = "Audit Comic v01.cbz"
            let size = try await client.fileSize(path)
            let comic = Comic(id: Comic.makeID(sourceID: source.id, relativePath: path), sourceID: source.id,
                              relativePath: path, kind: .archive, title: "Service recovery fixture", series: nil, volume: nil, chapter: nil,
                              author: nil, year: nil, subtitle: nil, pageCount: 8, totalBytes: size, addedAt: .now)
            library.mutateState { $0.sources.append(source); $0.nasServers.append(client.server); $0.comics = [comic] }
            library.clients[client.server.id] = client
            let manager = TransferManager(library: library, store: LibraryStore(directory: root.appending(path: "queue")), registersBackgroundTasks: false)
            let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: path)
            let partial = destination.appendingPathExtension("part")
            guard !FileManager.default.fileExists(atPath: destination.path), !FileManager.default.fileExists(atPath: partial.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            defer { try? FileManager.default.removeItem(at: destination); try? FileManager.default.removeItem(at: partial) }
            let fixtures = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SMB_AUDIT_ROOT"] ?? "/tmp/mango-earmark-smb-fixtures")
            let fixture = fixtures.appending(path: path)
            let originalBytes = try Data(contentsOf: fixture)
            let originalModification = try FileManager.default.attributesOfItem(atPath: fixture.path)[.modificationDate] as? Date
            manager.download(comic)
            for _ in 0..<2000 where manager.jobs.first?.doneBytes == 0 { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertGreaterThan(manager.jobs.first?.doneBytes ?? 0, 0)
            let stopped = try await service.setRunning(false)
            for _ in 0..<2000 where manager.jobs.first?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(manager.jobs.first?.state, .failed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            let bytes = try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber
            XCTAssertGreaterThan(bytes?.int64Value ?? 0, 0)
            XCTAssertLessThan(bytes?.int64Value ?? size, size)
            let restarted = try await service.setRunning(true)
            XCTAssertGreaterThan(restarted.generation, stopped.generation)
            XCTAssertEqual(try Data(contentsOf: fixture), originalBytes, "Restart must preserve the source file")
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: fixture.path)[.modificationDate] as? Date, originalModification)
            manager.retry(try XCTUnwrap(manager.jobs.first?.id))
            for _ in 0..<3000 where manager.jobs.first?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(manager.jobs.first?.state, .done, manager.jobs.first?.error ?? "")
            XCTAssertEqual(try Data(contentsOf: destination), originalBytes)
            await client.disconnect()
        } catch {
            _ = try? await service.setRunning(true)
            throw error
        }
    }

    func testReplacingSameSizeRemoteComicDoesNotMixVersionsOnRetry() async throws {
        try await exerciseReplacement(growing: false, preserveTimestamp: false)
    }

    func testReplacingLargerRemoteComicRefreshesCachedSizeOnRetry() async throws {
        try await exerciseReplacement(growing: true, preserveTimestamp: false)
    }

    func testReplacingRemoteComicWithPreservedTimestampRestartsPartial() async throws {
        try await exerciseReplacement(growing: false, preserveTimestamp: true)
    }

    func testRemoteComicChangingDuringDownloadIsNotPublished() async throws {
        try await exerciseReplacement(growing: false, preserveTimestamp: false, whileDownloading: true)
    }

    private func exerciseReplacement(growing: Bool, preserveTimestamp: Bool, whileDownloading: Bool = false) async throws {
        let client = try client()
        try await client.connect()
        let fixtures = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SMB_AUDIT_ROOT"] ?? "/tmp/mango-earmark-smb-fixtures")
        let old = fixtures.appending(path: ".versions/Comic-old.cbz")
        let new = fixtures.appending(path: growing ? ".versions/Comic-grown.cbz" : ".versions/Comic-new.cbz")
        let oldBytes = try Data(contentsOf: old), newBytes = try Data(contentsOf: new)
        if growing { XCTAssertGreaterThan(newBytes.count, oldBytes.count) } else { XCTAssertEqual(oldBytes.count, newBytes.count) }
        XCTAssertNotEqual(oldBytes, newBytes)
        let path = "Replacement Comic v01.cbz"
        let remote = fixtures.appending(path: path)
        guard !FileManager.default.fileExists(atPath: remote.path) else { throw CocoaError(.fileWriteFileExists) }
        try FileManager.default.copyItem(at: old, to: remote)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000_000_000)], ofItemAtPath: remote.path)
        defer { try? FileManager.default.removeItem(at: remote) }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = LibraryModel(store: LibraryStore(directory: root.appending(path: "state")),
                                   covers: CoverStore(directory: root.appending(path: "covers"), customDirectory: root.appending(path: "custom")),
                                   settings: AppSettings(defaults: defaults))
        let source = LibrarySource(id: UUID(), kind: .smb, displayName: "Generated replacement", addedAt: .now, serverID: client.server.id)
        let comic = Comic(id: Comic.makeID(sourceID: source.id, relativePath: path), sourceID: source.id,
                          relativePath: path, kind: .archive, title: "Replacement fixture", series: nil, volume: nil, chapter: nil,
                          author: nil, year: nil, subtitle: nil, pageCount: 8, totalBytes: Int64(oldBytes.count), addedAt: .now)
        library.mutateState { $0.sources.append(source); $0.nasServers.append(client.server); $0.comics = [comic] }
        library.clients[client.server.id] = client
        let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: path)
        let partial = destination.appendingPathExtension("part")
        guard !FileManager.default.fileExists(atPath: destination.path), !FileManager.default.fileExists(atPath: partial.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        defer { try? FileManager.default.removeItem(at: destination); try? FileManager.default.removeItem(at: partial) }
        let manager = TransferManager(library: library, store: LibraryStore(directory: root.appending(path: "queue")), registersBackgroundTasks: false)
        manager.download(comic)
        for _ in 0..<2000 where manager.jobs.first?.doneBytes == 0 { try await Task.sleep(for: .milliseconds(10)) }
        let id = try XCTUnwrap(manager.jobs.first?.id)
        if !whileDownloading {
            manager.cancel(id)
            for _ in 0..<2000 where manager.jobs.first?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(manager.jobs.first?.state, .cancelled)
        }
        let partialSize = try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber
        XCTAssertGreaterThan(partialSize?.intValue ?? 0, 0)
        XCTAssertLessThan(partialSize?.intValue ?? oldBytes.count, oldBytes.count)
        try FileManager.default.removeItem(at: remote)
        try FileManager.default.copyItem(at: new, to: remote)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: preserveTimestamp ? 1_000_000_000 : 1_000_000_100)], ofItemAtPath: remote.path)
        let freshPrefix = try await client.readAll(path, maxBytes: 65_536)
        XCTAssertEqual(freshPrefix, newBytes.prefix(65_536), "The live source must already serve the replacement")
        if whileDownloading {
            for _ in 0..<3000 where manager.jobs.first?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(manager.jobs.first?.state, .failed)
            XCTAssertTrue(manager.jobs.first?.error?.contains("changed") == true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "A mixed version must stay partial")
        }
        manager.retry(id)
        for _ in 0..<3000 where manager.jobs.first?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(manager.jobs.first?.state, .done, manager.jobs.first?.error ?? "")
        XCTAssertEqual(manager.jobs.first?.totalBytes, Int64(newBytes.count))
        XCTAssertEqual(try Data(contentsOf: destination), newBytes, "An offline comic must contain one complete source version")
        XCTAssertFalse(FileManager.default.fileExists(atPath: DownloadPartial.metadataURL(for: partial).path))
        let archive = try await ZipComicArchive.open(reader: LocalFileReader(url: destination), displayName: "Replacement fixture")
        XCTAssertEqual(archive.pageCount, growing ? 9 : 8)
        let page = try await archive.page(at: 5, maxPixel: 400)
        XCTAssertGreaterThan(page.width, 0, "The page spanning the partial boundary must decode")
        await client.disconnect()
    }

    func testShortSMBDownloadMustNotBePublishedAsComplete() async throws {
        let client = try client()
        try await client.connect()
        let remoteURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SMB_AUDIT_ROOT"] ?? "/tmp/mango-earmark-smb-fixtures").appending(path: "Short Comic.cbz")
        try FileManager.default.copyItem(at: remoteURL.deletingLastPathComponent().appending(path: "Audit Comic v01.cbz"), to: remoteURL)
        defer { try? FileManager.default.removeItem(at: remoteURL) }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        // Keep temporary state until the test host exits: cover backfills can finish later.
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = LibraryModel(store: LibraryStore(directory: root.appending(path: "state")), settings: AppSettings(defaults: defaults))
        let source = LibrarySource(id: UUID(), kind: .smb, displayName: "Local fixture SMB", addedAt: .now, serverID: client.server.id)
        let path = remoteURL.lastPathComponent
        let size = try await client.fileSize(path)
        let comic = Comic(id: Comic.makeID(sourceID: source.id, relativePath: path), sourceID: source.id,
                          relativePath: path, kind: .archive, title: "Short fixture", series: nil, volume: nil, chapter: nil,
                          author: nil, year: nil, subtitle: nil, pageCount: 8, totalBytes: size, addedAt: .now)
        library.mutateState { $0.sources.append(source); $0.nasServers.append(client.server); $0.comics = [comic] }
        library.clients[client.server.id] = client
        let manager = TransferManager(library: library, store: LibraryStore(directory: root.appending(path: "queue")), registersBackgroundTasks: false)
        let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: path)
        let partial = destination.appendingPathExtension("part")
        guard !FileManager.default.fileExists(atPath: destination.path), !FileManager.default.fileExists(atPath: partial.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        defer { try? FileManager.default.removeItem(at: destination); try? FileManager.default.removeItem(at: partial) }
        manager.download(comic)
        for _ in 0..<1000 where manager.jobs.first?.doneBytes == 0 { try await Task.sleep(for: .milliseconds(10)) }
        let handle = try FileHandle(forWritingTo: remoteURL)
        try handle.truncate(atOffset: 4 * 1024 * 1024)
        try handle.close()
        for _ in 0..<1000 where manager.jobs.first?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(manager.jobs.first?.state, .failed, "EOF before the expected length must not publish a broken download")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path), "Keep received bytes for retry")
        await client.disconnect()
    }

    func testOriginalVolume16OverDelayedReadOnlySMB() async throws {
        guard let original = ProcessInfo.processInfo.environment["MANGO_AUDIT_ORIGINAL_EPUB"] else {
            throw XCTSkip("No original EPUB requested; generated fixtures remain available")
        }
        let client = try NASClient(server: NASServer(id: UUID(), name: "Read-only original", host: "127.0.0.1", port: 1445,
                                                    share: "ORIGINAL", path: "", username: "audit", addedAt: .now), password: "local-fixture-only")
        try await client.connect()
        let document = try await EPUBDocument.open(reader: RemoteFileReader(client: client, relativePath: URL(fileURLWithPath: original).lastPathComponent), displayName: "Original volume 16")
        XCTAssertEqual(document.chapterCount, 18)
        try await exerciseTransitions(document: document, steps: 100, startingAt: 10)
        await client.disconnect()
    }

    func testRemoteImageFolderDownloadsEveryPage() async throws {
        let client = try client()
        try await client.connect()
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = LibraryModel(store: LibraryStore(directory: root.appending(path: "state")), settings: AppSettings(defaults: defaults))
        let source = LibrarySource(id: UUID(), kind: .smb, displayName: "Local fixture SMB", addedAt: .now, serverID: client.server.id)
        let path = "Image folder"
        let entries = try await client.list(path)
        let comic = Comic(id: Comic.makeID(sourceID: source.id, relativePath: path), sourceID: source.id,
                          relativePath: path, kind: .folder, title: "Image fixture", series: nil, volume: nil, chapter: nil,
                          author: nil, year: nil, subtitle: nil, pageCount: 8, totalBytes: entries.reduce(0) { $0 + $1.size }, addedAt: .now)
        library.mutateState { $0.sources.append(source); $0.nasServers.append(client.server); $0.comics = [comic] }
        library.clients[client.server.id] = client
        let manager = TransferManager(library: library, store: LibraryStore(directory: root.appending(path: "queue")), registersBackgroundTasks: false)
        let destination = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: path)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        defer { try? FileManager.default.removeItem(at: destination) }
        manager.download(comic)
        for _ in 0..<1000 where manager.jobs.first?.isActive == true { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(manager.jobs.first?.state, .done, manager.jobs.first?.error ?? "")
        let archive = try FolderComicArchive.open(folder: destination, displayName: "Downloaded fixture")
        XCTAssertEqual(archive.pageCount, 8)
        let page = try await archive.page(at: 7, maxPixel: 400)
        XCTAssertGreaterThan(page.width, 0)
        XCTAssertLessThanOrEqual(page.height, 400)
        await client.disconnect()
    }

    func testActualReaderEngineChapterBoundariesBackgroundAndBookEndOverSMB() async throws {
        let client = try client()
        try await client.connect()
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        settings.novelPaged = true
        settings.novelFontScale = 0.8
        let library = LibraryModel(store: LibraryStore(directory: root.appending(path: "state")),
                                   covers: CoverStore(directory: root.appending(path: "covers"), customDirectory: root.appending(path: "custom")),
                                   settings: settings)
        let source = LibrarySource(id: UUID(), kind: .smb, displayName: "Local fixture SMB", addedAt: .now, serverID: client.server.id)
        let path = "Audit Novel v01.epub"
        let comic = Comic(id: Comic.makeID(sourceID: source.id, relativePath: path), sourceID: source.id,
                          relativePath: path, kind: .epub, title: "Native reader fixture", series: nil, volume: nil, chapter: nil,
                          author: nil, year: nil, subtitle: nil, pageCount: 24, totalBytes: try await client.fileSize(path), addedAt: .now)
        library.mutateState { $0.sources.append(source); $0.nasServers.append(client.server); $0.comics = [comic] }
        library.clients[client.server.id] = client
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        defer { window.isHidden = true; window.rootViewController = nil }
        for _ in 0..<3 {
            library.mutateState { $0.progress[comic.id] = ReadingProgress(page: 10, pageCount: 24) }
            window.rootViewController = UIHostingController(rootView: NovelReaderView(comic: comic).environment(library).environment(settings))
            window.makeKeyAndVisible()
            for chapter in 10..<23 {
                let web = try await readyWeb(in: window, path: "ch\(chapter).xhtml")
                if chapter.isMultiple(of: 3) { await client.disconnect() }
                _ = try await web.evaluateJavaScript("""
                mangoPager.page = mangoPager.count - 1;
                for (let i = 0; i < 20; i++) document.body.dispatchEvent(new MouseEvent('click', {bubbles:true,clientX:380,detail:1}));
                null;
                """)
                _ = try await readyWeb(in: window, path: "ch\(chapter+1).xhtml", excluding: web)
                NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
                XCTAssertEqual(library.progress(for: comic)?.page, chapter + 1)
                XCTAssertEqual(SharedReading.read()?.positionLabel, "Chapter \(chapter+2) of 24")
                NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            }
            let last = try await readyWeb(in: window, path: "ch23.xhtml")
            _ = try await last.evaluateJavaScript("mangoPager.page=mangoPager.count-1; document.dispatchEvent(new KeyboardEvent('keydown',{key:'ArrowRight'})); null")
            for _ in 0..<200 {
                if self.findWeb(in: window) == nil { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNil(findWeb(in: window), "The end card must replace the final chapter")
            XCTAssertEqual(library.progress(for: comic)?.finished, true)
            window.rootViewController = nil
            try await Task.sleep(for: .milliseconds(30))
        }
        await client.disconnect()
    }

    private final class WeakLibrary {
        weak var value: LibraryModel?
        init(_ value: LibraryModel) { self.value = value }
    }

    func testClosingTheActualReaderReleasesItsSessionAndLibrary() async throws {
        func openReader() async throws -> (UIWindow, WeakLibrary) {
            let client = try client()
            try await client.connect()
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            let suite = UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let settings = AppSettings(defaults: defaults)
            settings.novelPaged = true
            let library = LibraryModel(store: LibraryStore(directory: root.appending(path: "state")),
                                       covers: CoverStore(directory: root.appending(path: "covers"), customDirectory: root.appending(path: "custom")),
                                       settings: settings)
            let source = LibrarySource(id: UUID(), kind: .smb, displayName: "Local fixture SMB", addedAt: .now, serverID: client.server.id)
            let path = "Audit Novel v01.epub"
            let comic = Comic(id: Comic.makeID(sourceID: source.id, relativePath: path), sourceID: source.id,
                              relativePath: path, kind: .epub, title: "Session release fixture", series: nil, volume: nil, chapter: nil,
                              author: nil, year: nil, subtitle: nil, pageCount: 24, totalBytes: try await client.fileSize(path), addedAt: .now)
            library.mutateState { $0.sources.append(source); $0.nasServers.append(client.server); $0.comics = [comic] }
            library.clients[client.server.id] = client
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            window.frame = scene.effectiveGeometry.coordinateSpace.bounds
            window.rootViewController = UIHostingController(rootView: NovelReaderView(comic: comic).environment(library).environment(settings))
            window.makeKeyAndVisible()
            _ = try await readyWeb(in: window, path: "ch0.xhtml")
            defaults.removePersistentDomain(forName: suite)
            return (window, WeakLibrary(library))
        }
        let (window, library) = try await openReader()
        let web = WeakWeb(try XCTUnwrap(findWeb(in: window)))
        window.rootViewController = nil
        window.isHidden = true
        for _ in 0..<600 {
            if library.value == nil && web.value == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(web.value, "The closed reader must release its WKWebView")
        XCTAssertNil(library.value, "The closed reader's engine and callbacks must release their library")
    }

    func testExpiredBackgroundBudgetPreservesQueueAndIgnoresStaleExpiration() async throws {
        try await exerciseExpiredBudget(resumeInForeground: false)
    }

    func testExpiredBackgroundBudgetResumesOnForeground() async throws {
        try await exerciseExpiredBudget(resumeInForeground: true)
    }

    func testForegroundBeforeExpiryKeepsLiveTransferRunning() async throws {
        try await exerciseExpiredBudget(resumeInForeground: true, foregroundBeforeExpiry: true)
    }

    private func exerciseExpiredBudget(resumeInForeground: Bool, foregroundBeforeExpiry: Bool = false) async throws {
        let client = try client()
        try await client.connect()
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = LibraryModel(store: LibraryStore(directory: root.appending(path: "state")),
                                   covers: CoverStore(directory: root.appending(path: "covers"), customDirectory: root.appending(path: "custom")),
                                   settings: AppSettings(defaults: defaults))
        let source = LibrarySource(id: UUID(), kind: .smb, displayName: "Local fixture SMB", addedAt: .now, serverID: client.server.id)
        var comics: [Comic] = []
        for (path, kind) in [("Audit Comic v01.cbz", Comic.Kind.archive), ("Audit Novel v01.epub", .epub), ("Image folder", .folder)] {
            let size = kind == .folder ? Int64(8000) : try await client.fileSize(path)
            comics.append(Comic(id: Comic.makeID(sourceID: source.id, relativePath: path), sourceID: source.id,
                                relativePath: path, kind: kind, title: path, series: nil, volume: nil, chapter: nil,
                                author: nil, year: nil, subtitle: nil, pageCount: 8, totalBytes: size, addedAt: .now))
        }
        library.mutateState { $0.sources.append(source); $0.nasServers.append(client.server); $0.comics = comics }
        library.clients[client.server.id] = client
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let destinations = comics.map { documents.appending(path: $0.relativePath) }
        for url in destinations {
            guard !FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: url.appendingPathExtension("part").path) else {
                throw CocoaError(.fileWriteFileExists)
            }
        }
        defer {
            for url in destinations { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: url.appendingPathExtension("part")) }
        }
        let manager = TransferManager(library: library, store: LibraryStore(directory: root.appending(path: "queue")), registersBackgroundTasks: false)
        for comic in comics { manager.download(comic) }
        let cancelledID = try XCTUnwrap(manager.jobs.last?.id)
        manager.cancel(cancelledID)
        let first = BackgroundTask()
        manager.runInBackground(first.execution)
        let stale = try XCTUnwrap(first.expiration)
        for _ in 0..<1000 where manager.jobs.first?.doneBytes == 0 { try await Task.sleep(for: .milliseconds(10)) }
        if foregroundBeforeExpiry {
            NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            XCTAssertEqual(first.completions, [false])
            stale()
            for _ in 0..<3000 where manager.jobs.contains(where: \.isActive) { try await Task.sleep(for: .milliseconds(10)) }
        } else {
            first.expire()
            for _ in 0..<1000 where first.completions.isEmpty || manager.jobs.contains(where: { $0.state == .running }) {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(first.completions, [false])
            XCTAssertEqual(manager.jobs.map(\.state), [.queued, .queued, .cancelled])
            let partial = destinations[0].appendingPathExtension("part")
            XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destinations[0].path))
            if resumeInForeground {
                NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
                stale()
                for _ in 0..<3000 where manager.jobs.contains(where: \.isActive) { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertEqual(first.completions, [false])
            } else {
                let second = BackgroundTask()
                manager.runInBackground(second.execution)
                stale()
                for _ in 0..<3000 where second.completions.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertEqual(second.completions, [true], "An old expiry must not stop the fresh budget")
                XCTAssertEqual(first.completions, [false], "Every budget completes exactly once")
            }
        }
        XCTAssertEqual(manager.jobs.map(\.state), [.done, .done, .cancelled])
        let fixtures = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SMB_AUDIT_ROOT"] ?? "/tmp/mango-earmark-smb-fixtures")
        XCTAssertEqual(try Data(contentsOf: destinations[0]), try Data(contentsOf: fixtures.appending(path: comics[0].relativePath)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinations[2].path))
        await client.disconnect()
    }

    private func exerciseTransitions(document: EPUBDocument, steps: Int = 30, startingAt: Int = 0) async throws {
        let reading = Reading()
        reading.chapter = startingAt
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.rootViewController = UIHostingController(rootView: Reader(document: document, reading: reading))
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil }
        var retired: [WeakWeb] = []
        for step in 0..<steps {
            let chapter = reading.chapter
            let web = try await readyWeb(in: window, path: document.spine[chapter % document.chapterCount].path)
            retired.append(WeakWeb(web))
            let forward = step.isMultiple(of: 2)
            let turnEvent = step.isMultiple(of: 3)
                ? "document.body.dispatchEvent(new MouseEvent('click', {bubbles:true, clientX:\(forward ? 380 : 1), detail:1}))"
                : "document.dispatchEvent(new KeyboardEvent('keydown', {key:'\(forward ? "ArrowRight" : "ArrowLeft")'}))"
            _ = try await web.evaluateJavaScript("""
            mangoPager.page = \(forward ? "mangoPager.count - 1" : "0");
            for (let i = 0; i < 20; i++) {
              \(turnEvent);
              window.webkit.messageHandlers.mangoNavigation.postMessage({action:'progress', fraction:0.9});
            }
            // Return a bridgeable value, rather than the message port's last result.
            null;
            """)
            for _ in 0..<100 {
                if reading.chapter != chapter { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(reading.chapter, chapter + 1, "One old chapter must issue only one transition")
            guard reading.chapter == chapter + 1 else { return }
            _ = try await readyWeb(in: window, path: document.spine[reading.chapter % document.chapterCount].path, excluding: web)
        }
        // A new WKWebView is created per chapter in the real reader. Old views must go away.
        for _ in 0..<100 {
            if retired.allSatisfy({ $0.value == nil }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(reading.turns, steps)
        XCTAssertFalse(reading.fractions.contains(0.9), "Queued progress from an old chapter must not overwrite the new chapter's place")
        XCTAssertTrue(retired.allSatisfy { $0.value == nil }, "Retired chapter web views must be released")
    }

    private final class WeakWeb {
        weak var value: WKWebView?
        init(_ value: WKWebView) { self.value = value }
    }

    private func readyWeb(in window: UIWindow, path: String, excluding old: WKWebView? = nil) async throws -> WKWebView {
        for _ in 0..<200 {
            if let web = findWeb(in: window), web !== old, web.url.map({ EPUBSchemeHandler.path(from: $0) }) == path,
               (try? await web.evaluateJavaScript("!!window.mangoPager && mangoPager.count >= 1")) as? Bool == true {
                return web
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw XCTUnwrapFailure.missingChapter
    }

    private enum XCTUnwrapFailure: Error { case missingChapter }

    private func findWeb(in view: UIView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { self.findWeb(in: $0) }.first
    }
}
