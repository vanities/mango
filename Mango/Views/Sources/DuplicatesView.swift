import SwiftUI

/// Comics on this device more than once, and a way to keep one.
struct DuplicatesView: View {
    @Environment(LibraryModel.self) private var library
    @State private var phase = Phase.idle
    @State private var pending: (comic: Comic, set: DuplicateSet)?
    @State private var error: String?

    private enum Phase {
        case idle
        case scanning(done: Int, total: Int)
        case found([DuplicateSet])
    }

    var body: some View {
        List {
            switch phase {
            case .idle:
                ContentUnavailableView {
                    Label("Find Duplicate Comics", systemImage: "doc.on.doc")
                } description: {
                    Text("Compares what's on this device by content, not name, so a copy made in Files or a folder added twice is caught. Nothing on your NAS is read or touched, and nothing is deleted without asking.")
                } actions: {
                    Button("Find Duplicates") { scan() }
                        .buttonStyle(.glassProminent)
                }
                .listRowBackground(Color.clear)
            case .scanning(let done, let total):
                Section {
                    ProgressView(value: Double(done), total: Double(max(total, 1))) {
                        Text("Checking \(done) of \(total)…").font(.caption).monospacedDigit()
                    }
                }
            case .found(let sets) where sets.isEmpty:
                ContentUnavailableView("No Duplicates", systemImage: "checkmark.seal",
                                       description: Text("Every comic on this device is here once."))
                    .listRowBackground(Color.clear)
            case .found(let sets):
                Section {
                    Label("\(sets.count) comic\(sets.count == 1 ? "" : "s") more than once · \(Formatting.bytes(sets.reduce(0) { $0 + $1.wastedBytes })) to win back",
                          systemImage: "internaldrive")
                        .font(.subheadline)
                }
                ForEach(sets) { set in
                    Section(set.copies[0].numberLabel.map { "\(set.copies[0].displaySeries) · \($0)" } ?? set.copies[0].title) {
                        ForEach(set.copies) { comic in
                            row(comic, in: set)
                        }
                    }
                }
            }
        }
        .navigationTitle("Duplicates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if case .found = phase {
                ToolbarItem(placement: .primaryAction) {
                    Button("Scan Again", systemImage: "arrow.clockwise") { scan() }
                }
            }
        }
        .confirmationDialog("Delete this copy?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            titleVisibility: .visible, presenting: pending) { item in
            Button("Delete from \(library.sourceName(for: item.comic))", role: .destructive) { delete(item.comic, in: item.set) }
        } message: { item in
            Text("\(item.comic.relativePath) is removed from \(library.sourceName(for: item.comic)). The other copy stays, and keeps your place, bookmarks and rating.")
        }
        .alert("Couldn't delete it", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    private func row(_ comic: Comic, in set: DuplicateSet) -> some View {
        let remaining = set.copies.filter { library.state.comics.contains($0) }
        return HStack(spacing: 10) {
            // The file name first, cut at its end — the number that tells copies apart is near
            // the front — then where it is.
            VStack(alignment: .leading, spacing: 1) {
                Text((comic.relativePath as NSString).lastPathComponent)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(location(of: comic))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(Formatting.bytes(comic.totalBytes))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button("Delete", role: .destructive) { pending = (comic, set) }
                .buttonStyle(.borderless)
                .font(.subheadline)
                .disabled(remaining.count < 2 || !remaining.contains(comic))
        }
    }

    /// "On My Device › Copies", or just the source for a file at its top.
    private func location(of comic: Comic) -> String {
        let folder = (comic.relativePath as NSString).deletingLastPathComponent
        return folder.isEmpty ? library.sourceName(for: comic) : "\(library.sourceName(for: comic)) › \(folder)"
    }

    private func scan() {
        phase = .scanning(done: 0, total: 0)
        Task {
            let sets = await library.findDuplicates { done, total in phase = .scanning(done: done, total: total) }
            phase = .found(sets)
        }
    }

    private func delete(_ comic: Comic, in set: DuplicateSet) {
        do {
            try library.deleteDuplicate(comic, in: set)
            if case .found(let sets) = phase {
                // The set drops the deleted copy; a set down to one copy is no longer a duplicate.
                phase = .found(sets.compactMap { current in
                    var current = current
                    current.copies.removeAll { $0.id == comic.id }
                    return current.copies.count > 1 ? current : nil
                })
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
