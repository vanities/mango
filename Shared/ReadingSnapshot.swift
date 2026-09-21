import Foundation

/// What the Home and Lock Screen widget needs to draw, handed from the app to the widget
/// through the App Group container. Deliberately tiny: no pages, just what to show and where
/// a tap should go.
struct ReadingSnapshot: Codable, Equatable {
    var comicID: String
    var title: String
    var series: String
    var positionLabel: String
    var fraction: Double
    var isNovel: Bool
    var updatedAt: Date

    /// Where a tap on the widget lands.
    var deepLink: URL? {
        var components = URLComponents()
        components.scheme = "mango"
        components.host = "open"
        components.path = "/" + comicID
        return components.url
    }
}

/// Reads and writes the snapshot and its cover in the shared container. Everything no-ops when
/// the App Group isn't available — the widget then shows its empty state instead of crashing.
enum SharedReading {
    static let appGroup = "group.com.vanities.mango"
    private static let jsonName = "reading.json"
    private static let coverName = "reading-cover.jpg"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    static var coverURL: URL? { containerURL?.appending(path: coverName) }

    static func write(_ snapshot: ReadingSnapshot?) {
        guard let directory = containerURL else { return }
        let url = directory.appending(path: jsonName)
        guard let snapshot else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot) { try? data.write(to: url, options: .atomic) }
    }

    static func read() -> ReadingSnapshot? {
        guard let directory = containerURL,
              let data = try? Data(contentsOf: directory.appending(path: jsonName)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ReadingSnapshot.self, from: data)
    }

    static func writeCover(_ jpeg: Data?) {
        guard let url = coverURL else { return }
        guard let jpeg else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? jpeg.write(to: url, options: .atomic)
    }
}
