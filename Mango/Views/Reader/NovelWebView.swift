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
    var paged: Bool
    var tapToTurn: Bool
    var fontFamily: String
    var lineSpacing: Double
    var margin: Double
    /// Where in the chapter to restore to, 0...1. Applied once per chapter load.
    var restoreFraction: Double
    var onScroll: (Double) -> Void
    var onTapMiddle: () -> Void
    var onNextChapter: () -> Void
    var onPreviousChapter: () -> Void
    var onReachedBottom: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(EPUBSchemeHandler(document: document), forURLScheme: EPUBSchemeHandler.scheme)
        configuration.suppressesIncrementalRendering = false
        configuration.userContentController.add(context.coordinator, name: "mangoNavigation")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.delegate = context.coordinator
        // .always, not .never: a comic page should run under the notch, but a line of prose
        // must not. The view itself still reaches the screen edges so the background is
        // full-bleed — only the text is inset.
        webView.scrollView.contentInsetAdjustmentBehavior = paged ? .never : .always
        webView.scrollView.isScrollEnabled = !paged
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.allowsBackForwardNavigationGestures = false

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        if !paged { webView.addGestureRecognizer(tap) }

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

    private var styleKey: String { "\(fontScale)-\(dark)-\(fontFamily)-\(lineSpacing)-\(margin)-\(tapToTurn)" }

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
          line-height: \(lineSpacing) !important;
          margin: 0 auto !important;
          /* Extra top room so the first line clears the floating chrome while it's up,
             and bottom room so the last line isn't hidden behind the bottom capsule. */
          padding: 16px \(margin)px 120px !important;
          max-width: 40em !important;
          text-rendering: optimizeLegibility;
          hyphens: auto;
        }
        \(paged ? paginationCSS : "")
        \(fontFamily.isEmpty ? "" : "body, p, span, div, li, td { font-family: \(fontFamily) !important; }")
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

    private var paginationCSS: String {
        """
        html { overflow: hidden !important; height: 100% !important; }
        body {
          box-sizing: border-box !important;
          width: 100vw !important; max-width: none !important; height: 100vh !important;
          padding: 64px \(margin)px !important; margin: 0 !important;
          column-width: calc(100vw - \(margin * 2)px) !important;
          column-gap: \(margin * 2)px !important; column-fill: auto !important;
          overflow: visible !important;
        }
        img, svg { max-height: calc(100vh - 128px) !important; break-inside: avoid; }
        """
    }

    /// Keep pagination in the document's CSS coordinates. Native scroll offsets vary with the
    /// EPUB viewport; using the same coordinate space for layout and turns avoids drift.
    var paginationScript: String {
        """
        (() => {
          const send = (action, fraction) => window.webkit.messageHandlers.mangoNavigation.postMessage({action, fraction});
          if (window.mangoPager) {
            window.mangoPager.tapEnabled = \(tapToTurn);
            window.mangoPager.layout();
            return;
          }
          const pager = { page: 0, count: 1, fraction: \(restoreFraction), tapEnabled: \(tapToTurn) };
          window.mangoPager = pager;
          const selected = () => !!window.getSelection()?.toString();
          const interactive = target => target?.closest?.('a, button, input, textarea, select, [contenteditable]');
          const show = () => {
            window.scrollTo(pager.page * window.innerWidth, 0);
            pager.fraction = pager.count > 1 ? pager.page / (pager.count - 1) : 0;
            send('progress', pager.fraction);
          };
          pager.layout = () => {
            {
              pager.count = Math.max(1, Math.round(Math.max(document.body.scrollWidth, document.documentElement.scrollWidth) / window.innerWidth));
              pager.page = Math.min(pager.count - 1, Math.round(pager.fraction * (pager.count - 1)));
              show();
            }
          };
          const turn = delta => {
            if (selected()) return;
            const next = pager.page + delta;
            if (next < 0) send('previous');
            else if (next >= pager.count) send('next');
            else { pager.page = next; show(); }
          };
          let start = null, swiped = false;
          document.addEventListener('touchstart', event => {
            swiped = false;
            start = event.touches.length === 1 && !interactive(event.target)
              ? { x: event.touches[0].clientX, y: event.touches[0].clientY, time: Date.now() } : null;
          }, {passive: true});
          document.addEventListener('touchend', event => {
            if (!start || selected()) return;
            const end = event.changedTouches[0];
            const dx = end.clientX - start.x, dy = end.clientY - start.y;
            if (Math.abs(dx) > 50 && Math.abs(dx) > Math.abs(dy) * 1.5 && Date.now() - start.time < 1000) {
              swiped = true; turn(dx < 0 ? 1 : -1);
            }
            start = null;
          }, {passive: true});
          document.addEventListener('click', event => {
            if (swiped) { swiped = false; return; }
            if (interactive(event.target) || selected() || event.detail > 1) return;
            const x = event.clientX / window.innerWidth;
            if (pager.tapEnabled && x <= 0.25) turn(-1);
            else if (pager.tapEnabled && x >= 0.75) turn(1);
            else send('controls');
          });
          document.addEventListener('keydown', event => {
            if (interactive(event.target) || selected()) return;
            if (event.key === 'ArrowRight' || event.key === ' ') { event.preventDefault(); turn(1); }
            if (event.key === 'ArrowLeft') { event.preventDefault(); turn(-1); }
          });
          window.addEventListener('resize', pager.layout);
          document.querySelectorAll('img').forEach(img => img.addEventListener('load', pager.layout));
          document.fonts.ready.then(pager.layout);
          pager.layout();
        })();
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate, UIGestureRecognizerDelegate, WKScriptMessageHandler {
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
              var viewport = document.querySelector('meta[name="viewport"]');
              if (!viewport) { viewport = document.createElement('meta'); viewport.name = 'viewport'; document.head.appendChild(viewport); }
              viewport.content = 'width=device-width, initial-scale=1.0';
              var id = 'mango-style';
              var el = document.getElementById(id);
              if (!el) { el = document.createElement('style'); el.id = id; document.head.appendChild(el); }
              el.textContent = `\(escaped)`;
            })();
            """
            webView.evaluateJavaScript(js) { [weak self] _, _ in
                guard let self, self.parent.paged else { return }
                webView.evaluateJavaScript(self.parent.paginationScript)
            }
            appliedStyle = parent.styleKey
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            reportedBottom = false
            applyStyle()
            if parent.paged { return }
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
            guard !parent.paged else { return }
            let reachable = max(1, scrollView.contentSize.height - scrollView.bounds.height)
            let fraction = min(1, max(0, scrollView.contentOffset.y / reachable))
            parent.onScroll(fraction)
            // A little slack: "close enough to the bottom" is what a reader means by finished.
            if fraction > 0.995, !reportedBottom {
                reportedBottom = true
                parent.onReachedBottom()
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
            switch action {
            case "progress":
                if let fraction = body["fraction"] as? Double { parent.onScroll(fraction) }
            case "next": parent.onNextChapter()
            case "previous": parent.onPreviousChapter()
            case "controls": parent.onTapMiddle()
            default: break
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
