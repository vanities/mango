import Foundation

/// What a filename turned out to mean.
struct ParsedName: Equatable, Sendable {
    var series: String?
    var title: String
    var volume: Double?
    var chapter: Double?
    var year: Int?
    /// The bit after the number in "Series - c001 - Potion of Flight": an episode or volume
    /// title, kept separate so it never contaminates the series name.
    var subtitle: String?
    /// True when `volume` came from a bare trailing number ("Akira 001") rather than an explicit
    /// marker ("v01"). A bare number is a guess, and `parseGroup` may overrule it.
    var volumeIsInferred = false
}

/// Pulls series, volume, chapter and year out of the names comics actually ship with.
///
/// There is no metadata standard worth trusting here — ComicInfo.xml exists but most of a real
/// library won't have it — so the filename *is* the metadata. The patterns below come from how
/// scanlation groups and digital releases name things:
///
///     Berserk v01 (2003) (Digital) (LuCaZ).cbz
///     [Group] Oyasumi Punpun - c001 (v01) [Pub].cbz
///     Attack on Titan - Volume 34 [End].cbz
///     Chainsaw Man - Vol. 1 Ch. 1.cbz
///     Saga #045 (2018).cbz
///     Akira 001.cbz
///
/// The enclosing folder is the tiebreaker: a folder named after the series beats anything the
/// filename implies, because folder structure is what people actually keep tidy.
enum NameParser {
    static func parse(fileName: String, folderName: String? = nil) -> ParsedName {
        let base = (fileName as NSString).deletingPathExtension
        var working = base.replacingOccurrences(of: "_", with: " ")
        // "30v2", "c030v2": the release's second version, glued to the number. "4400h", "1080p":
        // the scan's resolution. Neither is a volume, a chapter or a title.
        working = working.replacingOccurrences(of: #"(?<=\d)v\d{1,2}\b"#, with: "", options: .regularExpression)
        working = working.replacingOccurrences(of: #"(?i)\b\d{3,5}(?:h|p|px)\b"#, with: " ", options: .regularExpression)

        let year = firstYear(in: working)

        // Volume and chapter come out before brackets are stripped, because "(v01)" is a real
        // and common way to write a volume number.
        var volume: Double?
        var chapter: Double?
        var volumeIsInferred = false
        // A range ("v01-02", "c00-02") is one token; its end would otherwise be left behind as a
        // stray "02" subtitle. The volume is where the range starts.
        (volume, working) = extract(pattern: #"(?:\b|(?<=[\-–\.\(\[]))(?:v|vol|volume)\.?\s*(\d{1,4}(?:\.\d+)?)(?:\s*[-–]\s*(?:v|vol|volume)?\.?\s*\d{1,4}(?:\.\d+)?)?\b"#, from: working)
        let chapterPattern = #"(?:\b|(?<=[\-–\.\(\[]))(?:c|ch|chap|chapter)\.?\s*(\d{1,5}(?:\.\d+)?)(\s*[-–]\s*(?:c|ch|chap|chapter)?\.?\s*\d{1,5}(?:\.\d+)?)?\b"#
        let chapterIsRange = firstMatch(pattern: chapterPattern, in: working, options: [.caseInsensitive])
            .map { $0.range(at: 2).location != NSNotFound } ?? false
        (chapter, working) = extract(pattern: chapterPattern, from: working)
        // "c00-02 (v01)": a run of chapters with its volume number is that volume.
        if chapterIsRange, volume != nil { chapter = nil }
        // A second "v2" once the volume is known is the release's version: "Volume 05 - v2".
        if volume != nil {
            working = working.replacingOccurrences(of: #"(?i)(?<![A-Za-z0-9])v\d{1,2}(?![\d.])"#, with: " ", options: .regularExpression)
        }
        if volume == nil {
            let (issue, rest) = extract(pattern: ##"#\s*(\d{1,5}(?:\.\d+)?)"##, from: working)
            if let issue { volume = issue; working = rest }
        }

        working = stripBracketed(working)
        let split = splitAroundRemovedTokens(working)
        var series = split.series
        var subtitle = split.subtitle

        // "Akira 001", "Solo Leveling 180 - Epilogue 01" — a bare number is a volume (a guess
        // `parseGroup` may overrule), and a title after it is the episode's.
        if volume == nil, chapter == nil, let bare = bareNumber(in: series) {
            volume = bare.number
            volumeIsInferred = true
            series = bare.series
            if subtitle == nil { subtitle = bare.title }
        }

        // A folder named for the series is more reliable than whatever the file is called —
        // but only when the file didn't already say something longer and more specific.
        // Folder names carry the same release junk filenames do — "Tower Dungeon (Digital)"
        // should shelve as "Tower Dungeon".
        let folder = folderName.map { tidy(stripLanguage(stripBracketed($0))) }.flatMap { $0.nilIfEmpty }
        if series.isEmpty, let folder { series = folder }
        // Same name, the folder's capitals: "the voynich hotel" → "The Voynich Hotel".
        if let folder, folder.normalizedForMatching == series.normalizedForMatching { series = folder }
        // "Mushoku Tensei - Jobless Reincarnation - A Journey of Two Lifetimes", unnumbered, in
        // that series' folder: a side story, on the series' shelf. Numbered files are left alone
        // — in a folder called "Frieren", "Frieren - Beyond Journey's End 138" is the series.
        if let folder, volume == nil, chapter == nil,
           series.count > folder.count + 3, series.lowercased().hasPrefix(folder.lowercased() + " - ") {
            let rest = tidy(String(series.dropFirst(folder.count + 3)))
            series = folder
            if subtitle == nil { subtitle = rest.nilIfEmpty }
        }
        if let folder, !series.isEmpty, folder.normalizedForMatching != series.normalizedForMatching,
           series.normalizedForMatching.count < folder.normalizedForMatching.count,
           folder.normalizedForMatching.contains(series.normalizedForMatching) {
            series = folder
        }

        let title = displayTitle(series: series, volume: volume, chapter: chapter, fallback: tidy(stripBracketed(base)))
        return ParsedName(series: series.nilIfEmpty, title: title, volume: volume, chapter: chapter,
                          year: year, subtitle: subtitle.flatMap(meaningfulSubtitle), volumeIsInferred: volumeIsInferred)
    }

    /// Parses a whole folder at once so siblings can correct each other.
    ///
    /// A bare number ("Tower Dungeon 027") reads as a volume on its own; the folder decides
    /// whether it's really a chapter:
    ///
    /// - Beside explicit volumes *and* chapters, a bare number past the last volume is a
    ///   chapter — Tower Dungeon ships `v01`…`v05`, `c020`…`c026`, then a bare `027`.
    /// - Beside explicit volumes alone, a bare number *far* past the last one is — how 1r0n and
    ///   LuCaZ ship ongoing series: `Chainsaw Man v21` next to `Chainsaw Man 199`. Just past it
    ///   ("011" after v10) is more likely a volume named inconsistently.
    /// - With no volumes at all, bare numbers are chapters in a folder of chapters, a webtoon, or
    ///   a run that reaches 100 — Solo Leveling is `000`…`200`. A short run ("Akira 001"…"006")
    ///   stays volumes.
    static func parseGroup(_ files: [(fileName: String, folderName: String?)]) -> [ParsedName] {
        var results = files.map { parse(fileName: $0.fileName, folderName: $0.folderName) }

        let bare = results.indices.filter { results[$0].volumeIsInferred && results[$0].chapter == nil && results[$0].volume != nil }
        guard !bare.isEmpty else { return results }
        let highestVolume = results.filter { !$0.volumeIsInferred }.compactMap(\.volume).max()
        let hasExplicitChapters = results.contains { $0.chapter != nil }
        let folderName = files.first?.folderName ?? ""
        let serialized = folderName.range(of: #"webtoon|manhwa|manhua"#, options: [.regularExpression, .caseInsensitive]) != nil
            || (bare.compactMap { results[$0].volume }.max() ?? 0) >= 100

        for index in bare {
            guard let number = results[index].volume else { continue }
            let isChapter: Bool
            if let highestVolume {
                isChapter = number > highestVolume
                    && (hasExplicitChapters || (number >= highestVolume * 2 && number > highestVolume + 5))
            } else {
                isChapter = hasExplicitChapters || serialized
            }
            guard isChapter else { continue }
            results[index].volume = nil
            results[index].chapter = number
            results[index].volumeIsInferred = false
            results[index].title = displayTitle(series: results[index].series ?? "", volume: nil,
                                                chapter: number, fallback: results[index].title)
        }
        return results
    }

    // MARK: Pieces

    /// A chapter number is the file's identity even with its volume beside it ("v01_ch03" is
    /// chapter 3); otherwise the volume.
    private static func displayTitle(series: String, volume: Double?, chapter: Double?, fallback: String) -> String {
        guard !series.isEmpty else { return fallback.nilIfEmpty ?? "Untitled" }
        if let chapter { return "\(series) Ch. \(Formatting.number(chapter))" }
        if let volume { return "\(series) Vol. \(Formatting.number(volume))" }
        return series
    }

    /// "Stone Ocean English" → "Stone Ocean": a language tag on a folder isn't part of the name.
    private static func stripLanguage(_ text: String) -> String {
        text.replacingOccurrences(of: #"(?i)\s+(?:english|eng)\s*$"#, with: "", options: .regularExpression)
    }

    /// "Akira 001" or "Solo Leveling 180 - Epilogue 01": a bare number after the series,
    /// perhaps with an episode title after it. Never a year ("Blade Runner 2049"), and never a
    /// part — "Part 4 - Diamond is Unbreakable" is a part of the series, not volume 4.
    private static func bareNumber(in text: String) -> (series: String, number: Double, title: String?)? {
        let patterns = [
            #"^(.*?)[\s\-–]+(\d{1,4}(?:\.\d+)?)\s+[-–]\s+(\S.*)$"#,
            #"^(.*?)[\s\-–]+(\d{1,4}(?:\.\d+)?)(?:\s*[-–]\s*\d{1,4})?$"#,
        ]
        for pattern in patterns {
            guard let match = firstMatch(pattern: pattern, in: text),
                  let prefix = match.group(1, in: text).map(tidy), !prefix.isEmpty,
                  let number = match.group(2, in: text).flatMap(Double.init)
            else { continue }
            if number >= 1900, number <= 2100, number == number.rounded() { continue }
            if prefix.range(of: #"\b(part|season|book|arc)$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                continue
            }
            return (prefix, number, match.group(3, in: text).map(tidy)?.nilIfEmpty)
        }
        return nil
    }

    /// Scan-quality tags aren't titles: "GTO Volume 01 HQ" has no subtitle.
    private static func meaningfulSubtitle(_ text: String) -> String? {
        let noise = #"^(?:HQ|LQ|HD|SD|Hi-?Res|High Quality|Digital|English|Eng)$"#
        return text.range(of: noise, options: [.regularExpression, .caseInsensitive]) == nil ? text.nilIfEmpty : nil
    }

    private static func firstYear(in text: String) -> Int? {
        guard let match = firstMatch(pattern: #"[\(\[]((?:19|20)\d{2})[\)\]]"#, in: text),
              let value = match.group(1, in: text).flatMap({ Int($0) })
        else { return nil }
        return value
    }

    /// Marks where a number token was removed, so a later pass can tell
    /// "Series - c001 - Episode Title" (a real split) from "Series v01 (2003)" (just trailing junk).
    private static let removedToken = "\u{0}"

    /// Returns the first captured number and the string with that match replaced by a sentinel.
    private static func extract(pattern: String, from text: String) -> (Double?, String) {
        guard let match = firstMatch(pattern: pattern, in: text, options: [.caseInsensitive]),
              let value = match.group(1, in: text).flatMap({ Double($0) })
        else { return (nil, text) }
        let out = (text as NSString).replacingCharacters(in: match.range, with: removedToken)
        return (value, out)
    }

    /// Splits on the sentinels left by `extract`: what comes before the first number is the
    /// series, anything after it is the episode or volume title. Nothing before the number
    /// ("Volume 01 - Enter Josuke Higashikata") means the filename doesn't name the series —
    /// the folder will — and the words after it are the title, not the series.
    private static func splitAroundRemovedTokens(_ text: String) -> (series: String, subtitle: String?) {
        let pieces = text.components(separatedBy: removedToken).map(tidy)
        guard let first = pieces.first else { return ("", nil) }
        let rest = pieces.dropFirst().filter { !$0.isEmpty }.joined(separator: " - ")
        return (first, rest.nilIfEmpty)
    }

    /// Drops `(...)`, `[...]` and `{...}` groups — release group, scan quality, publisher tags.
    private static func stripBracketed(_ text: String) -> String {
        var out = text
        for pattern in [#"\([^)]*\)"#, #"\[[^\]]*\]"#, #"\{[^}]*\}"#] {
            out = out.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return out
    }

    /// Collapses whitespace and shaves the separators a removed token left behind.
    private static func tidy(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        out = out.replacingOccurrences(of: removedToken, with: "")
        while let last = out.last, "-–—_.,:;".contains(last) || last == " " {
            out.removeLast()
            out = out.trimmingCharacters(in: .whitespaces)
        }
        while let first = out.first, "-–—_.,:;".contains(first) || first == " " {
            out.removeFirst()
            out = out.trimmingCharacters(in: .whitespaces)
        }
        return out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func firstMatch(pattern: String, in text: String,
                                   options: NSRegularExpression.Options = []) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }
}

private extension NSTextCheckingResult {
    func group(_ index: Int, in text: String) -> String? {
        guard index < numberOfRanges, let range = Range(range(at: index), in: text) else { return nil }
        return String(text[range])
    }
}
