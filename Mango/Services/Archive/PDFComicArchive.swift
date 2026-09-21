import CoreGraphics
import Foundation
import PDFKit
import os

/// A `.pdf` read as a comic. Unlike a zip, a PDF has no per-page byte ranges you can fetch
/// independently — PDFKit wants the whole document — so a remote PDF is pulled into memory on
/// open, and a big one asks to be downloaded first instead.
///
/// An actor because `PDFDocument` is not Sendable and rendering must not race.
actor PDFComicArchive: ComicArchive {
    /// Above this, reading over the network is a worse experience than just downloading it.
    static let remoteSizeLimit: Int64 = 200_000_000

    private let document: PDFDocument
    nonisolated let pageCount: Int
    nonisolated let displayName: String

    private init(document: PDFDocument, displayName: String) {
        self.document = document
        self.pageCount = document.pageCount
        self.displayName = displayName
    }

    nonisolated func pageName(at index: Int) -> String { "Page \(index + 1)" }

    static func open(url: URL, displayName: String) throws -> PDFComicArchive {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw ArchiveError.noPages(displayName)
        }
        Logger.archive.info("[pdf] opened \(displayName, privacy: .public) pages=\(document.pageCount)")
        return PDFComicArchive(document: document, displayName: displayName)
    }

    static func open(data: Data, displayName: String) throws -> PDFComicArchive {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw ArchiveError.noPages(displayName)
        }
        Logger.archive.info("[pdf] opened \(displayName, privacy: .public) pages=\(document.pageCount) from \(data.count)B in memory")
        return PDFComicArchive(document: document, displayName: displayName)
    }

    func page(at index: Int, maxPixel: Int) async throws -> CGImage {
        guard index >= 0, index < pageCount, let page = document.page(at: index) else {
            throw ArchiveError.pageOutOfRange(index, count: pageCount)
        }
        let sw = Stopwatch()
        let bounds = page.bounds(for: .mediaBox)
        let longest = max(bounds.width, bounds.height)
        let scale = longest > 0 ? min(CGFloat(min(maxPixel, ImageDecoder.maxPixelCap)) / longest, 4) : 1
        let target = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        guard let cgImage = page.thumbnail(of: target, for: .mediaBox).cgImage else {
            throw ArchiveError.undecodable(page: pageName(at: index))
        }
        Logger.pages.debug("[pdf] rendered page \(index + 1) at \(cgImage.width)x\(cgImage.height) in \(sw.ms, format: .fixed(precision: 1))ms")
        return cgImage
    }

    func pageData(at index: Int) async throws -> Data {
        guard index >= 0, index < pageCount, let page = document.page(at: index) else {
            throw ArchiveError.pageOutOfRange(index, count: pageCount)
        }
        let bounds = page.bounds(for: .mediaBox)
        let image = page.thumbnail(of: CGSize(width: bounds.width * 2, height: bounds.height * 2), for: .mediaBox)
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            throw ArchiveError.undecodable(page: pageName(at: index))
        }
        return data
    }
}
