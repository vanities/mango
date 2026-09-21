import CoreGraphics
import SwiftUI

/// A comic cover, loaded off the main thread from `CoverStore`, with a placeholder that still
/// tells you what the book is when there's no cover yet.
struct CoverView: View {
    let coverID: String?
    let title: String
    var cornerRadius: CGFloat = 8

    @Environment(LibraryModel.self) private var library
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .aspectRatio(2 / 3, contentMode: .fit)
        .clipShape(.rect(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .task(id: coverID) { await load() }
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            VStack(spacing: 6) {
                Image(systemName: "book.closed")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption2)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
            }
        }
    }

    private func load() async {
        guard let coverID else { image = nil; return }
        let store = library.covers
        image = await Task.detached(priority: .utility) { store.load(coverID) }.value
    }
}
