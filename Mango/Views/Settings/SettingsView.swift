import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryModel.self) private var library

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

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.shortVersion)
                    Link("Source code", destination: URL(string: "https://github.com/vanities/mango")!)
                }

                Section {
                    Text("Mango reads the comics you already have — on this device or on your NAS — and never copies, moves, or renames them. No accounts, no tracking, no tip jar.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
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
