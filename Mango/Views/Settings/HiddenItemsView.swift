import SwiftUI

/// Everything hidden, and the way back. Behind Face ID when the lock is on — otherwise the list
/// of what's hidden would give it away.
struct HiddenItemsView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(AppSettings.self) private var settings
    @State private var revealed = false

    private var needsUnlock: Bool { settings.lockMode != .off && !revealed }

    var body: some View {
        List {
            if needsUnlock {
                Section {
                    Button("Show Hidden Items") {
                        Task { revealed = await AppLock.authenticate(reason: "Show hidden items") }
                    }
                } footer: {
                    Text("Hidden items stay behind Face ID while the lock is on.")
                }
            } else if library.hiddenShelves.isEmpty && library.hiddenVolumes.isEmpty {
                ContentUnavailableView("Nothing Hidden", systemImage: "eye",
                                       description: Text("Hide a series from its ••• menu, or a volume by touching and holding it."))
            } else {
                if !library.hiddenShelves.isEmpty {
                    Section("Series") {
                        ForEach(library.hiddenShelves) { shelf in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(shelf.name)
                                    Text(shelf.count == 1 ? "1 book" : "\(shelf.count) books")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Show") { library.unhideShelf(id: shelf.id) }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
                if !library.hiddenVolumes.isEmpty {
                    Section("Volumes") {
                        ForEach(library.hiddenVolumes) { comic in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(comic.series ?? comic.title)
                                    if let label = comic.numberLabel {
                                        Text(label).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Button("Show") { library.setHidden(false, for: comic) }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Hidden")
    }
}
