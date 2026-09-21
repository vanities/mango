import BackgroundTasks
import Foundation
import Observation
import UIKit
import os

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

        var fraction: Double { totalBytes > 0 ? min(1, Double(doneBytes) / Double(totalBytes)) : 0 }
        var isActive: Bool { state == .queued || state == .running }
    }

    static let backgroundTaskIdentifier = "com.vanities.mango.transfers"
    private static let queueFile = "transfers.json"
    /// Give up after this many automatic retries so a permanently broken file can't spin.
    private static let maxAttempts = 3

    private(set) var jobs: [Job] = [] { didSet { persist() } }

    @ObservationIgnored private let library: LibraryModel
    @ObservationIgnored private let store = LibraryStore()
    @ObservationIgnored private var restoring = false
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private let cancelled = OSAllocatedUnfairLock(initialState: Set<UUID>())
    @ObservationIgnored private var attempts: [String: Int] = [:]
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init(library: LibraryModel) {
        self.library = library
        restore()
        registerBackgroundTask()
        observers.append(NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeInterrupted(reason: "foreground") }
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
        cancelled.withLock { _ = $0.insert(jobID) }
        update(jobID) { if $0.isActive { $0.state = .cancelled } }
    }

    func cancelAll() {
        for job in jobs where job.isActive { cancel(job.id) }
    }

    func clearFinished() {
        jobs.removeAll { !$0.isActive }
    }

    func retry(_ jobID: UUID) {
        guard let job = jobs.first(where: { $0.id == jobID }) else { return }
        attempts[job.comicID] = 0
        update(jobID) { $0.state = .queued; $0.error = nil; $0.doneBytes = 0 }
        runNext()
    }

    // MARK: Queue

    private func enqueue(_ job: Job) {
        jobs.append(job)
        runNext()
    }

    private func runNext() {
        guard runner == nil, let next = jobs.first(where: { $0.state == .queued }) else { return }
        update(next.id) { $0.state = .running }
        updateIdleTimer()
        runner = Task { [weak self] in
            await self?.perform(next)
            await MainActor.run {
                self?.runner = nil
                self?.updateIdleTimer()
                self?.runNext()
            }
        }
    }

    private func update(_ jobID: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        change(&jobs[index])
    }

    /// A transfer only continues while the app is in the foreground, so don't let the screen
    /// lock halfway through a 300 MB volume.
    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = isTransferring
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
            if job.state == .running { job.state = .queued }
            return job
        }
        Logger.downloads.info("[transfers] restored \(self.jobs.count) job(s), \(self.jobs.count { $0.isActive }) still to do")
        runNext()
    }

    private func resumeInterrupted(reason: String) {
        let failed = jobs.filter { $0.state == .failed }
        for job in failed where (attempts[job.comicID] ?? 0) < Self.maxAttempts {
            attempts[job.comicID, default: 0] += 1
            update(job.id) { $0.state = .queued; $0.error = nil }
            Logger.downloads.info("[transfers] retrying \(job.title, privacy: .public) on \(reason, privacy: .public) (attempt \(self.attempts[job.comicID] ?? 0))")
        }
        runNext()
    }

    private func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backgroundTaskIdentifier, using: nil) { task in
            MainActor.assumeIsolated {
                guard let processing = task as? BGProcessingTask else { return task.setTaskCompleted(success: false) }
                self.runInBackground(processing)
            }
        }
    }

    private func scheduleBackgroundProcessing() {
        guard isTransferring else { return }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    private func runInBackground(_ task: BGProcessingTask) {
        task.expirationHandler = { MainActor.assumeIsolated { self.cancelAll() } }
        runNext()
        Task { @MainActor in
            while isTransferring { try? await Task.sleep(for: .seconds(2)) }
            task.setTaskCompleted(success: true)
        }
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
        let files = await remoteFiles(of: comic, client: client)
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
                try await client.download(file.path, to: partial) { bytes, _ in
                    Task { @MainActor [weak self] in self?.update(jobID) { $0.doneBytes = base + bytes } }
                    return !cancelled.withLock { $0.contains(jobID) }
                }
                if isCancelled(job.id) { finishCancelled(job, comic); return }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: partial, to: destination)
                done += file.size
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
                try await client.upload(file.url, to: file.remotePath) { bytes, _ in
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

    // MARK: File lists

    /// A `.cbz`, `.pdf` or `.epub` is one file; a folder comic is all the pages in it.
    private func remoteFiles(of comic: Comic, client: NASClient) async -> [(path: String, size: Int64)] {
        guard comic.kind == .folder else { return [(comic.relativePath, comic.totalBytes)] }
        let entries = (try? await client.list(comic.relativePath)) ?? []
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
