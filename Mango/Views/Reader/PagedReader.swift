import SwiftUI

/// One page — or one spread — at a time, swiped sideways.
///
/// Built on a paging `ScrollView` rather than a page-style `TabView` for one reason: paging has
/// to be suspendable. While a page is zoomed in, a horizontal drag means "pan across the art",
/// not "next page", and a `TabView` gives no way to hand the gesture over.
///
/// Pages stay in reading order and the whole pager gets `layoutDirection` flipped for
/// right-to-left manga, so "swipe from the right edge" advances in manga and "swipe from the
/// left" advances in a western comic, with no reversed arrays anywhere.
struct PagedReader: View {
    @Bindable var engine: ReaderEngine
    var fit: PageFit
    var tapToTurn: Bool
    var panAxes: PanAxes

    @State private var scrollPosition: Int?
    @State private var isZoomed = false

    private static let space = "mango.pager"

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(Array(engine.groups.enumerated()), id: \.offset) { position, group in
                        spread(group)
                            .containerRelativeFrame(.horizontal)
                            .id(position)
                    }
                    // One empty slot past the last page. Swiping into it is how a reader
                    // naturally says "I'm done with this one" — without it, the end is only
                    // reachable by tapping, and over-scrolling drove groupIndex out of range.
                    Color.clear
                        .containerRelativeFrame(.horizontal)
                        .id(engine.groups.count)
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $scrollPosition, anchor: .center)
            .scrollIndicators(.hidden)
            // The whole point of not using TabView: while zoomed, the drag belongs to the page.
            .scrollDisabled(isZoomed)
            .environment(\.layoutDirection, engine.direction == .rightToLeft ? .rightToLeft : .leftToRight)
            // A hit-testable overlay on top of the pager would eat the swipe before the scroll
            // view sees it. A simultaneous spatial tap reads the same position without taking
            // the gesture away.
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .named(Self.space))
                    .onEnded { value in handleTap(atX: value.location.x, width: geometry.size.width) }
            )
        }
        .coordinateSpace(.named(Self.space))
        .ignoresSafeArea()
        .onAppear { scrollPosition = engine.groupIndex }
        // Two-way: the slider and tap-to-turn drive the scroll view, and scrolling drives the
        // engine. Both sides check before writing so they can't ping-pong.
        .onChange(of: engine.groupIndex) { _, new in
            if scrollPosition != new { scrollPosition = new }
        }
        .onChange(of: scrollPosition) { _, new in
            guard let new else { return }
            // Landing on the trailing slot means "past the last page", not "page N+1".
            guard new < engine.groups.count else {
                engine.notifyReachedEnd()
                return
            }
            guard engine.groupIndex != new else { return }
            engine.groupIndex = new
        }
    }

    /// A group is one page, or two shown side by side. In right-to-left the environment flips
    /// the HStack too, so the lower page number lands on the right — which is correct.
    @ViewBuilder
    private func spread(_ group: [Int]) -> some View {
        ZoomableView(resetToken: group, panAxes: panAxes, isZoomed: $isZoomed) {
            if group.count == 1 {
                PageImageView(index: group[0], engine: engine, fit: fit)
            } else {
                HStack(spacing: 0) {
                    ForEach(group, id: \.self) { index in
                        PageImageView(index: index, engine: engine, fit: fit)
                    }
                }
            }
        }
    }

    /// Outer quarters turn the page, the middle half toggles the chrome. Measured in screen
    /// space — the coordinate space is named outside the flipped environment, so x is always
    /// "distance from the left edge of the device" — and "forward" then follows the reading
    /// direction. Weighted towards the middle: a mis-tap should show the controls, not
    /// silently lose your place. Ignored while zoomed, where taps belong to the page.
    private func handleTap(atX x: CGFloat, width: CGFloat) {
        guard !isZoomed else { return }
        guard tapToTurn, width > 0 else {
            engine.toggleControls()
            return
        }
        let edge = width * 0.25
        let towardsTheEnd = (x < edge) == (engine.direction == .rightToLeft)
        if x < edge || x > width - edge {
            if towardsTheEnd { engine.advance() } else { engine.retreat() }
        } else {
            engine.toggleControls()
        }
    }
}
