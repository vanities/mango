import SwiftUI

/// Choose many manga and novel series at once, without changing or moving their files.
struct HideSeriesPickerView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []
    @State private var query = ""
    @State private var medium: Medium = .manga

    private var shelves: [Series] {
        library.hideableSeries.filter {
            $0.isNovel == (medium == .novels) && !library.state.hiddenSeries.contains($0.id)
                && (query.isEmpty || $0.name.localizedStandardContains(query)
                    || $0.comics.contains { $0.title.localizedStandardContains(query) })
        }
    }

    var body: some View {
        NavigationStack {
            List(selection: $selection) {
                Section {
                    Picker("Medium", selection: $medium) {
                        ForEach(Medium.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                }
                Section {
                    ForEach(shelves) { shelf in
                        HStack(spacing: 12) {
                            CoverView(coverID: shelf.coverID, title: shelf.name).frame(width: 40)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(shelf.name)
                                Text(shelf.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(shelf.id)
                    }
                } footer: {
                    Text("Selections stay checked when you switch between manga and novels. Hidden series include new volumes added later.")
                }
            }
            .environment(\.editMode, .constant(.active))
            .searchable(text: $query, prompt: "Find titles to hide")
            .navigationTitle("Hide Titles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Hide \(selection.count)") {
                        library.hideSeries(ids: selection)
                        dismiss()
                    }
                    .disabled(selection.isEmpty)
                    .accessibilityIdentifier("Hide Selected Titles")
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Select All Shown") { selection.formUnion(shelves.map(\.id)) }
                        .disabled(shelves.isEmpty)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Clear Selection") { selection.removeAll() }.disabled(selection.isEmpty)
                }
            }
        }
    }
}
