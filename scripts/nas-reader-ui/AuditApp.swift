import ShelfKit
import SwiftUI

/// Compiled only by this simulator harness, in place of MangoApp. Uses the real reader.
@main
struct NASReaderAuditApp: App {
    @State private var settings: AppSettings
    @State private var library: LibraryModel
    @State private var comic: Comic
    @State private var showingReader = false

    init() {
        let settings = AppSettings()
        settings.novelPaged = !ProcessInfo.processInfo.arguments.contains("--scrolling")
        settings.novelFontScale = 0.8
        let root = URL.applicationSupportDirectory.appending(path: "GeneratedNASReaderAudit")
        let library = LibraryModel(store: LibraryStore(directory: root.appending(path: "state")),
                                   covers: CoverStore(directory: root.appending(path: "covers"), customDirectory: root.appending(path: "custom")),
                                   settings: settings)
        let server = NASServer(id: UUID(uuidString: "C5F4331C-1F76-4C39-BEA3-001607026321")!,
                               name: "Generated loopback fixtures", host: "127.0.0.1", port: 1445,
                               share: "AUDIT", path: "", username: "audit", addedAt: .now)
        let source = LibrarySource(id: UUID(uuidString: "1B2BCE94-728E-41A3-872B-3484B1AE2937")!, kind: .smb,
                                   displayName: "Generated loopback fixtures", addedAt: .now, serverID: server.id)
        let path = "Audit Novel v01.epub"
        let comic = Comic(id: Comic.makeID(sourceID: source.id, relativePath: path), sourceID: source.id,
                          relativePath: path, kind: .epub, title: "Chapter recovery fixture", series: nil, volume: nil, chapter: nil,
                          author: nil, year: nil, subtitle: nil, pageCount: 24, totalBytes: 0, addedAt: .now)
        library.mutateState {
            $0.sources = [source]
            $0.nasServers = [server]
            $0.comics = [comic]
            if !ProcessInfo.processInfo.arguments.contains("--resume") { $0.progress[comic.id] = nil }
        }
        library.clients[server.id] = try? NASClient(server: server, password: "local-fixture-only")
        _settings = State(initialValue: settings)
        _library = State(initialValue: library)
        _comic = State(initialValue: comic)
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Button("Open generated remote novel") { showingReader = true }
                    .navigationDestination(isPresented: $showingReader) { NovelReaderView(comic: comic) }
            }
            .environment(settings)
            .environment(library)
            .preferredColorScheme(.dark)
        }
    }
}
