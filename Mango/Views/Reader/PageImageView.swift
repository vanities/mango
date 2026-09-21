import CoreGraphics
import SwiftUI

/// One page. Asks the engine for its image when it appears and shows a spinner until it lands —
/// which on a NAS is a real wait, so it says which page it's fetching.
struct PageImageView: View {
    let index: Int
    let engine: ReaderEngine
    var fit: PageFit

    @State private var image: CGImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
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
        image = loaded
        failed = loaded == nil
    }
}
