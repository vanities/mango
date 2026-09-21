import SwiftUI

struct RootView: View {
    @Environment(LibraryModel.self) private var library

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
    }
}
