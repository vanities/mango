import ShelfKit
import SwiftUI

/// The shelf. Series first — a run of 34 volumes should be one thing you tap, not 34 things
/// you scroll past.
struct LibraryView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(AppSettings.self) private var settings

    @Environment(\.horizontalSizeClass) private var sizeClass

    @State private var query = ""
    @State private var readingComic: Comic?
    @State private var medium: Medium = .manga
    @State private var showingLists = false
    @State private var showingOffline = false
    @State private var showingBookmarks = false
    @State private var showingPicker = false

    /// Covers should be about the same physical size on both devices, not the same point size —
    /// phone-sized cards on a 13" iPad leave a sea of white and make the shelf look empty.
    private var coverWidth: (min: CGFloat, max: CGFloat) {
        sizeClass == .regular ? (170, 230) : (110, 180)
    }

    private var shelves: [Series] { library.search(query, in: medium) }
    /// Only worth showing the switch once there's something on both shelves.
    private var showsMediumPicker: Bool { library.hasNovels && library.hasComics }

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Group {
                if library.state.comics.isEmpty {
                    emptyState
                } else if shelves.isEmpty, !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else if shelves.isEmpty {
                    VStack(spacing: 16) {
                        mediumPicker
                        ContentUnavailableView(medium == .novels ? "No novels yet" : "No manga yet",
                                               systemImage: medium.systemImage,
                                               description: Text(medium.emptyMessage))
                    }
                } else {
                    shelfList
                }
            }
            .navigationTitle("Library")
            // Must sit outside the lazy containers below — SwiftUI doesn't register a
            // navigationDestination declared inside a LazyVStack, and the links go dead.
            .navigationDestination(for: String.self) { id in
                if id.hasPrefix(SeriesGrouping.groupPrefix) {
                    if let group = library.group(id: id) { GroupDetailView(groupID: id, fallback: group) }
                } else if let shelf = library.shelf(id: id) {
                    SeriesDetailView(series: shelf)
                }
            }
            .searchable(text: $query, prompt: "Series or title")
            // The same two buttons as Earmark's Library: the lists, and one menu for how the
            // shelf looks and for bringing comics in.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Reading Lists", systemImage: "list.bullet.rectangle") { showingLists = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Bookmarks & notes…", systemImage: "bookmark") { showingBookmarks = true }
                        Button("Ready for offline…", systemImage: "checkmark.icloud") { showingOffline = true }
                        Divider()
                        Picker("Sort By", systemImage: "arrow.up.arrow.down", selection: $settings.librarySort) {
                            ForEach(LibrarySort.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.menu)
                        Picker("Layout", selection: $settings.libraryLayout) {
                            ForEach(LibraryLayout.allCases, id: \.self) {
                                Label($0 == .grid ? "Grid" : "List", systemImage: $0.systemImage).tag($0)
                            }
                        }
                        Toggle("Show Finished", isOn: $settings.showFinished)
                        Divider()
                        Button("Rescan", systemImage: "arrow.clockwise") { Task { await library.scan() } }
                        Button("Add Folder…", systemImage: "folder.badge.plus") { showingPicker = true }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                }
            }
            .sheet(isPresented: $showingOffline) { OfflineLibraryView() }
            .sheet(isPresented: $showingBookmarks) { BookmarkSearchView() }
            .navigationDestination(isPresented: $showingLists) { ReadingListsView() }
            .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result { urls.forEach(library.addFolderSource) }
            }
            .overlay(alignment: .top) { scanBanner }
            .refreshable {
                await library.scan()
            }
            .fullScreenCover(item: $readingComic) { comic in
                ReaderRouter(comic: comic)
            }

        }
    }

    // MARK: Pieces

    @ViewBuilder
    private var mediumPicker: some View {
        if showsMediumPicker {
            Picker("Medium", selection: $medium) {
                ForEach(Medium.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var shelfList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                mediumPicker
                continueRow
                if settings.libraryLayout == .grid { grid } else { list }
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var continueRow: some View {
        let inProgress = library.continueReading.filter { $0.isNovel == (medium == .novels) }
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
                                    .frame(width: sizeClass == .regular ? 150 : 110)
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

    /// Stacked when browsing; flat when searching, so a match is never hidden inside a stack.
    private var items: [ShelfItem] {
        query.isEmpty ? library.shelfItems(shelves) : shelves.map(ShelfItem.series)
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: coverWidth.min, maximum: coverWidth.max), spacing: 16)], spacing: 22) {
            ForEach(items) { item in
                NavigationLink(value: item.id) {
                    switch item {
                    case .series(let shelf): SeriesCardView(series: shelf)
                    case .group(let group): GroupCardView(group: group)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }

    private var list: some View {
        LazyVStack(spacing: 0) {
            ForEach(items) { item in
                NavigationLink(value: item.id) {
                    HStack(spacing: 12) {
                        switch item {
                        case .series(let shelf):
                            CoverView(coverID: shelf.coverID, title: shelf.name)
                                .frame(width: 50)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(shelf.name).font(.body).lineLimit(1)
                                Text(shelf.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                        case .group(let group):
                            CoverView(coverID: group.members.first?.coverID, title: group.name)
                                .frame(width: 50)
                            VStack(alignment: .leading, spacing: 2) {
                                Label(group.name, systemImage: "square.stack").font(.body).lineLimit(1)
                                Text("\(group.members.count) series · \(group.volumeCount) books")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
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
            Text("Add a folder or a NAS share in Sources, or drop .cbz files into \(DeviceStorage.folder("Mango")) in the Files app.")
        } actions: {
            NavigationLink("Add a source") { SourcesView() }
                .buttonStyle(.glassProminent)
        }
    }
}

/// One shelf in the grid: the cover, the name, and how far through the run you are.
struct SeriesCardView: View {
    let series: Series
    /// Shown instead of the series name — inside a stack, without the stack's own name.
    var title: String?
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
            Text(title ?? series.name)
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
