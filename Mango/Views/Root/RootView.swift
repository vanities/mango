import SwiftUI
import ShelfKit
import UIKit

struct RootView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(AppLock.self) private var lock
    @Environment(\.scenePhase) private var scenePhase

    @State private var openedComic: Comic?

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
        // As in Earmark: the bar gets out of the way while you scroll a long shelf.
        .tabBarMinimizeBehavior(.onScrollDown)
        // The lock draws in a window of its own above this one: an overlay here sat under the
        // full-screen reader, so a page showed straight through the lock. `initial` puts it up
        // at launch.
        .onChange(of: scenePhase, initial: true) { _, phase in
            library.hiddenSceneChanged(to: phase)
            lock.sceneChanged(to: phase)
            if phase == .active {
                library.sceneBecameActive()
                openRequestedComic()
            }
        }
        .gesture(HiddenActivityTapGesture { library.noteHiddenActivity() })
        .onChange(of: library.requestedComic) { _, _ in openRequestedComic() }
        .fullScreenCover(item: $openedComic) { ReaderRouter(comic: $0) }
    }

    private func openRequestedComic() {
        guard scenePhase == .active, let comic = library.requestedComic else { return }
        library.requestedComic = nil
        openedComic = comic
    }
}

/// Observe taps without cancelling UIKit controls, including the adaptive tab sidebar.
/// A SwiftUI TapGesture on the whole TabView prevented its collection cells selecting.
private struct HiddenActivityTapGesture: UIGestureRecognizerRepresentable {
    let onActivity: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer {
        let recognizer = UITapGestureRecognizer()
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        guard recognizer.state == .ended else { return }
        onActivity()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
}
