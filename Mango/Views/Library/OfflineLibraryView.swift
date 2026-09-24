import SwiftUI
import ShelfKit

struct OfflineLibraryView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var revision = 0

    private var upcoming: [Comic] {
        let candidates = library.continueReading.flatMap { [$0] + [library.nextInSeries(after: $0)].compactMap { $0 } }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.syncKey).inserted }
    }
    private var others: [Comic] {
        let keys = Set(upcoming.map(\.syncKey))
        return library.visibleComics.filter { !keys.contains($0.syncKey) }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private func matching(_ items: [Comic]) -> [Comic] {
        items.filter { query.isEmpty || $0.title.localizedStandardContains(query) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Checks the files on this device. Download anything you need before leaving your network. Files managed by another app may need Keep Downloaded in Files.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !matching(upcoming).isEmpty {
                    Section("Up next") { rows(matching(upcoming)) }
                }
                Section("Library") { rows(matching(others)) }
            }
            .searchable(text: $query, prompt: "Find a book")
            .navigationTitle("Ready for offline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Check again", systemImage: "arrow.clockwise") { revision += 1 } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
    private func rows(_ items: [Comic]) -> some View {
        ForEach(items) { item in OfflineBookRow(comic: item).id("\(item.id)-\(revision)") }
    }
}

private struct OfflineBookRow: View {
    @Environment(LibraryModel.self) private var library
    @Environment(TransferManager.self) private var transfers
    let comic: Comic
    @State private var status: OfflineReadiness?
    private var remote: Bool { comic.isRemote(in: library) }
    private var downloadSource: Comic? { remote ? comic : library.nasCopy(of: comic) }
    private var active: Bool { downloadSource.map { transfers.job(for: $0.id)?.isActive == true } ?? false }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            OfflineReadinessRow(title: comic.title, status: status)
            if let source = downloadSource, remote || status == .unavailable {
                Button(active ? "Downloading…" : "Download", systemImage: "arrow.down.circle") { transfers.download(source) }
                    .disabled(active)
            }
        }
        .task(id: comic) { status = await check() }
    }
    private func check() async -> OfflineReadiness {
        if remote { return .needsDownload }
        guard let source = library.state.sources.first(where: { $0.id == comic.sourceID }),
              let root = library.root(for: source) else { return .unavailable }
        let url = source.kind == .file ? root : root.appending(path: comic.relativePath)
        let managed = source.kind == .appDocuments
        let expectedBytes = library.nasCopy(of: comic)?.totalBytes ?? comic.totalBytes
        return await Task.detached(priority: .utility) {
            comic.kind == .folder ? OfflineReadiness.checkImageFolder(url, managedCopy: managed, expectedBytes: expectedBytes)
                : OfflineReadiness.check(files: [.init(url: url, expectedBytes: expectedBytes)], managedCopy: managed)
        }.value
    }
}
