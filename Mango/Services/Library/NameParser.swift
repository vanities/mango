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

        let year = firstYear(in: working)

        // Volume and chapter come out before brackets are stripped, because "(v01)" is a real
        // and common way to write a volume number.
        var volume: Double?
        var chapter: Double?
        var volumeIsInferred = false
        (volume, working) = extract(pattern: #"(?:\b|(?<=[\-–\.\(\[]))(?:v|vol|volume)\.?\s*(\d{1,4}(?:\.\d+)?)\b"#, from: working)
        (chapter, working) = extract(pattern: #"(?:\b|(?<=[\-–\.\(\[]))(?:c|ch|chap|chapter)\.?\s*(\d{1,5}(?:\.\d+)?)\b"#, from: working)
        if volume == nil {
            let (issue, rest) = extract(pattern: ##"#\s*(\d{1,5}(?:\.\d+)?)"##, from: working)
            if let issue { volume = issue; working = rest }
        }

        working = stripBracketed(working)
        let split = splitAroundRemovedTokens(working)
        var series = split.series
        let subtitle = split.subtitle

        // "Akira 001" — a bare trailing number is a volume, unless it's a year.
        if volume == nil, chapter == nil,
           let match = firstMatch(pattern: #"^(.*?)[\s\-–]+(\d{1,4}(?:\.\d+)?)$"#, in: series),
           let prefix = match.group(1, in: series), let number = match.group(2, in: series).flatMap(Double.init),
           !(number >= 1900 && number <= 2100 && number == number.rounded()),
           !prefix.trimmingCharacters(in: .whitespaces).isEmpty {
            volume = number
            volumeIsInferred = true
            series = tidy(prefix)
        }

        // A folder named for the series is more reliable than whatever the file is called —
        // but only when the file didn't already say something longer and more specific.
        // Folder names carry the same release junk filenames do — "Tower Dungeon (Digital)"
        // should shelve as "Tower Dungeon".
        let folder = folderName.map { tidy(stripBracketed($0)) }.flatMap { $0.nilIfEmpty }
        if series.isEmpty, let folder { series = folder }
        if let folder, !series.isEmpty, folder.normalizedForMatching != series.normalizedForMatching,
           series.normalizedForMatching.count < folder.normalizedForMatching.count,
           folder.normalizedForMatching.contains(series.normalizedForMatching) {
            series = folder
        }

        let title = displayTitle(series: series, volume: volume, chapter: chapter, fallback: tidy(stripBracketed(base)))
        return ParsedName(series: series.nilIfEmpty, title: title, volume: volume, chapter: chapter,
                          year: year, subtitle: subtitle, volumeIsInferred: volumeIsInferred)
    }

    /// Parses a whole folder at once so siblings can correct each other.
    ///
    /// Releases mix conventions inside one folder: Tower Dungeon ships `v01`…`v05` alongside
    /// `c020`…`c026` and then, from the same scanlator, a bare `027`. On its own `027` reads as
    /// volume 27; sitting next to five volumes and seven chapters it plainly isn't. The rule:
    /// when a folder has both explicit volumes and explicit chapters, a *bare* number higher
    /// than any real volume is a chapter.
    static func parseGroup(_ files: [(fileName: String, folderName: String?)]) -> [ParsedName] {
        var results = files.map { parse(fileName: $0.fileName, folderName: $0.folderName) }

        let explicitVolumes = results.filter { !$0.volumeIsInferred }.compactMap(\.volume)
        let hasExplicitChapters = results.contains { $0.chapter != nil }
        guard hasExplicitChapters, let highestVolume = explicitVolumes.max() else { return results }

        for index in results.indices {
            guard results[index].volumeIsInferred,
                  results[index].chapter == nil,
                  let number = results[index].volume,
                  number > highestVolume
            else { continue }
            results[index].volume = nil
            results[index].chapter = number
            results[index].volumeIsInferred = false
            results[index].title = displayTitle(series: results[index].series ?? "", volume: nil,
                                                chapter: number, fallback: results[index].title)
        }
        return results
    }

    // MARK: Pieces

    private static func displayTitle(series: String, volume: Double?, chapter: Double?, fallback: String) -> String {
        guard !series.isEmpty else { return fallback.nilIfEmpty ?? "Untitled" }
        if let volume { return "\(series) Vol. \(Formatting.number(volume))" }
        if let chapter { return "\(series) Ch. \(Formatting.number(chapter))" }
        return series
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

    /// Splits on the sentinels left by `extract`. The first non-empty piece is the series; a
    /// second non-empty piece is the episode or volume title.
    private static func splitAroundRemovedTokens(_ text: String) -> (series: String, subtitle: String?) {
        let pieces = text.components(separatedBy: removedToken).map(tidy).filter { !$0.isEmpty }
        guard let first = pieces.first else { return ("", nil) }
        let rest = pieces.dropFirst().joined(separator: " - ")
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
