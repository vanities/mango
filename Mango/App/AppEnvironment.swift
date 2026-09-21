import Foundation
import Observation

/// Composition root. Built once at launch and handed down through the SwiftUI environment,
/// so nothing reaches for a singleton and tests can build their own.
@MainActor
final class AppEnvironment {
    let settings: AppSettings
    let library: LibraryModel

    init() {
        let settings = AppSettings()
        self.settings = settings
        self.library = LibraryModel(settings: settings)
    }
}
