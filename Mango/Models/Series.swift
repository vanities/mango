import Foundation

/// A shelf: every comic that `SeriesGrouper` decided belongs to the same run. Purely derived —
/// never persisted, rebuilt from `[Comic]` on each scan.
struct Series: Identifiable, Hashable, Sendable {
    /// Normalized series name, so the same run merges across sources (local copy + NAS copy).
    let id: String
    var name: String
    var author: String?
    var comics: [Comic]

    var coverID: String? { comics.first(where: { $0.coverID != nil })?.coverID }
    var volumeCount: Int { comics.count }
    var totalBytes: Int64 { comics.reduce(0) { $0 + $1.totalBytes } }
    var isStandalone: Bool { comics.count == 1 && comics[0].volume == nil && comics[0].chapter == nil }

    /// "12 volumes" / "1 book".
    var subtitle: String {
        comics.count == 1 ? "1 book" : "\(comics.count) volumes"
    }
}
