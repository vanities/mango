import Foundation
import os
import ShelfKit

/// Walks a source and derives the comics in it. Never opens an archive: cracking 2,000 zips to
/// count pages would make a NAS scan take minutes, so `Comic.pageCount` stays nil until the
/// reader opens one.
struct LibraryScanner: Sendable {
    /// How deep to walk. Deeper than this and it's someone's whole Downloads folder.
    static let maxDepth = 6
    /// A folder needs at least this many loose images before it counts as an unzipped volume
    /// rather than a series folder that happens to contain a cover.
    static let minLoosePages = 3

    struct Result: Sendable {
        var comics: [Comic] = []
        var fileCount = 0
        /// Archives found that Mango can't open, by extension.
        var unreadable: [String: Int] = [:]
        var error: String?
    }

    // MARK: Local

    /// `root` must already be security-scope-accessible; the caller owns that scope.
    static func scanLocal(source: LibrarySource, root: URL) -> Result {
        let sw = Stopwatch()
        var result = Result()
        walkLocal(root, base: root, source: source, depth: 0, into: &result)
        Logger.scan.info("[scan] \(source.displayName, privacy: .public) → \(result.comics.count) comics from \(result.fileCount) files (\(result.unreadable.values.reduce(0, +)) unreadable) in \(sw.ms, format: .fixed(precision: 0))ms")
        return result
    }

    private static func walkLocal(_ directory: URL, base: URL, source: LibrarySource, depth: Int, into result: inout Result) {
        guard depth <= maxDepth else { return }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else {
            Logger.scan.error("[scan] couldn't list \(directory.lastPathComponent, privacy: .public)")
            return
        }

        var subdirectories: [URL] = []
        var loosePages = 0
        // Collected and parsed as a group, not one by one: files in a folder disambiguate each
        // other (see NameParser.parseGroup).
        var candidates: [Candidate] = []
        var unreadable: [String] = []

        for url in entries {
            let name = url.lastPathComponent
            if ImageFileTypes.isJunk(name) { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                subdirectories.append(url)
                continue
            }
            result.fileCount += 1
            if ImageFileTypes.isPage(name) {
                loosePages += 1
            } else if ImageFileTypes.isUnreadableArchive(name) {
                unreadable.append(name)
            } else if ImageFileTypes.isReadable(name) {
                candidates.append(Candidate(
                    name: name,
                    folderName: directory == base ? nil : directory.lastPathComponent,
                    relativePath: relativePath(of: url, from: base),
                    kind: ImageFileTypes.kind(for: name),
                    size: Int64(values?.fileSize ?? 0)
                ))
            }
        }

        countUnreadable(unreadable, besides: candidates, into: &result)

        // A folder full of loose pages is an unzipped volume.
        if loosePages >= minLoosePages, directory != base {
            candidates.append(Candidate(
                name: directory.lastPathComponent,
                folderName: directory.deletingLastPathComponent() == base ? nil : directory.deletingLastPathComponent().lastPathComponent,
                relativePath: relativePath(of: directory, from: base),
                kind: .folder,
                size: folderSize(directory)
            ))
        }
        result.comics.append(contentsOf: makeComics(candidates, source: source))

        for sub in subdirectories {
            walkLocal(sub, base: base, source: source, depth: depth + 1, into: &result)
        }
    }

    private static func folderSize(_ directory: URL) -> Int64 {
        let entries = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return entries.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    private static func relativePath(of url: URL, from base: URL) -> String {
        let full = url.standardizedFileURL.path
        let root = base.standardizedFileURL.path
        guard full.hasPrefix(root) else { return url.lastPathComponent }
        return String(full.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    // MARK: Remote (SMB)

    static func scanRemote(source: LibrarySource, client: NASClient) async -> Result {
        let sw = Stopwatch()
        var result = Result()
        do {
            try await walkRemote("", client: client, source: source, depth: 0, into: &result)
        } catch {
            result.error = error.localizedDescription
            Logger.scan.error("[scan:nas] \(source.displayName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        Logger.scan.info("[scan:nas] \(source.displayName, privacy: .public) → \(result.comics.count) comics from \(result.fileCount) files (\(result.unreadable.values.reduce(0, +)) unreadable) in \(sw.ms, format: .fixed(precision: 0))ms")
        return result
    }

    private static func walkRemote(_ path: String, client: NASClient, source: LibrarySource, depth: Int, into result: inout Result) async throws {
        guard depth <= maxDepth else { return }
        let entries = try await client.list(path)
        var subdirectories: [NASEntry] = []
        var loosePages = 0
        var looseBytes: Int64 = 0
        var candidates: [Candidate] = []
        var unreadable: [String] = []

        for entry in entries {
            if ImageFileTypes.isJunk(entry.name) { continue }
            if entry.isDirectory {
                subdirectories.append(entry)
                continue
            }
            result.fileCount += 1
            if ImageFileTypes.isPage(entry.name) {
                loosePages += 1
                looseBytes += entry.size
            } else if ImageFileTypes.isUnreadableArchive(entry.name) {
                unreadable.append(entry.name)
            } else if ImageFileTypes.isReadable(entry.name) {
                candidates.append(Candidate(
                    name: entry.name,
                    folderName: path.isEmpty ? nil : (path as NSString).lastPathComponent,
                    relativePath: entry.relativePath,
                    kind: ImageFileTypes.kind(for: entry.name),
                    size: entry.size
                ))
            }
        }

        countUnreadable(unreadable, besides: candidates, into: &result)

        if loosePages >= minLoosePages, !path.isEmpty {
            let parent = (path as NSString).deletingLastPathComponent
            candidates.append(Candidate(
                name: (path as NSString).lastPathComponent,
                folderName: parent.isEmpty ? nil : (parent as NSString).lastPathComponent,
                relativePath: path,
                kind: .folder,
                size: looseBytes
            ))
        }
        result.comics.append(contentsOf: makeComics(candidates, source: source))

        for sub in subdirectories {
            try await walkRemote(sub.relativePath, client: client, source: source, depth: depth + 1, into: &result)
        }
    }

    // MARK: Shared

    /// RAR and 7z files the reader can't open — minus any with a readable twin beside them
    /// ("Akira v01.rar" next to its converted "Akira v01.cbz"), which isn't missing anything.
    private static func countUnreadable(_ names: [String], besides candidates: [Candidate], into result: inout Result) {
        guard !names.isEmpty else { return }
        let converted = Set(candidates.map { ($0.name as NSString).deletingPathExtension.lowercased() })
        for name in names where !converted.contains((name as NSString).deletingPathExtension.lowercased()) {
            result.unreadable[(name as NSString).pathExtension.lowercased(), default: 0] += 1
        }
    }

    /// One comic-shaped thing found in a directory, before its name has been interpreted.
    private struct Candidate {
        var name: String
        var folderName: String?
        var relativePath: String
        var kind: Comic.Kind
        var size: Int64
    }

    private static func makeComics(_ candidates: [Candidate], source: LibrarySource) -> [Comic] {
        guard !candidates.isEmpty else { return [] }
        let parsed = NameParser.parseGroup(candidates.map { ($0.name, $0.folderName) })
        let now = Date()
        return zip(candidates, parsed).map { candidate, name in
            Comic(
                id: Comic.makeID(sourceID: source.id, relativePath: candidate.relativePath),
                sourceID: source.id,
                relativePath: candidate.relativePath,
                kind: candidate.kind,
                title: name.title,
                series: name.series,
                volume: name.volume,
                chapter: name.chapter,
                author: nil,
                year: name.year,
                subtitle: name.subtitle,
                pageCount: nil,
                totalBytes: candidate.size,
                addedAt: now,
                coverID: nil
            )
        }
    }
}
