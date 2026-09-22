import SwiftUI

/// One run: every volume in order, with a Continue button that opens the right one.
struct SeriesDetailView: View {
    let series: Series

    @Environment(LibraryModel.self) private var library
    @Environment(TransferManager.self) private var transfers
    @Environment(\.dismiss) private var dismiss
    @State private var readingComic: Comic?
    @State private var editing: Comic?
    @State private var summaryExpanded = false
    /// Find Cover: for the shelf (true) or for one volume (false).
    @State private var coverTarget: (comic: Comic, forSeries: Bool)?
    @State private var lookingUp = false
    @State private var grouping = false
    /// Add to List…, for the shelf or one volume.
    @State private var listing: (item: ReadingList.Item, title: String)?

    private var shelf: Series { library.shelf(id: series.id) ?? series }

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
            if let summary = shelf.comics.lazy.compactMap(\.summary).first {
                Section {
                    Text(summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(summaryExpanded ? nil : 4)
                        .onTapGesture { withAnimation(.snappy) { summaryExpanded.toggle() } }
                } header: {
                    Text("About")
                } footer: {
                    Text("From the archive's own ComicInfo.xml.")
                }
            }

            Section("Volumes") {
                ForEach(shelf.comics) { comic in
                    Button { readingComic = comic } label: {
                        VolumeRow(comic: comic)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button {
                            library.setFinished(library.progress(for: comic)?.finished != true, for: comic)
                        } label: {
                            Label("Finished", systemImage: "checkmark")
                        }
                        .tint(.green)
                        Button { editing = comic } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.orange)
                    }
                    .contextMenu {
                        // Also a swipe action, but a swipe is invisible until you know it's there.
                        Button("Edit…", systemImage: "pencil") { editing = comic }
                        Button("Add to List…", systemImage: "text.badge.plus") {
                            listing = (ReadingList.Item(comic), comic.numberLabel ?? comic.title)
                        }
                        Button("Find Cover…", systemImage: "photo.badge.magnifyingglass") {
                            coverTarget = (comic, false)
                        }
                        if library.hasCustomCover(comic) {
                            Button("Use Original Cover", systemImage: "arrow.uturn.backward") {
                                library.useOriginalCover(for: comic)
                            }
                        }
                        if let copy = library.downloadedCopy(of: comic) {
                            Button("Remove Download (\(Formatting.bytes(copy.totalBytes)))", systemImage: "trash") {
                                library.removeDownload(of: comic)
                            }
                        } else if comic.isRemote(in: library) {
                            Button("Download to device", systemImage: "arrow.down.circle") {
                                transfers.download(comic)
                            }
                        } else if let server = library.state.nasServers.first {
                            Button("Upload to \(server.name)", systemImage: "arrow.up.circle") {
                                transfers.upload(comic, to: server.id)
                            }
                        }
                        // From a folder you picked into Mango's own: copied, checked, then removed there.
                        if library.state.sources.first(where: { $0.id == comic.sourceID })?.kind == .folder {
                            Button("Move into Mango", systemImage: "arrow.right.circle") { transfers.move(comic) }
                        }
                        Menu {
                            ForEach((1...5).reversed(), id: \.self) { stars in
                                Button(String(repeating: "★", count: stars)) { library.setRating(stars, for: comic) }
                            }
                            if library.rating(for: comic) != nil {
                                Button("Clear rating", role: .destructive) { library.setRating(nil, for: comic) }
                            }
                        } label: {
                            Label("Rate", systemImage: "star")
                        }
                        Button("Reset progress", systemImage: "arrow.counterclockwise") {
                            library.resetProgress(for: comic)
                        }
                        Button("Hide", systemImage: "eye.slash", role: .destructive) {
                            library.setHidden(true, for: comic)
                        }
                    }
                }
            }
        }
        .navigationTitle(shelf.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let first = shelf.comics.first {
                        Button("Find Cover…", systemImage: "photo.badge.magnifyingglass") { coverTarget = (first, true) }
                        if library.hasCustomCover(first) {
                            Button("Use Original Cover", systemImage: "arrow.uturn.backward") {
                                library.useOriginalCover(for: first)
                            }
                        }
                    }
                    let downloaded = shelf.comics.compactMap { library.downloadedCopy(of: $0) }
                    let onlyOnNAS = shelf.comics.filter { $0.isRemote(in: library) && library.downloadedCopy(of: $0) == nil }
                    if !onlyOnNAS.isEmpty {
                        Button("Download All (\(onlyOnNAS.count))", systemImage: "arrow.down.circle") {
                            onlyOnNAS.forEach(transfers.download)
                        }
                    }
                    if !downloaded.isEmpty {
                        Button("Remove Downloads (\(Formatting.bytes(downloaded.reduce(0) { $0 + $1.totalBytes })))",
                               systemImage: "trash") {
                            library.removeDownloads(downloaded)
                        }
                    }
                    Divider()
                    Button("Add to List…", systemImage: "text.badge.plus") {
                        listing = (ReadingList.Item(shelf), shelf.name)
                    }
                    Button("Look Up Series…", systemImage: "text.magnifyingglass") { lookingUp = true }
                    if let stack = library.group(containing: shelf) {
                        Button("Remove From \(stack.name)", systemImage: "square.stack.3d.up.slash") {
                            library.setGroup("", for: shelf)
                        }
                    } else {
                        Button("Group With…", systemImage: "square.stack") { grouping = true }
                    }
                    Divider()
                    Button("Hide Series", systemImage: "eye.slash", role: .destructive) {
                        library.setSeriesHidden(true, shelf)
                        dismiss()
                    }
                } label: {
                    Label("Series", systemImage: "ellipsis.circle")
                }
            }
        }
        .fullScreenCover(item: $readingComic) { ReaderRouter(comic: $0) }
        .sheet(item: $editing) { EditComicView(comic: $0) }
        .sheet(isPresented: Binding(get: { coverTarget != nil }, set: { if !$0 { coverTarget = nil } })) {
            if let target = coverTarget { CoverPickerView(comic: target.comic, forSeries: target.forSeries) }
        }
        .sheet(isPresented: $lookingUp) { SeriesLookupView(series: shelf) }
        .sheet(isPresented: $grouping) { GroupPickerView(shelf: shelf) }
        .sheet(isPresented: Binding(get: { listing != nil }, set: { if !$0 { listing = nil } })) {
            if let listing { ListPickerView(item: listing.item, title: listing.title) }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            CoverView(coverID: shelf.coverID, title: shelf.name, cornerRadius: 10)
                .frame(width: 110)
            VStack(alignment: .leading, spacing: 8) {
                Text(shelf.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(3)
                Text(shelf.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(Formatting.bytes(shelf.totalBytes))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                if let next = library.nextUp(in: shelf) {
                    Button {
                        readingComic = next
                    } label: {
                        Label(continueLabel(for: next), systemImage: "book")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal)
    }

    private func continueLabel(for comic: Comic) -> String {
        guard let progress = library.progress(for: comic), progress.isStarted else {
            return shelf.volumeCount > 1 ? "Start \(comic.numberLabel ?? "reading")" : "Read"
        }
        return "Continue \(comic.numberLabel ?? "")".trimmingCharacters(in: .whitespaces)
    }
}

struct VolumeRow: View {
    let comic: Comic
    @Environment(LibraryModel.self) private var library
    @Environment(TransferManager.self) private var transfers

    var body: some View {
        HStack(spacing: 12) {
            CoverView(coverID: comic.coverID, title: comic.title, cornerRadius: 4)
                .frame(width: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(comic.numberLabel ?? comic.title)
                        .font(.body)
                        .lineLimit(1)
                    if let subtitle = comic.subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 6) {
                    Text(comic.formatLabel)
                    if let pages = comic.pageCount {
                        Text("· \(pages) pages")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                if let progress = library.progress(for: comic), progress.isStarted {
                    ProgressBar(fraction: progress.fraction)
                        .frame(maxWidth: 160)
                }
                if let rating = library.rating(for: comic) {
                    StarsView(rating: rating)
                }
            }
            Spacer()
            if let job = transfers.job(for: comic.id), job.isActive {
                VStack(spacing: 3) {
                    ProgressView(value: job.fraction).frame(width: 46)
                    Text(job.kind == .download ? "Downloading" : job.kind == .upload ? "Uploading" : "Moving into Mango")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if comic.isRemote(in: library) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("On the NAS")
            } else if library.isDownloadedCopy(comic) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Downloaded to this device")
            }
            if library.progress(for: comic)?.finished == true {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .contentShape(.rect)
    }
}
