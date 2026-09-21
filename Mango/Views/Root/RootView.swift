import SwiftUI

struct RootView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(AppSettings.self) private var settings

    var body: some View {
        TabView {
            Tab("Library", systemImage: "books.vertical") {
                LibraryView()
            }
            Tab("Sources", systemImage: "folder") {
                SourcesView()
            }
            Tab("Settings", systemImage: "gearshape") {
                SettingsView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        // nil means "match the system" — the reader forces its own dark chrome regardless.
        .preferredColorScheme(settings.appearance.colorScheme)
    }
}
