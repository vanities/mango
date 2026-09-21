import Foundation

enum Formatting {
    /// "1.2 GB", "340 MB" — what the file actually weighs on disk.
    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: count)
    }

    /// "12" for a whole number, "12.5" for a half chapter. Manga numbering is full of .5s.
    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }

    /// "Page 14 of 192".
    static func pagePosition(_ page: Int, of total: Int) -> String {
        total > 0 ? "Page \(page + 1) of \(total)" : "Page \(page + 1)"
    }
}
