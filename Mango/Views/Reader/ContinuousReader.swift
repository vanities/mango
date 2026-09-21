import SwiftUI

/// Vertical scroll with no gaps — how webtoons and long-strip scanlations are meant to be read.
/// Pages are lazy, so a 200-page volume doesn't try to decode itself on appear.
struct ContinuousReader: View {
    @Bindable var engine: ReaderEngine

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(0..<engine.pageCount, id: \.self) { index in
                        PageImageView(index: index, engine: engine, fit: .width)
                            .frame(maxWidth: .infinity)
                            // A page with no image yet still needs height, or the whole book
                            // collapses to nothing and the scroll position is meaningless.
                            .frame(minHeight: 400)
                            .id(index)
                            .onAppear { engine.goToPage(index) }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .ignoresSafeArea()
            .onTapGesture { engine.toggleControls() }
            .onAppear {
                guard engine.currentPage > 0 else { return }
                proxy.scrollTo(engine.currentPage, anchor: .top)
            }
        }
    }
}
