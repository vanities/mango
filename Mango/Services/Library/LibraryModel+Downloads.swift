import Foundation
import os
import ShelfKit

// MARK: - Downloads
//
// A download is a copy of a NAS comic in Mango's own folder — TransferManager puts it at the
// same relative path, so the two share a `syncKey`. Removing one deletes that copy, and only
// ever that: a file in Mango's own folder whose original is still on a NAS. What was done to
// it (progress, bookmarks, rating) goes back to the NAS copy first.

extension LibraryModel {
    /// This comic's downloaded copy, if it has one.
    func downloadedCopy(of comic: Comic) -> Comic? {
        guard nasCopy(of: comic) != nil else { return nil }
        return state.copies(of: comic).first(where: isInMangoFolder)
    }

    /// The NAS copy of a comic, if it has one.
    func nasCopy(of comic: Comic) -> Comic? {
        let remote = remoteSourceIDs
        return state.copies(of: comic).first { remote.contains($0.sourceID) }
    }

    /// Every download that could go back to its NAS.
    var downloads: [Comic] {
        let remote = remoteSourceIDs
        let onNAS = Set(state.comics.filter { remote.contains($0.sourceID) }.map(\.syncKey))
        return state.comics.filter { isInMangoFolder($0) && onNAS.contains($0.syncKey) }
    }

    var downloadedBytes: Int64 { downloads.reduce(0) { $0 + $1.totalBytes } }

    /// Downloads of volumes that have been read to the end.
    var finishedDownloads: [Comic] {
        downloads.filter { state.progress[$0.id]?.finished == true }
    }

    /// Deletes a comic's downloaded copy; it carries on from the NAS. Returns the bytes freed.
    @discardableResult
    func removeDownload(of comic: Comic) -> Int64 {
        guard let local = downloadedCopy(of: comic), let remote = nasCopy(of: comic),
              let source = state.sources.first(where: { $0.id == local.sourceID }), let documents = root(for: source)
        else {
            Logger.downloads.notice("[downloads] nothing to remove for \(comic.title, privacy: .public)")
            return 0
        }
        let target = documents.appending(path: local.relativePath).standardizedFileURL
        // Only ever inside Mango's own folder, whatever a relative path might say.
        guard target.isInside(documents) else {
            Logger.downloads.error("[downloads] refusing to delete outside Mango's folder: \(local.relativePath, privacy: .public)")
            return 0
        }
        do {
            try FileManager.default.removeItem(at: target)
        } catch {
            Logger.downloads.error("[downloads] couldn't remove \(local.relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return 0
        }
        let pickedCover = state.customCovers[local.id]
        mutateState { $0.returnState(from: local.id, to: remote.id) }
        if let pickedCover, pickedCover != state.customCovers[remote.id] { covers.delete(pickedCover) }
        removeEmptyFolders(from: target.deletingLastPathComponent(), downTo: documents)
        publishWidgetSnapshot()
        Logger.downloads.info("[downloads] removed \(local.title, privacy: .public) (\(local.totalBytes)B) — reading from the NAS again")
        return local.totalBytes
    }

    /// Removes several downloads; returns how many and how much space came back.
    @discardableResult
    func removeDownloads(_ comics: [Comic]) -> (count: Int, bytes: Int64) {
        var count = 0, bytes: Int64 = 0
        for comic in comics {
            let freed = removeDownload(of: comic)
            if freed > 0 { count += 1; bytes += freed }
        }
        return (count, bytes)
    }

    private func isInMangoFolder(_ comic: Comic) -> Bool {
        state.sources.first { $0.id == comic.sourceID }?.kind == .appDocuments
    }

    /// A series folder emptied by removing its last download goes too — never Mango's folder itself.
    func removeEmptyFolders(from folder: URL, downTo root: URL) {
        var current = folder.standardizedFileURL
        let stop = root.standardizedFileURL.path
        while current.path.hasPrefix(stop + "/"),
              let contents = try? FileManager.default.contentsOfDirectory(atPath: current.path),
              contents.allSatisfy({ $0 == ".DS_Store" }) {
            try? FileManager.default.removeItem(at: current)
            current = current.deletingLastPathComponent()
        }
    }
}
