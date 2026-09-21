import Foundation
import UniformTypeIdentifiers

enum ImageFileTypes {
    /// Extensions iOS can decode. `.jxl` is deliberately absent — no system decoder.
    static let pageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "gif", "webp", "avif", "heic", "heif", "bmp", "tif", "tiff",
    ]

    /// Container extensions Mango treats as one comic.
    /// `.cbr` is deliberately absent: RAR's only decoder is non-free and can't ship in a GPL-3
    /// app. Convert those to `.cbz` (`scripts/cbr-to-cbz.sh` on the NAS side).
    static let comicExtensions: Set<String> = ["cbz", "zip", "pdf"]

    /// Reflowable books. An EPUB is a zip too, so the same reader opens it — but it's read as
    /// text, so it gets its own kind and its own shelf.
    static let novelExtensions: Set<String> = ["epub"]

    static func isPage(_ name: String) -> Bool {
        pageExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    static func isComic(_ name: String) -> Bool {
        comicExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    static func isNovel(_ name: String) -> Bool {
        novelExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// Anything Mango can open.
    static func isReadable(_ name: String) -> Bool {
        isComic(name) || isNovel(name)
    }

    static func kind(for name: String) -> Comic.Kind {
        switch (name as NSString).pathExtension.lowercased() {
        case "epub": .epub
        case "pdf": .pdf
        default: .archive
        }
    }

    /// Junk that shows up inside comic archives and would otherwise be read as blank pages:
    /// macOS resource forks, Finder metadata, Windows thumbnail caches, hidden files.
    static func isJunk(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.hasPrefix("__macosx/") || lower.contains("/__macosx/") { return true }
        let name = (path as NSString).lastPathComponent
        if name.hasPrefix("._") || name.hasPrefix(".") { return true }
        if name.lowercased() == "thumbs.db" || name.lowercased() == "desktop.ini" { return true }
        return false
    }
}
