import BackgroundTasks
import Foundation
import Observation
import UIKit
import os
import ShelfKit

/// Moves comics between the NAS and this device, one at a time.
///
/// Modelled on Earmark's transfer queue, and for the same reasons it learned the hard way:
/// SMB has no background-transfer API, iOS suspends an app about 30 seconds after you leave
/// it, and a suspended app can be killed outright. So the queue is persisted to disk,
/// restored and resumed on launch, retried on foreground, and holds the screen awake while
/// it runs. A half-finished file is kept as `.part` so the next attempt resumes rather than
/// starting a 300 MB volume again.
@MainActor @Observable
final class TransferManager {
    struct Job: Identifiable, Equatable, Codable {
        enum State: String, Equatable, Codable { case queued, running, done, failed, cancelled }
        enum Kind: String, Equatable, Codable {
            /// NAS → this device.
            case download
            /// This device → NAS.
            case upload
            /// A folder the user picked → Mango's own folder (copied, checked, original removed).
            case move
        }

        let id: UUID
        let comicID: String
        let title: String
        var kind: Kind = .download
        var serverID: UUID?
        var totalBytes: Int64
        var doneBytes: Int64 = 0
        var state: State = .queued
        var error: String?
        /// Optional for queues saved by older builds. Persist intent before the worker stops.
        var cancellationRequested: Bool?

        var fraction: Double { totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : 0 }
        var isActive: Bool { state == .queued || state == .running }
    }

    static let backgroundTaskIdentifier = "com.vanities.mango.transfers"
    private static let queueFile = "transfers.json"
    /// Give up after this many automatic retries so a permanently broken file can't spin.
    private static let maxAttempts = 3

    private(set) var jobs: [Job] = [] { didSet { persist() } }

    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private let store: LibraryStore
    @ObservationIgnored private let backgroundSchedulingEnabled: Bool
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private let cancelled = OSAllocatedUnfairLock(initialState: Set<UUID>())
    @ObservationIgnored private var attempts: [String: Int] = [:]
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var backgroundExecution: TransferBackgroundExecution?
    @ObservationIgnored private var backgroundPaused = false
    @ObservationIgnored private var systemInterrupted: Set<UUID> = []

    init(library: LibraryModel, store: LibraryStore = LibraryStore(), registersBackgroundTasks: Bool = true) {
        self.library = library
        self.store = store
        self.backgroundSchedulingEnabled = registersBackgroundTasks
        restore()
        if registersBackgroundTasks { registerBackgroundTask() }
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeInForeground() }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleBackgroundProcessing() }
            })
    }

    // MARK: Public surface

    var isTransferring: Bool { jobs.contains(where: \.isActive) }
    var activeJob: Job? { jobs.first { $0.state == .running } }

    func job(for comicID: String) -> Job? {
        jobs.last { $0.comicID == comicID && $0.state != .cancelled }
    }

    /// Pull a remote comic into this device's own folder, keeping the same relative layout so
    /// it groups exactly as it did on the share.
    func download(_ comic: Comic) {
        guard comic.isRemote(in: library), job(for: comic.id)?.isActive != true else { return }
        enqueue(Job(id: UUID(), comicID: comic.id, title: comic.title, kind: .download,
                    totalBytes: max(1, comic.totalBytes)))
    }

    /// Push a local comic up to a share, skipping anything already there at the same size.
    func upload(_ comic: Comic, to serverID: UUID) {
        guard !comic.isRemote(in: library), job(for: comic.id)?.isActive != true else { return }
        enqueue(Job(id: UUID(), comicID: comic.id, title: comic.title, kind: .upload,
                    serverID: serverID, totalBytes: max(1, comic.totalBytes)))
    }

    /// Move a comic from a folder the user picked into Mango's own folder: copy, check, and
    /// only then remove the original. Only ever when asked.
    func move(_ comic: Comic) {
        guard library.state.sources.first(where: { $0.id == comic.sourceID })?.kind == .folder,
              job(for: comic.id)?.isActive != true else { return }
        enqueue(Job(id: UUID(), comicID: comic.id, title: comic.title, kind: .move, totalBytes: max(1, comic.totalBytes)))
    }

    /// Everything on this share that isn't on the device yet.
    func downloadable(in source: LibrarySource) -> [Comic] {
        let localPaths = Set(library.state.comics.filter { !$0.isRemote(in: library) }.map(\.syncKey))
        return library.state.comics.filter { $0.sourceID == source.id && !localPaths.contains($0.syncKey) }
    }

    /// Everything on the device that isn't on the share yet.
    func uploadable(to serverID: UUID) -> [Comic] {
        let remotePaths = Set(library.state.comics.filter { $0.isRemote(in: library) }.map(\.syncKey))
        return library.state.comics.filter { !$0.isRemote(in: library) && !remotePaths.contains($0.syncKey) }
    }

    @discardableResult
    func downloadAll(from source: LibrarySource) -> Int {
        let pending = downloadable(in: source)
        pending.forEach { download($0) }
        Logger.downloads.info("[transfers] queued \(pending.count) download(s) from \(source.displayName, privacy: .public)")
        return pending.count
    }

    @discardableResult
    func uploadAll(to serverID: UUID) -> Int {
        let pending = uploadable(to: serverID)
        pending.forEach { upload($0, to: serverID) }
        Logger.downloads.info("[transfers] queued \(pending.count) upload(s)")
        return pending.count
    }

    func cancel(_ jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }), job.isActive else { return }
        cancelled.withLock { _ = $0.insert(jobID) }
        update(jobID) {
            $0.cancellationRequested = true
            if $0.state == .queued { $0.state = .cancelled }
        }
        updateIdleTimer()
    }

    func cancelAll() {
        for job in jobs where job.isActive { cancel(job.id) }
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
    }

    func retry(_ jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }), !job.isActive else { return }
        attempts[job.comicID] = 0
        backgroundPaused = false
        update(jobID) { $0.state = .queued; $0.error = nil; $0.doneBytes = 0; $0.cancellationRequested = nil }
        runNext()
    }

    // MARK: Queue

    private func enqueue(_ job: Job) {
        jobs.append(job)
        runNext()
    }

    private func runNext() {
        defer { updateIdleTimer() }
        guard !backgroundPaused, runner == nil else { return }
        guard let next = jobs.first(where: { $0.state == .queued }) else {
            finishBackgroundExecution(success: !jobs.contains { $0.state == .failed })
            return
        }
        cancelled.withLock { _ = $0.remove(next.id) }
        update(next.id) { $0.state = .running }
        runner = Task { [weak self] in
            await self?.perform(next)
            self?.finishWorker(next.id)
            self?.runner = nil
            self?.runNext()
        }
    }

    private func finishWorker(_ jobID: UUID) {
        let interrupted = systemInterrupted.remove(jobID) != nil
        update(jobID) {
            guard $0.state != .done else { $0.cancellationRequested = nil; return }
            if $0.cancellationRequested == true {
                $0.state = .cancelled
                $0.error = nil
            } else if interrupted {
                $0.state = .queued
                $0.error = nil
            }
        }
        cancelled.withLock { _ = $0.remove(jobID) }
    }

    private func update(_ jobID: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        change(&jobs[index])
    }

    /// A transfer only continues while the app is in the foreground, so don't let the screen
    /// lock halfway through a 300 MB volume. Through `ScreenAwake`, so an idle queue lets go
    /// of the screen without switching off an open book's hold on it.
    private func updateIdleTimer() {
        ScreenAwake.shared.hold("transfers", isTransferring && !backgroundPaused)
    }

    // MARK: Persistence and resumption

    private func persist() {
        guard !restoring else { return }
        try? store.saveJSON(jobs, named: Self.queueFile)
    }

    private func restore() {
        restoring = true
        defer { restoring = false }
        guard let saved = store.loadJSON([Job].self, named: Self.queueFile) else { return }
        // Anything that was mid-flight when we were killed goes back in the queue.
        jobs = saved.map { job in
            var job = job
            if job.cancellationRequested == true && job.state != .done {
                job.state = .cancelled
                job.error = nil
            } else if job.state == .running {
                job.state = .queued
            }
            return job
        }
        Logger.downloads.info("[transfers] restored \(self.jobs.count) job(s), \(self.jobs.count { $0.isActive }) still to do")
        runNext()
    }

    private func resumeInForeground() {
        // iOS can deliver this before withdrawing the old background budget. Invalidate
        // that budget now so its later expiry cannot pause foreground transfers.
        finishBackgroundExecution(success: false)
        resumeInterrupted(reason: "foreground")
    }

    private func resumeInterrupted(reason: String) {
        backgroundPaused = false
        var requeued = 0
        for job in jobs where job.state == .failed && job.cancellationRequested != true {
            let key = job.comicID
            guard (attempts[key] ?? 0) < Self.maxAttempts else { continue }
            attempts[key, default: 0] += 1
            update(job.id) { $0.state = .queued; $0.error = nil }
            requeued += 1
        }
        if requeued > 0 {
            Logger.downloads.info("[transfers] requeued \(requeued) interrupted job(s) on \(reason, privacy: .public)")
        }
        runNext()
    }

    private func registerBackgroundTask() {
        // `using: nil` runs this on a background queue, so hop to the main actor rather than
        // assume it: `MainActor.assumeIsolated` traps off the main thread, which would crash
        // the app each time iOS ran a transfer in the background. Earmark hops the same way.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backgroundTaskIdentifier, using: nil) { task in
            guard let processing = task as? BGProcessingTask else { return task.setTaskCompleted(success: false) }
            Task { @MainActor in self.runInBackground(.live(processing)) }
        }
        Logger.downloads.info("[transfers] background task registered=\(registered)")
    }

    private func scheduleBackgroundProcessing() {
        guard backgroundSchedulingEnabled, isTransferring else { return }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    func runInBackground(_ task: TransferBackgroundExecution) {
        finishBackgroundExecution(success: false)
        backgroundExecution = task
        task.setExpirationHandler { [weak self, id = task.id] in
            Task { @MainActor [weak self] in self?.expireBackgroundExecution(id) }
        }
        resumeInterrupted(reason: "background task")
    }

    private func expireBackgroundExecution(_ id: UUID) {
        guard backgroundExecution?.id == id else { return }
        backgroundPaused = true
        if let running = jobs.first(where: { $0.state == .running && $0.cancellationRequested != true }) {
            systemInterrupted.insert(running.id)
            cancelled.withLock { _ = $0.insert(running.id) }
        }
        // Pending jobs keep their queued state. A stopped worker joins them after unwinding.
        finishBackgroundExecution(success: false)
        scheduleBackgroundProcessing()
        updateIdleTimer()
    }

    private func finishBackgroundExecution(success: Bool) {
        guard let task = backgroundExecution else { return }
        backgroundExecution = nil
        task.setExpirationHandler(nil)
        task.complete(success)
    }

    // MARK: Doing the work

    private func perform(_ job: Job) async {
        guard let comic = library.state.comics.first(where: { $0.id == job.comicID }) else {
            update(job.id) { $0.state = .failed; $0.error = "This comic isn't in the library any more." }
            return
        }
        let background = UIApplication.shared.beginBackgroundTask(withName: "mango.transfer")
        defer { UIApplication.shared.endBackgroundTask(background) }

        switch job.kind {
        case .download: await performDownload(job, comic: comic)
        case .upload: await performUpload(job, comic: comic)
        case .move: await performMove(job, comic: comic)
        }
    }

    private func performDownload(_ job: Job, comic: Comic) async {
        guard let source = library.state.sources.first(where: { $0.id == comic.sourceID }),
              let serverID = source.serverID, let client = library.client(for: serverID)
        else {
            update(job.id) { $0.state = .failed; $0.error = "This comic's NAS isn't available." }
            return
        }
        let sw = Stopwatch()
        let files: [(path: String, size: Int64)]
        do {
            files = try await remoteFiles(of: comic, client: client)
        } catch {
            Logger.downloads.error("[transfers] couldn't list \(comic.relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            update(job.id) { $0.state = .failed; $0.error = error.localizedDescription }
            return
        }
        update(job.id) { $0.totalBytes = max(1, files.reduce(0) { $0 + $1.size }) }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var done: Int64 = 0
        for file in files {
            if isCancelled(job.id) { finishCancelled(job, comic); return }
            let destination = documents.appending(path: file.path)
            // Already here at the right size — nothing to do.
            if let existing = try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               Int64(existing) == file.size, file.size > 0 {
                done += file.size
                update(job.id) { $0.doneBytes = done }
                continue
            }
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let partial = destination.appendingPathExtension("part")
            let base = done
            let jobID = job.id
            let cancelled = self.cancelled
            do {
                let source = try await DownloadPartial.currentSource(client: client, path: file.path)
                if isCancelled(job.id) { finishCancelled(job, comic); return }
                update(job.id) { $0.totalBytes += source.size - file.size }
                let candidate = try DownloadPartial.prepare(at: partial, source: source)
                let prepared = try await candidate.verifyingRetainedBytes(client: client) {
                    !cancelled.withLock { $0.contains(jobID) }
                }
                update(job.id) { $0.doneBytes = base + prepared.retainedBytes }
                if !prepared.isComplete {
                    try await client.download(file.path, to: partial) { [weak self] bytes, _ in
                        Task { @MainActor [weak self] in self?.update(jobID) { $0.doneBytes = base + bytes } }
                        return !cancelled.withLock { $0.contains(jobID) }
                    }
                }
                if isCancelled(job.id) { finishCancelled(job, comic); return }
                try await prepared.validate(client: client)
                if isCancelled(job.id) { finishCancelled(job, comic); return }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: partial, to: destination)
                prepared.removeMetadata()
                done += source.size
                update(job.id) { $0.doneBytes = done }
            } catch is CancellationError {
                // The .part file stays: the next attempt resumes from it.
                finishCancelled(job, comic)
                return
            } catch {
                Logger.downloads.error("[transfers] download failed \(file.path, privacy: .public): \(error.localizedDescription, privacy: .public) (partial kept)")
                update(job.id) { $0.state = .failed; $0.error = error.localizedDescription }
                return
            }
        }
        update(job.id) { $0.state = .done; $0.doneBytes = $0.totalBytes }
        Logger.downloads.info("[transfers] downloaded \(comic.title, privacy: .public) files=\(files.count) in \(sw.seconds, format: .fixed(precision: 1))s")
        await library.scan()
    }

    private func performUpload(_ job: Job, comic: Comic) async {
        guard let serverID = job.serverID, let client = library.client(for: serverID),
              case .local(let url)? = library.location(for: comic)
        else {
            update(job.id) { $0.state = .failed; $0.error = "That server isn't available." }
            return
        }
        let sw = Stopwatch()
        let files = localFiles(of: comic, at: url)
        update(job.id) { $0.totalBytes = max(1, files.reduce(0) { $0 + $1.size }) }

        var done: Int64 = 0
        for file in files {
            if isCancelled(job.id) { finishCancelled(job, comic); return }
            // Skip anything already up there at the same size — re-uploading a 300 MB volume
            // because a sync ran twice is the kind of thing people notice on their bandwidth.
            if let remoteSize = await client.remoteSizeIfExists(file.remotePath), remoteSize == file.size {
                done += file.size
                update(job.id) { $0.doneBytes = done }
                continue
            }
            let base = done
            let jobID = job.id
            let cancelled = self.cancelled
            do {
                try await client.upload(file.url, to: file.remotePath) { [weak self] bytes, _ in
                    Task { @MainActor [weak self] in self?.update(jobID) { $0.doneBytes = base + bytes } }
                    return !cancelled.withLock { $0.contains(jobID) }
                }
                done += file.size
                update(job.id) { $0.doneBytes = done }
            } catch {
                Logger.downloads.error("[transfers] upload failed \(file.remotePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                update(job.id) { $0.state = .failed; $0.error = error.localizedDescription }
                return
            }
        }
        update(job.id) { $0.state = .done; $0.doneBytes = $0.totalBytes }
        Logger.downloads.info("[transfers] uploaded \(comic.title, privacy: .public) files=\(files.count) in \(sw.seconds, format: .fixed(precision: 1))s")
        await library.scan()
    }

    /// Into Mango's folder at the same relative path, so it groups exactly as it did. The
    /// comic's place, bookmarks and rating go with it.
    private func performMove(_ job: Job, comic: Comic) async {
        guard case .local(let url)? = library.location(for: comic),
              let documentsSource = library.state.sources.first(where: { $0.kind == .appDocuments }) else {
            update(job.id) { $0.state = .failed; $0.error = "That folder isn't available." }
            return
        }
        let sw = Stopwatch()
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let files = localFiles(of: comic, at: url).map {
            LocalMove.File(source: $0.url, destination: documents.appending(path: $0.remotePath), size: $0.size)
        }
        update(job.id) { $0.totalBytes = max(1, files.reduce(0) { $0 + $1.size }) }
        let jobID = job.id, cancelled = self.cancelled
        // Folders the move empties go too, up to — never including — the folder the user picked.
        let pickedRoot = library.state.sources.first { $0.id == comic.sourceID }.flatMap { library.root(for: $0) }
        let reportProgress: @Sendable (Int64) -> Void = { [weak self] bytes in
            Task { @MainActor [weak self] in self?.update(jobID) { $0.doneBytes = bytes } }
        }
        let outcome: Result<Void, any Error> = await Task.detached(priority: .userInitiated) {
            Result {
                try LocalMove.run(files, into: "Mango", pruningUpTo: pickedRoot, progress: reportProgress,
                                  isCancelled: { cancelled.withLock { $0.contains(jobID) } })
            }
        }.value
        var originalsNote: String?
        switch outcome {
        case .success:
            break
        case .failure(LocalMove.Failure.originalsLeft(let count, let app)):
            originalsNote = LocalMove.Failure.originalsLeft(count, app: app).errorDescription
        case .failure(LocalMove.Failure.cancelled):
            finishCancelled(job, comic)
            return
        case .failure(let error):
            Logger.downloads.error("[move] \(comic.relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            update(job.id) { $0.state = .failed; $0.error = error.localizedDescription }
            return
        }
        let movedID = Comic.makeID(sourceID: documentsSource.id, relativePath: comic.relativePath)
        library.mutateState { $0.returnState(from: comic.id, to: movedID) }
        update(job.id) {
            $0.state = .done
            $0.doneBytes = $0.totalBytes
            if let originalsNote { $0.error = originalsNote }
        }
        Logger.downloads.info("[move] \(comic.title, privacy: .public) files=\(files.count) into Mango's folder in \(sw.seconds, format: .fixed(precision: 1))s\(originalsNote == nil ? "" : " (some originals left)", privacy: .public)")
        await library.scan()
    }

    // MARK: File lists

    /// A `.cbz`, `.pdf` or `.epub` is one file; a folder comic is all the pages in it.
    private func remoteFiles(of comic: Comic, client: NASClient) async throws -> [(path: String, size: Int64)] {
        guard comic.kind == .folder else { return [(comic.relativePath, comic.totalBytes)] }
        let entries = try await client.list(comic.relativePath)
        guard entries.contains(where: { !$0.isDirectory && ImageFileTypes.isPage($0.name) && !ImageFileTypes.isJunk($0.name) }) else {
            throw ArchiveError.noPages(comic.title)
        }
        return entries.filter { !$0.isDirectory }.map { ($0.relativePath, $0.size) }
    }

    private func localFiles(of comic: Comic, at url: URL) -> [(url: URL, remotePath: String, size: Int64)] {
        func size(_ url: URL) -> Int64 {
            Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        guard comic.kind == .folder else {
            return [(url, comic.relativePath, size(url))]
        }
        let contents = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return contents.map { ($0, "\(comic.relativePath)/\($0.lastPathComponent)", size($0)) }
    }

    // MARK: Helpers

    private func isCancelled(_ jobID: UUID) -> Bool {
        cancelled.withLock { $0.contains(jobID) }
    }

    private func finishCancelled(_ job: Job, _ comic: Comic) {
        update(job.id) { $0.state = .cancelled }
        Logger.downloads.info("[transfers] cancelled \(comic.title, privacy: .public)")
    }
}

extension Comic {
    /// Whether this comic lives on a share rather than on the device.
    @MainActor
    func isRemote(in library: LibraryModel) -> Bool {
        library.state.sources.first { $0.id == sourceID }?.isRemote ?? false
    }
}
