import PhotosUI
import SwiftUI
import os

/// Find Cover: search MangaDex, AniList and Apple Books — or use an image from Photos or Files —
/// and apply it. For a whole series it sets the first volume's cover, which is what the shelf shows.
struct CoverPickerView: View {
    let comic: Comic
    let forSeries: Bool

    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var results: [CoverCandidate] = []
    @State private var isSearching = false
    @State private var applying: String?
    @State private var errorMessage: String?
    @State private var showPhotos = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showFiles = false

    init(comic: Comic, forSeries: Bool) {
        self.comic = comic
        self.forSeries = forSeries
        _text = State(initialValue: comic.series ?? comic.title)
    }

    /// A volume's own cover when it's for one volume; chapters have none, so they search the series.
    private var query: CoverQuery {
        CoverQuery(title: text, volume: forSeries ? nil : comic.volume, isNovel: comic.isNovel)
    }

    private var sources: String { comic.isNovel ? "AniList and Apple Books" : "MangaDex, AniList and Apple Books" }

    var body: some View {
        NavigationStack {
            Group {
                if isSearching && results.isEmpty {
                    ProgressView("Searching…")
                } else if results.isEmpty {
                    ContentUnavailableView("No Covers Found", systemImage: "photo",
                                           description: Text("Try the series name on its own, or use your own image."))
                } else {
                    grid
                }
            }
            .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Series name")
            .onSubmit(of: .search) { Task { await search() } }
            .navigationTitle(forSeries ? "Series Cover" : "Cover for \(comic.numberLabel ?? comic.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Choose from Photos", systemImage: "photo.on.rectangle") { showPhotos = true }
                        Button("Choose File…", systemImage: "folder") { showFiles = true }
                        if library.hasCustomCover(comic) {
                            Divider()
                            Button("Use Original Cover", systemImage: "arrow.uturn.backward") {
                                library.useOriginalCover(for: comic)
                                dismiss()
                            }
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .disabled(applying != nil)
                }
            }
            .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                photoItem = nil
                Task { await applyPhoto(item) }
            }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image]) { applyFile($0) }
            .alert("Couldn't Use That Cover", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") {}
            } message: {
                Text(errorMessage ?? "")
            }
            .task { await search() }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 14)], spacing: 18) {
                ForEach(results) { candidate in
                    Button { apply(candidate) } label: { tile(candidate) }
                        .buttonStyle(.plain)
                        .disabled(applying != nil)
                }
            }
            .padding()
            // Say plainly what left the device, since this is the one place Mango talks to anyone
            // but your NAS.
            Text("Searched \(sources) for “\(text)”. Only the name\(query.volume == nil ? "" : " and volume number") was sent.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .padding(.bottom)
        }
    }

    private func tile(_ candidate: CoverCandidate) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay {
                    AsyncImage(url: candidate.thumbnailURL) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Rectangle().fill(.quaternary)
                        }
                    }
                }
                .clipShape(.rect(cornerRadius: 8))
                .overlay {
                    if applying == candidate.id { ProgressView().tint(.white) }
                }
            Text(candidate.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
            Text([candidate.detail, candidate.source.rawValue].compactMap { $0 }.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func search() async {
        isSearching = true
        defer { isSearching = false }
        results = await CoverSearch.search(query)
    }

    private func apply(_ candidate: CoverCandidate) {
        applying = candidate.id
        Task {
            defer { applying = nil }
            do {
                let data = try await CoverSearch.download(candidate.fullURL)
                if await library.setCustomCover(data, origin: candidate.fullURL.absoluteString, for: comic) {
                    dismiss()
                } else {
                    errorMessage = "That image couldn't be read."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func applyPhoto(_ item: PhotosPickerItem) async {
        applying = "photos"
        defer { applying = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                errorMessage = "That photo couldn't be loaded."
                return
            }
            Logger.cover.info("[covers] photo picked (\(data.count)B)")
            await applyOwnImage(data)
        } catch {
            Logger.cover.error("[covers] photo load failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    private func applyFile(_ result: Result<URL, any Error>) {
        switch result {
        case .success(let url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                Logger.cover.info("[covers] file picked \(url.lastPathComponent, privacy: .public) (\(data.count)B)")
                Task { await applyOwnImage(data) }
            } catch {
                Logger.cover.error("[covers] file read failed \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                errorMessage = error.localizedDescription
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func applyOwnImage(_ data: Data) async {
        let origin = "device-" + CoverStore.stableHex(bytes: data)
        if await library.setCustomCover(data, origin: origin, for: comic) {
            dismiss()
        } else {
            errorMessage = "That image couldn't be read."
        }
    }
}
