import Foundation
import os
import ShelfKit

/// A cover found online.
struct CoverCandidate: Identifiable, Hashable, Sendable {
    var id: String { fullURL.absoluteString }
    var title: String
    /// Which volume this is the cover of, when the source says.
    var volume: Double?
    /// A second line for the picker: the edition's language, the year, the author.
    var detail: String?
    /// The edition's language code ("ja", "en") when the source says — for ranking, since
    /// `detail` is localized for display.
    var language: String?
    var thumbnailURL: URL
    var fullURL: URL
    var source: CoverSource
    /// The cover of the series as a whole rather than of one volume.
    var isSeriesCover = false
}

enum CoverSource: String, Sendable, Hashable {
    case mangaDex = "MangaDex"
    case aniList = "AniList"
    case appleBooks = "Apple Books"
}

/// What a Find Cover search is looking for.
struct CoverQuery: Sendable, Hashable {
    /// The series name, as typed or as shelved.
    var title: String
    /// The volume whose cover is wanted, if it's for one volume.
    var volume: Double?
    var isNovel = false
}

/// Looks up cover art — only when someone taps Find Cover, never in the background. It sends the
/// series name (and the volume number) to MangaDex, AniList and Apple's iTunes Search API; no
/// keys, no accounts, nothing else about the library.
///
/// MangaDex is first because it has a cover for *each volume*, which is what a shelf of volumes
/// wants; AniList has one well-kept cover per series; Apple Books has the retail cover of each
/// English volume, and covers light novels and western comics too.
enum CoverSearch {
    static let userAgent = "Mango/1.0 (+https://github.com/vanities/mango)"
    static let timeout: TimeInterval = 15

    static func search(_ query: CoverQuery) async -> [CoverCandidate] {
        let sw = Stopwatch()
        let title = query.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return [] }
        async let mangaDex = query.isNovel ? [] : mangaDexCandidates(title: title, volume: query.volume)
        async let aniList = aniListCandidates(title: title, isNovel: query.isNovel)
        async let apple = appleBooksCandidates(title: title, volume: query.volume, isNovel: query.isNovel)
        let all = await mangaDex + aniList + apple
        let ranked = rank(all, for: query)
        Logger.cover.info("[covers] \(ranked.count) candidates for \"\(title, privacy: .public)\" vol=\(query.volume.map { Formatting.number($0) } ?? "-", privacy: .public) in \(sw.ms, format: .fixed(precision: 0))ms")
        return ranked
    }

    static func download(_ url: URL) async throws -> Data {
        let sw = Stopwatch()
        let (data, response) = try await URLSession.shared.data(for: request(url))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
            throw URLError(.badServerResponse)
        }
        Logger.cover.info("[covers] downloaded \(data.count)B from \(url.host() ?? "?", privacy: .public) in \(sw.ms, format: .fixed(precision: 0))ms")
        return data
    }

    // MARK: Ranking

    /// The wanted volume's covers first — MangaDex's original Japanese edition, then its English
    /// one, then the retail cover — then the series' own covers, then everything else in volume
    /// order. Duplicates (the same image from two routes) are dropped.
    static func rank(_ candidates: [CoverCandidate], for query: CoverQuery) -> [CoverCandidate] {
        func score(_ candidate: CoverCandidate) -> Int {
            let sourceBonus = switch candidate.source {
            case .mangaDex: candidate.language == "ja" ? 0 : candidate.language == "en" ? 1 : 3
            case .appleBooks: 2
            case .aniList: 4
            }
            if let wanted = query.volume {
                if candidate.volume == wanted { return sourceBonus }
                if candidate.isSeriesCover { return 10 + sourceBonus }
                return 20 + sourceBonus
            }
            if candidate.isSeriesCover { return sourceBonus }
            if candidate.volume == 1 { return 10 + sourceBonus }
            return 20 + sourceBonus
        }
        var seen = Set<URL>()
        return candidates
            .enumerated()
            .sorted { lhs, rhs in
                let (left, right) = (score(lhs.element), score(rhs.element))
                if left != right { return left < right }
                let (lv, rv) = (lhs.element.volume ?? .infinity, rhs.element.volume ?? .infinity)
                if lv != rv { return lv < rv }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
            .filter { seen.insert($0.fullURL).inserted }
    }

    // MARK: MangaDex

    struct MangaDexSeries: Equatable, Sendable {
        var id: String
        var title: String
        /// Every title it goes by, for telling whether it's what was searched for.
        var names: [String] = []
        /// The series' current main cover, straight from the search's `includes[]=cover_art`.
        var mainCoverFile: String?
        var mainCoverVolume: Double?
    }

    private static func mangaDexCandidates(title: String, volume: Double?) async -> [CoverCandidate] {
        var search = URLComponents(string: "https://api.mangadex.org/manga")!
        search.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "limit", value: "3"),
            URLQueryItem(name: "includes[]", value: "cover_art"),
            URLQueryItem(name: "order[relevance]", value: "desc"),
        ] + ["safe", "suggestive", "erotica"].map { URLQueryItem(name: "contentRating[]", value: $0) }
        guard let url = search.url, let data = await fetch(url, label: "mangadex search") else { return [] }
        let series = mangaDexSeries(from: data)
        guard let best = series.first(where: { isRelevant($0.names + [$0.title], to: title) }) else { return [] }

        var covers = URLComponents(string: "https://api.mangadex.org/cover")!
        covers.queryItems = [
            URLQueryItem(name: "manga[]", value: best.id),
            URLQueryItem(name: "limit", value: "100"),
            URLQueryItem(name: "order[volume]", value: "asc"),
        ]
        var out = mangaDexMainCover(best).map { [$0] } ?? []
        if let url = covers.url, let data = await fetch(url, label: "mangadex covers") {
            out += mangaDexCovers(from: data, series: best, volume: volume)
        }
        return out
    }

    static func mangaDexSeries(from data: Data) -> [MangaDexSeries] {
        struct Response: Decodable {
            struct Manga: Decodable {
                struct Attributes: Decodable {
                    let title: [String: String]
                    let altTitles: [[String: String]]?
                }
                struct Relationship: Decodable {
                    struct Cover: Decodable {
                        let fileName: String?
                        let volume: String?
                    }
                    let type: String
                    let attributes: Cover?
                }
                let id: String
                let attributes: Attributes
                let relationships: [Relationship]
            }
            let data: [Manga]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            Logger.cover.error("[covers] mangadex search: unreadable response (\(data.count)B)")
            return []
        }
        return response.data.map { manga in
            let names = manga.attributes.title
            let english = manga.attributes.altTitles?.lazy.compactMap { $0["en"] }.first
            let title = names["en"] ?? english ?? names["ja-ro"] ?? names.values.first ?? manga.id
            let cover = manga.relationships.first { $0.type == "cover_art" }?.attributes
            let allNames = Array(Set(Array(names.values) + (manga.attributes.altTitles ?? []).flatMap(\.values)))
            return MangaDexSeries(id: manga.id, title: title, names: allNames, mainCoverFile: cover?.fileName,
                                  mainCoverVolume: cover?.volume.flatMap(Double.init))
        }
    }

    static func mangaDexMainCover(_ series: MangaDexSeries) -> CoverCandidate? {
        guard let file = series.mainCoverFile,
              let full = URL(string: "https://uploads.mangadex.org/covers/\(series.id)/\(file)"),
              let thumb = URL(string: "https://uploads.mangadex.org/covers/\(series.id)/\(file).512.jpg")
        else { return nil }
        return CoverCandidate(title: series.title, volume: series.mainCoverVolume, detail: "Current cover",
                              thumbnailURL: thumb, fullURL: full, source: .mangaDex, isSeriesCover: true)
    }

    /// The wanted volume's covers in every language MangaDex has, plus the Japanese and English
    /// covers of the nearest other volumes (numbering differs between editions) — capped, so the
    /// picker isn't 118 near-identical tiles.
    static func mangaDexCovers(from data: Data, series: MangaDexSeries, volume: Double?, nearby: Int = 12) -> [CoverCandidate] {
        struct Response: Decodable {
            struct Cover: Decodable {
                struct Attributes: Decodable {
                    let volume: String?
                    let fileName: String
                    let locale: String?
                }
                let attributes: Attributes
            }
            let data: [Cover]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            Logger.cover.error("[covers] mangadex covers: unreadable response (\(data.count)B)")
            return []
        }
        let focus = volume ?? 1
        let all: [CoverCandidate] = response.data.compactMap { cover in
            let attributes = cover.attributes
            let number = attributes.volume.flatMap(Double.init)
            let locale = attributes.locale ?? ""
            // One volume: every edition of it (sometimes only a translation has one). A whole
            // series: the original and English covers are what anyone wants on a shelf.
            guard (volume != nil && number == focus) || ["ja", "en"].contains(locale) else { return nil }
            guard let full = URL(string: "https://uploads.mangadex.org/covers/\(series.id)/\(attributes.fileName)"),
                  let thumb = URL(string: "https://uploads.mangadex.org/covers/\(series.id)/\(attributes.fileName).512.jpg")
            else { return nil }
            let language = Locale.current.localizedString(forLanguageCode: locale) ?? locale
            let label = number.map { "\(series.title) Vol. \(Formatting.number($0))" } ?? series.title
            return CoverCandidate(title: label, volume: number, detail: language, language: locale,
                                  thumbnailURL: thumb, fullURL: full, source: .mangaDex)
        }
        let wanted = all.filter { $0.volume == focus }
        let others = all.filter { $0.volume != focus }
            .sorted { abs(($0.volume ?? .infinity) - focus) < abs(($1.volume ?? .infinity) - focus) }
            .prefix(nearby)
        return wanted + others
    }

    // MARK: AniList

    private static func aniListCandidates(title: String, isNovel: Bool) async -> [CoverCandidate] {
        let graphQL = """
        query ($search: String) { Page(perPage: 6) { media(search: $search, type: MANGA, sort: SEARCH_MATCH) {
          id format title { romaji english } coverImage { extraLarge large } startDate { year }
          staff(perPage: 3, sort: RELEVANCE) { edges { role node { name { full } } } } } } }
        """
        let body: [String: Any] = ["query": graphQL, "variables": ["search": title]]
        guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return [] }
        var request = request(URL(string: "https://graphql.anilist.co")!)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let data = await fetch(request, label: "anilist") else { return [] }
        return aniListCovers(from: data, isNovel: isNovel, query: title)
    }

    static func aniListCovers(from data: Data, isNovel: Bool, query: String? = nil) -> [CoverCandidate] {
        struct Response: Decodable {
            struct Payload: Decodable {
                struct Page: Decodable {
                    struct Media: Decodable {
                        struct Title: Decodable { let romaji: String?; let english: String? }
                        struct Cover: Decodable { let extraLarge: String?; let large: String? }
                        struct Start: Decodable { let year: Int? }
                        struct Staff: Decodable {
                            struct Edge: Decodable {
                                struct Node: Decodable { struct Name: Decodable { let full: String? }; let name: Name }
                                let role: String?
                                let node: Node
                            }
                            let edges: [Edge]
                        }
                        let id: Int
                        let format: String?
                        let title: Title
                        let coverImage: Cover
                        let startDate: Start?
                        let staff: Staff?
                    }
                    let media: [Media]
                }
                let page: Page
                enum CodingKeys: String, CodingKey { case page = "Page" }
            }
            let data: Payload?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), let page = response.data?.page else {
            Logger.cover.error("[covers] anilist: unreadable response (\(data.count)B)")
            return []
        }
        return page.media.compactMap { media in
            // AniList files light novels under MANGA with format NOVEL; keep to the right shelf.
            let titles = [media.title.english, media.title.romaji].compactMap { $0 }
            guard (media.format == "NOVEL") == isNovel,
                  query.map({ isRelevant(titles, to: $0) }) ?? true,
                  let full = media.coverImage.extraLarge.flatMap(URL.init(string:)),
                  let thumb = (media.coverImage.large ?? media.coverImage.extraLarge).flatMap(URL.init(string:))
            else { return nil }
            let author = media.staff?.edges.first { ($0.role ?? "").localizedCaseInsensitiveContains("story") }?.node.name.full
                ?? media.staff?.edges.first?.node.name.full
            let detail = [media.startDate?.year.map(String.init), author].compactMap { $0 }.joined(separator: " · ")
            return CoverCandidate(title: media.title.english ?? media.title.romaji ?? "AniList \(media.id)", volume: nil,
                                  detail: detail.nilIfEmpty, thumbnailURL: thumb, fullURL: full, source: .aniList,
                                  isSeriesCover: true)
        }
    }

    // MARK: Apple Books

    private static func appleBooksCandidates(title: String, volume: Double?, isNovel: Bool) async -> [CoverCandidate] {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        let term = volume.map { "\(title) Volume \(Formatting.number($0))" } ?? title
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "ebook"),
            URLQueryItem(name: "limit", value: "15"),
        ]
        guard let url = components.url, let data = await fetch(url, label: "apple books") else { return [] }
        return appleBooksCovers(from: data, isNovel: isNovel).filter { isRelevant([$0.title], to: title) }
    }

    static func appleBooksCovers(from data: Data, isNovel: Bool) -> [CoverCandidate] {
        struct Response: Decodable {
            struct Item: Decodable {
                let trackId: Int?
                let trackName: String?
                let artistName: String?
                let artworkUrl100: String?
                let genres: [String]?
            }
            let results: [Item]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            Logger.cover.error("[covers] apple books: unreadable response (\(data.count)B)")
            return []
        }
        return response.results.compactMap { item in
            let genres = item.genres ?? []
            // A manga search for "Berserk" also finds "Dragon Guard Berserkers", a paranormal
            // romance. Comics must be filed as comics; novels can be anything.
            if !isNovel, !genres.contains(where: { $0.contains("Manga") || $0.contains("Comics") }) { return nil }
            guard let art = item.artworkUrl100, let name = item.trackName,
                  let thumb = URL(string: art.replacingOccurrences(of: "100x100bb", with: "400x400bb")),
                  let full = URL(string: art.replacingOccurrences(of: "100x100bb", with: "1200x1200bb"))
            else { return nil }
            return CoverCandidate(title: name, volume: volumeNumber(in: name), detail: item.artistName,
                                  thumbnailURL: thumb, fullURL: full, source: .appleBooks)
        }
    }

    /// "Berserk Volume 41" → 41; "Solo Leveling, Vol. 3 (comic)" → 3.
    static func volumeNumber(in name: String) -> Double? {
        guard let match = name.range(of: #"(?i)\b(?:volume|vol\.?)\s*(\d{1,4}(?:\.\d+)?)"#, options: .regularExpression) else {
            return nil
        }
        let digits = name[match].drop { !$0.isNumber }
        return Double(digits)
    }

    // MARK: Relevance

    /// Whether any of a result's titles contains every word searched for — accents and case
    /// aside. Catalogs answer loosely ("Power Leveling" for "Solo Leveling"); a sequel that names
    /// the series ("Solo Leveling: Ragnarok") still counts.
    static func isRelevant(_ titles: [String], to query: String) -> Bool {
        func words(_ text: String) -> Set<String> {
            Set(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .normalizedForMatching.split(separator: " ").map(String.init))
        }
        let wanted = words(query)
        guard !wanted.isEmpty else { return true }
        return titles.contains { wanted.isSubset(of: words($0)) }
    }

    // MARK: Plumbing

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func fetch(_ url: URL, label: String) async -> Data? {
        await fetch(request(url), label: label)
    }

    /// A failed source is logged and skipped — the others still fill the picker.
    private static func fetch(_ request: URLRequest, label: String) async -> Data? {
        let sw = Stopwatch()
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                Logger.cover.error("[covers] \(label, privacy: .public) HTTP \(status) in \(sw.ms, format: .fixed(precision: 0))ms")
                return nil
            }
            Logger.cover.debug("[covers] \(label, privacy: .public) \(data.count)B in \(sw.ms, format: .fixed(precision: 0))ms")
            return data
        } catch {
            Logger.cover.error("[covers] \(label, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
