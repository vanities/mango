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


/// Which way a zoomed page moves under your finger.
///
/// There is no right answer — a map pans one way, a photo drags the other — so it's a choice
/// rather than a default someone has to live with.
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
