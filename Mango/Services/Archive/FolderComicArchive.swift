import CoreGraphics
import Foundation
import ImageIO
import os

/// A folder of loose page images — what you get after unzipping, or from a scanlation dump.
/// Pages come from the folder listing, in natural order, including one level of subfolders
/// (a volume split into chapter folders reads straight through).
struct FolderComicArchive: ComicArchive {
    /// Where each page lives and how to read it. Local folders and SMB folders both fit here.
    enum PageLocation: Sendable {
        case local(URL)
        case remote(client: NASClient, relativePath: String)
    }

    private let pages: [(name: String, location: PageLocation)]
    let displayName: String

    var pageCount: Int { pages.count }

    func pageName(at index: Int) -> String {
        pages.indices.contains(index) ? pages[index].name : "?"
    }

    init(pages: [(name: String, location: PageLocation)], displayName: String) {
        self.pages = pages
        self.displayName = displayName
    }

    /// Walks a local folder (and one level of subfolders) for page images.
    static func open(folder: URL, displayName: String) throws -> FolderComicArchive {
        let fm = FileManager.default
        var found: [(String, PageLocation)] = []
        let top = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for url in top.sorted(by: { $0.lastPathComponent.naturallyPrecedes($1.lastPathComponent) }) {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                let inner = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
                for page in inner.sorted(by: { $0.lastPathComponent.naturallyPrecedes($1.lastPathComponent) })
                where ImageFileTypes.isPage(page.lastPathComponent) && !ImageFileTypes.isJunk(page.lastPathComponent) {
                    found.append(("\(url.lastPathComponent)/\(page.lastPathComponent)", .local(page)))
                }
            } else if ImageFileTypes.isPage(url.lastPathComponent), !ImageFileTypes.isJunk(url.lastPathComponent) {
                found.append((url.lastPathComponent, .local(url)))
            }
        }
        guard !found.isEmpty else { throw ArchiveError.noPages(displayName) }
        Logger.archive.info("[folder] opened \(displayName, privacy: .public) pages=\(found.count)")
        return FolderComicArchive(pages: found.map { (name: $0.0, location: $0.1) }, displayName: displayName)
    }

    /// Same, over SMB: one listing of the folder plus one of each subfolder.
    static func openRemote(client: NASClient, relativePath: String, displayName: String) async throws -> FolderComicArchive {
        var found: [(String, PageLocation)] = []
        let top = try await client.list(relativePath).sorted { $0.name.naturallyPrecedes($1.name) }
        for entry in top {
            if entry.isDirectory {
                let inner = try await client.list(entry.relativePath).sorted { $0.name.naturallyPrecedes($1.name) }
                for page in inner where !page.isDirectory && ImageFileTypes.isPage(page.name) && !ImageFileTypes.isJunk(page.name) {
                    found.append(("\(entry.name)/\(page.name)", .remote(client: client, relativePath: page.relativePath)))
                }
            } else if ImageFileTypes.isPage(entry.name), !ImageFileTypes.isJunk(entry.name) {
                found.append((entry.name, .remote(client: client, relativePath: entry.relativePath)))
            }
        }
        guard !found.isEmpty else { throw ArchiveError.noPages(displayName) }
        Logger.archive.info("[folder:nas] opened \(displayName, privacy: .public) pages=\(found.count)")
        return FolderComicArchive(pages: found.map { (name: $0.0, location: $0.1) }, displayName: displayName)
    }

    func pageData(at index: Int) async throws -> Data {
        guard pages.indices.contains(index) else {
            throw ArchiveError.pageOutOfRange(index, count: pages.count)
        }
        switch pages[index].location {
        case .local(let url):
            return try Data(contentsOf: url, options: .mappedIfSafe)
        case .remote(let client, let path):
            return try await client.readAll(path, maxBytes: 64_000_000)
        }
    }

    func pageSize(at index: Int) async -> CGSize? {
        guard pages.indices.contains(index) else { return nil }
        switch pages[index].location {
        case .local(let url):
            // ImageIO reads only the header from a URL source.
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            else { return nil }
            return ImageDecoder.pixelSize(from: properties)
        case .remote(let client, let path):
            let reader = RemoteFileReader(client: client, relativePath: path, knownLength: nil)
            guard let prefix = try? await reader.read(offset: 0, count: ZipComicArchive.sizeProbeBytes),
                  let size = ImageDecoder.pixelSize(of: prefix)
            else { return nil }
            return size
        }
    }

    func page(at index: Int, maxPixel: Int) async throws -> CGImage {
        let data = try await pageData(at: index)
        guard let image = ImageDecoder.downsample(data, maxPixel: maxPixel) else {
            throw ArchiveError.undecodable(page: pageName(at: index))
        }
        return image
    }
}
