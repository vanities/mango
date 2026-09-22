import Foundation
import UniformTypeIdentifiers
import WebKit
import os

/// Serves an EPUB's own files to a `WKWebView` straight out of the zip.
///
/// The alternative is unpacking the book to a temp directory so relative hrefs resolve, which
/// would mean writing a whole copy of the user's book to disk — exactly what Mango promises not
/// to do — and downloading all of it from the NAS before page one. This way a chapter's images
/// and stylesheets are fetched individually, on demand, as ranged reads.
final class EPUBSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "mango-epub"
    private static let host = "book"

    private let document: EPUBDocument
    private let tasks = OSAllocatedUnfairLock(initialState: Set<ObjectIdentifier>())

    init(document: EPUBDocument) {
        self.document = document
    }

    /// `mango-epub://book/OEBPS/Text/section-0005.html`
    static func url(for path: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = path.hasPrefix("/") ? path : "/" + path
        return components.url
    }

    static func path(from url: URL) -> String {
        let raw = url.path
        let trimmed = raw.hasPrefix("/") ? String(raw.dropFirst()) : raw
        return trimmed.removingPercentEncoding ?? trimmed
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let key = ObjectIdentifier(urlSchemeTask)
        tasks.withLock { _ = $0.insert(key) }
        let path = Self.path(from: url)

        Task { [document, tasks] in
            let data = await document.data(at: path)
            // The web view may have moved on; finishing a stopped task crashes WebKit.
            guard tasks.withLock({ $0.contains(key) }) else { return }
            guard let data else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                tasks.withLock { _ = $0.remove(key) }
                return
            }
            let response = URLResponse(url: url, mimeType: Self.mimeType(for: path),
                                       expectedContentLength: data.count, textEncodingName: "utf-8")
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
            tasks.withLock { _ = $0.remove(key) }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)   // only the id crosses into the lock
        tasks.withLock { _ = $0.remove(key) }
    }

    private static func mimeType(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "html", "xhtml", "htm": return "application/xhtml+xml"
        case "css": return "text/css"
        case "js": return "text/javascript"
        case "svg": return "image/svg+xml"
        case "ncx", "opf", "xml": return "application/xml"
        default:
            if let type = UTType(filenameExtension: ext)?.preferredMIMEType { return type }
            return "application/octet-stream"
        }
    }
}
