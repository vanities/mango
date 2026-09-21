import Foundation
import os

// MARK: - Hidden shelves and volumes

extension LibraryModel {
    struct HiddenShelf: Identifiable, Hashable {
        let id: String
        let name: String
        let count: Int
    }

    /// Hides (or brings back) a whole shelf — by shelf id, so volumes added later stay hidden.
    func setSeriesHidden(_ hidden: Bool, _ series: Series) {
        mutateState { state in
            if hidden { state.hiddenSeries.insert(series.id) } else { state.hiddenSeries.remove(series.id) }
        }
        Logger.library.info("[library] \(hidden ? "hid" : "unhid", privacy: .public) shelf \"\(series.name, privacy: .public)\"")
        publishWidgetSnapshot()
    }

    func unhideShelf(id: String) {
        mutateState { state in _ = state.hiddenSeries.remove(id) }
        publishWidgetSnapshot()
    }

    /// Hidden shelves, named from the comics on them (a hidden shelf isn't in `series`).
    var hiddenShelves: [HiddenShelf] {
        let byShelf = Dictionary(grouping: state.comics) { SeriesGrouper.key(for: $0) }
        return state.hiddenSeries.compactMap { id -> HiddenShelf? in
            guard let comics = byShelf[id], let first = comics.first else { return nil }
            return HiddenShelf(id: id, name: first.series ?? first.title, count: comics.count)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Volumes hidden one at a time (Hide on a volume).
    var hiddenVolumes: [Comic] {
        state.comics.filter { state.hiddenComicIDs.contains($0.id) }
            .sorted { ($0.series ?? $0.title).localizedStandardCompare($1.series ?? $1.title) == .orderedAscending }
    }
}
