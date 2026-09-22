import Foundation
import os

// MARK: - Duplicates
//
// The same comic twice on this device — a folder added twice, a copy made in Files. Only
// comics on this device are compared (a NAS isn't read end to end for this), and a copy goes
// only when the user deletes it here: never the last one, never one on a NAS.

enum DuplicateError: LocalizedError {
    case lastCopy, notOnThisDevice, outsideItsFolder

    var errorDescription: String? {
        switch self {
        case .lastCopy: "That's the only copy left."
        case .notOnThisDevice: "Only a copy on this device can be deleted here."
        case .outsideItsFolder: "That file isn't inside its folder."
        }
    }
}

extension LibraryModel {
    /// "On My Device", "Downloads", the NAS's name — where a copy lives, for the list.
    func sourceName(for comic: Comic) -> String {
        state.sources.first { $0.id == comic.sourceID }?.displayName ?? "Unknown"
    }

    /// Fingerprints every comic on this device off the main actor, and groups the matches.
    func findDuplicates(progress: @escaping @MainActor @Sendable (_ done: Int, _ total: Int) -> Void) async -> [DuplicateSet] {
        let targets: [(Comic, URL)] = state.comics.compactMap { comic in
            guard case .local(let url)? = location(for: comic) else { return nil }
            return (comic, url)
        }
        let sw = Stopwatch()
        Logger.library.info("[duplicates] start comics=\(targets.count)")
        let printed = await Task.detached(priority: .userInitiated) { () -> [(comic: Comic, fingerprint: ComicFingerprint)] in
            var out: [(comic: Comic, fingerprint: ComicFingerprint)] = []
            for (index, (comic, url)) in targets.enumerated() {
                do {
                    out.append((comic, try DuplicateFinder.fingerprint(of: url)))
                } catch {
                    Logger.library.error("[duplicates] couldn't read \(comic.relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                if index % 8 == 0 || index == targets.count - 1 { await progress(index + 1, targets.count) }
            }
            return out
        }.value
        let sets = DuplicateFinder.sets(of: printed)
        Logger.library.info("[duplicates] done sets=\(sets.count) wasted=\(sets.reduce(0) { $0 + $1.wastedBytes })B in \(sw.ms, format: .fixed(precision: 0))ms")
        return sets
    }

    /// Deletes one copy of a duplicate. Its place, bookmarks and rating go to a copy that stays.
    func deleteDuplicate(_ comic: Comic, in set: DuplicateSet) throws {
        guard let keeper = set.copies.first(where: { $0.id != comic.id && state.comics.contains($0) }) else {
            throw DuplicateError.lastCopy
        }
        guard let source = state.sources.first(where: { $0.id == comic.sourceID }), source.kind == .appDocuments || source.kind == .folder,
              let root = root(for: source)?.standardizedFileURL else { throw DuplicateError.notOnThisDevice }
        let target = root.appending(path: comic.relativePath).standardizedFileURL
        guard target.isInside(root) else {
            Logger.library.error("[duplicates] refusing to delete outside its folder: \(comic.relativePath, privacy: .public)")
            throw DuplicateError.outsideItsFolder
        }
        try FileManager.default.removeItem(at: target)
        removeEmptyFolders(from: target.deletingLastPathComponent(), downTo: root)
        let pickedCover = state.customCovers[comic.id]
        mutateState { $0.returnState(from: comic.id, to: keeper.id) }
        if let pickedCover, pickedCover != state.customCovers[keeper.id] { covers.delete(pickedCover) }
        Logger.library.notice("[duplicates] deleted \(comic.relativePath, privacy: .public) (\(comic.totalBytes)B) from \(source.displayName, privacy: .public); kept \(keeper.relativePath, privacy: .public)")
        Task { await scan() }
    }
}
