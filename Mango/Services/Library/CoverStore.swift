import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

/// Cover thumbnails, on disk in Caches. Alongside the library JSON, these are the only files
/// Mango ever writes about a comic — the comics themselves are never copied or touched.
///
/// Caches because the system may reclaim them; they're always rebuildable from page one. Covers
/// the user picked (Find Cover, Photos) aren't — they live in Application Support instead, told
/// apart by their id's `custom-` prefix, so every caller keeps passing one kind of id.
struct CoverStore: Sendable {
    let directory: URL
    let customDirectory: URL
    /// Big enough for a grid cell on a 13" iPad at 3x, small enough that a 500-volume library
    /// isn't a gigabyte of thumbnails.
    static let maxPixel = 600
    /// A picked cover is also shown large in the series header, so it keeps more detail.
    static let customMaxPixel = 1200
    static let customPrefix = "custom-"

    init(directory: URL? = nil, customDirectory: URL? = nil) {
        let fileManager = FileManager.default
        self.directory = directory ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "Covers", directoryHint: .isDirectory)
        self.customDirectory = customDirectory ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Mango/Covers", directoryHint: .isDirectory)
        try? fileManager.createDirectory(at: self.directory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: self.customDirectory, withIntermediateDirectories: true)
    }

    static func isCustom(_ coverID: String) -> Bool { coverID.hasPrefix(customPrefix) }

    func url(for coverID: String) -> URL {
        (Self.isCustom(coverID) ? customDirectory : directory).appending(path: "\(coverID).jpg")
    }

    func exists(_ coverID: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: coverID).path)
    }

    /// A stable id for a comic's cover — hashed so it's filesystem-safe whatever the path holds.
    /// Stable across launches: this used `Hasher`, which is seeded randomly per process, so every
    /// launch expected a different file, re-extracted the cover on open (a page read, over the
    /// NAS) and orphaned the last one.
    static func coverID(for comic: Comic) -> String {
        stableHex(comic.id)
    }

    /// Deletes cached thumbnails no comic points at any more — the leftovers of the unstable ids
    /// above, and of comics that left the library. Picked covers are never touched.
    @discardableResult
    func removeUnreferenced(keeping referenced: Set<String>) -> Int {
        let sw = Stopwatch()
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return 0
        }
        var removed = 0
        for file in files where file.pathExtension == "jpg" {
            let id = file.deletingPathExtension().lastPathComponent
            guard !referenced.contains(id), !Self.isCustom(id) else { continue }
            if (try? FileManager.default.removeItem(at: file)) != nil { removed += 1 }
        }
        if removed > 0 {
            Logger.cover.info("[cover] removed \(removed) unreferenced thumbnail(s) of \(files.count) in \(sw.ms, format: .fixed(precision: 1))ms")
        }
        return removed
    }

    /// An id for a cover the user picked. It changes with the picture (`origin` is the URL it
    /// came from, or a fingerprint of a photo), so a view showing the old cover reloads.
    static func customID(for comic: Comic, origin: String) -> String {
        customPrefix + stableHex(comic.id + "|" + origin)
    }

    /// FNV-1a — unlike `Hasher`, the same across launches, which a filename has to be.
    static func stableHex(_ text: String) -> String {
        stableHex(bytes: Data(text.utf8))
    }

    static func stableHex(bytes: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }

    /// Files a picked image: decoded (so a file that isn't a picture is refused here, not in the
    /// grid), shrunk to `customMaxPixel`, and stored as JPEG.
    @discardableResult
    func storeCustom(imageData: Data, as coverID: String) -> Bool {
        guard Self.isCustom(coverID), let image = ImageDecoder.downsample(imageData, maxPixel: Self.customMaxPixel) else {
            Logger.cover.error("[cover] picked image unusable for \(coverID, privacy: .public) (\(imageData.count)B)")
            return false
        }
        return store(image, as: coverID)
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
