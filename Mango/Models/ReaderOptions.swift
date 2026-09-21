import CoreGraphics
import Foundation

/// Which way the pages turn. Manga is right-to-left; western comics and most webtoons are not.
enum ReadingDirection: String, Codable, CaseIterable, Sendable {
    case rightToLeft
    case leftToRight

    var label: String {
        switch self {
        case .rightToLeft: "Right to left (manga)"
        case .leftToRight: "Left to right"
        }
    }

    var shortLabel: String {
        switch self {
        case .rightToLeft: "RTL"
        case .leftToRight: "LTR"
        }
    }

    var systemImage: String {
        switch self {
        case .rightToLeft: "arrow.left"
        case .leftToRight: "arrow.right"
        }
    }
}

/// How pages are laid out.
enum ReaderMode: String, Codable, CaseIterable, Sendable {
    /// One page (or spread) at a time, swiped sideways.
    case paged
    /// Vertical scroll with no gaps — how webtoons are meant to be read.
    case continuous

    var label: String {
        switch self {
        case .paged: "Paged"
        case .continuous: "Continuous scroll"
        }
    }

    var systemImage: String {
        switch self {
        case .paged: "book.pages"
        case .continuous: "arrow.down.doc"
        }
    }
}

/// How a page is sized to the screen before the reader zooms it.
enum PageFit: String, Codable, CaseIterable, Sendable {
    case screen
    case width
    case height

    var label: String {
        switch self {
        case .screen: "Fit screen"
        case .width: "Fit width"
        case .height: "Fit height"
        }
    }
}

/// A tint over the page, for reading in the dark or on paper-white glare. Display only — the
/// pages themselves are never changed.
enum PageFilter: String, Codable, CaseIterable, Sendable {
    case none
    /// Warm, like newsprint — easier on the eyes than paper white.
    case sepia
    /// The whole page darker, below what the screen's own brightness goes down to.
    case dim
    /// Black and white swapped (hues kept), for reading in bed with the lights off.
    case night

    var label: String {
        switch self {
        case .none: "None"
        case .sepia: "Sepia"
        case .dim: "Dim"
        case .night: "Night (inverted)"
        }
    }
}

/// Whether to pair pages into a two-page spread, the way a physical book falls open.
enum SpreadMode: String, Codable, CaseIterable, Sendable {
    /// Pair them when the screen is wider than it is tall. The sane default.
    case auto
    case always
    case never

    var label: String {
        switch self {
        case .auto: "Automatic (landscape only)"
        case .always: "Always"
        case .never: "Never"
        }
    }
}

/// Which way a zoomed page moves under your finger, on one axis.
///
/// There is no right answer — a map pans one way, a photo drags the other — and the two axes
/// genuinely pull in different directions: sideways feels like a pager, downwards feels like
/// scrolling a document. So each axis is its own choice.
enum PanDirection: String, Codable, CaseIterable, Sendable {
    /// Drag right and you see what was off to the right. The page appears to move the
    /// opposite way, like panning across a map.
    case movesView
    /// The page follows your finger, like sliding a photo around a table.
    case movesPage

    var title: String {
        switch self {
        case .movesView: "Moves the view"
        case .movesPage: "Moves the page"
        }
    }

    var explanation: String {
        switch self {
        case .movesView: "Drag right to see what's off to the right, like panning across a map."
        case .movesPage: "The page follows your finger, like sliding a photo around."
        }
    }

    /// +1 follows the finger, -1 moves the viewport instead.
    var sign: CGFloat { self == .movesPage ? 1 : -1 }
}

/// The pair of choices, and the arithmetic that applies them. Pure so the signs are testable
/// without a gesture.
struct PanAxes: Equatable, Sendable {
    var horizontal: PanDirection
    var vertical: PanDirection

    /// Defaults land where Adam settled: sideways moves the view, downwards moves the page.
    static let standard = PanAxes(horizontal: .movesView, vertical: .movesPage)

    func offset(from committed: CGSize, translation: CGSize) -> CGSize {
        CGSize(width: committed.width + horizontal.sign * translation.width,
               height: committed.height + vertical.sign * translation.height)
    }
}
