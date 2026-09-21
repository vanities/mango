import SwiftUI
import WebKit

/// Renders one EPUB chapter, served straight out of the zip by `EPUBSchemeHandler`.
///
/// The book's own CSS is left alone — that's the typography the publisher shipped — and a
/// small stylesheet is layered over it for the things the reader controls: measure, margins,
/// body size, and the colours, so a light novel doesn't glare white in a dark room.
struct NovelWebView: UIViewRepresentable {
    let document: EPUBDocument
    let chapterPath: String
    var fontScale: Double
    var dark: Bool
    /// Where in the chapter to restore to, 0...1. Applied once per chapter load.
    var restoreFraction: Double
    var onScroll: (Double) -> Void
    var onTapMiddle: () -> Void
    var onReachedBottom: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(EPUBSchemeHandler(document: document), forURLScheme: EPUBSchemeHandler.scheme)
        configuration.suppressesIncrementalRendering = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.delegate = context.coordinator
        // .always, not .never: a comic page should run under the notch, but a line of prose
        // must not. The view itself still reaches the screen edges so the background is
        // full-bleed — only the text is inset.
        webView.scrollView.contentInsetAdjustmentBehavior = .always
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.allowsBackForwardNavigationGestures = false

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        webView.addGestureRecognizer(tap)

        context.coordinator.webView = webView
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loadedPath != chapterPath {
            context.coordinator.loadedPath = chapterPath
            context.coordinator.pendingRestore = restoreFraction
            guard let url = EPUBSchemeHandler.url(for: chapterPath) else { return }
            webView.load(URLRequest(url: url))
        } else if context.coordinator.appliedStyle != styleKey {
            context.coordinator.applyStyle()
        }
    }

    private var styleKey: String { "\(fontScale)-\(dark)" }

    /// Layered over the book's own stylesheet.
    var css: String {
        let background = dark ? "#000000" : "#ffffff"
        let text = dark ? "#e8e4dd" : "#16130f"
        return """
        :root { color-scheme: \(dark ? "dark" : "light"); }
        html { -webkit-text-size-adjust: none; }
        body {
          background: \(background) !important;
          color: \(text) !important;
          font-size: \(Int(fontScale * 100))% !important;
          line-height: 1.6 !important;
          margin: 0 auto !important;
          /* Extra top room so the first line clears the floating chrome while it's up,
             and bottom room so the last line isn't hidden behind the bottom capsule. */
          padding: 16px 22px 120px !important;
          max-width: 40em !important;
          text-rendering: optimizeLegibility;
          hyphens: auto;
        }
        p { orphans: 2; widows: 2; }
        /* Plates, colour galleries and cover pages are single full-page images; let them
           fill the screen instead of sitting small in the corner the publisher put them in. */
        img, svg {
          max-width: 100% !important;
          max-height: 100vh !important;
          height: auto !important;
          width: auto !important;
          display: block !important;
          margin: 0 auto !important;
        }
        svg { width: 100% !important; }
        a { color: \(dark ? "#f0a23c" : "#b45309") !important; }
        /* Publisher stylesheets often hard-code black on white. */
        * { background-color: transparent !important; }
        h1, h2, h3, h4, h5, h6, p, span, div, li, td { color: inherit !important; }
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: NovelWebView
        weak var webView: WKWebView?
        var loadedPath: String?
        var appliedStyle: String?
        var pendingRestore: Double = 0
        private var reportedBottom = false

        init(_ parent: NovelWebView) {
            self.parent = parent
        }

        func applyStyle() {
            guard let webView else { return }
            let escaped = parent.css
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
            let js = """
            (function() {
              var id = 'mango-style';
              var el = document.getElementById(id);
              if (!el) { el = document.createElement('style'); el.id = id; document.head.appendChild(el); }
              el.textContent = `\(escaped)`;
            })();
            """
            webView.evaluateJavaScript(js)
            appliedStyle = "\(parent.fontScale)-\(parent.dark)"
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            reportedBottom = false
            applyStyle()
            // Restore after layout settles, or the content height is still zero.
            let fraction = pendingRestore
            pendingRestore = 0
            guard fraction > 0.001 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak webView] in
                guard let scroll = webView?.scrollView else { return }
                let reachable = max(0, scroll.contentSize.height - scroll.bounds.height)
                scroll.setContentOffset(CGPoint(x: 0, y: reachable * fraction), animated: false)
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let reachable = max(1, scrollView.contentSize.height - scrollView.bounds.height)
            let fraction = min(1, max(0, scrollView.contentOffset.y / reachable))
            parent.onScroll(fraction)
            // A little slack: "close enough to the bottom" is what a reader means by finished.
            if fraction > 0.995, !reportedBottom {
                reportedBottom = true
                parent.onReachedBottom()
            }
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let x = recognizer.location(in: view).x
            let width = view.bounds.width
            // Middle half toggles the chrome; the edges are left to the page so links still work.
            if x > width * 0.25, x < width * 0.75 {
                parent.onTapMiddle()
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}
