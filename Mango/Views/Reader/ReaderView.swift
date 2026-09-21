import SwiftUI
import os

/// The reader. Paged or continuous, left-to-right or right-to-left, one page or a spread.
///
/// Owns the *session* rather than a single book: turning past the last page rolls straight on
/// to the next volume in the series without a trip back to the library, which is the whole
/// point of a run of 34 volumes.
struct ReaderView: View {
    let comic: Comic

    @Environment(LibraryModel.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    /// The volume actually open, which changes as the reader rolls on through a series.
    @State private var current: Comic?
    @State private var engine: ReaderEngine?
    @State private var showingSettings = false
    /// Shown after the last page: finished this one, what now?
    @State private var atEnd = false

    private var openComic: Comic { current ?? comic }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                background.ignoresSafeArea()

                if atEnd {
                    endCard
                } else if let engine {
                    if engine.isOpening {
                        openingState
                    } else if let error = engine.openError {
                        errorState(error)
                    } else {
                        content(engine: engine)
                        ReaderControls(engine: engine, showingSettings: $showingSettings, onClose: close)
                    }
                } else {
                    ProgressView()
                }
            }
            .onChange(of: geometry.size) { _, new in
                engine?.isLandscape = new.width > new.height
            }
            // Keyed on the open volume: rolling on to the next one rebuilds the engine.
            .task(id: openComic.id) {
                let created = ReaderEngine(comic: openComic, library: library, settings: settings)
                created.isLandscape = geometry.size.width > geometry.size.height
                created.onReachedEnd = { reachEnd() }
                engine = created
                await created.open(maxPixel: maxPixel(for: geometry.size))
            }
        }
        .statusBarHidden(!(engine?.showsControls ?? true))
        .persistentSystemOverlays(engine?.showsControls ?? true ? .automatic : .hidden)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingSettings) {
            if let engine { ReaderSettingsSheet(engine: engine) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            engine?.handleMemoryWarning()
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake }
        .onDisappear {
            engine?.close()
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private var background: Color {
        settings.blackBackground ? .black : Color(.systemBackground)
    }

    /// Decode budget: the screen's longest edge in real pixels, with headroom so a pinch-zoom
    /// doesn't immediately go soft. Capped inside `ImageDecoder`.
    private func maxPixel(for size: CGSize) -> Int {
        Int(max(size.width, size.height) * displayScale * 1.5)
    }

    @ViewBuilder
    private func content(engine: ReaderEngine) -> some View {
        switch engine.mode {
        case .paged:
            PagedReader(engine: engine, fit: settings.pageFit, tapToTurn: settings.tapToTurn,
                        panDirection: settings.panDirection)
        case .continuous:
            ContinuousReader(engine: engine)
        }
    }

    // MARK: End of a volume

    /// Turning past the last page marks this one finished and asks what to do next, rather
    /// than either stopping dead or silently jumping — the reader should stay in control of
    /// when a 34-volume run carries them onward.
    private func reachEnd() {
        guard let engine else { return }
        library.setFinished(true, for: engine.comic)
        engine.close()
        withAnimation(.smooth(duration: 0.25)) { atEnd = true }
    }

    private func readNext(_ next: Comic) {
        Logger.reader.info("[reader] continuing to \(next.title, privacy: .public)")
        atEnd = false
        current = next
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

            VStack(spacing: 6) {
                Text("Finished \(openComic.numberLabel ?? openComic.title)")
                    .font(.headline)
                if let next {
                    Text("Up next")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    Button { readNext(next) } label: {
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
        .environment(\.colorScheme, .dark)
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }

    // MARK: States

    private var openingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Opening \(openComic.title)…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Couldn't open this", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Back") { close() }
                .buttonStyle(.glassProminent)
        }
    }

    private func close() {
        engine?.close()
        dismiss()
    }
}
