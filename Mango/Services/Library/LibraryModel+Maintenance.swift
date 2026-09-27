import Foundation
import ShelfKit
import os

extension LibraryModel {
    func reconnectNAS(_ server: NASServer) throws {
        guard !isScanning, let index = state.nasServers.firstIndex(where: { $0.id == server.id }) else { throw CocoaError(.fileWriteUnknown) }
        mutateState { $0.nasServers[index] = server }
        let old = clients.removeValue(forKey: server.id)
        Task { await old?.disconnect() }
        let ids = Set(state.sources.filter { $0.serverID == server.id }.map(\.id))
        Task { await scan(sourceIDs: ids) }
        Logger.nas.info("[reconnect] updated NAS source \(server.id.uuidString, privacy: .public)")
    }

    func reconnectFolder(_ source: LibrarySource, to url: URL) throws {
        guard !isScanning, let index = state.sources.firstIndex(where: { $0.id == source.id }),
              source.kind == .folder || source.kind == .smb else { throw CocoaError(.fileWriteUnknown) }
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        for other in state.sources where other.id != source.id {
            guard let root = root(for: other) else { continue }
            let existing = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            guard !candidate.hasPrefix(existing), !existing.hasPrefix(candidate) else {
                throw NSError(domain: "LibraryReconnect", code: 1, userInfo: [NSLocalizedDescriptionKey: "That folder overlaps another library source."])
            }
        }
        let scoped = url.startAccessingSecurityScopedResource()
        do {
            let bookmark = try BookmarkStore.makeBookmark(for: url)
            scopedURLs[source.id]?.stopAccessingSecurityScopedResource()
            mutateState { state in
                state.sources[index].bookmark = bookmark
                state.sources[index].kind = .folder
                state.sources[index].serverID = nil
                state.sources[index].lastError = nil
            }
            roots[source.id] = url
            scopedURLs[source.id] = scoped ? url : nil
            Logger.library.info("[reconnect] source=\(source.id.uuidString, privacy: .public) folder=\(url.lastPathComponent, privacy: .public)")
            Task { await scan(sourceIDs: [source.id]) }
        } catch {
            if scoped { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

}
