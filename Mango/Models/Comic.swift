import Foundation

/// One readable thing: a volume, a chapter, or a single issue. Derived from the files on
/// disk by `LibraryScanner` and rebuilt on every scan — user state lives in `LibraryState`
/// keyed by the stable `id`, so it survives rescans.
struct Comic: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// A `.cbz` — a zip full of page images. The common case.
        case archive
        /// A `.pdf`.
        case pdf
        /// A folder of loose page images (001.jpg, 002.jpg, ...).
        case folder
        /// An `.epub` — a light novel or any reflowable book. Read as text, not as pages.
        case epub
    }

    /// Stable across rescans while the file layout doesn't change: `"<sourceID>|<relativePath>"`.
    let id: String
    var sourceID: UUID
    /// Relative to the source root: the file for `.archive`/`.pdf`, the folder for `.folder`.
    var relativePath: String
    var kind: Kind

    var title: String
    var series: String?
    /// Volume or issue number. Doubles because manga numbering is full of halves (v12.5).
    var volume: Double?
    /// Chapter number, when a file is one chapter rather than a bound volume.
    var chapter: Double?
    var author: String?
    var year: Int?
    /// Episode or volume title, when the filename carried one beyond the series and the number.
    /// Optional, so older library files still decode.
    var subtitle: String?

    /// Filled in the first time the archive is opened — cracking every archive during a scan
    /// would make scanning a 2,000-file share unbearable, so this stays nil until then.
    var pageCount: Int?
    var totalBytes: Int64
    var addedAt: Date
    /// Key into `ArtworkStore`. Covers are the only thing Mango ever writes about a comic.
    var coverID: String?

    // MARK: Derived

    /// Novels get their own shelf in the library: reading a light novel and reading a manga
    /// are different activities, even when they're the same series.
    var isNovel: Bool { kind == .epub }

    /// Device-independent identity for cross-device sync. Unlike `id`, it omits the per-install
    /// source UUID, so the same file on another device resolves to the same key.
    var syncKey: String { relativePath.lowercased() }

    var displaySeries: String { series ?? title }

    /// "Vol. 3", "Ch. 12.5", or nil for a standalone.
    var numberLabel: String? {
        if let volume { return "Vol. \(Formatting.number(volume))" }
        if let chapter { return "Ch. \(Formatting.number(chapter))" }
        return nil
    }

    /// Sort key inside a series: volume, then chapter, then title.
    var sortKey: Double { volume ?? chapter ?? .greatestFiniteMagnitude }

    /// "CBZ · 184 MB" — what the user actually has.
    var formatLabel: String {
        let format: String
        switch kind {
        case .archive: format = "CBZ"
        case .pdf: format = "PDF"
        case .folder: format = "Folder"
        case .epub: format = "EPUB"
        }
        return "\(format) · \(Formatting.bytes(totalBytes))"
    }

    static func makeID(sourceID: UUID, relativePath: String) -> String {
        "\(sourceID.uuidString)|\(relativePath)"
    }
}
