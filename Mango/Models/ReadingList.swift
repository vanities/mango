import Foundation

/// A list of your own across the library — "Up next", "JoJo in order", a to-read pile.
struct ReadingList: Identifiable, Codable, Hashable, Sendable {
    /// A whole series, by shelf id, or one volume, by its file (`Comic.syncKey`) — so a download
    /// or a rescan never drops it.
    enum Item: Codable, Hashable, Sendable {
        case series(String)
        case volume(String)

        init(_ comic: Comic) { self = .volume(comic.syncKey) }
        init(_ series: Series) { self = .series(series.id) }
    }

    let id: UUID
    var name: String
    var items: [Item]
    var createdAt: Date

    init(id: UUID = UUID(), name: String, items: [Item] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.items = items
        self.createdAt = createdAt
    }
}

extension LibraryState {
    @discardableResult
    mutating func createList(named name: String) -> UUID {
        let list = ReadingList(name: name)
        readingLists.append(list)
        return list.id
    }

    mutating func deleteList(_ id: UUID) {
        readingLists.removeAll { $0.id == id }
    }

    mutating func renameList(_ id: UUID, to name: String) {
        guard let index = readingLists.firstIndex(where: { $0.id == id }) else { return }
        readingLists[index].name = name
    }

    /// Adds to the end; something already on the list stays where it is.
    mutating func addToList(_ id: UUID, _ item: ReadingList.Item) {
        guard let index = readingLists.firstIndex(where: { $0.id == id }),
              !readingLists[index].items.contains(item) else { return }
        readingLists[index].items.append(item)
    }

    mutating func removeFromList(_ id: UUID, _ item: ReadingList.Item) {
        guard let index = readingLists.firstIndex(where: { $0.id == id }) else { return }
        readingLists[index].items.removeAll { $0 == item }
    }

    mutating func moveInList(_ id: UUID, from offsets: IndexSet, to destination: Int) {
        guard let index = readingLists.firstIndex(where: { $0.id == id }) else { return }
        readingLists[index].items.move(fromOffsets: offsets, toOffset: destination)
    }
}
