import SwiftUI
import ShelfKit

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryModel.self) private var library
    @Environment(AppLock.self) private var lock
    @State private var confirmingRemoveAll = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section("Reading") {
                    Picker("Default direction", selection: $settings.defaultDirection) {
                        ForEach(ReadingDirection.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Default layout", selection: $settings.defaultMode) {
                        ForEach(ReaderMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Page fit", selection: $settings.pageFit) {
                        ForEach(PageFit.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Two-page spreads", selection: $settings.spreadMode) {
                        ForEach(SpreadMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                }
                Section {
                    Picker("Dragging sideways", selection: $settings.horizontalPan) {
                        ForEach(PanDirection.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Dragging up and down", selection: $settings.verticalPan) {
                        ForEach(PanDirection.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } header: {
                    Text("Panning a zoomed page")
                } footer: {
                    Text("Moves the view: drag right and you see what's off to the right, like panning a map. Moves the page: it follows your finger, like sliding a photo. The two axes can differ — sideways often wants one and up-down the other.")
                }

                Section {
                    Toggle("Tap edges to turn", isOn: $settings.tapToTurn)
                    Toggle("Keep screen awake", isOn: $settings.keepScreenAwake)
                    Toggle("Black background", isOn: $settings.blackBackground)
                    Picker("Pages to load ahead", selection: $settings.prefetchCount) {
                        ForEach(AppSettings.prefetchChoices, id: \.self) { Text("\($0)").tag($0) }
                    }
                } header: {
                    Text("Behaviour")
                } footer: {
                    Text("Loading more pages ahead makes turns instant and uses more memory. Over a network, three is about right.")
                }

                Section {
                    LabeledContent("On this device",
                                   value: "\(library.downloads.count) · \(Formatting.bytes(library.downloadedBytes))")
                    Toggle("Remove when finished", isOn: $settings.removeFinishedDownloads)
                    Button("Remove Finished Downloads") { library.removeDownloads(library.finishedDownloads) }
                        .disabled(library.finishedDownloads.isEmpty)
                    Button("Remove All Downloads", role: .destructive) { confirmingRemoveAll = true }
                        .disabled(library.downloads.isEmpty)
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("A removed download goes back to being read from your NAS — your place, bookmarks and rating stay. Only copies that are still on the NAS are listed here.")
                }

                Section {
                    Picker("Lock with Face ID", selection: Binding(
                        get: { settings.lockMode },
                        set: { mode in
                            Task {
                                // Asks first; the picker snaps back if Face ID says no.
                                if await lock.setMode(mode) { library.publishWidgetSnapshot() }
                            }
                        }
                    )) {
                        ForEach(LockMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .disabled(!AppLock.canLock)
                    NavigationLink {
                        HiddenItemsView()
                    } label: {
                        LabeledContent("Hidden", value: "\(library.state.hiddenSeries.count + library.state.hiddenComicIDs.count)")
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text(AppLock.canLock
                         ? "With the lock on, Mango asks for Face ID when it opens, covers itself in the app switcher, and the widget stops showing what you're reading."
                         : "Set a passcode for this device to use the lock.")
                }

                Section {
                    Toggle("Demo library", isOn: $settings.demoMode)
                } footer: {
                    Text("Shows only what's in Mango's own folder and ignores every NAS share and added folder — for screenshots, so a real library never ends up in one. Your sources are left exactly as they are.")
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.shortVersion)
                    Link("Source code", destination: URL(string: "https://github.com/vanities/mango")!)
                }

                Section {
                    Text("Mango reads the comics you already have — on this device or on your NAS — and never copies, moves, renames or deletes them unless you ask. No accounts, no tracking, no tip jar.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Remove all \(library.downloads.count) downloads?", isPresented: $confirmingRemoveAll,
                                titleVisibility: .visible) {
                Button("Remove \(Formatting.bytes(library.downloadedBytes))", role: .destructive) {
                    library.removeDownloads(library.downloads)
                }
            } message: {
                Text("They stay on your NAS, and Mango reads them from there again.")
            }
        }
    }
}

extension Bundle {
    var shortVersion: String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
