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
}

enum ArchiveError: LocalizedError {
    case noPages(String)
    case pageOutOfRange(Int, count: Int)
    case undecodable(page: String)
    case tooLargeToStream(name: String, bytes: Int64)

    var errorDescription: String? {
        switch self {
        case .noPages(let name): "\(name) has no readable pages."
        case .pageOutOfRange(let index, let count): "Page \(index + 1) doesn't exist — this comic has \(count)."
        case .undecodable(let page): "Couldn't decode \(page)."
        case .tooLargeToStream(let name, let bytes):
            "\(name) is \(Formatting.bytes(bytes)) — download it before reading, PDFs can't be read a page at a time over the network."
        }
    }
}

/// Orders page names the way a person would: "page2" before "page10", chapter folders in order.
enum PageOrder {
    static func sort(_ names: [String]) -> [String] {
        names.sorted { $0.naturallyPrecedes($1) }
    }
}
