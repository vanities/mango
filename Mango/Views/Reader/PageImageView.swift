import CoreGraphics
import SwiftUI

/// One page. Asks the engine for its image when it appears and shows a spinner until it lands —
/// which on a NAS is a real wait, so it says which page it's fetching.
struct PageImageView: View {
    let index: Int
    let engine: ReaderEngine
    var fit: PageFit
    /// Part of a continuous strip: full width, natural height, drawn as stacked tiles so a
    /// 12,000-pixel page doesn't exceed what the GPU will draw in one texture.
    var asStrip = false

    @State private var image: CGImage?
    @State private var tiles: [CGImage] = []
    @State private var failed = false

    var body: some View {
        Group {
            if asStrip {
                strip
            } else if let image {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else if failed {
                missing
            } else {
                loading
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: index) { await load() }
        // A strip page is tens of megabytes decoded. Once it's scrolled away, let it go — the
        // loader still has it if it's recent, and its known shape holds its place meanwhile.
        .onDisappear {
            guard asStrip else { return }
            image = nil
            tiles = []
        }
    }

    @ViewBuilder
    private var strip: some View {
        if !tiles.isEmpty {
            VStack(spacing: 0) {
                ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                    Image(decorative: tile, scale: 1, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
        } else if let ratio = engine.aspectRatio(of: index) {
            // Hold the page's real height (or the last page's, as a guess) so the pages below
            // don't jump when it lands, and one scrolled back to doesn't collapse.
            Color.clear
                .aspectRatio(1 / ratio, contentMode: .fit)
                .overlay { if failed { missing } else { loading } }
        } else {
            Group { if failed { missing } else { loading } }
                .frame(maxWidth: .infinity, minHeight: 400)
        }
    }

    private var contentMode: ContentMode {
        switch fit {
        case .screen: .fit
        case .width, .height: .fill
        }
    }

    private var loading: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Page \(index + 1)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var missing: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.secondary)
            Text("Page \(index + 1) wouldn't open")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(engine.pageName(at: index))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding()
    }

    private func load() async {
        failed = false
        let loaded = await engine.image(at: index)
        // Scrolled away while it decoded: don't pin a bitmap to a view that's gone.
        guard !Task.isCancelled else { return }
        image = loaded
        tiles = asStrip ? loaded.map(ImageDecoder.tiles(of:)) ?? [] : []
        failed = loaded == nil
    }
}
