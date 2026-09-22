import Foundation
import WidgetKit
import os
import ShelfKit

/// Everything that reaches the library from outside its own screens: Siri, Shortcuts,
/// widget taps, and the widget itself. It only reads the library and asks for a book to be
/// opened, so it lives apart from the model's core.
extension LibraryModel {
    // MARK: Opening from outside the app

    static let deepLinkScheme = "mango"

    static func deepLink(for comic: Comic) -> URL? {
        var components = URLComponents()
        components.scheme = deepLinkScheme
        components.host = "open"
        components.path = "/" + comic.id
        return components.url
    }

    /// `mango://open/<comic id>`, or `mango://continue` for whatever you were last reading.
    func handleDeepLink(_ url: URL) {
        guard url.scheme == Self.deepLinkScheme else { return }
        Logger.ui.info("[deeplink] \(url.absoluteString, privacy: .public)")
        switch url.host {
        case "continue":
            requestedComic = lastRead
        case "open":
            let id = String(url.path.dropFirst()).removingPercentEncoding ?? String(url.path.dropFirst())
            requestedComic = visibleComics.first { $0.id == id }
        default:
            break
        }
    }

    func comic(id: String) -> Comic? { visibleComics.first { $0.id == id } }

    // MARK: Widget

    /// Hands the widget what you're reading. Called when a book closes rather than on every
    /// page turn: the widget is what you look at when you're *not* in the app.
    func publishWidgetSnapshot() {
        guard let comic = lastRead else {
            SharedReading.write(nil)
            SharedReading.writeCover(nil)
            WidgetCenter.shared.reloadTimelines(ofKind: "ContinueReading")
            return
        }
        // With the lock on, the Home Screen mustn't say what's being read — the widget still
        // opens it, after Face ID.
        if settings.lockMode != .off {
            SharedReading.write(ReadingSnapshot(comicID: comic.id, title: "Continue reading", series: "Mango is locked",
                                                positionLabel: "", fraction: 0, isNovel: comic.isNovel, updatedAt: .now))
            SharedReading.writeCover(nil)
            WidgetCenter.shared.reloadTimelines(ofKind: "ContinueReading")
            Logger.ui.info("[widget] published a locked snapshot")
            return
        }
        let progress = state.progress[comic.id]
        SharedReading.write(ReadingSnapshot(
            comicID: comic.id,
            title: [comic.numberLabel, comic.subtitle].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? comic.title,
            series: comic.displaySeries,
            positionLabel: progress.map { comic.isNovel ? $0.novelLabel : $0.label } ?? "Not started",
            fraction: progress?.fraction ?? 0,
            isNovel: comic.isNovel,
            updatedAt: progress?.updatedAt ?? .now
        ))
        if let coverID = comic.coverID {
            SharedReading.writeCover(try? Data(contentsOf: covers.url(for: coverID)))
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "ContinueReading")
        Logger.ui.info("[widget] published \(comic.title, privacy: .public)")
    }
}
