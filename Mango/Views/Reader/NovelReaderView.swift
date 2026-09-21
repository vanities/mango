import SwiftUI
import os

/// The light-novel reader. Same shape as the comic reader — full-bleed content, floating
/// glass chrome that fades, an end card that offers the next volume — but the content is
/// reflowable text, so the controls are chapters and type size rather than pages and spreads.
struct NovelReaderView: View {
    let comic: Comic

    @Environment(LibraryModel.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var systemScheme

    @State private var current: Comic?
    @State private var engine: NovelEngine?
    @State private var showingChapters = false
    @State private var atEnd = false

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
                    NovelWebView(
                        document: document,
                        chapterPath: chapter.path,
                        fontScale: settings.novelFontScale,
                        dark: dark,
                        restoreFraction: engine.pendingJumpFraction > 0 ? engine.pendingJumpFraction : engine.scrollFraction,
                        onScroll: { engine.scrollFraction = $0 },
                        onTapMiddle: { engine.toggleControls() },
                        onReachedBottom: {
                            // Reaching the bottom of the last chapter is the end of the book.
                            if engine.isAtLastChapter { engine.notifyReachedEnd() }
                        }
                    )
                    .ignoresSafeArea()
                    .id(chapter.path)

                    NovelControls(engine: engine, showingChapters: $showingChapters, onClose: close)
                }
            } else {
                ProgressView()
            }
        }
        .statusBarHidden(!(engine?.showsControls ?? true))
        .persistentSystemOverlays(engine?.showsControls ?? true ? .automatic : .hidden)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .task(id: openComic.id) {
            let created = NovelEngine(comic: openComic, library: library, settings: settings)
            created.onReachedEnd = { reachEnd() }
            engine = created
            await created.open()
        }
        .sheet(isPresented: $showingChapters) {
            if let engine { ChapterListView(engine: engine) }
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake }
        .onDisappear {
            engine?.close()
            UIApplication.shared.isIdleTimerDisabled = false
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

    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                button("chevron.left", label: "Close", action: onClose)
                VStack(alignment: .leading, spacing: 0) {
                    Text(engine.comic.numberLabel ?? engine.comic.title)
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(engine.comic.series ?? engine.bookTitle ?? "")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

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
                button("list.bullet", label: "Chapters") {
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
                Button { engine.previousChapter() } label: { Image(systemName: "chevron.left") }
                    .disabled(engine.chapterIndex <= 0)
                Text(engine.positionLabel)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Button { engine.nextChapter() } label: { Image(systemName: "chevron.right") }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .glassEffect(in: .capsule)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
        }
        .opacity(engine.showsControls ? 1 : 0)
        .allowsHitTesting(engine.showsControls)
        .accessibilityHidden(!engine.showsControls)
        .animation(.smooth(duration: 0.25), value: engine.showsControls)
    }

    private func button(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 40, height: 40)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct ChapterListView: View {
    @Bindable var engine: NovelEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !engine.bookmarks.isEmpty {
                    Section("Bookmarks") {
                        ForEach(engine.bookmarks) { mark in
                            Button {
                                engine.go(to: mark)
                                dismiss()
                            } label: {
                                HStack {
                                    Label(mark.label(isNovel: true), systemImage: "bookmark.fill")
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
                ForEach(Array(engine.chapters.enumerated()), id: \.offset) { index, chapter in
                    Button {
                        engine.goToChapter(index)
                        dismiss()
                    } label: {
                        HStack {
                            Text(chapter.title ?? "Chapter \(index + 1)")
                                .foregroundStyle(index == engine.chapterIndex ? Color.accentColor : .primary)
                            Spacer()
                            if index == engine.chapterIndex {
                                Image(systemName: "book.fill").foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
                }
            }
            .navigationTitle("Chapters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
