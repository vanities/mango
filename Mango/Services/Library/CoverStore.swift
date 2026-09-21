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
            return store(try await Self.cover(from: archive), as: coverID)
        } catch {
            Logger.cover.error("[cover] page 1 failed for \(coverID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// A long strip's cover is drawn at this width, then cut to a book's 2:3 shape.
    static let stripCoverWidth = maxPixel * 2 / 3

    private static func cover(from archive: any ComicArchive) async throws -> CGImage {
        // A PDF knows its page size and renders straight to it; only a strip needs the top cut out.
        if let known = await archive.knownPageSize(at: 0) {
            guard PageShape.isLongStrip(width: known.width, height: known.height) else {
                return try await archive.page(at: 0, maxPixel: maxPixel)
            }
            return topOfStrip(try await archive.page(at: 0, sizing: .fitWidth(pixels: stripCoverWidth)))
        }
        let data = try await archive.pageData(at: 0)
        guard let image = coverImage(from: data) else {
            throw ArchiveError.undecodable(page: archive.pageName(at: 0))
        }
        return image
    }

    /// A cover from page one's bytes: an ordinary page shrunk whole; a long strip cut to its top
    /// at full cover width — shrinking a whole 1:9 strip into 600 pixels would leave a
    /// 67-pixel-wide smear, and the top is where a strip puts its title.
    static func coverImage(from data: Data) -> CGImage? {
        guard let size = ImageDecoder.pixelSize(of: data),
              PageShape.isLongStrip(width: size.width, height: size.height),
              let strip = ImageDecoder.decode(data, sizing: .fitWidth(pixels: stripCoverWidth))
        else { return ImageDecoder.downsample(data, maxPixel: maxPixel) }
        return topOfStrip(strip)
    }

    private static func topOfStrip(_ strip: CGImage) -> CGImage {
        let height = min(strip.height, strip.width * 3 / 2)
        return strip.cropping(to: CGRect(x: 0, y: 0, width: strip.width, height: height)) ?? strip
    }
}
