import SwiftUI
import ShelfKit

struct LibraryToolsView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(TransferManager.self) private var transfers
    @State private var reading: Comic?
    private var tools: Binding<LibraryToolsState> {
        Binding(get: { library.state.tools }, set: { value in library.mutateState { $0.tools = value } })
    }
    var body: some View {
        List {
            NavigationLink("Prepare for a trip") {
                TripPreparationView(items: library.toolItems, groups: library.tripGroups,
                                    check: library.checkOffline, download: download)
            }
            NavigationLink("Smart lists") {
                SmartShelvesView(items: library.toolItems, state: tools, open: open)
            }
            NavigationLink("New arrivals") {
                NewArrivalsView(items: library.toolItems, state: tools, download: download, open: open)
            }
            Button("Show dismissed series gaps again") { library.mutateState { $0.tools.dismissedGaps.removeAll() } }
                .disabled(library.state.tools.dismissedGaps.isEmpty)
            NavigationLink("Backup and restore") { LibraryBackupView() }
            NavigationLink("Reconnect a folder") { ReconnectLibraryView() }
        }
        .navigationTitle("Library tools")
        .fullScreenCover(item: $reading) { ReaderRouter(comic: $0) }
    }
    private func open(_ key: String) {
        reading = library.visibleComics.first { $0.syncKey == key }
    }
    private func download(_ keys: Set<String>) async -> String {
        var requested = 0, ready = 0, unavailable = 0
        for key in keys {
            if await library.checkOffline(key: key) == .ready { ready += 1; continue }
            if let comic = library.visibleComics.first(where: { $0.syncKey == key }),
               let source = comic.isRemote(in: library) ? comic : library.nasCopy(of: comic) {
                transfers.download(source)
                requested += 1
            } else { unavailable += 1 }
        }
        return "\(requested) downloads requested; \(ready) already ready."
            + (unavailable > 0 ? " \(unavailable) need attention in Files or Sources." : " Check Sources for transfer progress, then verify here.")
    }
}
