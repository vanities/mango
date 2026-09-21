import AppIntents
import Foundation

/// One comic or novel, exposed to Siri and Shortcuts so "Open Tower Dungeon in Mango" works.
struct ComicEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Book"
    static let defaultQuery = ComicEntityQuery()

    let id: String
    let title: String
    let series: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(series)")
    }

    init(_ comic: Comic) {
        id = comic.id
        title = comic.numberLabel.map { "\(comic.displaySeries) \($0)" } ?? comic.title
        series = comic.series ?? (comic.isNovel ? "Light novel" : "Comic")
    }
}

struct ComicEntityQuery: EntityQuery, EntityStringQuery {
    @MainActor func entities(for identifiers: [String]) async throws -> [ComicEntity] {
        let library = AppEnvironment.shared.library
        return identifiers.compactMap { library.comic(id: $0).map(ComicEntity.init) }
    }

    /// Spoken or typed names match series and titles, loosely.
    @MainActor func entities(matching string: String) async throws -> [ComicEntity] {
        let needle = string.normalizedForMatching
        return AppEnvironment.shared.library.visibleComics
            .filter { $0.title.normalizedForMatching.contains(needle) || ($0.series?.normalizedForMatching.contains(needle) ?? false) }
            .prefix(20)
            .map(ComicEntity.init)
    }

    /// What you're in the middle of shows up first as a suggestion.
    @MainActor func suggestedEntities() async throws -> [ComicEntity] {
        let library = AppEnvironment.shared.library
        let reading = library.continueReading
        let pool = reading.isEmpty ? Array(library.visibleComics.prefix(10)) : reading
        return pool.prefix(10).map(ComicEntity.init)
    }
}

/// "Continue reading in Mango" — opens straight into whatever you were last reading. Unlike
/// audio, reading needs the screen, so this brings the app forward.
struct ContinueReadingIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Reading"
    static let description = IntentDescription("Open the book you were last reading, where you left off.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let library = AppEnvironment.shared.library
        guard let comic = library.lastRead else {
            return .result(dialog: "You haven't started anything in Mango yet.")
        }
        library.requestedComic = comic
        return .result(dialog: "Opening \(comic.displaySeries).")
    }
}

/// "Open <book> in Mango".
struct OpenComicIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Book"
    static let description = IntentDescription("Open a specific manga, comic or light novel in Mango.")
    static let openAppWhenRun = true

    @Parameter(title: "Book")
    var comic: ComicEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let match = AppEnvironment.shared.library.comic(id: comic.id) else {
            throw $comic.needsValueError("Which book?")
        }
        AppEnvironment.shared.library.requestedComic = match
        return .result()
    }

    static var parameterSummary: some ParameterSummary { Summary("Open \(\.$comic)") }
}

struct MangoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ContinueReadingIntent(),
            phrases: [
                "Continue reading in \(.applicationName)",
                "Keep reading in \(.applicationName)",
                "Open my manga in \(.applicationName)",
            ],
            shortTitle: "Continue Reading",
            systemImageName: "book.fill"
        )
        AppShortcut(
            intent: OpenComicIntent(),
            phrases: ["Open \(\.$comic) in \(.applicationName)"],
            shortTitle: "Open Book",
            systemImageName: "books.vertical.fill"
        )
    }
}
