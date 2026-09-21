import SwiftUI

/// The shelf. Series first — a run of 34 volumes should be one thing you tap, not 34 things
/// you scroll past.
struct LibraryView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(AppSettings.self) private var settings

    @State private var query = ""
    @State private var readingComic: Comic?

    private var shelves: [Series] { library.search(query) }

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Group {
                if library.state.comics.isEmpty {
                    emptyState
                } else if shelves.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    shelfList
                }
            }
            .navigationTitle("Library")
            // Must sit outside the lazy containers below — SwiftUI doesn't register a
            // navigationDestination declared inside a LazyVStack, and the links go dead.
            .navigationDestination(for: String.self) { id in
                if let shelf = library.series.first(where: { $0.id == id }) {
                    SeriesDetailView(series: shelf)
                }
            }
            .searchable(text: $query, prompt: "Series or title")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $settings.librarySort) {
                            ForEach(LibrarySort.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Picker("Layout", selection: $settings.libraryLayout) {
                            ForEach(LibraryLayout.allCases, id: \.self) {
                                Label($0 == .grid ? "Grid" : "List", systemImage: $0.systemImage).tag($0)
                            }
                        }
                        Toggle("Show finished", isOn: $settings.showFinished)
                        Divider()
                        Button {
                            Task { await library.scan() }
                        } label: {
                            Label("Rescan", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .overlay(alignment: .top) { scanBanner }
            .refreshable {
                await library.scan()
            }
            .fullScreenCover(item: $readingComic) { comic in
                ReaderView(comic: comic)
            }
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private var shelfList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                continueRow
                if settings.libraryLayout == .grid { grid } else { list }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var continueRow: some View {
        let inProgress = library.continueReading
        if !inProgress.isEmpty, query.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Continue Reading")
                    .font(.headline)
                    .padding(.horizontal)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(inProgress.prefix(12)) { comic in
                            Button { readingComic = comic } label: {
                                ComicThumbnail(comic: comic)
                                    .frame(width: 110)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110, maximum: 180), spacing: 14)], spacing: 18) {
            ForEach(shelves) { shelf in
                NavigationLink(value: shelf.id) {
                    SeriesCardView(series: shelf)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }

    private var list: some View {
        LazyVStack(spacing: 0) {
            ForEach(shelves) { shelf in
                NavigationLink(value: shelf.id) {
                    HStack(spacing: 12) {
                        CoverView(coverID: shelf.coverID, title: shelf.name)
                            .frame(width: 50)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(shelf.name).font(.body).lineLimit(1)
                            Text(shelf.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 78)
            }
        }
    }

    @ViewBuilder
    private var scanBanner: some View {
        if library.isScanning, let status = library.scanStatus {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(status).font(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(in: .capsule)
            .padding(.top, 4)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No comics yet", systemImage: "books.vertical")
        } description: {
            Text("Add a folder or a NAS share in Sources, or drop .cbz files into \"On My iPhone › Mango\" in the Files app.")
        } actions: {
            NavigationLink("Add a source") { SourcesView() }
                .buttonStyle(.glassProminent)
        }
    }
}

/// One shelf in the grid: the cover, the name, and how far through the run you are.
struct SeriesCardView: View {
    let series: Series
    @Environment(LibraryModel.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                CoverView(coverID: series.coverID, title: series.name)
                if series.volumeCount > 1 {
                    Text("\(series.volumeCount)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .glassEffect(in: .capsule)
                        .padding(6)
                }
            }
            Text(series.name)
                .font(.caption)
                .lineLimit(2, reservesSpace: true)
            let finished = library.finishedCount(in: series)
            if finished > 0 {
                Text("\(finished)/\(series.volumeCount) read")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
