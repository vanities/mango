import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

/// Cover thumbnails, on disk in Caches. Alongside the library JSON, these are the only files
/// Mango ever writes about a comic — the comics themselves are never copied or touched.
///
/// Caches because the system may reclaim them; they're always rebuildable from page one.
struct CoverStore: Sendable {
    let directory: URL
    /// Big enough for a grid cell on a 13" iPad at 3x, small enough that a 500-volume library
    /// isn't a gigabyte of thumbnails.
    static let maxPixel = 600

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            self.directory = base.appending(path: "Covers", directoryHint: .isDirectory)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    func url(for coverID: String) -> URL {
        directory.appending(path: "\(coverID).jpg")
    }

    func exists(_ coverID: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: coverID).path)
    }

    /// A stable id for a comic's cover — hashed so it's filesystem-safe whatever the path holds.
    static func coverID(for comic: Comic) -> String {
        var hasher = Hasher()
        hasher.combine(comic.id)
        return String(format: "%016llx", UInt64(bitPattern: Int64(hasher.finalize())))
    }

    @discardableResult
    func store(_ image: CGImage, as coverID: String) -> Bool {
        let sw = Stopwatch()
        let destination = url(for: coverID)
        guard let sink = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            Logger.cover.error("[cover] couldn't create destination for \(coverID, privacy: .public)")
            return false
        }
        CGImageDestinationAddImage(sink, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        let ok = CGImageDestinationFinalize(sink)
        Logger.cover.info("[cover] stored \(coverID, privacy: .public) \(image.width)x\(image.height) ok=\(ok) in \(sw.ms, format: .fixed(precision: 1))ms")
        return ok
    }

    func load(_ coverID: String) -> CGImage? {
        let source = url(for: coverID)
        guard let data = try? Data(contentsOf: source, options: .mappedIfSafe) else { return nil }
        return ImageDecoder.downsample(data, maxPixel: Self.maxPixel)
    }

    func delete(_ coverID: String) {
        try? FileManager.default.removeItem(at: url(for: coverID))
    }

    /// Pulls page one out of an already-open archive and files it as the cover.
    func extractCover(from archive: any ComicArchive, as coverID: String) async -> Bool {
        guard archive.pageCount > 0 else { return false }
        do {
            let image = try await archive.page(at: 0, maxPixel: Self.maxPixel)
            return store(image, as: coverID)
        } catch {
            Logger.cover.error("[cover] page 1 failed for \(coverID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
