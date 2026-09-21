import SwiftUI

/// Every list, and a way to start one.
struct ReadingListsView: View {
    @Environment(LibraryModel.self) private var library
    @State private var naming = false
    @State private var newName = ""

    var body: some View {
        List {
            if library.state.readingLists.isEmpty {
                ContentUnavailableView("No Lists Yet", systemImage: "list.bullet.rectangle",
                                       description: Text("Make one here, or choose Add to List… on any series or volume."))
            }
            ForEach(library.state.readingLists) { list in
                NavigationLink {
                    ReadingListView(listID: list.id)
                } label: {
                    LabeledContent(list.name, value: "\(list.items.count)")
                }
            }
            .onDelete { offsets in
                for offset in offsets { library.deleteList(library.state.readingLists[offset].id) }
            }
        }
        .navigationTitle("Reading Lists")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New List", systemImage: "plus") { naming = true }
            }
        }
        .alert("New List", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Create") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { library.createList(named: name) }
                newName = ""
            }
            Button("Cancel", role: .cancel) { newName = "" }
        }
    }
}

/// One list, in your order. Series open their shelf; volumes open straight into the reader.
struct ReadingListView: View {
    let listID: UUID

    @Environment(LibraryModel.self) private var library
    @State private var reading: Comic?
    @State private var renaming = false
    @State private var newName = ""

    var body: some View {
        let list = library.readingList(id: listID)
        List {
            if let list {
                if list.items.isEmpty {
                    ContentUnavailableView("Nothing Here Yet", systemImage: "text.badge.plus",
                                           description: Text("Choose Add to List… on a series or a volume."))
                }
                ForEach(library.entries(of: list)) { entry in
                    row(entry)
                }
                .onMove { library.moveInList(listID, from: $0, to: $1) }
                .onDelete { offsets in
                    let entries = library.entries(of: list)
                    for offset in offsets { library.removeFromList(listID, entries[offset].item) }
                }
            }
        }
        .navigationTitle(list?.name ?? "List")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Rename…", systemImage: "pencil") {
                        newName = list?.name ?? ""
                        renaming = true
                    }
                    EditButton()
                } label: {
                    Label("List", systemImage: "ellipsis.circle")
                }
            }
        }
        .alert("Rename List", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { library.renameList(listID, to: name) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .fullScreenCover(item: $reading) { ReaderRouter(comic: $0) }
    }

    @ViewBuilder
    private func row(_ entry: LibraryModel.ListEntry) -> some View {
        switch entry {
        case .series(let shelf):
            NavigationLink(value: shelf.id) {
                label(coverID: shelf.coverID, title: shelf.name, detail: shelf.subtitle)
            }
        case .volume(let comic):
            Button { reading = comic } label: {
                label(coverID: comic.coverID, title: comic.series ?? comic.title,
                      detail: [comic.numberLabel, comic.subtitle].compactMap { $0 }.joined(separator: " · "))
            }
            .buttonStyle(.plain)
        case .missing:
            label(coverID: nil, title: "Not in the library right now", detail: "Comes back when its source does")
                .foregroundStyle(.secondary)
        }
    }

    private func label(coverID: String?, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            CoverView(coverID: coverID, title: title, cornerRadius: 5)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// Add to List…: tick the lists this series or volume belongs on, or start a new one.
struct ListPickerView: View {
    let item: ReadingList.Item
    let title: String

    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            Form {
                if !library.state.readingLists.isEmpty {
                    Section("Lists") {
                        ForEach(library.state.readingLists) { list in
                            let listed = library.isListed(item, in: list.id)
                            Button {
                                if listed { library.removeFromList(list.id, item) } else { library.addToList(list.id, item) }
                            } label: {
                                HStack {
                                    Text(list.name).foregroundStyle(.primary)
                                    Spacer()
                                    if listed { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                            }
                        }
                    }
                }
                Section("New list") {
                    TextField("Name, like “Up next”", text: $newName)
                        .onSubmit(create)
                    Button("Create and Add", action: create)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Add \(title) to…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let id = library.createList(named: name)
        library.addToList(id, item)
        newName = ""
    }
}
