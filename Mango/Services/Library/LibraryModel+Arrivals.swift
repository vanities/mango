import Foundation
import os
import ShelfKit

extension LibraryModel {
    static var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// Returning from Files refreshes local folders without walking the NAS.
    func sceneBecameActive() {
        let due = Set(state.sources.filter {
            !$0.isRemote && ($0.lastScanAt.map { Date().timeIntervalSince($0) > 10 } ?? true)
        }.map(\.id))
        guard !due.isEmpty else { return }
        Task { await scan(sourceIDs: due) }
    }

    func watchOwnFolder() {
        guard ownFolderWatcher == nil else { return }
        ownFolderWatcher = FolderWatcher(url: Self.documentsURL) { [weak self] in
            guard let self, let own = self.state.sources.first(where: { $0.kind == .appDocuments }) else { return }
            Task { await self.scan(sourceIDs: [own.id]) }
        }
    }

    /// Keep external files in place; only a copy iOS placed in our Inbox moves into Documents.
    func addOpenedFile(_ url: URL) {
        guard url.isFileURL, ImageFileTypes.isReadable(url.lastPathComponent) else { return }
        let documents = Self.documentsURL
        let kept = OpenedFiles.isInInbox(url, documents: documents)
            ? OpenedFiles.moveOutOfInbox(url, into: documents) : url
        for source in state.sources where !source.isRemote {
            guard let root = root(for: source) else { continue }
            if source.kind == .file, root.isSameFile(as: kept) {
                expectOpen(source.id, path: nil)
                return
            }
            if source.kind != .file, let path = kept.relativePath(inside: root) {
                expectOpen(source.id, path: path)
                return
            }
        }
        do {
            let bookmark = try BookmarkStore.makeBookmark(for: kept)
            let source = LibrarySource(id: UUID(), kind: .file, displayName: kept.lastPathComponent,
                                       bookmark: bookmark, addedAt: Date())
            mutateState { $0.sources.append(source) }
            expectOpen(source.id, path: nil)
        } catch {
            lastError = error.localizedDescription
            Logger.library.error("[open] couldn't bookmark file: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func expectOpen(_ sourceID: UUID, path: String?) {
        pendingOpen = (sourceID, path, .now)
        Task { await scan(sourceIDs: [sourceID]) }
    }

    func resolvePendingOpen(scanned: Set<UUID>) {
        guard let pending = pendingOpen, scanned.contains(pending.sourceID) else { return }
        guard Date().timeIntervalSince(pending.date) < 60 else {
            pendingOpen = nil
            return
        }
        guard let comic = state.comics.first(where: {
            $0.sourceID == pending.sourceID && (pending.path == nil || $0.relativePath == pending.path)
        }) else { return }
        pendingOpen = nil
        requestedComic = comic
        Logger.library.info("[open] ready to read \(comic.title, privacy: .public)")
    }
}
