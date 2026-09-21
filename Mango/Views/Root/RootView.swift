import SwiftUI

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
        // Over everything, reader included: locked means nothing of the library shows.
        .overlay {
            if lock.isLocked {
                LockView(lock: lock)
            } else if lock.isCovered {
                // What the app switcher photographs.
                Rectangle().fill(.background).ignoresSafeArea()
                    .overlay { Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.tint) }
            }
        }
        .onChange(of: scenePhase) { _, phase in lock.sceneChanged(to: phase) }
    }
}
