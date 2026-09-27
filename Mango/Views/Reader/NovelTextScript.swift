import Foundation

/// Works in document text coordinates. No publisher HTML or selected text is interpolated as code.
enum NovelTextScript {
    static let source = #"""
    (() => {
      if (window.mangoText) return;
      const nodes = () => {
        const result = [], walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
          acceptNode: n => n.parentElement?.closest('script,style,noscript') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT
        });
        while (walker.nextNode()) result.push(walker.currentNode);
        return result;
      };
      const locate = (anchor, text) => {
        if (!anchor || !anchor.quote) return -1;
        if (text.slice(anchor.offset, anchor.offset + anchor.quote.length) === anchor.quote) return anchor.offset;
        const matches = [];
        let i = text.indexOf(anchor.quote);
        while (i >= 0) {
          if ((!anchor.prefix || text.slice(Math.max(0, i - anchor.prefix.length), i) === anchor.prefix) &&
              (!anchor.suffix || text.slice(i + anchor.quote.length, i + anchor.quote.length + anchor.suffix.length) === anchor.suffix)) matches.push(i);
          i = text.indexOf(anchor.quote, i + 1);
        }
        return matches.length === 1 ? matches[0] : -1;
      };
      const range = anchor => {
        const list = nodes(), text = list.map(n => n.textContent).join('');
        const start = locate(anchor, text);
        if (start < 0) return null;
        const end = start + anchor.quote.length, r = document.createRange();
        let position = 0, begun = false;
        for (const n of list) {
          const next = position + n.length;
          if (!begun && start < next) { r.setStart(n, start - position); begun = true; }
          if (begun && end <= next) { r.setEnd(n, end - position); return r; }
          position = next;
        }
        return null;
      };
      window.mangoText = {
        locate,
        paint: anchors => {
          if (!window.Highlight || !CSS.highlights) return;
          const ranges = anchors.map(range).filter(Boolean);
          CSS.highlights.set('mango', new Highlight(...ranges));
        },
        jump: anchor => {
          const r = range(anchor);
          if (!r) return false;
          const rect = r.getBoundingClientRect();
          if (window.mangoPager) {
            const p = window.mangoPager;
            p.page = Math.max(0, Math.min(p.count - 1, Math.floor((rect.left + window.scrollX) / window.innerWidth)));
            p.fraction = p.count > 1 ? p.page / (p.count - 1) : 0;
            window.scrollTo(p.page * window.innerWidth, 0);
            window.webkit.messageHandlers.mangoNavigation.postMessage({action: 'progress', fraction: p.fraction});
          } else window.scrollTo(0, Math.max(0, window.scrollY + rect.top - 90));
          return true;
        }
      };
      document.addEventListener('selectionchange', () => {
        const selection = window.getSelection();
        if (!selection || selection.isCollapsed || !selection.rangeCount) return;
        const r = selection.getRangeAt(0), list = nodes();
        let offset = 0, start = -1, end = -1;
        for (const n of list) {
          if (n === r.startContainer) start = offset + r.startOffset;
          if (n === r.endContainer) end = offset + r.endOffset;
          offset += n.length;
        }
        if (start < 0 || end <= start || end - start > 10000) return;
        const text = list.map(n => n.textContent).join('');
        window.webkit.messageHandlers.mangoNavigation.postMessage({action: 'selection', anchor: {
          quote: text.slice(start, end), prefix: text.slice(Math.max(0, start - 32), start),
          suffix: text.slice(end, end + 32), offset: start
        }});
      });
      const style = document.createElement('style');
      style.textContent = '::highlight(mango) { background-color: #f5cc63; color: #16130f; }';
      document.head.appendChild(style);
    })();
    """#
}
