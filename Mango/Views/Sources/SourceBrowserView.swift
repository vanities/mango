import SwiftUI
import os
import ShelfKit

/// Everything on one source, a compact row per series, and a ring showing how much of it is in
/// both places — on a NAS, how much is on this device; on this device, how much is safe on the
/// NAS. The ring's menu downloads a series, uploads it, or sends it back to the NAS. Open a
/// series for its volumes as a grid of numbers; Select picks any mix of series and volumes.
/// Stacks show as in the library: JoJo's parts together, under JoJo.
struct SourceBrowserView: View {
    let source: LibrarySource

    @Environment(LibraryModel.self) private var library
    @Environment(TransferManager.self) private var transfers
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var expanded = Set<String>()
    @State private var reading: Comic?
    /// A move asks first: the originals leave the folder the user picked.
    @State private var confirmingMove: [Comic]?
    /// So does everything at once from the ••• menu, with its count and size.
    @State private var confirmingDownload: [Comic]?
    @State private var confirmingUpload: [Comic]?

    var body: some View {
        let shelves = shelves
        let status = Status(library: library, transfers: transfers)
        let comics = shelves.flatMap(\.comics)
        List {
            Section { summary(comics, status) }
            ForEach(blocks(shelves)) { block in
                Section {
                    ForEach(block.members, id: \.series.id) { member in
                        seriesRow(member.series, name: member.name, status)
                    }
                } header: {
                    if let title = block.title { Text(title) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .environment(\.defaultMinListRowHeight, 36)
        // No search: a search drawer shows and hides as the list grows and shrinks, and the
        // title jumps with it every time a series opens.
        .navigationTitle(selecting ? (selection.isEmpty ? "Select Volumes" : "\(selection.count) Selected") : source.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(selecting)
        // The selection's actions live in the bottom bar; the floating tab bar would sit on them.
        .toolbar(selecting ? .hidden : .automatic, for: .tabBar)
        .toolbar { toolbar(comics, status) }
        .fullScreenCover(item: $reading) { ReaderRouter(comic: $0) }
        .confirmationDialog(
            "Move \(confirmingMove?.count ?? 0) into Mango?",
            isPresented: Binding(get: { confirmingMove != nil }, set: { if !$0 { confirmingMove = nil } }),
            titleVisibility: .visible, presenting: confirmingMove
        ) { comics in
            Button("Move \(comics.count) (\(Self.bytes(comics)))") { move(comics) }
        } message: { _ in
            Text("Each is copied into Mango's own folder, checked, and only then removed from \(source.displayName). Your place, bookmarks and ratings go with them. A different file already in Mango's folder is never replaced.")
        }
        .confirmationDialog(
            "Download \(confirmingDownload?.count ?? 0) to this device?",
            isPresented: Binding(get: { confirmingDownload != nil }, set: { if !$0 { confirmingDownload = nil } }),
            titleVisibility: .visible, presenting: confirmingDownload
        ) { comics in
            Button("Download \(comics.count) (\(Self.bytes(comics)))") { download(comics) }
        } message: { _ in
            Text("Copies go into Mango's folder with the same layout, one at a time, while Mango is open. Files already here are skipped.")
        }
        .confirmationDialog(
            "Upload \(confirmingUpload?.count ?? 0) to \(uploadServer?.name ?? "the NAS")?",
            isPresented: Binding(get: { confirmingUpload != nil }, set: { if !$0 { confirmingUpload = nil } }),
            titleVisibility: .visible, presenting: confirmingUpload
        ) { comics in
            Button("Upload \(comics.count) (\(Self.bytes(comics)))") { upload(comics) }
        } message: { _ in
            Text("Each is uploaded to \(uploadServer?.name ?? "the NAS"), one at a time, while Mango is open. Your copies stay on this device; ones already on the NAS are skipped.")
        }
        .task {
            // A source with a series or two opens with its volumes showing.
            if expanded.isEmpty, shelves.count <= 2 { expanded = Set(shelves.map(\.id)) }
        }
    }

    private var shelves: [Series] {
        let comics = library.state.comics.filter {
            $0.sourceID == source.id && !library.state.hiddenComicIDs.contains($0.id)
        }
        return SeriesGrouper.group(comics).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Where this device's comics can go: the first NAS, as elsewhere in the app.
    private var uploadServer: NASServer? {
        source.isRemote ? nil : library.state.nasServers.first
    }

    /// Where this source lives: a NAS share, or the folder on this device.
    private var location: String? {
        if let server = source.serverID.flatMap({ id in library.state.nasServers.first { $0.id == id } }) { return server.displayLocation }
        return library.root(for: source)?.path(percentEncoded: false)
    }

    // MARK: Stacks

    /// A run of the list: a stack under its name, or the plain series between stacks.
    private struct Block: Identifiable {
        let id: String
        let title: String?
        var members: [(series: Series, name: String)]
    }

    /// Stacks as the library makes them (per medium, the user's choices winning), in name order;
    /// a stack's members read without its name in front ("Part 1 - Phantom Blood").
    private func blocks(_ shelves: [Series]) -> [Block] {
        let manual = library.state.seriesGroups
        let items = [false, true]
            .flatMap { novels in SeriesGrouping.arrange(shelves.filter { $0.isNovel == novels }, manual: manual) }
            .sorted { Self.name(of: $0).localizedStandardCompare(Self.name(of: $1)) == .orderedAscending }
        var blocks: [Block] = []
        for item in items {
            switch item {
            case .group(let group):
                let members = group.members.map { ($0, SeriesGrouping.shortName(of: $0.name, in: group.name)) }
                blocks.append(Block(id: group.id, title: group.name, members: members))
            case .series(let series):
                if let last = blocks.indices.last, blocks[last].title == nil {
                    blocks[last].members.append((series, series.name))
                } else {
                    blocks.append(Block(id: "run|" + series.id, title: nil, members: [(series, series.name)]))
                }
            }
        }
        return blocks
    }

    private static func name(of item: ShelfItem) -> String {
        switch item {
        case .series(let series): series.name
        case .group(let group): group.name
        }
    }

    // MARK: Where things stand

    /// Where every comic stands, worked out once per update rather than once per tile.
    private struct Status {
        /// Downloads — copies in Mango's own folder of comics still on a NAS — by `syncKey`.
        let downloads: [String: Comic]
        /// Everything on a NAS, by `syncKey`.
        let onNAS: Set<String>
        /// Transfers queued or under way, by comic id.
        let jobs: [String: TransferManager.Job]

        @MainActor init(library: LibraryModel, transfers: TransferManager) {
            downloads = Dictionary(library.downloads.map { ($0.syncKey, $0) }, uniquingKeysWith: { first, _ in first })
            onNAS = Set(library.state.comics.filter { $0.isRemote(in: library) }.map(\.syncKey))
            jobs = Dictionary(transfers.jobs.filter(\.isActive).map { ($0.comicID, $0) }, uniquingKeysWith: { _, last in last })
        }
    }

    private enum Action { case download, upload, remove }

    private func state(of comic: Comic, _ status: Status) -> CopyPlace {
        if let job = status.jobs[comic.id] { return .transferring(job.fraction) }
        if source.isRemote { return status.downloads[comic.syncKey] != nil ? .both : .remote }
        return status.onNAS.contains(comic.syncKey) ? .both : .deviceOnly
    }

    /// What Download, Upload or Remove would do to a comic, if anything. A folder you picked
    /// is yours: its comics can go up to the NAS, but Mango never deletes them.
    private func action(for state: CopyPlace) -> Action? {
        switch state {
        case .remote: .download
        case .both: source.isRemote || source.kind == .appDocuments ? .remove : nil
        case .deviceOnly: uploadServer == nil ? nil : .upload
        case .transferring: nil
        }
    }

    private func comics(_ comics: [Comic], for action: Action, _ status: Status) -> [Comic] {
        comics.filter { self.action(for: state(of: $0, status)) == action }
    }

    /// A folder the user picked can be moved into Mango's own — only when they ask.
    private var canMove: Bool { source.kind == .folder }

    private func movable(_ comics: [Comic], _ status: Status) -> [Comic] {
        guard canMove else { return [] }
        return comics.filter { status.jobs[$0.id] == nil }
    }

    /// Something a bulk action can do to it: download, upload, remove — or move, from a folder.
    private func isSelectable(_ comic: Comic, _ status: Status) -> Bool {
        action(for: state(of: comic, status)) != nil || (canMove && status.jobs[comic.id] == nil)
    }

    private static func bytes(_ comics: [Comic]) -> String {
        Formatting.bytes(comics.reduce(0) { $0 + $1.totalBytes })
    }

    /// How much of `comics` is in both places by size, counting what's on its way.
    private func bothFraction(_ comics: [Comic], _ status: Status) -> Double {
        let total = comics.reduce(Int64(0)) { $0 + $1.totalBytes }
        guard total > 0 else { return 0 }
        let both = comics.reduce(Int64(0)) { sum, comic in
            switch state(of: comic, status) {
            case .both: sum + comic.totalBytes
            case .transferring: sum + (status.jobs[comic.id]?.doneBytes ?? 0)
            case .remote, .deviceOnly: sum
            }
        }
        return Double(both) / Double(total)
    }

    // MARK: Summary

    private func summary(_ comics: [Comic], _ status: Status) -> some View {
        let both = comics.filter { state(of: $0, status) == .both }
        let total = Self.bytes(comics)
        let tracksNAS = source.isRemote || !status.onNAS.isEmpty || uploadServer != nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(!tracksNAS ? "\(comics.count) comics" : source.isRemote ? "On this device" : "On the NAS")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(!tracksNAS ? total
                     : both.isEmpty ? "None of \(comics.count) · \(total)"
                     : "\(both.count) of \(comics.count) · \(Self.bytes(both)) of \(total)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if tracksNAS {
                StorageBar(fraction: bothFraction(comics, status))
                HStack(spacing: 14) {
                    PlaceLegend(.both, source.isRemote ? "On this device" : "Also on the NAS")
                    PlaceLegend(source.isRemote ? .remote : .deviceOnly, source.isRemote ? "Only on the NAS" : "Only on this device")
                }
            }
            if let location {
                Text(location)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Series

    private func seriesRow(_ shelf: Series, name: String, _ status: Status) -> some View {
        let isOpen = expanded.contains(shelf.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if selecting { seriesMark(shelf, name: name, status) }
                CoverView(coverID: shelf.coverID, title: shelf.name, cornerRadius: 3)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    // The end of a long name is what tells series apart ("… Part 5 - Vento Aureo").
                    Text(name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(detail(shelf, status))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(isOpen ? "Hides the volumes" : "Shows the volumes")
                Spacer(minLength: 4)
                if !selecting { seriesButton(shelf, status) }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.snappy(duration: 0.25)) {
                    if isOpen { expanded.remove(shelf.id) } else { expanded.insert(shelf.id) }
                }
            }
            .contextMenu { if !selecting { seriesActions(shelf, status) } }

            if isOpen { volumeGrid(shelf, status) }
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
    }

    /// "3 of 40 on this device · 12.3 GB", "201 chapters · 9.8 GB".
    private func detail(_ shelf: Series, _ status: Status) -> String {
        let both = shelf.comics.count { state(of: $0, status) == .both }
        let size = Self.bytes(shelf.comics), kind = shelf.isNovel ? "Novels · " : ""
        guard both > 0 else { return kind + "\(shelf.subtitle) · \(size)" }
        let place = source.isRemote ? "on this device" : "on the NAS"
        return kind + (both == shelf.comics.count ? "All \(place) · \(size)" : "\(both) of \(shelf.comics.count) \(place) · \(size)")
    }

    /// The series' one-tap control: a ring of how much is in both places (or on its way), with a
    /// menu of what it can do.
    @ViewBuilder
    private func seriesButton(_ shelf: Series, _ status: Status) -> some View {
        let states = shelf.comics.map { state(of: $0, status) }
        let moving = states.contains { if case .transferring = $0 { true } else { false } }
        if moving || canMove || states.contains(where: { action(for: $0) != nil }) {
            Menu {
                seriesActions(shelf, status)
            } label: {
                Group {
                    if canMove, uploadServer == nil, !moving {
                        Image(systemName: "arrow.right.circle").font(.title3).foregroundStyle(Color.accentColor)
                    } else {
                        TransferRing(fraction: bothFraction(shelf.comics, status), upward: !source.isRemote, isMoving: moving,
                                   isComplete: !moving && !states.contains { $0 == .remote || $0 == .deviceOnly })
                    }
                }
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(source.isRemote ? "Download options" : "Upload options")
        }
    }

    @ViewBuilder
    private func seriesActions(_ shelf: Series, _ status: Status) -> some View {
        let downloads = comics(shelf.comics, for: .download, status)
        let uploads = comics(shelf.comics, for: .upload, status)
        let removals = comics(shelf.comics, for: .remove, status)
        let active = shelf.comics.compactMap { status.jobs[$0.id] }
        if !active.isEmpty {
            Button("Stop \(active.count) Transfer\(active.count == 1 ? "" : "s")", systemImage: "stop.circle") {
                active.forEach { transfers.cancel($0.id) }
            }
        }
        if !downloads.isEmpty {
            Button(downloads.count == shelf.comics.count ? "Download All \(downloads.count) (\(Self.bytes(downloads)))"
                   : "Download \(downloads.count) More (\(Self.bytes(downloads)))", systemImage: "arrow.down.circle") {
                download(downloads)
            }
        }
        if !uploads.isEmpty, let server = uploadServer {
            Button("Upload \(uploads.count) to \(server.name) (\(Self.bytes(uploads)))", systemImage: "arrow.up.circle") {
                upload(uploads)
            }
        }
        if !removals.isEmpty {
            Button("Remove \(removals.count) Download\(removals.count == 1 ? "" : "s") (\(Self.bytes(removals)))",
                   systemImage: "trash", role: .destructive) {
                remove(removals)
            }
        }
        let moves = movable(shelf.comics, status)
        if !moves.isEmpty {
            Button("Move \(moves.count) into Mango (\(Self.bytes(moves)))", systemImage: "arrow.right.circle") {
                confirmingMove = moves
            }
        }
    }

    /// Select mode's circle for a whole series: empty, part-picked, or all picked.
    private func seriesMark(_ shelf: Series, name: String, _ status: Status) -> some View {
        let ids = Set(shelf.comics.filter { isSelectable($0, status) }.map(\.id))
        let picked = ids.intersection(selection).count
        return Button {
            if !ids.isEmpty, picked == ids.count { selection.subtract(ids) } else { selection.formUnion(ids) }
        } label: {
            Image(systemName: picked == 0 ? "circle" : picked == ids.count ? "checkmark.circle.fill" : "minus.circle.fill")
                .font(.title3)
                .foregroundStyle(picked == 0 ? Color.secondary : Color.accentColor)
                .frame(width: 28, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(ids.isEmpty)
        .opacity(ids.isEmpty ? 0.35 : 1)
        .accessibilityLabel(!ids.isEmpty && picked == ids.count ? "Deselect \(name)" : "Select \(name)")
    }

    // MARK: Volumes

    private func volumeGrid(_ shelf: Series, _ status: Status) -> some View {
        // Chapters and volumes both numbered from 1 would collide, so a series with both marks them.
        let mixed = shelf.comics.contains { $0.chapter != nil } && shelf.comics.contains { $0.chapter == nil && $0.volume != nil }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 44, maximum: 80), spacing: 6)], spacing: 6) {
            ForEach(Array(shelf.comics.enumerated()), id: \.element.id) { index, comic in
                tile(comic, label: Self.label(for: comic, at: index, mixed: mixed), status)
            }
        }
        .padding(.leading, selecting ? 38 : 0)
    }

    /// "3", "12.5"; "c12" / "v3" when a series has both; "#4" for a file with no number.
    static func label(for comic: Comic, at index: Int, mixed: Bool) -> String {
        if let chapter = comic.chapter { return (mixed ? "c" : "") + Formatting.number(chapter) }
        if let volume = comic.volume { return (mixed ? "v" : "") + Formatting.number(volume) }
        return "#\(index + 1)"
    }

    private func tile(_ comic: Comic, label: String, _ status: Status) -> some View {
        let state = state(of: comic, status)
        let actionable = isSelectable(comic, status)
        let picked = selection.contains(comic.id)
        return Button {
            if selecting {
                guard actionable else { return }
                if picked { selection.remove(comic.id) } else { selection.insert(comic.id) }
            } else {
                reading = status.downloads[comic.syncKey] ?? comic
            }
        } label: {
            Text(label)
                .font(.footnote.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(state == .remote ? Color.primary : state == .deviceOnly ? Color.secondary : Color.accentColor)
                .frame(maxWidth: .infinity, minHeight: 32)
                .padding(.horizontal, 2)
                .background { PlaceBackground(state) }
                .overlay {
                    if picked {
                        RoundedRectangle(cornerRadius: PlaceBackground.radius, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if picked {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.white, Color.accentColor)
                            .offset(x: 4, y: -4)
                    }
                }
                .opacity(selecting && !actionable ? 0.4 : 1)
        }
        .buttonStyle(.borderless)
        .contextMenu { if !selecting { tileActions(comic, state, status) } }
        .accessibilityLabel(accessibilityLabel(comic, state))
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    @ViewBuilder
    private func tileActions(_ comic: Comic, _ state: CopyPlace, _ status: Status) -> some View {
        Button("Read", systemImage: "book") { reading = status.downloads[comic.syncKey] ?? comic }
        switch action(for: state) {
        case .download:
            Button("Download (\(Formatting.bytes(comic.totalBytes)))", systemImage: "arrow.down.circle") { download([comic]) }
        case .upload:
            if let server = uploadServer {
                Button("Upload to \(server.name) (\(Formatting.bytes(comic.totalBytes)))", systemImage: "arrow.up.circle") { upload([comic]) }
            }
        case .remove:
            Button("Remove Download (\(Formatting.bytes(comic.totalBytes)))", systemImage: "trash", role: .destructive) { remove([comic]) }
        case nil:
            if let job = status.jobs[comic.id] {
                Button("Stop", systemImage: "stop.circle") { transfers.cancel(job.id) }
            }
        }
    }

    private func accessibilityLabel(_ comic: Comic, _ state: CopyPlace) -> String {
        let name = comic.numberLabel ?? comic.title
        switch state {
        case .remote: return "\(name), only on the NAS"
        case .transferring(let fraction): return "\(name), \(source.isRemote ? "downloading" : "uploading"), \(Int(fraction * 100)) percent"
        case .both: return source.isRemote ? "\(name), on this device" : "\(name), also on the NAS"
        case .deviceOnly: return "\(name), only on this device"
        }
    }

    // MARK: Select

    @ToolbarContentBuilder
    private func toolbar(_ comics: [Comic], _ status: Status) -> some ToolbarContent {
        let actionable = Set(comics.filter { isSelectable($0, status) }.map(\.id))
        if !selecting {
            ToolbarItem(placement: .primaryAction) { moreMenu(comics, status) }
        }
        if selecting || !actionable.isEmpty {
            ToolbarItem(placement: .primaryAction) {
                Button(selecting ? "Done" : "Select") {
                    withAnimation {
                        selecting.toggle()
                        selection.removeAll()
                    }
                }
            }
        }
        if selecting {
            let picked = comics.filter { selection.contains($0.id) }
            let downloads = self.comics(picked, for: .download, status)
            let uploads = self.comics(picked, for: .upload, status)
            let removals = self.comics(picked, for: .remove, status)
            let moves = movable(picked, status)
            ToolbarItem(placement: .topBarLeading) {
                Button(!actionable.isEmpty && actionable.isSubset(of: selection) ? "Deselect All" : "Select All") {
                    selection = actionable.isSubset(of: selection) ? [] : actionable
                }
                .disabled(actionable.isEmpty)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                // Words with a count and a size, so it's clear what a tap will do: the bottom
                // bar draws an icon-only label as a bare glyph.
                if source.isRemote {
                    Button { download(downloads) } label: {
                        Text(downloads.isEmpty ? "Download" : "Download \(downloads.count) (\(Self.bytes(downloads)))")
                    }
                    .disabled(downloads.isEmpty)
                } else if uploadServer != nil {
                    Button { upload(uploads) } label: {
                        Text(uploads.isEmpty ? "Upload" : "Upload \(uploads.count) (\(Self.bytes(uploads)))")
                    }
                    .disabled(uploads.isEmpty)
                }
                Spacer()
                if source.isRemote || source.kind == .appDocuments {
                    Button(role: .destructive) { remove(removals) } label: {
                        Text(removals.isEmpty ? "Remove" : "Remove \(removals.count) (\(Self.bytes(removals)))")
                    }
                    .disabled(removals.isEmpty)
                } else if canMove {
                    Button { confirmingMove = moves } label: {
                        Text(moves.isEmpty ? "Move" : "Move \(moves.count) (\(Self.bytes(moves)))")
                    }
                    .disabled(moves.isEmpty)
                }
            }
        }
    }

    /// What can be done to the whole source at once, each with its count and size — as on
    /// Earmark's source pages.
    private func moreMenu(_ comics: [Comic], _ status: Status) -> some View {
        let downloads = self.comics(comics, for: .download, status)
        let uploads = self.comics(comics, for: .upload, status)
        let moves = movable(comics, status)
        return Menu {
            Button("Rescan", systemImage: "arrow.clockwise") { Task { await library.scan() } }
            if source.isRemote {
                Button(downloads.isEmpty ? "Everything Is on This Device" : "Download \(downloads.count) Missing (\(Self.bytes(downloads)))",
                       systemImage: "arrow.down.circle") { confirmingDownload = downloads }
                    .disabled(downloads.isEmpty)
            }
            if let server = uploadServer {
                Button(uploads.isEmpty ? "All Backed Up to \(server.name)" : "Upload \(uploads.count) to \(server.name) (\(Self.bytes(uploads)))",
                       systemImage: "arrow.up.circle") { confirmingUpload = uploads }
                    .disabled(uploads.isEmpty)
            }
            if canMove {
                Button(moves.isEmpty ? "Nothing Left to Move" : "Move All \(moves.count) into Mango (\(Self.bytes(moves)))",
                       systemImage: "arrow.right.circle") { confirmingMove = moves }
                    .disabled(moves.isEmpty)
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }

    private func download(_ comics: [Comic]) {
        comics.forEach(transfers.download)
        Logger.downloads.info("[sources] queued \(comics.count) download(s) from \(source.displayName, privacy: .public)")
        finishSelecting()
    }

    private func upload(_ comics: [Comic]) {
        guard let server = uploadServer else { return }
        comics.forEach { transfers.upload($0, to: server.id) }
        Logger.downloads.info("[sources] queued \(comics.count) upload(s) from \(source.displayName, privacy: .public)")
        finishSelecting()
    }

    private func move(_ comics: [Comic]) {
        comics.forEach(transfers.move)
        Logger.downloads.info("[sources] queued \(comics.count) move(s) into Mango from \(source.displayName, privacy: .public)")
        finishSelecting()
    }

    private func remove(_ comics: [Comic]) {
        let result = library.removeDownloads(comics)
        Logger.downloads.info("[sources] removed \(result.count) download(s), \(result.bytes)B, from \(source.displayName, privacy: .public)")
        finishSelecting()
    }

    private func finishSelecting() {
        guard selecting else { return }
        withAnimation {
            selecting = false
            selection.removeAll()
        }
    }
}
