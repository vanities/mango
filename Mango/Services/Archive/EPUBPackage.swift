import Foundation
import os
import ShelfKit

/// One document in the reading order.
struct EPUBSpineItem: Sendable, Hashable, Identifiable {
    var id: String
    /// Path inside the zip, already resolved against the OPF's directory.
    var path: String
    var mediaType: String
}

/// One entry in the book's own table of contents.
struct EPUBTOCEntry: Sendable, Hashable {
    var title: String
    /// Path inside the zip of the document it points into, without the fragment.
    var path: String
}

/// What the OPF package document told us about the book.
struct EPUBPackage: Sendable {
    var title: String?
    var creator: String?
    var language: String?
    /// Reading order.
    var spine: [EPUBSpineItem] = []
    /// Path inside the zip of the cover image, if the book declares one.
    var coverPath: String?
    /// Path inside the zip of the EPUB 3 navigation document — its table of contents — if any.
    var navPath: String?
    /// Path inside the zip of the EPUB 2 table of contents (the NCX), if any. EPUB 3 books often
    /// carry one too, for older readers.
    var ncxPath: String?
    /// Directory the OPF lives in — every href in it is relative to this.
    var opfDirectory: String = ""

    var isEmpty: Bool { spine.isEmpty }
}

enum EPUBError: LocalizedError {
    case noContainer
    case noRootfile
    case noSpine(String)

    var errorDescription: String? {
        switch self {
        case .noContainer: "This isn't an EPUB — META-INF/container.xml is missing."
        case .noRootfile: "The EPUB's container doesn't point at a package document."
        case .noSpine(let name): "\(name) has no readable chapters."
        }
    }
}

/// Reads an EPUB's structure: `META-INF/container.xml` points at the OPF package document,
/// and the OPF carries the metadata, the manifest of every file, and the spine — the order
/// the documents are meant to be read in.
///
/// Parsed with `XMLParser` rather than regex: these files are namespaced (`dc:title`), carry
/// entity escapes, and come from a dozen different toolchains.
enum EPUBParser {
    static func parseContainer(_ data: Data) throws -> String {
        let delegate = ContainerDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        guard let path = delegate.rootfile, !path.isEmpty else { throw EPUBError.noRootfile }
        return path
    }

    static func parsePackage(_ data: Data, opfPath: String) -> EPUBPackage {
        let delegate = PackageDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()

        let directory = (opfPath as NSString).deletingLastPathComponent
        var package = EPUBPackage()
        package.opfDirectory = directory
        package.title = delegate.title?.nilIfEmpty
        package.creator = delegate.creator?.nilIfEmpty
        package.language = delegate.language?.nilIfEmpty

        // Spine holds manifest ids; the manifest holds the hrefs.
        package.spine = delegate.spine.compactMap { idref in
            guard let item = delegate.manifest[idref] else { return nil }
            // Only documents are readable; a spine can reference other things.
            guard item.mediaType.contains("xhtml") || item.mediaType.contains("html") else { return nil }
            return EPUBSpineItem(id: idref, path: resolve(item.href, against: directory), mediaType: item.mediaType)
        }

        // EPUB 3 marks the cover with properties="cover-image"; EPUB 2 uses <meta name="cover">.
        if let item = delegate.manifest.values.first(where: { $0.properties.contains("cover-image") }) {
            package.coverPath = resolve(item.href, against: directory)
        } else if let id = delegate.coverMetaID, let item = delegate.manifest[id] {
            package.coverPath = resolve(item.href, against: directory)
        }

        // EPUB 3 marks its navigation document with properties="nav"; EPUB 2 names its NCX in
        // the spine's toc attribute, or it can only be found by its media type.
        if let item = delegate.manifest.values.first(where: { $0.properties.split(separator: " ").contains("nav") }) {
            package.navPath = resolve(item.href, against: directory)
        }
        if let id = delegate.spineTOC, let item = delegate.manifest[id] {
            package.ncxPath = resolve(item.href, against: directory)
        } else if let item = delegate.manifest.values.first(where: { $0.mediaType == "application/x-dtbncx+xml" }) {
            package.ncxPath = resolve(item.href, against: directory)
        }

        Logger.archive.info("[epub] package: spine=\(package.spine.count) title=\(package.title ?? "?", privacy: .public) cover=\(package.coverPath != nil)")
        return package
    }

    // MARK: Table of contents

    /// EPUB 2's table of contents: the NCX's navMap in reading order, nested points flattened.
    /// Its page list and other nav lists aren't chapters and are left out.
    static func parseNCX(_ data: Data, ncxPath: String) -> [EPUBTOCEntry] {
        let delegate = NCXDelegate()
        let parser = XMLParser(data: resolvingHTMLEntities(data))
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        let directory = (ncxPath as NSString).deletingLastPathComponent
        return delegate.points.map { EPUBTOCEntry(title: $0.title, path: resolve($0.src, against: directory)) }
    }

    /// EPUB 3's: the links in the navigation document's `<nav epub:type="toc">` — or in its
    /// first nav, for a book that doesn't say which is which — nested lists flattened.
    static func parseNav(_ data: Data, navPath: String) -> [EPUBTOCEntry] {
        let delegate = NavDelegate()
        let parser = XMLParser(data: resolvingHTMLEntities(data))
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        let directory = (navPath as NSString).deletingLastPathComponent
        let links = delegate.toc.isEmpty ? delegate.firstNav : delegate.toc
        return links.map { EPUBTOCEntry(title: $0.title, path: resolve($0.href, against: directory)) }
    }

    /// The table of contents' name for each document in the reading order — nil where it has
    /// none (the second half of a split chapter, an illustration page). The first entry that
    /// points into a document names it.
    static func chapterTitles(spine: [EPUBSpineItem], toc: [EPUBTOCEntry]) -> [String?] {
        var names: [String: String] = [:]
        for entry in toc where names[entry.path] == nil { names[entry.path] = entry.title }
        return spine.map { names[$0.path] }
    }

    /// A label as the reader should see it: whitespace (line breaks, indentation, no-break
    /// spaces) collapsed to single spaces.
    static func label(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Navigation documents are XHTML and some use HTML's named entities (`&nbsp;`, `&rsquo;`),
    /// which XMLParser stops at: without the DTD they're undefined, and the rest of the table of
    /// contents would be lost. The common ones become their characters and any other is dropped;
    /// XML's own five are left for the parser.
    static func resolvingHTMLEntities(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8), text.contains("&"),
              let pattern = try? NSRegularExpression(pattern: "&([A-Za-z][A-Za-z0-9]*);") else { return data }
        var result = ""
        var last = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let whole = Range(match.range, in: text), let name = Range(match.range(at: 1), in: text) else { continue }
            result += text[last..<whole.lowerBound]
            let entity = String(text[name])
            result += xmlEntities.contains(entity) ? String(text[whole]) : (htmlEntities[entity] ?? "")
            last = whole.upperBound
        }
        result += text[last...]
        return Data(result.utf8)
    }

    private static let xmlEntities: Set<String> = ["amp", "lt", "gt", "quot", "apos"]

    private static let htmlEntities: [String: String] = [
        "nbsp": "\u{00A0}", "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}", "zwnj": "", "zwj": "",
        "ndash": "–", "mdash": "—", "hellip": "…", "middot": "·", "bull": "•",
        "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "ldquo": "“", "rdquo": "”", "bdquo": "„",
        "laquo": "«", "raquo": "»", "lsaquo": "‹", "rsaquo": "›", "prime": "′", "Prime": "″",
        "copy": "©", "reg": "®", "trade": "™", "deg": "°", "times": "×", "sect": "§", "para": "¶",
        "dagger": "†", "Dagger": "‡", "iexcl": "¡", "iquest": "¿", "frac12": "½", "frac14": "¼", "frac34": "¾",
        "aacute": "á", "agrave": "à", "acirc": "â", "auml": "ä", "aring": "å", "aelig": "æ", "ccedil": "ç",
        "eacute": "é", "egrave": "è", "ecirc": "ê", "euml": "ë", "iacute": "í", "icirc": "î", "iuml": "ï",
        "ntilde": "ñ", "oacute": "ó", "ocirc": "ô", "ouml": "ö", "oslash": "ø", "uacute": "ú", "ucirc": "û",
        "uuml": "ü", "szlig": "ß", "Eacute": "É", "Uuml": "Ü", "Ouml": "Ö", "Auml": "Ä",
    ]

    /// Joins an href to the OPF's directory, collapsing `..` and percent-decoding — zip entry
    /// names are raw, but hrefs are URL-escaped.
    static func resolve(_ href: String, against directory: String) -> String {
        let decoded = href.removingPercentEncoding ?? href
        let cleaned = decoded.components(separatedBy: "#").first ?? decoded
        var parts = directory.isEmpty ? [] : directory.components(separatedBy: "/")
        for component in cleaned.components(separatedBy: "/") {
            switch component {
            case "", ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(component)
            }
        }
        return parts.joined(separator: "/")
    }
}

// MARK: - Delegates

private final class ContainerDelegate: NSObject, XMLParserDelegate {
    var rootfile: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        guard elementName == "rootfile", rootfile == nil else { return }
        rootfile = attributes["full-path"]
    }
}

private final class PackageDelegate: NSObject, XMLParserDelegate {
    struct ManifestItem {
        var href: String
        var mediaType: String
        var properties: String
    }

    var title: String?
    var creator: String?
    var language: String?
    var manifest: [String: ManifestItem] = [:]
    var spine: [String] = []
    /// The manifest id of the NCX, from the spine's toc attribute (EPUB 2).
    var spineTOC: String?
    var coverMetaID: String?

    private var collecting: String?
    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        switch elementName {
        case "item":
            if let id = attributes["id"], let href = attributes["href"] {
                manifest[id] = ManifestItem(href: href,
                                            mediaType: attributes["media-type"] ?? "",
                                            properties: attributes["properties"] ?? "")
            }
        case "spine":
            spineTOC = attributes["toc"]
        case "itemref":
            // linear="no" marks things like ads and colophons that aren't part of the read.
            if let idref = attributes["idref"], attributes["linear"]?.lowercased() != "no" {
                spine.append(idref)
            }
        case "meta":
            if attributes["name"]?.lowercased() == "cover" { coverMetaID = attributes["content"] }
        case "title", "creator", "language":
            collecting = elementName
            buffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard collecting != nil else { return }
        buffer += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        guard collecting == elementName else { return }
        let value = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        // First one wins: some books repeat dc:title for subtitles and collections.
        case "title": if title == nil { title = value }
        case "creator": if creator == nil { creator = value }
        case "language": if language == nil { language = value }
        default: break
        }
        collecting = nil
        buffer = ""
    }
}

/// The NCX's navPoints in document order: each point's first label and where it points.
private final class NCXDelegate: NSObject, XMLParserDelegate {
    var points: [(title: String, src: String)] = []
    private var inNavMap = false
    /// One slot per open navPoint, holding its label once read.
    private var labels: [String?] = []
    private var inLabel = false
    private var collecting = false
    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        switch elementName {
        case "navMap":
            inNavMap = true
        case "navPoint" where inNavMap:
            labels.append(nil)
        case "navLabel" where inNavMap:
            inLabel = true
        case "text" where inLabel:
            collecting = true
            buffer = ""
        case "content" where inNavMap:
            guard let src = attributes["src"], let title = labels.last.flatMap({ $0 }), !title.isEmpty else { return }
            points.append((title, src))
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collecting { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch elementName {
        case "text" where collecting:
            collecting = false
            // A point can carry a label per language; the first one names it.
            if let last = labels.indices.last, labels[last] == nil { labels[last] = EPUBParser.label(buffer) }
        case "navLabel":
            inLabel = false
        case "navPoint" where inNavMap:
            if !labels.isEmpty { labels.removeLast() }
        case "navMap":
            inNavMap = false
        default:
            break
        }
    }
}

/// The links in an EPUB 3 navigation document: those in the table of contents, and those in
/// its first nav for a book that doesn't mark which nav that is. Landmarks and page lists are
/// other navs, so they're left out once the table of contents is marked.
private final class NavDelegate: NSObject, XMLParserDelegate {
    var toc: [(title: String, href: String)] = []
    var firstNav: [(title: String, href: String)] = []
    private var navDepth = 0
    private var navCount = 0
    private var inTOC = false
    private var href: String?
    private var buffer = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        switch elementName {
        case "nav":
            navDepth += 1
            if navDepth == 1 {
                navCount += 1
                inTOC = Self.isTableOfContents(attributes)
            }
        case "a" where navDepth > 0:
            href = attributes["href"]
            buffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if href != nil { buffer += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        switch elementName {
        case "a" where navDepth > 0:
            defer { href = nil }
            guard let href else { return }
            let title = EPUBParser.label(buffer)
            guard !title.isEmpty else { return }
            if inTOC { toc.append((title, href)) }
            if navCount == 1 { firstNav.append((title, href)) }
        case "nav":
            navDepth = max(0, navDepth - 1)
            if navDepth == 0 { inTOC = false }
        default:
            break
        }
    }

    /// `epub:type="toc"`, or the ARIA role some books use instead. Keys are matched by their
    /// local name: how XMLParser spells a prefixed attribute depends on namespace processing.
    static func isTableOfContents(_ attributes: [String: String]) -> Bool {
        attributes.contains { key, value in
            let name = key.split(separator: ":").last.map(String.init) ?? key
            let tokens = value.split(separator: " ")
            return (name == "type" && tokens.contains("toc")) || (name == "role" && tokens.contains("doc-toc"))
        }
    }
}
