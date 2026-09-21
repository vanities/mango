import SwiftUI
import os

@main
struct MangoApp: App {
    @State private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment.library)
                .environment(environment.settings)
                .task {
                    Logger.ui.info("[app] launched")
                    await environment.library.scan()
                }
        }
    }
}
