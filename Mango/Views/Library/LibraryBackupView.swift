import SwiftUI
import ShelfKit

struct LibraryBackupView: View {
    @Environment(LibraryModel.self) private var library
    var body: some View {
        BackupRestoreView(app: "Mango", export: export, preview: preview, restore: restore)
    }
    private func export() async throws -> LibraryBackupDocument {
        var state = library.state
        state.nasServers = []
        for i in state.sources.indices { state.sources[i].bookmark = nil }
        let coverIDs = Set(state.customCovers.values)
        let covers = library.covers
        let images = await Task.detached(priority: .utility) {
            var images: [String: Data] = [:]
            for id in coverIDs {
                if let data = try? Data(contentsOf: covers.url(for: id)) { images[id] = data }
            }
            return images
        }.value
        return try LibraryBackupDocument(app: "Mango", state: JSONEncoder().encode(state), covers: images)
    }
    private func decode(_ backup: LibraryBackupDocument) throws -> LibraryState {
        try backup.validate(app: "Mango")
        let state = try JSONDecoder().decode(LibraryState.self, from: backup.state)
        guard state.customCovers.values.allSatisfy(LibraryBackupDocument.safeCoverID) else { throw CocoaError(.fileReadCorruptFile) }
        return state
    }
    private func preview(_ backup: LibraryBackupDocument) throws -> String {
        let old = try decode(backup)
        let matches = library.state.portableMatches(old)
        let matchedIDs = Set(matches.map { $0.0 })
        let matchedKeys = Set(old.comics.filter { matchedIDs.contains($0.id) }.map(\.syncKey))
        let savedKeys = Set(old.comics.map(\.syncKey))
        let skipped = old.comics.filter { !matchedKeys.contains($0.syncKey) }.map(\.title)
        var summary = "\(matchedKeys.count) of \(savedKeys.count) saved books match this library. \(old.readingLists.count) lists and \(backup.covers.count) cover images in this backup."
        if !skipped.isEmpty { summary += "\n\nSkipped: " + skipped.prefix(30).joined(separator: ", ") }
        return summary
    }
    private func restore(_ backup: LibraryBackupDocument) async throws {
        var old = try decode(backup)
        let valid = Set(old.customCovers.values)
        for (id, data) in backup.covers where valid.contains(id) {
            if !library.covers.exists(id), !library.covers.storeCustom(imageData: data, as: id) { throw CocoaError(.fileWriteUnknown) }
        }
        // Never retain a reference to an image absent from the portable bundle/device.
        old.customCovers = old.customCovers.filter { library.covers.exists($0.value) }
        library.mutateState { $0.restorePortable(old) }
        await library.scan()
    }
}
