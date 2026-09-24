import SwiftUI

/// Relative offsets preserve the same part of a page across viewport sizes.
struct PageZoom: Equatable {
    var scale: CGFloat = 1
    var x: CGFloat = 0
    var y: CGFloat = 0

    func offset(in size: CGSize) -> CGSize {
        let limit = max(0, (scale - 1) / 2)
        return CGSize(width: min(max(x, -limit), limit) * size.width,
                      height: min(max(y, -limit), limit) * size.height)
    }
}

/// Pinch-to-zoom and pan for one page, with double-tap to toggle between fit and 2.5×.
///
/// Reports its zoom state upward: while a page is zoomed in, the pager has to stop claiming
/// horizontal drags or panning across the page is impossible.
///
/// The active page can share a normalized zoom with the next page for this reading session.
struct ZoomableView<Content: View>: View {
    var resetToken: AnyHashable
    var maxScale: CGFloat = 5
    var panAxes: PanAxes = .standard
    @Binding var isZoomed: Bool
    var active: Bool
    var locksZoom: Bool
    @Binding var retainedZoom: PageZoom
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
                .onAppear { restore(in: geometry.size) }
                .onChange(of: active) { _, _ in restore(in: geometry.size) }
                .onChange(of: locksZoom) { _, locked in
                    guard active else { return }
                    if locked { remember(in: geometry.size) } else { reset() }
                }
                .onChange(of: geometry.size) { _, size in restore(in: size) }
                .onChange(of: scale) { _, _ in remember(in: geometry.size) }
                .onChange(of: offset) { _, _ in remember(in: geometry.size) }
        }
        .onChange(of: resetToken) { reset() }
        .onChange(of: scale) { _, new in
            let zoomed = new > Self.zoomThreshold
            if active, zoomed != isZoomed { isZoomed = zoomed }
        }
    }

    private func remember(in size: CGSize) {
        guard active, locksZoom, size.width > 0, size.height > 0 else { return }
        retainedZoom = PageZoom(scale: scale, x: offset.width / size.width, y: offset.height / size.height)
    }

    private func restore(in size: CGSize) {
        guard active else { return }
        if locksZoom {
            scale = retainedZoom.scale
            committedScale = scale
            offset = retainedZoom.offset(in: size)
            committedOffset = offset
            isZoomed = scale > Self.zoomThreshold
        } else { reset() }
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
        DragGesture()
            .onChanged { value in
                offset = clamp(panAxes.offset(from: committedOffset, translation: value.translation), in: size)
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
        if active, isZoomed { isZoomed = false }
    }
}
