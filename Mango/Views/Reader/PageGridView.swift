import CoreGraphics
import SwiftUI

/// Every page as a thumbnail — jump anywhere in one tap. Cells load as they scroll into view,
/// because on a NAS each one reads its page. It runs the way the book does, like the slider.
struct PageGridView: View {
    let engine: ReaderEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88, maximum: 140), spacing: 10)], spacing: 14) {
                        ForEach(0..<engine.pageCount, id: \.self) { index in
                            Button {
                                engine.goToPage(index)
                                dismiss()
                            } label: {
                                PageThumbnailCell(index: index, engine: engine,
                                                  isCurrent: index == engine.currentPage,
                                                  isBookmarked: engine.bookmarks.contains { $0.page == index })
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                    .padding()
                }
                .environment(\.layoutDirection, engine.direction == .rightToLeft ? .rightToLeft : .leftToRight)
                .onAppear { proxy.scrollTo(engine.currentPage, anchor: .center) }
            }
            .navigationTitle("Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

private struct PageThumbnailCell: View {
    let index: Int
    let engine: ReaderEngine
    let isCurrent: Bool
    let isBookmarked: Bool

    @State private var image: CGImage?

    var body: some View {
        VStack(spacing: 4) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(decorative: image, scale: 1, orientation: .up)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        ProgressView()
                    }
                }
                .background(.quaternary, in: .rect(cornerRadius: 6))
                .clipShape(.rect(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 3)
                }
                .overlay(alignment: .topTrailing) {
                    if isBookmarked {
                        Image(systemName: "bookmark.fill")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                            .padding(4)
                    }
                }
            Text("\(index + 1)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(isCurrent ? .primary : .secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Page \(index + 1)\(isBookmarked ? ", bookmarked" : "")\(isCurrent ? ", current page" : "")")
        .task(id: index) { image = await engine.thumbnail(at: index) }
    }
}

extension View {
    /// The reader's page tint. Display only — the pages themselves are never changed.
    @ViewBuilder
    func pageFilter(_ filter: PageFilter) -> some View {
        switch filter {
        case .none: self
        case .sepia: self.colorMultiply(Color(red: 1.0, green: 0.93, blue: 0.80))
        case .dim: self.brightness(-0.28)
        // Inverting keeps line art readable white-on-black; turning the hue back round keeps a
        // colour page's reds red.
        case .night: self.colorInvert().hueRotation(.degrees(180))
        }
    }
}
