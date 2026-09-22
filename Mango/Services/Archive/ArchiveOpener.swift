import Foundation
import os
import ShelfKit

/// Where a comic's bytes actually are. Resolving a `Comic` to one of these is `LibraryModel`'s
/// job (it owns the security-scoped bookmarks and the NAS connections); opening it is this file's.
enum ComicLocation: Sendable {
    /// A file or folder on disk. The caller must be holding security-scoped access for as long
    /// as the archive is open.
    case local(URL)
    /// A file or folder on an SMB share, relative to the server's library root.
    case remote(client: NASClient, relativePath: String, size: Int64)
}

enum ArchiveOpener {
    static func open(_ comic: Comic, at location: ComicLocation) async throws -> any ComicArchive {
        let sw = Stopwatch()
        let name = comic.title
        let archive: any ComicArchive

        switch (comic.kind, location) {
        case (.archive, .local(let url)):
            archive = try await ZipComicArchive.open(reader: LocalFileReader(url: url), displayName: name)

        case (.archive, .remote(let client, let path, let size)):
            // The good case: the zip index lives at the end of the file, so this is two ranged
            // reads regardless of whether the volume is 4 MB or 400 MB.
            let reader = RemoteFileReader(client: client, relativePath: path, knownLength: size)
            archive = try await ZipComicArchive.open(reader: reader, displayName: name)

        case (.pdf, .local(let url)):
            archive = try PDFComicArchive.open(url: url, displayName: name)

        case (.pdf, .remote(let client, let path, let size)):
            guard size <= PDFComicArchive.remoteSizeLimit else {
                throw ArchiveError.tooLargeToStream(name: name, bytes: size)
            }
            let data = try await client.readAll(path, maxBytes: PDFComicArchive.remoteSizeLimit)
            archive = try PDFComicArchive.open(data: data, displayName: name)

        case (.folder, .local(let url)):
            archive = try FolderComicArchive.open(folder: url, displayName: name)

        case (.folder, .remote(let client, let path, _)):
            archive = try await FolderComicArchive.openRemote(client: client, relativePath: path, displayName: name)

        case (.epub, _):
            // A novel isn't a sequence of page images; LibraryModel.openNovel handles it.
            throw ArchiveError.notAComic(name)
        }

        Logger.archive.info("[open] \(name, privacy: .public) kind=\(comic.kind.rawValue, privacy: .public) pages=\(archive.pageCount) in \(sw.ms, format: .fixed(precision: 0))ms")
        return archive
    }
}
