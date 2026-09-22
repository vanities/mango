import SwiftUI
import UniformTypeIdentifiers
import os
import ShelfKit

/// Where the comics come from — Mango's own folder, folders the user picked, NAS shares — laid
/// out as Earmark's Sources are. Adding one never copies anything: it keeps a security-scoped
/// bookmark to a folder, or a share's login in the Keychain.
struct SourcesView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(TransferManager.self) private var transfers

    @State private var showingPicker = false
    @State private var showingNASSetup = false
    @State private var sourceToRemove: LibrarySource?
    /// Everything at once asks first, with its count and size.
    @State private var downloadSource: LibrarySource?
    @State private var moveSource: LibrarySource?
    @State private var uploadServer: NASServer?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(library.state.sources) { source in
                        NavigationLink {
                            SourceBrowserView(source: source)
                        } label: {
                            SourceRow(source: source)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if source.isRemovable {
                                Button("Remove", systemImage: "trash", role: .destructive) { sourceToRemove = source }
                            }
                            Button("Rescan", systemImage: "arrow.clockwise") { Task { await library.scan() } }
                                .tint(.blue)
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            if source.isRemote {
                                Button("Sync", systemImage: "arrow.down.circle") { downloadSource = source }
                                    .tint(.green)
                            } else if source.kind == .folder {
                                Button("Move In", systemImage: "arrow.right.doc.on.clipboard") { moveSource = source }
                                    .tint(.green)
                            }
                        }
                    }
                } header: {
                    Text("Sources")
                } footer: {
                    Text("Mango reads your files where they are. It never copies, moves, renames or deletes them unless you ask — only covers and a small library file are written.")
                }

                Section {
                    Button("Add Folder…", systemImage: "folder.badge.plus") { showingPicker = true }
                    Button("Add NAS Share…", systemImage: "externaldrive.badge.plus") { showingNASSetup = true }
                }

                orphanedServers

                if !transfers.jobs.isEmpty {
                    Section {
                        ForEach(transfers.jobs) { job in
                            TransferRow(job: job)
                        }
                    } header: {
                        Text("Transfers")
                    } footer: {
                        Text("One at a time, and only while Mango is open — SMB has no background transfer. A half-finished file resumes rather than starting over.")
                    }
                    Section {
                        if transfers.isTransferring {
                            Button("Stop All", role: .destructive) { transfers.cancelAll() }
                        }
                        if transfers.jobs.contains(where: { !$0.isActive }) {
                            Button("Clear Finished") { transfers.clearFinished() }
                        }
                    }
                }

                syncSection

                Section("Tools") {
                    NavigationLink {
                        DuplicatesView()
                    } label: {
                        Label("Find Duplicates", systemImage: "doc.on.doc")
                    }
                }

                Section("Library") {
                    LabeledContent("Comics", value: "\(library.totalComics)")
                    LabeledContent("Series", value: "\(library.series.count)")
                    LabeledContent("Total size", value: Formatting.bytes(library.totalBytes))
                }

                Section("Tips") {
                    TipRowView(systemImage: "iphone", title: "Keep comics on this device",
                               detail: "In the Files app, move comics into On My iPhone › Mango. They stay put and show up here automatically.")
                    TipRowView(systemImage: "externaldrive.connected.to.line.below", title: "Read from a NAS",
                               detail: "Add NAS Share… reads pages straight from an SMB share on your network, and downloads any volume you want to keep.")
                    TipRowView(systemImage: "folder", title: "Folder layout that just works",
                               detail: "Series / volumes: .cbz, .pdf, .epub, or a folder of pages. Mango reads volume and chapter numbers from the names.")
                }
            }
            .navigationTitle("Sources")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Rescan Everything", systemImage: "arrow.clockwise") { Task { await library.scan() } }
                        .disabled(library.isScanning)
                }
            }
            .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    Logger.ui.info("[ui] picked \(urls.count) folder(s) from Sources")
                    urls.forEach(library.addFolderSource)
                }
            }
            .sheet(isPresented: $showingNASSetup) { NASSetupView() }
            .confirmationDialog(downloadTitle, isPresented: presence($downloadSource), titleVisibility: .visible, presenting: downloadSource) { source in
                Button("Download All") { downloadAll(from: source) }
                    .disabled(transfers.downloadable(in: source).isEmpty)
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Copies go into Mango's folder with the same layout, one at a time, while Mango is open. Files already here are skipped.")
            }
            .confirmationDialog(uploadTitle, isPresented: presence($uploadServer), titleVisibility: .visible, presenting: uploadServer) { server in
                Button("Upload All") { uploadAll(to: server) }
                    .disabled(transfers.uploadable(to: server.id).isEmpty)
                Button("Cancel", role: .cancel) {}
            } message: { server in
                Text("Each is uploaded to \(server.name), one at a time, while Mango is open. Your copies stay on this device; ones already on the NAS are skipped.")
            }
            .confirmationDialog(moveTitle, isPresented: presence($moveSource), titleVisibility: .visible, presenting: moveSource) { source in
                Button("Move All") { moveAll(from: source) }
                    .disabled(movable(in: source).isEmpty)
                Button("Cancel", role: .cancel) {}
            } message: { source in
                Text("Each is copied into Mango's own folder, checked, and only then removed from \(source.displayName). Your place, bookmarks and ratings go with them. A different file already in Mango's folder is never replaced.")
            }
            .confirmationDialog("Remove \(sourceToRemove?.displayName ?? "folder")?", isPresented: presence($sourceToRemove),
                                titleVisibility: .visible, presenting: sourceToRemove) { source in
                Button("Remove from Mango", role: .destructive) { library.removeSource(source) }
            } message: { source in
                Text(source.isRemote
                     ? "Disconnects from this NAS and forgets its login. Comics you downloaded stay on this device."
                     : "The files stay where they are. Only Mango's link to this folder is removed; your place in each comic is kept in case you add it back.")
            }
        }
    }

    private func presence<T>(_ item: Binding<T?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }

    // MARK: Everything at once

    /// Everything at once, as Earmark's Sources has it: a NAS's comics down to this device, or
    /// this device's comics up to a NAS.
    @ViewBuilder
    private var syncSection: some View {
        let remotes = library.state.sources.filter(\.isRemote)
        if !remotes.isEmpty || !library.state.nasServers.isEmpty {
            Section {
                ForEach(remotes) { source in
                    Button("Download Everything from \(source.displayName)", systemImage: "arrow.down.circle") { downloadSource = source }
                }
                ForEach(library.state.nasServers) { server in
                    Button("Upload Everything to \(server.name)", systemImage: "arrow.up.circle") { uploadServer = server }
                }
            } header: {
                Text("Sync")
            } footer: {
                Text("Comics on a NAS are read straight from it while you're on its network. Download any of them to keep a copy on this device; files already here are skipped.")
            }
        }
    }

    /// Logins kept by builds that didn't forget a NAS with its last share. Normally empty.
    @ViewBuilder
    private var orphanedServers: some View {
        let orphans = library.state.nasServers.filter { server in !library.state.sources.contains { $0.serverID == server.id } }
        if !orphans.isEmpty {
            Section {
                ForEach(orphans) { server in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(server.name)
                        Text(server.displayLocation)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    .swipeActions {
                        Button("Forget", systemImage: "trash", role: .destructive) { library.removeServer(server) }
                    }
                }
            } header: {
                Text("Servers")
            } footer: {
                Text("These logins no longer have a share in Mango. Swipe to forget one.")
            }
        }
    }

    private static func bytes(_ comics: [Comic]) -> String {
        Formatting.bytes(comics.reduce(0) { $0 + $1.totalBytes })
    }

    private func movable(in source: LibrarySource) -> [Comic] {
        guard source.kind == .folder else { return [] }
        return library.state.comics.filter { $0.sourceID == source.id && transfers.job(for: $0.id)?.isActive != true }
    }

    private var downloadTitle: String {
        let comics = downloadSource.map { transfers.downloadable(in: $0) } ?? []
        return comics.isEmpty ? "Everything is on this device" : "Download \(comics.count) (\(Self.bytes(comics))) to this device?"
    }

    private var uploadTitle: String {
        let comics = uploadServer.map { transfers.uploadable(to: $0.id) } ?? []
        return comics.isEmpty ? "Everything is on \(uploadServer?.name ?? "the NAS")" : "Upload \(comics.count) (\(Self.bytes(comics))) to \(uploadServer?.name ?? "the NAS")?"
    }

    private var moveTitle: String {
        let comics = moveSource.map { movable(in: $0) } ?? []
        return comics.isEmpty ? "Nothing left to move" : "Move \(comics.count) (\(Self.bytes(comics))) into Mango?"
    }

    private func downloadAll(from source: LibrarySource) {
        let count = transfers.downloadAll(from: source)
        if count == 0 { library.lastError = "Everything on \(source.displayName) is already here." }
    }

    private func uploadAll(to server: NASServer) {
        let count = transfers.uploadAll(to: server.id)
        if count == 0 { library.lastError = "\(server.name) already has everything on this device." }
    }

    private func moveAll(from source: LibrarySource) {
        let comics = movable(in: source)
        comics.forEach(transfers.move)
        Logger.downloads.info("[sources] queued \(comics.count) move(s) into Mango from \(source.displayName, privacy: .public)")
    }
}

/// A source in the list (`SourceRowView`, as Earmark's are), with Mango's words.
struct SourceRow: View {
    @Environment(LibraryModel.self) private var library
    let source: LibrarySource

    var body: some View {
        SourceRowView(systemImage: source.systemImage, name: source.displayName,
                      location: source.serverID.flatMap { id in library.state.nasServers.first { $0.id == id }?.displayLocation },
                      status: source.lastError ?? SourceRowView.scanSummary(items: source.lastScanBookCount ?? 0, noun: "comic",
                                                                            files: source.lastScanFileCount ?? 0, at: source.lastScanAt),
                      isError: source.lastError != nil,
                      // Otherwise a series kept as .cbr just isn't there, with no clue why.
                      warning: ImageFileTypes.describeUnreadable(source.lastScanUnreadable ?? [:]).map { "\($0) can't be opened — convert them to .cbz" },
                      isScanning: library.isScanning)
    }
}

/// A transfer in the list (`TransferRowView`, as Earmark's are).
struct TransferRow: View {
    @Environment(TransferManager.self) private var transfers
    let job: TransferManager.Job

    var body: some View {
        TransferRowView(kind: job.kind == .download ? .download : job.kind == .upload ? .upload : .move,
                        title: job.title, phase: phase, fraction: job.fraction,
                        doneBytes: job.doneBytes, totalBytes: job.totalBytes, error: job.error,
                        cancel: { transfers.cancel(job.id) }, retry: { transfers.retry(job.id) })
    }

    private var phase: TransferRowView.Phase {
        switch job.state {
        case .queued: .queued
        case .running: .running
        case .done: .done
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }
}
