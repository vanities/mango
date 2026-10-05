import SwiftUI
import os

/// The light-novel reader. Same shape as the comic reader — full-bleed content, floating
/// glass chrome that fades, an end card that offers the next volume — but the content is
/// reflowable text, so the controls are chapters and type size rather than pages and spreads.
struct NovelReaderView: View {
    let comic: Comic
    var startAt: Bookmark?

    @Environment(LibraryModel.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var systemScheme

    @State private var current: Comic?
    @State private var engine: NovelEngine?
    @State private var showingChapters = false
    @State private var findAfterChaptersDismiss = false
    @State private var atEnd = false
    @State private var hasHorizontalFold = false
    @State private var selection: NovelTextAnchor?
    @State private var highlightNote = ""
    @State private var addingHighlight = false

    private var openComic: Comic { current ?? comic }
    private var dark: Bool { settings.blackBackground || systemScheme == .dark }

    var body: some View {
        ZStack {
            (dark ? Color.black : Color.white).ignoresSafeArea()

            if atEnd {
                endCard
            } else if let engine {
                if engine.isOpening {
                    opening
                } else if let error = engine.openError {
                    failure(error)
                } else if let document = engine.document, let chapter = engine.currentChapter {
                    novelSurface(engine: engine, document: document, chapterPath: chapter.path)
                }
            } else {
                ProgressView()
            }
        }
        .alert("Highlight note", isPresented: $addingHighlight) {
            TextField("Optional note", text: $highlightNote)
            Button("Save") {
                if let selection, let engine {
                    library.addHighlight(selection, page: engine.chapterIndex, fraction: engine.scrollFraction, note: highlightNote, to: engine.comic)
                    self.selection = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: engine?.chapterIndex) { selection = nil }
        .onGeometryChange(for: Bool.self) { $0.hasHorizontalReadingFold } action: { hasHorizontalFold = $0 }
        .statusBarHidden(!(hasHorizontalFold || (engine?.showsControls ?? true)))
        .persistentSystemOverlays(hasHorizontalFold || (engine?.showsControls ?? true) ? .automatic : .hidden)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: openComic.id) {
            let created = NovelEngine(comic: openComic, library: library, settings: settings)
            created.onReachedEnd = { reachEnd() }
            engine = created
            await created.open()
            if openComic.id == comic.id, let startAt { created.go(to: startAt) }
        }
        .sheet(isPresented: $showingChapters, onDismiss: {
            // Present the system find navigator only after the sheet's dismissal completes.
            // Starting it from the sheet's button makes UIKit dismiss it with the sheet.
            if findAfterChaptersDismiss {
                findAfterChaptersDismiss = false
                engine?.findRequest += 1
            }
        }, content: {
            if let engine { ChapterListView(engine: engine, onFind: { findAfterChaptersDismiss = true }) }
        })
        .onAppear { UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake }
        .onDisappear {
            engine?.close()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func novelSurface(engine: NovelEngine, document: EPUBDocument, chapterPath: String) -> some View {
        GeometryReader { geometry in
#if IPHONE_DUO_LAYOUTS
            if #available(iOS 27.1, *), geometry.hasHorizontalReadingFold {
                ArrangementView {
                    novelPages(engine: engine, document: document, chapterPath: chapterPath)
                        .padding(.bottom, geometry.horizontalReadingFoldMargins?.before ?? 0)
                } secondary: {
                    novelChrome(engine: engine, alwaysVisible: true)
                        .padding(.top, geometry.horizontalReadingFoldMargins?.after ?? 0)
                }
                .arrangementViewStyle(.split)
            } else {
                floatingNovelSurface(engine: engine, document: document, chapterPath: chapterPath)
            }
#else
            floatingNovelSurface(engine: engine, document: document, chapterPath: chapterPath)
#endif
        }
    }

    private func floatingNovelSurface(engine: NovelEngine, document: EPUBDocument, chapterPath: String) -> some View {
        ZStack {
            novelPages(engine: engine, document: document, chapterPath: chapterPath)
            novelChrome(engine: engine)
        }
    }

    private func novelPages(engine: NovelEngine, document: EPUBDocument, chapterPath: String) -> some View {
        GeometryReader { geometry in
            chapterContent(engine: engine, document: document, chapterPath: chapterPath,
                           widePageMargin: facingPageMargin(in: geometry))
        }
        // Content uses the full page width; controls retain the system safe area.
        .ignoresSafeArea(.container, edges: .horizontal)
    }

    private func facingPageMargin(in geometry: GeometryProxy) -> Double {
#if IPHONE_DUO_LAYOUTS
        if #available(iOS 27.1, *), let fold = geometry.reservedRegions(kind: .division).first(where: { $0.frame.height > $0.frame.width }) {
            let clearance = abs(fold.frame.midX - geometry.size.width / 2) + fold.frame.width / 2
                + max(fold.margins.leading, fold.margins.trailing) + 12
            return max(settings.novelMargin, clearance)
        }
#endif
        return settings.novelMargin
    }

    private func chapterContent(engine: NovelEngine, document: EPUBDocument, chapterPath: String, widePageMargin: Double) -> some View {
        NovelWebView(
            document: document,
            chapterPath: chapterPath,
            fontScale: settings.novelFontScale,
            dark: dark,
            paged: settings.novelPaged,
            tapToTurn: settings.tapToTurn,
            fontFamily: settings.novelFont == .publisher ? "" : settings.novelFont.css,
            lineSpacing: settings.novelLineSpacing,
            margin: settings.novelMargin,
            widePageMargin: widePageMargin,
            restoreFraction: engine.pendingJumpFraction > 0 ? engine.pendingJumpFraction : engine.scrollFraction,
            highlights: engine.bookmarks.filter { $0.page == engine.chapterIndex }.compactMap(\.anchor),
            jumpAnchor: engine.pendingTextAnchor,
            findRequest: engine.findRequest,
            onSelection: { selection = $0 },
            onScroll: { engine.scrollFraction = $0 },
            onTapMiddle: { engine.toggleControls() },
            onNextChapter: { engine.nextChapter() },
            onPreviousChapter: { engine.previousChapter(atEnd: true) },
            onReachedBottom: {
                // Reaching the bottom of the last chapter is the end of the book.
                if engine.isAtLastChapter { engine.notifyReachedEnd() }
            },
            onOpenChapter: { engine.openLink(toPath: $0) }
        )
        .id("\(chapterPath)-\(settings.novelPaged)-\(engine.jumpID)")

    }

    private func novelChrome(engine: NovelEngine, alwaysVisible: Bool = false) -> some View {
        ZStack {
            if selection != nil {
                VStack { Spacer(); HStack {
                    Button { highlightNote = ""; addingHighlight = true } label: {
                        Label("Save highlight", systemImage: "highlighter").frame(minHeight: 44)
                    }
                    Button { selection = nil } label: { Text("Cancel").frame(minHeight: 44) }
                }.padding().glassEffect(in: .capsule).padding(.bottom, 70) }
            }
            NovelControls(engine: engine, showingChapters: $showingChapters, onClose: close, alwaysVisible: alwaysVisible)
        }
    }

    private var opening: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Opening \(openComic.title)…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func failure(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't open this book", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Back") { close() }.buttonStyle(.glassProminent)
        }
    }

    // MARK: End of a volume

    private func reachEnd() {
        guard let engine else { return }
        library.setFinished(true, for: engine.comic)
        engine.close()
        withAnimation(.smooth(duration: 0.25)) { atEnd = true }
    }

    @ViewBuilder
    private var endCard: some View {
        let next = library.nextInSeries(after: openComic)
        VStack(spacing: 22) {
            if let next {
                CoverView(coverID: next.coverID, title: next.title, cornerRadius: 10)
                    .frame(width: 150)
                    .shadow(radius: 18, y: 8)
            }
            VStack(spacing: 4) {
                Text("How was it?")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                StarRating(rating: library.rating(for: openComic), size: 24) { library.setRating($0, for: openComic) }
            }

            VStack(spacing: 6) {
                Text("Finished \(openComic.numberLabel ?? openComic.title)")
                    .font(.headline)
                if let next {
                    Text("Up next").font(.caption).foregroundStyle(.secondary)
                    Text([next.numberLabel, next.subtitle].compactMap { $0 }.joined(separator: " · "))
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                } else {
                    Text("That's the last one in \(openComic.series ?? openComic.title).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 32)

            VStack(spacing: 10) {
                if let next {
                    Button {
                        atEnd = false
                        current = next
                    } label: {
                        Label("Read \(next.numberLabel ?? "next")", systemImage: "arrow.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                }
                Button("Back to library") { close() }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: 280)
        }
        .padding(32)
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    private func close() {
        engine?.close()
        dismiss()
    }
}

/// Floating chrome for the novel reader: where you are, type size, and the chapter list.
struct NovelControls: View {
    @Bindable var engine: NovelEngine
    @Binding var showingChapters: Bool
    var onClose: () -> Void
    var alwaysVisible = false

    private var controlsVisible: Bool { alwaysVisible || engine.showsControls }

    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        GeometryReader { geometry in
            let widths = foldClearWidths(in: geometry)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    button("chevron.left", label: "Close", action: onClose)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(engine.comic.numberLabel ?? engine.comic.title)
                            .font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(engine.comic.series ?? engine.bookTitle ?? "")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(width: widths?.title, alignment: .leading)
                    .frame(maxWidth: widths == nil ? .infinity : nil, alignment: .leading)

                    if widths != nil { Spacer(minLength: 0) }

                    button("textformat.size.smaller", label: "Smaller text") {
                        settings.novelFontScale = max(0.7, settings.novelFontScale - 0.1)
                        engine.keepControlsAwake()
                    }
                    button("textformat.size.larger", label: "Larger text") {
                        settings.novelFontScale = min(2.0, settings.novelFontScale + 0.1)
                        engine.keepControlsAwake()
                    }
                    button(engine.isHereBookmarked ? "bookmark.fill" : "bookmark",
                           label: engine.isHereBookmarked ? "Remove bookmark" : "Bookmark this spot") {
                        engine.toggleBookmark()
                    }
                    button("list.bullet", label: "Chapters and reading settings") {
                        showingChapters = true
                        engine.keepControlsAwake()
                    }
                }
                .padding(.leading, 4)
                .padding(.trailing, 8)
                .padding(.vertical, 4)
                .glassEffect(in: .capsule)
                .padding(.horizontal, 12)
                .padding(.top, 4)

                Spacer(minLength: 0)

                HStack(spacing: 12) {
                    if engine.jumpOrigin != nil {
                        button("arrow.uturn.backward", label: "Undo position jump") { engine.undoJump() }
                    }
                    // Chapters, not pages: VoiceOver would otherwise read the symbols as Back and Forward.
                    button("chevron.left", label: "Previous chapter") { engine.previousChapter() }
                        .disabled(engine.chapterIndex <= 0)
                    if widths != nil { Spacer(minLength: 0) }
                    VStack(spacing: 2) {
                        // A long chapter name gives way; the percentage always shows.
                        HStack(spacing: 0) {
                            Text(engine.chapterLabel).lineLimit(1)
                            if !engine.chapterLabel.isEmpty { Text(" · \(engine.percentLabel)").fixedSize() }
                        }
                        .font(.caption.weight(.medium)).monospacedDigit()
                        .accessibilityElement(children: .combine)
                        if settings.showReadingEstimates, let minutes = engine.chapterMinutesRemaining {
                            Text("~\(minutes) min left in chapter").font(.caption2)
                                .accessibilityLabel("About \(minutes) minutes left, estimated at 220 words per minute")
                        }
                    }
                    .foregroundStyle(.secondary)
                    .frame(width: widths?.position)
                    .frame(maxWidth: widths == nil ? .infinity : nil)
                    button("chevron.right", label: "Next chapter") { engine.nextChapter() }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 6)
                .glassEffect(in: .capsule)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
            }
        }
        .opacity(controlsVisible ? 1 : 0)
        .allowsHitTesting(controlsVisible)
        .accessibilityHidden(!controlsVisible)
        .animation(.smooth(duration: 0.25), value: controlsVisible)
    }

    private func foldClearWidths(in geometry: GeometryProxy) -> (title: CGFloat, position: CGFloat)? {
#if IPHONE_DUO_LAYOUTS
        if #available(iOS 27.1, *),
           let fold = geometry.reservedRegions(kind: .division).first(where: {
               $0.frame.height > $0.frame.width && $0.frame.minX > 0 && $0.frame.maxX < geometry.size.width
           }) {
            // The title stays on the leading page; reading position stays on the
            // trailing page. Include capsule padding, adjacent buttons and spacing.
            let titleInset: CGFloat = 12 + 4 + 44 + 10
            let positionInset: CGFloat = 12 + 18 + 44 + 12
            return (
                title: max(0, fold.frame.minX - fold.margins.leading - titleInset),
                position: max(0, geometry.size.width - fold.frame.maxX - fold.margins.trailing - positionInset)
            )
        }
#endif
        return nil
    }

    private func button(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct ChapterListView: View {
    @Environment(AppSettings.self) private var settings
    @Bindable var engine: NovelEngine
    var onFind: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button("Find in this chapter", systemImage: "magnifyingglass") { onFind(); dismiss() }
                    Text("Select text in the chapter to save a highlight and optional note.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Reading") {
                    Toggle("Show chapter time estimate", isOn: Bindable(settings).showReadingEstimates)
                    Toggle("Turn pages like a book", isOn: Bindable(settings).novelPaged)
                    Toggle("Tap edges to turn", isOn: Bindable(settings).tapToTurn)
                    Picker("Font", selection: Bindable(settings).novelFont) {
                        ForEach(NovelFont.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    LabeledContent("Text size", value: "\(Int(settings.novelFontScale * 100))%")
                    Slider(value: Bindable(settings).novelFontScale, in: 0.7...2, step: 0.1) {
                        Text("Text size")
                    }
                    LabeledContent("Line spacing", value: settings.novelLineSpacing.formatted(.number.precision(.fractionLength(1))))
                    Slider(value: Bindable(settings).novelLineSpacing, in: 1.2...2.2, step: 0.1) {
                        Text("Line spacing")
                    }
                    LabeledContent("Margins", value: "\(Int(settings.novelMargin))")
                    Slider(value: Bindable(settings).novelMargin, in: 12...48, step: 2) {
                        Text("Margins")
                    }
                }
                if !engine.bookmarks.isEmpty {
                    Section("Bookmarks") {
                        ForEach(engine.bookmarks) { mark in
                            Button {
                                engine.go(to: mark)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Label(engine.contents.name(of: mark.page), systemImage: mark.anchor == nil ? "bookmark.fill" : "highlighter")
                                        if let anchor = mark.anchor { Text(anchor.quote).font(.caption).lineLimit(3) }
                                        if !mark.note.isEmpty { Text(mark.note).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    Text("\(Int((mark.fraction ?? 0) * 100))% in")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions { Button("Delete", role: .destructive) { engine.removeBookmark(mark) } }
                        }
                    }
                }
                Section("Chapters") {
                    // The book's own contents: a chapter split across documents, or with an
                    // illustration page inside it, is one entry, current wherever in it you are.
                    let current = engine.contents.entry(containing: engine.chapterIndex)?.index
                    ForEach(engine.contents.entries, id: \.index) { entry in
                        Button {
                            engine.goToChapter(entry.index)
                            dismiss()
                        } label: {
                            HStack {
                                Text(entry.title)
                                    .foregroundStyle(entry.index == current ? Color.accentColor : .primary)
                                Spacer()
                                if entry.index == current {
                                    Image(systemName: "book.fill").foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Reading")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
