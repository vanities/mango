import SwiftUI
import os

/// The reader. Paged or continuous, left-to-right or right-to-left, one page or a spread.
///
/// Right-to-left is done with `layoutDirection` rather than by reversing the page array: the
/// pages stay in reading order everywhere else (progress, prefetch, the slider), and only the
/// direction the screen moves changes.
struct ReaderView: View {
    let comic: Comic

    @Environment(LibraryModel.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    @State private var engine: ReaderEngine?
    @State private var showingSettings = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                background.ignoresSafeArea()

                if let engine {
                    if engine.isOpening {
                        openingState
                    } else if let error = engine.openError {
                        errorState(error)
                    } else {
                        content(engine: engine, size: geometry.size)
                        ReaderControls(engine: engine, showingSettings: $showingSettings, onClose: close)
                    }
                } else {
                    ProgressView()
                }
            }
            .onChange(of: geometry.size) { _, new in
                engine?.isLandscape = new.width > new.height
            }
            .task {
                let created = ReaderEngine(comic: comic, library: library, settings: settings)
                created.isLandscape = geometry.size.width > geometry.size.height
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
        .onDisappear { engine?.close() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = settings.keepScreenAwake }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
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
    private func content(engine: ReaderEngine, size: CGSize) -> some View {
        switch engine.mode {
        case .paged:
            PagedReader(engine: engine, fit: settings.pageFit, tapToTurn: settings.tapToTurn)
        case .continuous:
            ContinuousReader(engine: engine)
        }
    }

    private var openingState: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Opening \(comic.title)…")
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
