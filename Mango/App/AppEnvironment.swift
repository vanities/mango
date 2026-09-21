import Foundation
import Observation

/// Composition root. Built once at launch and handed down through the SwiftUI environment,
/// so nothing reaches for a singleton and tests can build their own.
@MainActor
final class AppEnvironment {
    let settings: AppSettings
    let library: LibraryModel
    let transfers: TransferManager

    init() {
        let settings = AppSettings()
        let library = LibraryModel(settings: settings)
        self.settings = settings
        self.library = library
        self.transfers = TransferManager(library: library)
    }
}
