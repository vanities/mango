import SwiftUI
import ShelfKit

/// Adding an SMB share: ShelfKit's form, the same one Earmark uses. The share is added only once
/// it answers; the password goes to the Keychain, never into the library JSON.
struct NASSetupView: View {
    @Environment(LibraryModel.self) private var library

    var body: some View {
        NASSetupForm(
            folderPlaceholder: "comics",
            footer: "Folder is optional — the path inside the share to treat as the top of the library, like \"comics\" or \"media/manga\"."
        ) { server, password in
            library.addServer(server, password: password)
        }
    }
}
