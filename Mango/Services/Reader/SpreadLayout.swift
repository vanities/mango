import Foundation

/// Decides which pages get shown side by side.
///
/// A printed volume falls open on pages 2-3, 4-5 and so on: the cover is alone, then pages pair
/// up. A double-page spread — one image that's wider than it is tall — has to break the pairing
/// and take the screen to itself, or the art gets cut in half.
enum SpreadLayout {
    /// Groups of page indices, in reading order. One index per group when spreads are off.
    static func groups(pageCount: Int, wide: Set<Int> = [], enabled: Bool) -> [[Int]] {
        guard pageCount > 0 else { return [] }
        guard enabled else { return (0..<pageCount).map { [$0] } }

        var out: [[Int]] = [[0]] // the cover stands alone
        var index = 1
        while index < pageCount {
            if wide.contains(index) {
                out.append([index])
                index += 1
            } else if index + 1 < pageCount, !wide.contains(index + 1) {
                out.append([index, index + 1])
                index += 2
            } else {
                out.append([index])
                index += 1
            }
        }
        return out
    }

    /// Which group a page ended up in — for restoring a saved position after the layout changes.
    static func groupIndex(containing page: Int, in groups: [[Int]]) -> Int {
        groups.firstIndex { $0.contains(page) } ?? 0
    }
}
