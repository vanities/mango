import SwiftUI
import os
import ShelfKit

@main
struct MangoApp: App {
    @State private var environment = AppEnvironment.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment.library)
                .environment(environment.settings)
                .environment(environment.transfers)
                .environment(environment.lock)
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                // Widget taps and Siri land here as mango://open/<comic id>.
                .onOpenURL { url in
                    if url.isFileURL {
                        environment.library.addOpenedFile(url)
                    } else {
                        environment.library.handleDeepLink(url)
                    }
                }
                .task {
                    Logger.ui.info("[app] launched")
                    environment.library.watchOwnFolder()
                    await environment.library.scan()
                }
        }
    }
}
