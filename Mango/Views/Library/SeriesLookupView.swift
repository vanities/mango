import SwiftUI
import os

/// Look Up Series: find the shelf on AniList, pick the right match, and put its English title
/// and author on every volume — optionally its cover too. Nothing changes until Apply.
struct SeriesLookupView: View {
    let series: Series

    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var matches: [SeriesLookup.Match] = []
    @State private var isSearching = false
    @State private var chosen: SeriesLookup.Match?
    @State private var useCover = false
    @State private var applying = false
    @State private var errorMessage: String?
    /// Ended after each search: while it's presented, iOS swaps the toolbar (and Apply) for the
    /// search bar, and a picked match had no way to be applied.
    @State private var searchPresented = false
    /// What was last looked up — ending the search can clear the field.
    @State private var searched = ""

    init(series: Series) {
        self.series = series
        _text = State(initialValue: series.name)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Now") {
                    Text(series.name)
                    if let author = series.comics.lazy.compactMap(\.author).first {
                        LabeledContent("Author", value: author)
                    }
                }
                Section {
                    if isSearching && matches.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking it up…").foregroundStyle(.secondary)
                        }
                    } else if matches.isEmpty {
                        Text("Nothing found. Try fewer words — just the series' name.").foregroundStyle(.secondary)
                    }
                    ForEach(matches) { match in
                        Button { chosen = match } label: { row(match) }
                            .buttonStyle(.plain)
                    }
                } header: {
                    Text("On AniList")
                } footer: {
                    Text("Looked up “\(searched)” on AniList. Only the name was sent.")
                }
                if let chosen {
                    Section {
                        LabeledContent("Name", value: chosen.title)
                        if let author = chosen.author, series.comics.allSatisfy({ $0.author == nil }) {
                            LabeledContent("Author", value: author)
                        }
                        if chosen.coverURL != nil {
                            Toggle("Use its cover for the shelf", isOn: $useCover)
                        }
                    } header: {
                        Text("Will change")
                    } footer: {
                        Text("For the whole shelf (\(series.subtitle)). An author already known from the files is kept.")
                    }
                }
            }
            .searchable(text: $text, isPresented: $searchPresented, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Series name")
            .onSubmit(of: .search) {
                let term = text
                searchPresented = false
                Task { await search(term) }
            }
            .navigationTitle("Look Up Series")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if applying {
                        ProgressView()
                    } else {
                        Button("Apply") { Task { await apply() } }.disabled(chosen == nil)
                    }
                }
            }
            .alert("Couldn't Use That Cover", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { dismiss() }
            } message: {
                Text(errorMessage ?? "")
            }
            .task { await search(series.name) }
        }
    }

    private func row(_ match: SeriesLookup.Match) -> some View {
        HStack(spacing: 12) {
            Color.clear
                .frame(width: 44)
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay {
                    AsyncImage(url: match.thumbnailURL) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() } else { Rectangle().fill(.quaternary) }
                    }
                }
                .clipShape(.rect(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(match.title).font(.body.weight(.medium))
                if let original = match.originalTitle {
                    Text(original).font(.caption).foregroundStyle(.secondary)
                }
                Text([match.year.map(String.init), match.author].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if chosen?.id == match.id {
                Image(systemName: "checkmark").foregroundStyle(.tint)
            }
        }
        .contentShape(.rect)
    }

    private func search(_ term: String) async {
        isSearching = true
        defer { isSearching = false }
        chosen = nil
        searched = term
        matches = await SeriesLookup.search(term, isNovel: series.isNovel)
    }

    private func apply() async {
        guard let chosen else { return }
        applying = true
        defer { applying = false }
        library.renameSeries(series, to: chosen.title, author: chosen.author)
        if useCover, let url = chosen.coverURL, let first = series.comics.first {
            do {
                let data = try await CoverSearch.download(url)
                guard await library.setCustomCover(data, origin: url.absoluteString, for: first) else {
                    errorMessage = "The name was changed, but that cover couldn't be read."
                    return
                }
            } catch {
                errorMessage = "The name was changed, but the cover didn't download: \(error.localizedDescription)"
                return
            }
        }
        dismiss()
    }
}
