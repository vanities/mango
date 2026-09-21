import SwiftUI
import os

@main
struct MangoApp: App {
    @State private var environment = AppEnvironment.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment.library)
                .environment(environment.settings)
                .environment(environment.transfers)
                // Widget taps and Siri land here as mango://open/<comic id>.
                .onOpenURL { url in environment.library.handleDeepLink(url) }
                .task {
                    Logger.ui.info("[app] launched")
                    await environment.library.scan()
                }
        }
    }
}
