import Foundation
import os
import ShelfKit

/// Turns a flat list of scanned comics into shelves.
///
/// Pure logic, no I/O, so it's all unit-testable — and it needs to be, because this is the part
/// users notice when it's wrong. Rules, in order:
///
/// 1. Comics with the same normalized series name are one run, even across sources — the NAS
///    copy and the downloaded copy of Berserk v3 land on the same shelf.
/// 2. A run is sorted by volume, then chapter, then name, so v2 comes before v10.
/// 3. A one-off with no volume or chapter is a standalone, and stays on its own shelf.
enum SeriesGrouper {
    static func group(_ comics: [Comic]) -> [Series] {
        let sw = Stopwatch()
        var buckets: [String: [Comic]] = [:]
        for comic in comics {
            buckets[key(for: comic), default: []].append(comic)
        }

        let series = buckets.map { key, members -> Series in
            let sorted = members.sorted(by: order)
            // Prefer the longest spelling as the display name: "Vinland Saga" over "Vinland".
            let name = sorted.compactMap(\.series).max(by: { $0.count < $1.count })
                ?? sorted.first?.title
                ?? key
            return Series(id: key, name: name, author: sorted.compactMap(\.author).first, comics: sorted)
        }
        .sorted { $0.name.naturallyPrecedes($1.name) }

        Logger.library.info("[group] \(comics.count) comics → \(series.count) series in \(sw.ms, format: .fixed(precision: 1))ms")
        return series
    }

    /// Shelf identity. Normalized so punctuation and casing don't split a run in two, and
    /// prefixed by medium so the manga and the light novel of the same series are two shelves
    /// — Mushoku Tensei exists as both, and they are not the same thing to read.
    static func key(for comic: Comic) -> String {
        let medium = comic.isNovel ? "novel" : "comic"
        return medium + "|" + key(forName: comic.series ?? comic.title, fallback: comic.title)
    }

    static func key(forName name: String, fallback: String = "") -> String {
        let normalized = name.normalizedForIdentity
        return normalized.isEmpty ? fallback.lowercased() : normalized
    }

    /// Reading order within a shelf.
    static func order(_ lhs: Comic, _ rhs: Comic) -> Bool {
        let left = lhs.sortKey, right = rhs.sortKey
        if left != right { return left < right }
        let leftChapter = lhs.chapter ?? .greatestFiniteMagnitude
        let rightChapter = rhs.chapter ?? .greatestFiniteMagnitude
        if leftChapter != rightChapter { return leftChapter < rightChapter }
        return lhs.title.naturallyPrecedes(rhs.title)
    }

    /// The next unread volume in a run — what "Continue" should open.
    static func nextUp(in series: Series, progress: [String: ReadingProgress]) -> Comic? {
        // Something already started beats something never opened.
        if let started = series.comics.first(where: { comic in
            guard let p = progress[comic.id] else { return false }
            return p.isStarted && !p.finished
        }) {
            return started
        }
        return series.comics.first { progress[$0.id]?.finished != true }
    }
}
