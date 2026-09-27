import Foundation

/// Only internal holes in ordinary volume numbering. Ambiguous collected editions are held.
enum SeriesGaps {
    static func missing(in comics: [Comic]) -> [Int] {
        var present: Set<Int> = []
        for comic in comics where comic.chapter == nil {
            let name = comic.relativePath.lowercased()
            // Edition numbering isn't volume numbering. Suppress guesses rather than report false gaps.
            if ["omnibus", "3-in-1", "2-in-1", "collected", "box set"].contains(where: name.contains) { return [] }
            guard let volume = comic.volume, volume.isFinite, volume.rounded() == volume,
                  volume >= 1, volume <= 10000 else { continue }
            present.insert(Int(volume))
        }
        guard let first = present.min(), let last = present.max(), last > first, last - first <= 1000 else { return [] }
        return (first...last).filter { !present.contains($0) }
    }
    static func key(series: Series, volume: Int) -> String { "\(series.id)|missing-volume|\(volume)" }
}
