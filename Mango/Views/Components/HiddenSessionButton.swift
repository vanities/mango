import SwiftUI

/// One shared action in the Library, Hidden settings, and a concealed series.
struct HiddenSessionButton: View {
    @Environment(LibraryModel.self) private var library
    @State private var authenticating = false

    var body: some View {
        Button(library.hiddenSession.isUnlocked ? "Hide Hidden Titles" : "Unlock Hidden",
               systemImage: library.hiddenSession.isUnlocked ? "eye.slash" : "lock.open") {
            if library.hiddenSession.isUnlocked {
                library.lockHiddenItems()
            } else {
                authenticating = true
                Task {
                    _ = await library.unlockHiddenItems()
                    authenticating = false
                }
            }
        }
        .disabled(authenticating)
        .accessibilityIdentifier("Hidden Session Toggle")
    }
}
