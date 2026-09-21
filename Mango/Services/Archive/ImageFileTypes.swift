import Foundation
import UniformTypeIdentifiers

enum ImageFileTypes {
    /// Extensions iOS can decode. `.jxl` is deliberately absent — no system decoder.
    static let pageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "gif", "webp", "avif", "heic", "heif", "bmp", "tif", "tiff",
    ]

    /// Container extensions Mango treats as one comic.
    /// `.cbr` is deliberately absent: RAR's only decoder is non-free and can't ship in a GPL-3
    /// app. Convert those to `.cbz` with `scripts/convert-to-cbz.sh`.
    static let comicExtensions: Set<String> = ["cbz", "zip", "pdf"]

    /// Reflowable books. An EPUB is a zip too, so the same reader opens it — but it's read as
    /// text, so it gets its own kind and its own shelf.
    static let novelExtensions: Set<String> = ["epub"]

    /// Comic archives Mango recognises but can't open: RAR (non-free decoder), 7z, tar. The
    /// scan counts them so a series kept this way doesn't just silently not exist.
    static let unreadableArchiveExtensions: Set<String> = ["cbr", "rar", "cb7", "7z", "cbt", "tar"]

    static func isUnreadableArchive(_ name: String) -> Bool {
        unreadableArchiveExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    /// "3 files in RAR or 7z", from a scan's per-extension counts.
    static func describeUnreadable(_ counts: [String: Int]) -> String? {
        let total = counts.values.reduce(0, +)
        guard total > 0 else { return nil }
        let formats = [("RAR", ["cbr", "rar"]), ("7z", ["cb7", "7z"]), ("tar", ["cbt", "tar"])]
            .filter { _, extensions in extensions.contains { counts[$0, default: 0] > 0 } }
            .map(\.0)
        let list = formats.count > 1
            ? formats.dropLast().joined(separator: ", ") + " or " + (formats.last ?? "")
            : (formats.first ?? "")
        return "\(total) \(total == 1 ? "file" : "files") in \(list)"
    }

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
