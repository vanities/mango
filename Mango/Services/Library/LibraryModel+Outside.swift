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
            requestedComic = publicLastRead
        case "open":
            let id = String(url.path.dropFirst()).removingPercentEncoding ?? String(url.path.dropFirst())
            requestedComic = publicComics.first { $0.id == id }
        default:
            break
        }
    }

    func comic(id: String) -> Comic? { visibleComics.first { $0.id == id } }

    // MARK: Widget

    /// Every saved position reaches the widget, including a reader left open in the background.
    /// Shared data stays current; unchanged visible content doesn't consume a timeline reload.
    func publishWidgetSnapshot() {
        var snapshot: ReadingSnapshot?
        var cover: Data?
        if let comic = publicLastRead {
            if settings.lockMode != .off {
                snapshot = ReadingSnapshot(comicID: comic.id, title: "Continue reading", series: "Mango is locked",
                                           positionLabel: "", fraction: 0, isNovel: comic.isNovel, updatedAt: .now)
            } else {
                let progress = state.progress[comic.id]
                snapshot = ReadingSnapshot(
                    comicID: comic.id,
                    title: [comic.numberLabel, comic.subtitle].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? comic.title,
                    series: comic.displaySeries,
                    positionLabel: progress.map { comic.isNovel ? novelPositionLabel($0, in: comic) : $0.label } ?? "Not started",
                    fraction: progress?.fraction ?? 0,
                    isNovel: comic.isNovel,
                    updatedAt: progress?.updatedAt ?? .now
                )
                if let coverID = comic.coverID { cover = try? Data(contentsOf: covers.url(for: coverID)) }
            }
        }
        let previous = SharedReading.read()
        let previousCover = SharedReading.coverURL.flatMap { try? Data(contentsOf: $0) }
        if previous != snapshot { SharedReading.write(snapshot) }
        if previousCover != cover { SharedReading.writeCover(cover) }
        guard previous?.widgetUpdateKey != snapshot?.widgetUpdateKey || previousCover != cover else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: "ContinueReading")
        Logger.ui.debug("[widget] refreshed reading snapshot")
    }

}
