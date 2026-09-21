import SwiftUI
import UniformTypeIdentifiers

/// Where the comics come from. Adding a source never copies anything — it stores a
/// security-scoped bookmark to a folder, or SMB credentials for a share.
struct SourcesView: View {
    @Environment(LibraryModel.self) private var library
    @Environment(TransferManager.self) private var transfers

    @State private var showingPicker = false
    @State private var showingNASSetup = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(library.state.sources) { source in
                        SourceRow(source: source)
                    }
                    .onDelete(perform: delete)
                } header: {
                    Text("Sources")
                } footer: {
                    Text("Mango reads your files where they are. It never copies, moves, or renames them — only covers and a small library file are written.")
                }

                Section {
                    Button { showingPicker = true } label: {
                        Label("Add a folder", systemImage: "folder.badge.plus")
                    }
                    Button { showingNASSetup = true } label: {
                        Label("Add a NAS share", systemImage: "externaldrive.badge.plus")
                    }
                }

                if !library.state.nasServers.isEmpty {
                    Section("Servers") {
                        ForEach(library.state.nasServers) { server in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.name)
                                Text(server.displayLocation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    library.removeServer(server)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

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
                            Button("Stop all", role: .destructive) { transfers.cancelAll() }
                        }
                        Button("Clear finished") { transfers.clearFinished() }
                    }
                }

                Section("Sync") {
                    ForEach(library.state.sources.filter(\.isRemote)) { source in
                        Button {
                            let count = transfers.downloadAll(from: source)
                            if count == 0 { library.lastError = "Everything on \(source.displayName) is already here." }
                        } label: {
                            Label("Download everything from \(source.displayName)", systemImage: "arrow.down.circle")
                        }
                    }
                    ForEach(library.state.nasServers) { server in
                        Button {
                            let count = transfers.uploadAll(to: server.id)
                            if count == 0 { library.lastError = "\(server.name) already has everything on this device." }
                        } label: {
                            Label("Upload everything to \(server.name)", systemImage: "arrow.up.circle")
                        }
                    }
                }

                Section("Library") {
                    LabeledContent("Comics", value: "\(library.totalComics)")
                    LabeledContent("Series", value: "\(library.series.count)")
                    LabeledContent("Total size", value: Formatting.bytes(library.totalBytes))
                }
            }
            .navigationTitle("Sources")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await library.scan() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(library.isScanning)
                }
            }
            .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { library.addFolderSource(url) }
            }
            .sheet(isPresented: $showingNASSetup) { NASSetupView() }
        }
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets {
            library.removeSource(library.state.sources[index])
        }
    }
}

struct TransferRow: View {
    let job: TransferManager.Job
    @Environment(TransferManager.self) private var transfers

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: job.kind == .download ? "arrow.down.circle" : "arrow.up.circle")
                    .foregroundStyle(job.state == .failed ? Color.red : Color.accentColor)
                Text(job.title).font(.subheadline).lineLimit(1)
                Spacer()
                Text(label).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            if job.isActive {
                ProgressView(value: job.fraction)
            }
            if let error = job.error {
                Text(error).font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
        }
        .swipeActions {
            if job.isActive {
                Button("Cancel", role: .destructive) { transfers.cancel(job.id) }
            } else if job.state == .failed {
                Button("Retry") { transfers.retry(job.id) }.tint(.blue)
            }
        }
    }

    private var label: String {
        switch job.state {
        case .queued: "Waiting"
        case .running: "\(Int(job.fraction * 100))% of \(Formatting.bytes(job.totalBytes))"
        case .done: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }
}

struct SourceRow: View {
    let source: LibrarySource

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: source.systemImage)
                .foregroundStyle(source.isRemote ? Color.accentColor : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.displayName)
                if let error = source.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else if let count = source.lastScanBookCount {
                    Text("\(count) comics · \(source.lastScanFileCount ?? 0) files")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not scanned yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}
