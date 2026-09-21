import SwiftUI
import os

/// Everything on one source, by series — what's on the device, what's only on the NAS, what's
/// coming down. Select several to download them, or to give their space back and read them
/// from the NAS again.
struct SourceBrowserView: View {
    let source: LibrarySource

    @Environment(LibraryModel.self) private var library
    @Environment(TransferManager.self) private var transfers
    @State private var selection = Set<String>()
    @State private var editMode = EditMode.inactive
    @State private var reading: Comic?

    private var shelves: [Series] {
        let comics = library.state.comics.filter {
            $0.sourceID == source.id && !library.state.hiddenComicIDs.contains($0.id)
        }
        return SeriesGrouper.group(comics).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var selected: [Comic] {
        shelves.flatMap(\.comics).filter { selection.contains($0.id) }
    }

    /// Selected comics that are only on the NAS.
    private var toDownload: [Comic] {
        selected.filter { $0.isRemote(in: library) && library.downloadedCopy(of: $0) == nil
            && transfers.job(for: $0.id)?.isActive != true }
    }

    /// Selected comics with a download that could go back to the NAS.
    private var toRemove: [Comic] {
        selected.filter { library.downloadedCopy(of: $0) != nil }
    }

    var body: some View {
        List(selection: $selection) {
            summary
            ForEach(shelves) { shelf in
                Section {
                    ForEach(shelf.comics) { comic in
                        // Outside Select a tap reads it; inside, the row is plain so List's own tick works.
                        Group {
                            if editMode.isEditing {
                                row(comic)
                            } else {
                                Button { reading = library.downloadedCopy(of: comic) ?? comic } label: { row(comic) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .tag(comic.id)
                    }
                } header: {
                    HStack {
                        Text(shelf.name)
                        Spacer()
                        if editMode.isEditing {
                            let ids = Set(shelf.comics.map(\.id))
                            Button(ids.isSubset(of: selection) ? "Deselect" : "Select All") {
                                if ids.isSubset(of: selection) { selection.subtract(ids) } else { selection.formUnion(ids) }
                            }
                            .font(.caption)
                        }
                    }
                }
            }
        }
        .environment(\.editMode, $editMode)
        // The selection's actions live in the bottom bar; the floating tab bar would sit on them.
        .toolbar(editMode.isEditing ? .hidden : .automatic, for: .tabBar)
        .navigationTitle(source.displayName)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(editMode.isEditing ? "Done" : "Select") {
                    withAnimation {
                        editMode = editMode.isEditing ? .inactive : .active
                        if !editMode.isEditing { selection.removeAll() }
                    }
                }
            }
            if editMode.isEditing {
                ToolbarItemGroup(placement: .bottomBar) {
                    if source.isRemote {
                        Button {
                            toDownload.forEach(transfers.download)
                            Logger.downloads.info("[sources] queued \(toDownload.count) download(s) from \(source.displayName, privacy: .public)")
                            selection.removeAll()
                        } label: {
                            // Words with a count, so it's clear what a tap will do: the bottom
                            // bar draws an icon-only label as a bare glyph.
                            Text("Download \(toDownload.count)")
                        }
                        .disabled(toDownload.isEmpty)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        library.removeDownloads(toRemove)
                        selection.removeAll()
                    } label: {
                        Text("Remove \(toRemove.count)")
                    }
                    .disabled(toRemove.isEmpty)
                }
            }
        }
        .fullScreenCover(item: $reading) { ReaderRouter(comic: $0) }
    }

    @ViewBuilder
    private var summary: some View {
        let comics = shelves.flatMap(\.comics)
        let onDevice = comics.filter { library.downloadedCopy(of: $0) != nil }
        Section {
            LabeledContent("Comics", value: "\(comics.count) · \(Formatting.bytes(comics.reduce(0) { $0 + $1.totalBytes }))")
            if source.isRemote {
                LabeledContent("On this device", value: onDevice.isEmpty ? "None"
                               : "\(onDevice.count) · \(Formatting.bytes(onDevice.reduce(0) { $0 + $1.totalBytes }))")
            } else if !onDevice.isEmpty {
                LabeledContent("Also on the NAS", value: "\(onDevice.count)")
            }
        } footer: {
            Text(source.isRemote
                 ? "Select to download for reading anywhere, or to remove downloads and read from the NAS again."
                 : "Downloads can be removed here and read from the NAS again. Files that exist only on this device aren't touched.")
        }
    }

    private func row(_ comic: Comic) -> some View {
        HStack(spacing: 12) {
            CoverView(coverID: comic.coverID, title: comic.title, cornerRadius: 4)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text([comic.numberLabel, comic.subtitle].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? comic.title)
                    .lineLimit(1)
                Text(Formatting.bytes(comic.totalBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            status(comic)
        }
    }

    @ViewBuilder
    private func status(_ comic: Comic) -> some View {
        if let job = transfers.job(for: comic.id), job.isActive {
            ProgressView(value: job.fraction)
                .frame(width: 44)
                .accessibilityLabel("Downloading, \(Int(job.fraction * 100)) percent")
        } else if library.downloadedCopy(of: comic) != nil {
            Image(systemName: source.isRemote ? "checkmark.circle.fill" : "externaldrive.badge.checkmark")
                .foregroundStyle(source.isRemote ? Color.green : Color.secondary)
                .accessibilityLabel(source.isRemote ? "On this device" : "Also on the NAS")
        } else if source.isRemote {
            Image(systemName: "externaldrive")
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Only on the NAS")
        }
    }
}
