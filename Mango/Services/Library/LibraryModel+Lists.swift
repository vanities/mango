import Foundation
import os

// MARK: - Reading lists

extension LibraryModel {
    /// What a list entry is today: the shelf (following renames), or the copy of the volume on
    /// screen — or nothing, when it's left the library (it stays listed, and comes back with it).
    enum ListEntry: Identifiable {
        case series(Series)
        case volume(Comic)
        case missing(ReadingList.Item)

        var id: String {
            switch self {
            case .series(let series): "s|" + series.id
            case .volume(let comic): "v|" + comic.syncKey
            case .missing(let item): "m|\(item)"
            }
        }

        var item: ReadingList.Item {
            switch self {
            case .series(let series): .series(series.id)
            case .volume(let comic): .volume(comic.syncKey)
            case .missing(let item): item
            }
        }
    }

    func entries(of list: ReadingList) -> [ListEntry] {
        let visible = Dictionary(visibleComics.map { ($0.syncKey, $0) }, uniquingKeysWith: { first, _ in first })
        return list.items.map { item in
            switch item {
            case .series(let id): shelf(id: id).map(ListEntry.series) ?? .missing(item)
            case .volume(let key): visible[key].map(ListEntry.volume) ?? .missing(item)
            }
        }
    }

    func readingList(id: UUID) -> ReadingList? { state.readingLists.first { $0.id == id } }

    @discardableResult
    func createList(named name: String) -> UUID {
        var id = UUID()
        mutateState { id = $0.createList(named: name) }
        Logger.library.info("[lists] created \"\(name, privacy: .public)\"")
        return id
    }

    func deleteList(_ id: UUID) { mutateState { $0.deleteList(id) } }
    func renameList(_ id: UUID, to name: String) { mutateState { $0.renameList(id, to: name) } }
    func addToList(_ id: UUID, _ item: ReadingList.Item) { mutateState { $0.addToList(id, item) } }
    func removeFromList(_ id: UUID, _ item: ReadingList.Item) { mutateState { $0.removeFromList(id, item) } }
    func moveInList(_ id: UUID, from offsets: IndexSet, to destination: Int) {
        mutateState { $0.moveInList(id, from: offsets, to: destination) }
    }

    func isListed(_ item: ReadingList.Item, in id: UUID) -> Bool {
        readingList(id: id)?.items.contains(item) ?? false
    }
}
