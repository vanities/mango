import SwiftUI

/// Pinch-to-zoom and pan for one page, with double-tap to toggle between fit and 2.5×.
///
/// Reports its zoom state upward: while a page is zoomed in, the pager has to stop claiming
/// horizontal drags or panning across the page is impossible.
///
/// Zoom resets whenever `resetToken` changes, so turning the page doesn't leave you zoomed
/// into the corner of the next one.
struct ZoomableView<Content: View>: View {
    var resetToken: AnyHashable
    var maxScale: CGFloat = 5
    /// false: dragging moves the viewport across the page (the page appears to go the other
    /// way). true: the page follows your finger. Neither is objectively right, so it's a setting.
    var dragMovesPage: Bool = false
    @Binding var isZoomed: Bool
    @ViewBuilder var content: () -> Content

    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    /// Below this, treat it as "not zoomed" — floating point never lands exactly on 1.
    private static var zoomThreshold: CGFloat { 1.01 }

    var body: some View {
        GeometryReader { geometry in
            content()
                .scaleEffect(scale)
                .offset(offset)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(.rect)
                .simultaneousGesture(magnification)
                .simultaneousGesture(scale > Self.zoomThreshold ? pan(in: geometry.size) : nil)
                .onTapGesture(count: 2) { toggleZoom() }
                .animation(.snappy(duration: 0.2), value: scale)
                .animation(.snappy(duration: 0.2), value: offset)
        }
        .onChange(of: resetToken) { reset() }
        .onChange(of: scale) { _, new in
            let zoomed = new > Self.zoomThreshold
            if zoomed != isZoomed { isZoomed = zoomed }
        }
    }

    private var magnification: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(1, committedScale * value.magnification), maxScale)
            }
            .onEnded { _ in
                committedScale = scale
                if scale <= Self.zoomThreshold { reset() }
            }
    }

    private func pan(in size: CGSize) -> some Gesture {
        let direction: CGFloat = dragMovesPage ? 1 : -1
        return DragGesture()
            .onChanged { value in
                offset = clamp(CGSize(width: committedOffset.width + direction * value.translation.width,
                                      height: committedOffset.height + direction * value.translation.height), in: size)
            }
            .onEnded { _ in committedOffset = offset }
    }

    /// Keeps the page from being dragged off screen entirely.
    private func clamp(_ proposed: CGSize, in size: CGSize) -> CGSize {
        let limitX = max(0, (size.width * scale - size.width) / 2)
        let limitY = max(0, (size.height * scale - size.height) / 2)
        return CGSize(width: min(max(proposed.width, -limitX), limitX),
                      height: min(max(proposed.height, -limitY), limitY))
    }

    private func toggleZoom() {
        if scale > Self.zoomThreshold {
            reset()
        } else {
            scale = 2.5
            committedScale = 2.5
        }
    }

    private func reset() {
        scale = 1
        committedScale = 1
        offset = .zero
        committedOffset = .zero
        if isZoomed { isZoomed = false }
    }
}
