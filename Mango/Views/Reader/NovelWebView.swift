import SwiftUI
import WebKit
import os

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
    var highlights: [NovelTextAnchor] = []
    var jumpAnchor: NovelTextAnchor?
    var findRequest: Int = 0
    var onSelection: (NovelTextAnchor) -> Void = { _ in }
    var onScroll: (Double) -> Void
    var onTapMiddle: () -> Void
    var onNextChapter: () -> Void
    var onPreviousChapter: () -> Void
    var onReachedBottom: () -> Void
    /// A link to another document in the book, by its path in the zip.
    var onOpenChapter: (String) -> Void = { _ in }
    /// A link out of the book. Opened in the browser, never in the reader.
    var onOpenExternal: @MainActor (URL) -> Void = { UIApplication.shared.open($0) }

    /// Where a link in a chapter leads.
    enum LinkTarget: Equatable {
        /// This chapter; with a fragment, an anchor in it.
        case sameChapter(fragment: String?)
        /// Another document in the book, by its path in the zip.
        case chapter(String)
        /// Anything outside the book.
        case external(URL)
    }

    nonisolated static func linkTarget(_ url: URL, chapterPath: String) -> LinkTarget {
        guard url.scheme == EPUBSchemeHandler.scheme else { return .external(url) }
        let path = EPUBSchemeHandler.path(from: url)
        let fragment = url.fragment(percentEncoded: false).flatMap { $0.isEmpty ? nil : $0 }
        return path == chapterPath ? .sameChapter(fragment: fragment) : .chapter(path)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(EPUBSchemeHandler(document: document), forURLScheme: EPUBSchemeHandler.scheme)
        configuration.suppressesIncrementalRendering = false
        configuration.userContentController.add(context.coordinator, name: "mangoNavigation")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isFindInteractionEnabled = true
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
        if context.coordinator.lastFindRequest != findRequest {
            context.coordinator.lastFindRequest = findRequest
            webView.findInteraction?.presentFindNavigator(showingReplace: false)
        }
        if context.coordinator.lastHighlights != highlights {
            context.coordinator.paintHighlights()
        }
        if context.coordinator.loadedPath != chapterPath {
            context.coordinator.loadedPath = chapterPath
            context.coordinator.pendingRestore = Self.clamped(restoreFraction)
            context.coordinator.chapterLoaded = false
            guard let url = EPUBSchemeHandler.url(for: chapterPath) else { return }
            webView.load(URLRequest(url: url))
        } else if context.coordinator.chapterLoaded, context.coordinator.appliedStyle != styleKey {
            // Until the chapter has loaded, the web view holds an empty placeholder page:
            // styling it would start a pager there, which finds one page and reports the
            // start of the chapter as the reader's place. didFinish applies the style.
            context.coordinator.applyStyle()
        }
    }

    private var styleKey: String { "\(fontScale)-\(dark)-\(fontFamily)-\(lineSpacing)-\(margin)-\(tapToTurn)" }

    /// A position as the pager and the engine take it: 0...1, never NaN (which would also
    /// read as an undefined `nan` once written into the script).
    static func clamped(_ fraction: Double) -> Double {
        fraction.isFinite ? min(1, max(0, fraction)) : 0
    }

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
        /* Page limits must follow the general image rules: an illustration taller than a
           column gets fragmented by WebKit, even with break-inside: avoid. */
        \(paged ? paginationCSS : "")
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
        /* A final paragraph's margin can overflow into an otherwise empty column. */
        body > :last-child { margin-bottom: 0 !important; }
        """
    }

    /// Keep pagination in the document's CSS coordinates. Native scroll offsets vary with the
    /// EPUB viewport; using the same coordinate space for layout and turns avoids drift.
    ///
    /// `fraction` is the reader's place in the chapter: it starts at `startFraction` and only a
    /// turn or a jump changes it. Layout runs several times while a chapter settles (fonts,
    /// images, a resize), and a pass can measure fewer pages than there are; deriving the
    /// place from that pass would send the reader back towards the start.
    ///
    /// A page is the body, which `paginationCSS` makes one viewport wide with columns at that
    /// pitch — never `window.innerWidth`. That's the *visual* viewport, which iOS updates from
    /// the UI process after a viewport change: just after the reader's styles go in it can
    /// still read WebKit's 980 px default page while every column is already the phone's
    /// 402, and WebKit sends no resize event when it settles. A count measured then stuck at
    /// 9 pages of a 21-page chapter, and tap-to-turn left the chapter less than halfway in.
    func paginationScript(startingAt startFraction: Double) -> String {
        """
        (() => {
          const send = (action, fraction) => window.webkit.messageHandlers.mangoNavigation.postMessage({action, fraction});
          if (window.mangoPager) {
            window.mangoPager.tapEnabled = \(tapToTurn);
            window.mangoPager.layout();
            return;
          }
          const pager = { page: 0, count: 1, fraction: \(Self.clamped(startFraction)), tapEnabled: \(tapToTurn) };
          window.mangoPager = pager;
          pager.width = () => document.body.getBoundingClientRect().width;
          const selected = () => !!window.getSelection()?.toString();
          const interactive = target => target?.closest?.('a, button, input, textarea, select, [contenteditable]');
          const show = () => {
            window.scrollTo(pager.page * pager.width(), 0);
            send('progress', pager.count > 1 ? pager.page / (pager.count - 1) : pager.fraction);
          };
          const measure = () => {
            const width = pager.width(), scrolled = window.scrollX;
            // Measure fresh so a smaller font or wider viewport can reduce the page count.
            document.documentElement.style.width = '100%';
            pager.count = Math.max(1, Math.round(Math.max(document.body.scrollWidth, document.documentElement.scrollWidth) / width));
            // Column overflow omits the final right padding. Reserve a whole last page or
            // WebKit clamps its scroll offset and shifts the text after the tap completes.
            document.documentElement.style.width = (pager.count * width) + 'px';
            // Measuring shrank the document, which clamps a scroll on the last page; undo that.
            if (window.scrollX !== scrolled) window.scrollTo(scrolled, 0);
          };
          pager.layout = () => {
            // A view being resized or snapshotted can be zero wide for a moment.
            if (pager.width() < 1) return;
            measure();
            pager.page = Math.min(pager.count - 1, Math.round(pager.fraction * (pager.count - 1)));
            show();
          };
          // A link to an anchor in this chapter: turn to the page it's on.
          pager.showElement = id => {
            const target = document.getElementById(id) || document.getElementsByName(id)[0];
            if (!target || pager.width() < 1) return false;
            const left = target.getBoundingClientRect().left + window.scrollX;
            pager.page = Math.max(0, Math.min(pager.count - 1, Math.floor(left / pager.width())));
            pager.fraction = pager.count > 1 ? pager.page / (pager.count - 1) : 0;
            show();
            return true;
          };
          const turn = delta => {
            if (selected()) return;
            // Leaving the chapter is the turn that skips whatever the count missed, so it's
            // never decided on a count that may have gone stale since it was measured.
            if (pager.page + delta >= pager.count && pager.width() >= 1) measure();
            const next = pager.page + delta;
            if (next < 0) send('previous');
            else if (next >= pager.count) send('next');
            else { pager.page = next; pager.fraction = pager.count > 1 ? next / (pager.count - 1) : 0; show(); }
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
            const x = event.clientX / pager.width();
            if (pager.tapEnabled && x <= 0.25) turn(-1);
            else if (pager.tapEnabled && x >= 0.75) turn(1);
            else send('controls');
          });
          document.addEventListener('keydown', event => {
            if (interactive(event.target) || selected()) return;
            if (event.key === 'ArrowRight' || event.key === ' ') { event.preventDefault(); turn(1); }
            if (event.key === 'ArrowLeft') { event.preventDefault(); turn(-1); }
          });
          // Lay out again whenever the pages or the text can have changed. The body is sized by
          // the viewport, so it resizing is the pages resizing — including the viewport tag
          // taking effect, which fires no window resize. The visual viewport settling can have
          // clamped a scroll made while it read too wide; not while the reader is zoomed in.
          window.addEventListener('resize', pager.layout);
          new ResizeObserver(() => pager.layout()).observe(document.body);
          window.visualViewport?.addEventListener('resize', () => {
            if (Math.abs(window.visualViewport.scale - 1) < 0.01) pager.layout();
          });
          // Captured at the document, so any image that loads late re-lays out — an SVG <image>
          // or one added later, not only the <img>s there when the pager started.
          document.addEventListener('load', () => pager.layout(), true);
          document.fonts.addEventListener?.('loadingdone', () => pager.layout());
          document.fonts.ready.then(() => pager.layout());
          pager.layout();
        })();
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate, UIGestureRecognizerDelegate, WKScriptMessageHandler {
        var parent: NovelWebView
        weak var webView: WKWebView?
        var loadedPath: String?
        var appliedStyle: String?
        /// Where the chapter opens if it's (re)loaded now: the restore point at first, then the
        /// place the pager last reported, so a reload after WebKit's process is killed while
        /// in the background comes back to the same page.
        var pendingRestore: Double = 0
        /// False while the web view still holds the page before this chapter.
        var chapterLoaded = false
        private var reportedBottom = false
        var lastFindRequest = 0
        var lastHighlights: [NovelTextAnchor] = []

        func paintHighlights() {
            guard let data = try? JSONEncoder().encode(parent.highlights), let json = String(data: data, encoding: .utf8) else { return }
            webView?.evaluateJavaScript("window.mangoText?.paint(\(json))")
            lastHighlights = parent.highlights
        }

        func prepareTextTools() {
            guard let webView else { return }
            webView.evaluateJavaScript(NovelTextScript.source) { [weak self] _, _ in
                guard let self else { return }
                self.paintHighlights()
                if let anchor = self.parent.jumpAnchor,
                   let data = try? JSONEncoder().encode(anchor), let json = String(data: data, encoding: .utf8) {
                    webView.evaluateJavaScript("document.fonts.ready.then(() => window.mangoText.jump(\(json)))")
                }
            }
        }

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
                guard let self else { return }
                if self.parent.paged {
                    webView.evaluateJavaScript(self.parent.paginationScript(startingAt: self.pendingRestore)) { [weak self] _, _ in self?.prepareTextTools() }
                } else { self.prepareTextTools() }
            }
            appliedStyle = parent.styleKey
        }

        /// Links in a chapter never navigate this view. Left to WebKit, the book's own contents
        /// page replaced the chapter on screen while the reader still counted the contents page
        /// as the place — saving progress against it, and "next chapter" leading back into the
        /// book — and a web link loaded the site inside the reader, with no way back.
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            switch NovelWebView.linkTarget(url, chapterPath: parent.chapterPath) {
            case .sameChapter(let fragment?) where parent.paged:
                // Scrolling follows an anchor by itself; a page has to be turned to it.
                decisionHandler(.cancel)
                guard let data = try? JSONEncoder().encode(fragment), let id = String(data: data, encoding: .utf8) else { return }
                Logger.reader.info("[novel:link] anchor in this chapter, turning to its page")
                webView.evaluateJavaScript("window.mangoPager?.showElement(\(id))")
            case .sameChapter(let fragment):
                decisionHandler(fragment == nil ? .cancel : .allow)
            case .chapter(let path):
                decisionHandler(.cancel)
                Logger.reader.info("[novel:link] to \(path, privacy: .public) from \(self.parent.chapterPath, privacy: .public)")
                parent.onOpenChapter(path)
            case .external(let target):
                decisionHandler(.cancel)
                Logger.reader.info("[novel:link] out of the book to \(target.host() ?? target.scheme ?? "?", privacy: .public), opening in the browser")
                parent.onOpenExternal(target)
            }
        }

        /// Also covers WebKit reloading the chapter itself after its process was killed.
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            chapterLoaded = false
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            reportedBottom = false
            chapterLoaded = true
            applyStyle()
            if parent.paged { return }
            // Restore after layout settles, or the content height is still zero.
            let fraction = pendingRestore
            pendingRestore = 0
            guard fraction > 0.001, parent.jumpAnchor == nil else { return }
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
            // Only the book's own pages speak for the reader's place — never a placeholder.
            guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.scheme == EPUBSchemeHandler.scheme,
                  let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
            switch action {
            case "selection":
                if let value = body["anchor"] as? [String: Any], let quote = value["quote"] as? String,
                   let offset = value["offset"] as? Int, offset >= 0, !quote.isEmpty, quote.utf16.count <= 10000 {
                    parent.onSelection(NovelTextAnchor(quote: quote, prefix: String((value["prefix"] as? String ?? "").suffix(32)),
                                                       suffix: String((value["suffix"] as? String ?? "").prefix(32)), offset: offset))
                }
            case "progress":
                guard let reported = body["fraction"] as? Double, reported.isFinite else { return }
                let fraction = NovelWebView.clamped(reported)
                Logger.reader.debug("[novel:page] progress \(fraction, format: .fixed(precision: 3)) paged=\(self.parent.paged) loaded=\(self.chapterLoaded) from \(message.frameInfo.request.url?.lastPathComponent ?? "?", privacy: .public)")
                if parent.paged { pendingRestore = fraction }
                parent.onScroll(fraction)
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
