import Foundation

/// A shelf: every comic that `SeriesGrouper` decided belongs to the same run. Purely derived —
/// never persisted, rebuilt from `[Comic]` on each scan.
struct Series: Identifiable, Hashable, Sendable {
    /// Normalized series name, so the same run merges across sources (local copy + NAS copy).
    let id: String
    var name: String
    var author: String?
    var comics: [Comic]

    /// A shelf is all one medium — `SeriesGrouper` keys on it, so manga and light novels of
    /// the same series never land together.
    var isNovel: Bool { comics.first?.isNovel ?? false }

    var coverID: String? { comics.first(where: { $0.coverID != nil })?.coverID }
    var volumeCount: Int { comics.count }
    var totalBytes: Int64 { comics.reduce(0) { $0 + $1.totalBytes } }
    var isStandalone: Bool { comics.count == 1 && comics[0].volume == nil && comics[0].chapter == nil }

    /// "12 volumes", "201 chapters", "21 volumes, 34 chapters", "1 book".
    var subtitle: String {
        let chapters = comics.count { $0.chapter != nil }
        let volumes = comics.count { $0.volume != nil && $0.chapter == nil }
        guard volumes + chapters > 0 else { return comics.count == 1 ? "1 book" : "\(comics.count) books" }
        let parts = [(volumes, "volume"), (chapters, "chapter")]
            .filter { $0.0 > 0 }
            .map { count, noun in "\(count) \(noun)\(count == 1 ? "" : "s")" }
        return parts.joined(separator: ", ")
    }
}
