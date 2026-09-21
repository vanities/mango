import CoreGraphics
import Foundation

/// An opened comic: something with an ordered list of pages that can hand back any one of them.
///
/// Implementations exist for a `.cbz` (`ZipComicArchive`), a `.pdf` (`PDFComicArchive`), and a
/// folder of loose images (`FolderComicArchive`). All three work over local files; the zip one
/// also works over SMB without downloading the file, which is the whole point.
protocol ComicArchive: Sendable {
    var pageCount: Int { get }
    /// The page's name inside the container — for logs and the page-jump list.
    func pageName(at index: Int) -> String
    /// A decoded page, downsampled so its longest edge is at most `maxPixel`.
    func page(at index: Int, maxPixel: Int) async throws -> CGImage
    /// Encoded bytes for a page, when the caller needs them raw (cover extraction).
    func pageData(at index: Int) async throws -> Data
    /// The archive's own ComicInfo.xml, if it ships one.
    func comicInfo() async -> ComicInfo?
    /// A page's size when the container knows it without reading the page — a PDF's media box.
    /// nil means read the page to find out.
    func knownPageSize(at index: Int) async -> CGSize?
    /// A page sized for a layout: whole on screen, or width-first for a long strip.
    func page(at index: Int, sizing: PageSizing) async throws -> CGImage
    /// A page's pixel size, read as cheaply as the container allows — free for a PDF, a header's
    /// worth of bytes for a zip or a folder. For laying out a strip before its pages load.
    func pageSize(at index: Int) async -> CGSize?
}

extension ComicArchive {
    func comicInfo() async -> ComicInfo? { nil }

    func knownPageSize(at index: Int) async -> CGSize? { nil }

    func pageSize(at index: Int) async -> CGSize? {
        if let known = await knownPageSize(at: index) { return known }
        guard let data = try? await pageData(at: index) else { return nil }
        return ImageDecoder.pixelSize(of: data)
    }

    /// Image containers decode width-first from the page's bytes.
    func page(at index: Int, sizing: PageSizing) async throws -> CGImage {
        switch sizing {
        case .fitScreen(let maxPixel):
            return try await page(at: index, maxPixel: maxPixel)
        case .fitWidth:
            let data = try await pageData(at: index)
            guard let image = ImageDecoder.decode(data, sizing: sizing) else {
                throw ArchiveError.undecodable(page: pageName(at: index))
            }
            return image
        }
    }
}

enum ArchiveError: LocalizedError {
    case noPages(String)
    case pageOutOfRange(Int, count: Int)
    case undecodable(page: String)
    case tooLargeToStream(name: String, bytes: Int64)
    case notAComic(String)

    var errorDescription: String? {
        switch self {
        case .noPages(let name): "\(name) has no readable pages."
        case .pageOutOfRange(let index, let count): "Page \(index + 1) doesn't exist — this comic has \(count)."
        case .undecodable(let page): "Couldn't decode \(page)."
        case .tooLargeToStream(let name, let bytes):
            "\(name) is \(Formatting.bytes(bytes)) — download it before reading, PDFs can't be read a page at a time over the network."
        case .notAComic(let name): "\(name) is a book, not a comic — it opens in the novel reader."
        }
    }
}

/// Orders page names the way a person would: "page2" before "page10", chapter folders in order.
enum PageOrder {
    static func sort(_ names: [String]) -> [String] {
        names.sorted { $0.naturallyPrecedes($1) }
    }
}
