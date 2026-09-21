import Foundation
import os

/// Finds a shelf's series on AniList, so a real name, author and year can go on it — only when
/// someone asks, and only the name is sent.
///
/// This is deliberately a lookup and not Apple Intelligence. Tested 2026-09-21 on real names,
/// the on-device model called "Part 5 - Vento Aureo" One Piece — twice, the second time when
/// told to use only what the file name says — and misread "Solo Leveling 180" as volume 180. A
/// database answers "JoJo's Bizarre Adventure Part 5: Golden Wind", Hirohiko Araki, 1995, and
/// the person picks the match, so a wrong one is never applied on its own.
enum SeriesLookup {
    struct Match: Identifiable, Hashable, Sendable {
        let id: Int
        /// The English title when there is one — it's what an English shelf should say.
        var title: String
        /// The romanized Japanese title, when it differs.
        var originalTitle: String?
        var year: Int?
        var author: String?
        var thumbnailURL: URL?
        var coverURL: URL?
    }

    static func search(_ name: String, isNovel: Bool) async -> [Match] {
        let sw = Stopwatch()
        var seen = Set<Int>()
        var matches: [Match] = []
        // AniList's search is strict about extra words: "Goodnight Punpun Omnibus" finds nothing
        // and "Goodnight Punpun" finds it. Try the name, then the name without edition words.
        for term in searchTerms(for: name) {
            guard let data = await fetch(term) else { continue }
            for match in parseMatches(from: data, isNovel: isNovel) where seen.insert(match.id).inserted {
                matches.append(match)
            }
            if !matches.isEmpty { break }
        }
        Logger.library.info("[lookup] \(matches.count) AniList match(es) for \"\(name, privacy: .public)\" in \(sw.ms, format: .fixed(precision: 0))ms")
        return matches
    }

    /// The name as shelved, then without edition and release words.
    static func searchTerms(for name: String) -> [String] {
        let edition = #"(?i)\b(omnibus|full colou?r|colou?red|master edition|perfect edition|deluxe edition|deluxe|kanzenban|complete edition|digital|black and white|b&w)\b"#
        let stripped = name.replacingOccurrences(of: edition, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–:"))
        let terms = [name.trimmingCharacters(in: .whitespaces), stripped]
        var seen = Set<String>()
        return terms.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    static func parseMatches(from data: Data, isNovel: Bool) -> [Match] {
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
                        let coverImage: Cover?
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
            Logger.library.error("[lookup] unreadable AniList response (\(data.count)B)")
            return []
        }
        return page.media.compactMap { media in
            guard (media.format == "NOVEL") == isNovel, let title = media.title.english ?? media.title.romaji else { return nil }
            let original = media.title.romaji.flatMap { $0 == title ? nil : $0 }
            let credits = media.staff?.edges.map { (role: $0.role, name: $0.node.name.full) } ?? []
            return Match(id: media.id, title: title, originalTitle: original, year: media.startDate?.year,
                         author: author(from: credits),
                         thumbnailURL: (media.coverImage?.large ?? media.coverImage?.extraLarge).flatMap(URL.init(string:)),
                         coverURL: media.coverImage?.extraLarge.flatMap(URL.init(string:)))
        }
    }

    /// The writer: a story or original-creator credit, else a story-and-art one, never a
    /// translator or letterer. (AniList lists "Story (chs 1-92)", "Art", "Translator" alike.)
    static func author(from credits: [(role: String?, name: String?)]) -> String? {
        let people = credits.compactMap { credit -> (role: String, name: String)? in
            guard let name = credit.name, !name.isEmpty else { return nil }
            return ((credit.role ?? "").lowercased(), name)
        }
        let excluded = ["translat", "letter", "touch", "assistant", "editor"]
        let eligible = people.filter { person in !excluded.contains { person.role.contains($0) } }
        return eligible.first { $0.role.contains("story") || $0.role.contains("original") }?.name
            ?? eligible.first { $0.role.contains("art") }?.name
    }

    private static func fetch(_ term: String) async -> Data? {
        let graphQL = """
        query ($search: String) { Page(perPage: 6) { media(search: $search, type: MANGA, sort: SEARCH_MATCH) {
          id format title { romaji english } coverImage { extraLarge large } startDate { year }
          staff(perPage: 6, sort: RELEVANCE) { edges { role node { name { full } } } } } } }
        """
        guard let body = try? JSONSerialization.data(withJSONObject: ["query": graphQL, "variables": ["search": term]]) else {
            return nil
        }
        var request = URLRequest(url: URL(string: "https://graphql.anilist.co")!, timeoutInterval: CoverSearch.timeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(CoverSearch.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                Logger.library.error("[lookup] AniList HTTP \(status) for \"\(term, privacy: .public)\"")
                return nil
            }
            return data
        } catch {
            Logger.library.error("[lookup] AniList failed for \"\(term, privacy: .public)\": \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
