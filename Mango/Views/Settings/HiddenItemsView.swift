import SwiftUI
import ShelfKit

/// Hidden names always require device authentication, independently of the whole-app lock.
struct HiddenItemsView: View {
    @Environment(LibraryModel.self) private var library
    private var needsUnlock: Bool { !library.hiddenSession.isUnlocked }

    var body: some View {
        List {
            if needsUnlock {
                Section {
                    HiddenSessionButton()
                } footer: {
                    Text("Unlock with Face ID to reveal hidden manga and novels in the library and Continue Reading. Device authentication is always required, even with App Lock off. They hide again when Mango enters the background or after three hours without activity.")
                }
            } else if library.hiddenShelves.isEmpty && library.hiddenVolumes.isEmpty {
                ContentUnavailableView("Nothing Hidden", systemImage: "eye",
                                       description: Text("Choose Hide titles… in the library menu, hide a series from its ••• menu, or touch and hold a volume."))
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
                                Button("Unhide") { library.unhideShelf(id: shelf.id) }
                                    .accessibilityLabel("Permanently unhide \(shelf.name)")
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
                                Button("Unhide") { library.setHidden(false, for: comic) }
                                    .accessibilityLabel("Permanently unhide \(comic.title)")
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Hidden")
        .toolbar {
            if library.hiddenSession.isUnlocked {
                ToolbarItem(placement: .topBarTrailing) { HiddenSessionButton() }
            }
        }
    }
}
