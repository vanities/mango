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
        let page = try pdfPage(at: index)
        let bounds = page.bounds(for: .mediaBox)
        let longest = max(bounds.width, bounds.height)
        let scale = longest > 0 ? min(CGFloat(min(maxPixel, ImageDecoder.maxPixelCap)) / longest, Self.maxUpscale) : 1
        return try render(page, index: index, size: CGSize(width: bounds.width * scale, height: bounds.height * scale))
    }

    /// Rendered straight to size — going through `pageData` would mean an oversized bitmap and
    /// a JPEG round trip first, which for a tall page is a lot of memory for nothing.
    func page(at index: Int, sizing: PageSizing) async throws -> CGImage {
        switch sizing {
        case .fitScreen(let maxPixel):
            return try await page(at: index, maxPixel: maxPixel)
        case .fitWidth(let pixels):
            let page = try pdfPage(at: index)
            let bounds = page.bounds(for: .mediaBox)
            let ceiling = CGSize(width: bounds.width * Self.maxUpscale, height: bounds.height * Self.maxUpscale)
            return try render(page, index: index, size: ImageDecoder.widthFirstSize(of: ceiling, width: pixels))
        }
    }

    func knownPageSize(at index: Int) async -> CGSize? {
        guard let page = try? pdfPage(at: index) else { return nil }
        return page.bounds(for: .mediaBox).size
    }

    /// Vector pages have real detail to give when drawn bigger — up to a point.
    private static let maxUpscale: CGFloat = 4

    private func pdfPage(at index: Int) throws -> PDFPage {
        guard index >= 0, index < pageCount, let page = document.page(at: index) else {
            throw ArchiveError.pageOutOfRange(index, count: pageCount)
        }
        return page
    }

    private func render(_ page: PDFPage, index: Int, size: CGSize) throws -> CGImage {
        let sw = Stopwatch()
        let target = CGSize(width: max(1, size.width), height: max(1, size.height))
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
