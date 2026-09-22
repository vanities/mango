import SwiftUI
import ShelfKit

struct RootView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(AppLock.self) private var lock
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            Tab("Library", systemImage: "books.vertical") {
                LibraryView()
            }
            Tab("Stats", systemImage: "chart.bar") {
                StatsView()
            }
            Tab("Sources", systemImage: "folder") {
                SourcesView()
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // The lock draws in a window of its own above this one: an overlay here sat under the
        // full-screen reader, so a page showed straight through the lock. `initial` puts it up
        // at launch.
        .onChange(of: scenePhase, initial: true) { _, phase in lock.sceneChanged(to: phase) }
    }
}
