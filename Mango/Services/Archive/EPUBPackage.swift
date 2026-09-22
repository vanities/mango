import Foundation
import os
import ShelfKit

/// One document in the reading order.
struct EPUBSpineItem: Sendable, Hashable, Identifiable {
    var id: String
    /// Path inside the zip, already resolved against the OPF's directory.
    var path: String
    var mediaType: String
    /// Label from the table of contents, when one points at this item.
    var title: String?
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

        Logger.archive.info("[epub] package: spine=\(package.spine.count) title=\(package.title ?? "?", privacy: .public) cover=\(package.coverPath != nil)")
        return package
    }

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
