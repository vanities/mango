import SwiftUI

/// Manual corrections, for when the filename lied. Overrides survive rescans.
struct EditComicView: View {
    let comic: Comic

    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var series = ""
    @State private var volume = ""
    @State private var chapter = ""
    @State private var author = ""
    @State private var findingCover = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Details") {
                    LabeledContent("Title") { TextField("Title", text: $title).multilineTextAlignment(.trailing) }
                    LabeledContent("Series") { TextField("Series", text: $series).multilineTextAlignment(.trailing) }
                    LabeledContent("Volume") {
                        TextField("—", text: $volume)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Chapter") {
                        TextField("—", text: $chapter)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Author") { TextField("Author", text: $author).multilineTextAlignment(.trailing) }
                }
                Section("Cover") {
                    Button("Find Cover…", systemImage: "photo.badge.magnifyingglass") { findingCover = true }
                    if library.hasCustomCover(comic) {
                        Button("Use Original Cover", systemImage: "arrow.uturn.backward") {
                            library.useOriginalCover(for: comic)
                        }
                    }
                }
                Section {
                    LabeledContent("File", value: comic.relativePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("Corrections are kept separately from the file and survive a rescan. Mango never renames or moves your files.")
                }
            }
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .onAppear(perform: load)
            .sheet(isPresented: $findingCover) { CoverPickerView(comic: comic, forSeries: false) }
        }
    }

    private func load() {
        title = comic.title
        series = comic.series ?? ""
        volume = comic.volume.map { Formatting.number($0) } ?? ""
        chapter = comic.chapter.map { Formatting.number($0) } ?? ""
        author = comic.author ?? ""
    }

    private func save() {
        var override = library.state.overrides[comic.id] ?? ComicOverride()
        override.title = title.nilIfEmpty
        override.series = series.nilIfEmpty
        override.volume = Double(volume)
        override.chapter = Double(chapter)
        override.author = author.nilIfEmpty
        library.setOverride(override, for: comic)
        dismiss()
    }
}
