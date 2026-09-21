import CoreGraphics
import Foundation
import os

/// A `.cbz`: a zip whose entries are page images, in name order.
///
/// Opening one costs two ranged reads (the tail, then the index) no matter how big the file is,
/// so a 400 MB volume on the NAS opens as fast as a 4 MB one. Each page after that is one more
/// ranged read.
struct ZipComicArchive: ComicArchive {
    private let reader: any RandomAccessReader
    private let entries: [ZipEntry]
    let displayName: String

    var pageCount: Int { entries.count }

    func pageName(at index: Int) -> String {
        guard entries.indices.contains(index) else { return "?" }
        return entries[index].name
    }

    static func open(reader: any RandomAccessReader, displayName: String) async throws -> ZipComicArchive {
        let all = try await ZipReader.readCentralDirectory(reader)
        let pages = all
            .filter { !$0.isDirectory && !ImageFileTypes.isJunk($0.name) && ImageFileTypes.isPage($0.name) }
            .sorted { $0.name.naturallyPrecedes($1.name) }
        guard !pages.isEmpty else {
            Logger.archive.error("[zip] \(displayName, privacy: .public) has \(all.count) entries but no images")
            throw ArchiveError.noPages(displayName)
        }
        Logger.archive.info("[zip] opened \(displayName, privacy: .public) pages=\(pages.count)")
        return ZipComicArchive(reader: reader, entries: pages, displayName: displayName)
    }

    func pageData(at index: Int) async throws -> Data {
        guard entries.indices.contains(index) else {
            throw ArchiveError.pageOutOfRange(index, count: entries.count)
        }
        return try await ZipReader.read(entries[index], from: reader)
    }

    func page(at index: Int, maxPixel: Int) async throws -> CGImage {
        let data = try await pageData(at: index)
        guard let image = ImageDecoder.downsample(data, maxPixel: maxPixel) else {
            throw ArchiveError.undecodable(page: pageName(at: index))
        }
        return image
    }
}
