import Foundation
import os
import SwiftUI
import ShelfKit

// MARK: - Hidden shelves and volumes

extension LibraryModel {
    func setHidden(_ hidden: Bool, for comic: Comic) {
        mutateState {
            if hidden { $0.hiddenComicIDs.insert(comic.id) } else { $0.hiddenComicIDs.remove(comic.id) }
        }
        if hidden { lockHiddenItems() }
        publishWidgetSnapshot()
    }

    var hasHiddenItems: Bool { !state.hiddenSeries.isEmpty || !state.hiddenComicIDs.isEmpty }

    /// Always concealed outside Mango, even while the in-app session is unlocked.
    var publicComics: [Comic] {
        LibraryDedupe.visible(comics: state.comics, remoteSourceIDs: remoteSourceIDs,
                             hidden: state.hiddenComicIDs, hiddenSeries: state.hiddenSeries)
    }

    var publicContinueReading: [Comic] {
        publicComics.filter { state.progress[$0.id]?.isStarted == true && state.progress[$0.id]?.finished != true }
            .sorted { (state.progress[$0.id]?.updatedAt ?? .distantPast) > (state.progress[$1.id]?.updatedAt ?? .distantPast) }
    }

    var publicLastRead: Comic? {
        publicComics.first { $0.id == state.lastComicID } ?? publicContinueReading.first
    }

    func isHidden(_ comic: Comic) -> Bool {
        state.hiddenComicIDs.contains(comic.id) || state.hiddenSeries.contains(SeriesGrouper.key(for: comic))
    }

    func isConcealed(_ comic: Comic) -> Bool { isHidden(comic) && !hiddenSession.isUnlocked }

    /// Includes hidden volumes, with local/NAS twins reconciled, for explicit bulk management.
    var hideableSeries: [Series] {
        SeriesGrouper.group(LibraryDedupe.visible(comics: state.comics, remoteSourceIDs: remoteSourceIDs,
                                                hidden: hiddenSession.isUnlocked ? [] : state.hiddenComicIDs))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func hideSeries(ids: Set<String>) {
        let valid = ids.intersection(Set(hideableSeries.map(\.id)))
        guard !valid.isEmpty else { return }
        mutateState { $0.hiddenSeries.formUnion(valid) }
        lockHiddenItems()
        publishWidgetSnapshot()
    }

    @discardableResult
    func unlockHiddenItems() async -> Bool {
        let generation = hiddenAuthenticationGeneration
        if settings.lockMode != .off {
            guard await AppLock.authenticate(reason: "Unlock hidden titles for this session") else { return false }
        }
        guard generation == hiddenAuthenticationGeneration else { return false }
        hiddenSession.unlock()
        rebuildSeries()
        scheduleHiddenExpiration()
        startCoverBackfill()
        return true
    }

    func lockHiddenItems() {
        hiddenAuthenticationGeneration += 1
        hiddenExpirationTask?.cancel()
        hiddenExpirationTask = nil
        let wasUnlocked = hiddenSession.isUnlocked
        hiddenSession.lock()
        if wasUnlocked { rebuildSeries() }
        if let comic = requestedComic, isHidden(comic) { requestedComic = nil }
    }

    func hiddenSceneChanged(to phase: ScenePhase) {
        hiddenShield.cover(phase != .active && hasHiddenItems)
        if phase == .background { lockHiddenItems() }
        if phase == .active { noteHiddenActivity() }
    }

    func noteHiddenActivity(at now: Date = .now) {
        guard hiddenSession.isUnlocked else { return }
        if hiddenSession.expire(at: now) {
            lockHiddenItems()
            rebuildSeries()
            return
        }
        hiddenSession.recordActivity(at: now)
        scheduleHiddenExpiration()
    }

    private func scheduleHiddenExpiration() {
        hiddenExpirationTask?.cancel()
        hiddenExpirationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(HiddenContentSession.inactivityLimit)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.noteHiddenActivity()
        }
    }

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
        if hidden { lockHiddenItems() }
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
