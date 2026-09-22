import Foundation
import os
import ShelfKit

/// Metadata a release ships *inside* its archive, as `ComicInfo.xml` — the Anansi schema that
/// Komga, Kavita and ComicRack all read. When it's there it beats anything guessed from the
/// filename, because someone actually typed it in.
struct ComicInfo: Codable, Hashable, Sendable {
    var series: String?
    var title: String?
    var volume: Double?
    var number: String?
    var summary: String?
    var writer: String?
    var year: Int?
    var pageCount: Int?
    var genre: String?
    var languageISO: String?
    /// The `<Manga>` field. `YesAndRightToLeft` is the one that matters: it says which way
    /// this particular book reads, so nobody has to set it by hand.
    var manga: MangaFlag?

    enum MangaFlag: String, Codable, Sendable {
        case unknown = "Unknown"
        case no = "No"
        case yes = "Yes"
        case yesAndRightToLeft = "YesAndRightToLeft"

        /// Only an explicit answer sets a direction; "Yes" alone doesn't say which way.
        var direction: ReadingDirection? {
            switch self {
            case .yesAndRightToLeft: .rightToLeft
            case .no: .leftToRight
            case .yes, .unknown: nil
            }
        }
    }

    var isEmpty: Bool {
        series == nil && title == nil && volume == nil && number == nil && summary == nil
            && writer == nil && year == nil && manga == nil
    }

    init(series: String? = nil, title: String? = nil, volume: Double? = nil, number: String? = nil,
         summary: String? = nil, writer: String? = nil, year: Int? = nil, pageCount: Int? = nil,
         genre: String? = nil, languageISO: String? = nil, manga: MangaFlag? = nil) {
        self.series = series
        self.title = title
        self.volume = volume
        self.number = number
        self.summary = summary
        self.writer = writer
        self.year = year
        self.pageCount = pageCount
        self.genre = genre
        self.languageISO = languageISO
        self.manga = manga
    }

    /// Lays this over a comic parsed from its filename. Only fields the file actually filled in
    /// are used, and chapter numbers are left alone: `<Number>` means "issue" in one tagger and
    /// "volume" in the next, so it's too inconsistent to trust over the filename.
    func applied(to comic: Comic) -> Comic {
        var out = comic
        if let series = series?.nilIfEmpty { out.series = series }
        if let volume { out.volume = volume }
        if let writer = writer?.nilIfEmpty { out.author = writer }
        if let year { out.year = year }
        if let title = title?.nilIfEmpty, title.normalizedForIdentity != (series ?? "").normalizedForIdentity {
            out.subtitle = title
        }
        if let summary = summary?.nilIfEmpty { out.summary = summary }
        // Re-derive the display title from whatever's now known.
        if let series = out.series {
            if let volume = out.volume {
                out.title = "\(series) Vol. \(Formatting.number(volume))"
            } else if let chapter = out.chapter {
                out.title = "\(series) Ch. \(Formatting.number(chapter))"
            }
        }
        return out
    }
}

/// Reads `ComicInfo.xml`. XMLParser rather than regex: summaries contain markup and entities.
enum ComicInfoParser {
    static func parse(_ data: Data) -> ComicInfo? {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        guard parser.parse() || !delegate.fields.isEmpty else {
            Logger.archive.error("[comicinfo] unparseable (\(data.count)B)")
            return nil
        }
        let f = delegate.fields
        let info = ComicInfo(
            series: f["Series"],
            title: f["Title"],
            volume: f["Volume"].flatMap(Double.init),
            number: f["Number"],
            summary: f["Summary"],
            writer: f["Writer"],
            year: f["Year"].flatMap(Int.init),
            pageCount: f["PageCount"].flatMap(Int.init),
            genre: f["Genre"],
            languageISO: f["LanguageISO"],
            manga: f["Manga"].flatMap(ComicInfo.MangaFlag.init(rawValue:))
        )
        return info.isEmpty ? nil : info
    }

    /// The file name inside an archive, compared case-insensitively — taggers disagree.
    static func isComicInfo(_ path: String) -> Bool {
        (path as NSString).lastPathComponent.lowercased() == "comicinfo.xml"
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        private static let wanted: Set<String> = [
            "Series", "Title", "Volume", "Number", "Summary", "Writer", "Year",
            "PageCount", "Genre", "LanguageISO", "Manga",
        ]
        var fields: [String: String] = [:]
        private var current: String?
        private var buffer = ""

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String]) {
            // Only top-level fields: <Pages><Page .../></Pages> has nothing we want.
            guard Self.wanted.contains(elementName) else { return }
            current = elementName
            buffer = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if current != nil { buffer += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            guard elementName == current else { return }
            let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, fields[elementName] == nil { fields[elementName] = value }
            current = nil
            buffer = ""
        }
    }
}
