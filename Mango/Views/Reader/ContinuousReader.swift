import SwiftUI
import os

/// Vertical scroll with no gaps — how webtoons and long-strip scanlations are meant to be read.
/// Pages are lazy, so a 200-page volume doesn't try to decode itself on appear.
///
/// Pages are laid out at their real heights before they load (the engine sizes them from their
/// headers), so nothing shifts when a page arrives — which is what makes both the resume and the
/// page tracking below trustworthy.
struct ContinuousReader: View {
    @Bindable var engine: ReaderEngine

    /// Pages crossing the reading line right now. Normally exactly one; briefly two while the
    /// lazy stack is still placing pages, which is why this is a set rather than "the last page
    /// that crossed" — that version got stuck on a page the first layout pass misplaced.
    @State private var underLine: Set<Int> = []
    /// Where the strip is headed on open, to pick up where this book was left off. Set before the
    /// first layout, because pages report crossing the line before `onAppear` runs — and page
    /// one, laid out first, isn't where the reader is.
    @State private var resumeTarget: Int?

    /// The page crossing this line, just below the Dynamic Island, is the one being read.
    /// `onAppear` can't say that (a lazy stack builds pages before they're on screen), and
    /// neither can a scroll position that only knows which page's top is nearest.
    /// `nonisolated`: the geometry check that reads it runs off the main actor.
    private nonisolated static let readingLine: CGFloat = 120

    init(engine: ReaderEngine) {
        self.engine = engine
        _resumeTarget = State(initialValue: engine.currentPage > 0 ? engine.currentPage : nil)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(0..<engine.pageCount, id: \.self) { index in
                        PageImageView(index: index, engine: engine, fit: .width, asStrip: true)
                            .frame(maxWidth: .infinity)
                            .id(index)
                            .onGeometryChange(for: Bool.self) { geometry in
                                let frame = geometry.frame(in: .scrollView)
                                return frame.minY <= Self.readingLine && frame.maxY > Self.readingLine
                            } action: { crossesLine in
                                if crossesLine { underLine.insert(index) } else { underLine.remove(index) }
                                reportPage()
                            }
                            .onDisappear {
                                // Recycled while under the line (a jump away): no edge will come.
                                underLine.remove(index)
                            }
                    }
                    endOfChapter
                        .id(engine.pageCount)
                }
            }
            .scrollIndicators(.hidden)
            // Deliberately not ignoring the safe area: a scroll view then starts the strip below
            // the Dynamic Island and still scrolls it underneath, full bleed. Ignoring it would
            // park the top of page one — usually the title — behind the island.
            .onTapGesture { engine.toggleControls() }
            .onAppear {
                guard let resumeTarget else { return }
                proxy.scrollTo(resumeTarget, anchor: .top)
            }
            // If the reader starts scrolling before the resume lands, wherever they are wins.
            .onScrollPhaseChange { _, phase in
                if phase == .interacting { resumeTarget = nil }
            }
            // The slider, a bookmark: take the strip there. (Scrolling doesn't come through here.)
            .onChange(of: engine.jumpCount) {
                let page = engine.currentPage
                Logger.reader.info("[strip] jump to page \(page + 1)")
                proxy.scrollTo(page, anchor: .top)
            }
            // Scrolling on past the last page is how a strip says "done" — the same gesture as
            // swiping into the paged reader's empty trailing slot. Only once you've actually
            // scrolled, so a short chapter still laying out can't end itself on open.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y > 0
                    && geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 2
            } action: { _, atBottom in
                if atBottom { engine.notifyReachedEnd() }
            }
        }
    }

    private func reportPage() {
        guard let page = underLine.min() else { return }
        if let target = resumeTarget {
            guard page == target else { return }
            resumeTarget = nil
        }
        guard page != engine.currentPage else { return }
        Logger.reader.info("[strip] reading page \(page + 1)")
        engine.readingPage(page)
    }

    private var endOfChapter: some View {
        VStack(spacing: 8) {
            Image(systemName: "chevron.compact.down")
                .font(.title)
            Text("End of \(engine.comic.numberLabel ?? engine.comic.title)")
                .font(.callout.weight(.medium))
            Text("Keep scrolling to finish")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
        .containerRelativeFrame(.vertical, alignment: .top) { length, _ in length * 0.45 }
    }
}
