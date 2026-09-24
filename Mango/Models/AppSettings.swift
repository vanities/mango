import Foundation
import Observation
import ShelfKit

enum LibrarySort: String, CaseIterable, Codable, Sendable {
    case recent, title, lastRead

    var title: String {
        switch self {
        case .recent: "Recently added"
        case .title: "Title"
        case .lastRead: "Last read"
        }
    }
}

enum LibraryLayout: String, CaseIterable, Codable, Sendable {
    case grid, list

    var systemImage: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .list: "list.bullet"
        }
    }
}

/// User preferences, backed by UserDefaults so they survive reinstalls via iCloud backup.
/// Per-comic overrides (a western comic in a manga library) live in `LibraryState.readerOverrides`.
@MainActor @Observable
final class AppSettings {
    static let prefetchChoices = [1, 2, 3, 5, 8]

    @ObservationIgnored private let defaults: UserDefaults

    /// Manga is right-to-left, and this app is called Mango, so that is the default.
    var defaultDirection: ReadingDirection { didSet { defaults.set(defaultDirection.rawValue, forKey: Key.direction) } }
    var defaultMode: ReaderMode { didSet { defaults.set(defaultMode.rawValue, forKey: Key.mode) } }
    var pageFit: PageFit { didSet { defaults.set(pageFit.rawValue, forKey: Key.fit) } }
    var spreadMode: SpreadMode { didSet { defaults.set(spreadMode.rawValue, forKey: Key.spread) } }
    /// How many pages to decode ahead of the one on screen. Costs memory, buys instant turns.
    var prefetchCount: Int { didSet { defaults.set(prefetchCount, forKey: Key.prefetch) } }
    /// Which way a zoomed page moves under your finger. Separate per axis — sideways and
    /// downwards genuinely want different answers.
    var horizontalPan: PanDirection { didSet { defaults.set(horizontalPan.rawValue, forKey: Key.horizontalPan) } }
    var verticalPan: PanDirection { didSet { defaults.set(verticalPan.rawValue, forKey: Key.verticalPan) } }

    var panAxes: PanAxes { PanAxes(horizontal: horizontalPan, vertical: verticalPan) }
    /// Tapping the left/right thirds of the screen turns the page.
    var tapToTurn: Bool { didSet { defaults.set(tapToTurn, forKey: Key.tapToTurn) } }
    /// Keep the screen on while reading. People read slower than the 30s auto-lock.
    var keepScreenAwake: Bool { didSet { defaults.set(keepScreenAwake, forKey: Key.keepAwake) } }
    /// Black background behind pages instead of the system one — less halo in the dark.
    var blackBackground: Bool { didSet { defaults.set(blackBackground, forKey: Key.blackBg) } }
    /// Cut plain white or black scan borders so the art fills the screen (paged reading).
    var cropMargins: Bool { didSet { defaults.set(cropMargins, forKey: Key.cropMargins) } }
    /// Face ID (or the passcode) to open Mango, and how long it may sit in the background first.
    var lockMode: LockMode { didSet { defaults.set(lockMode.rawValue, forKey: Key.lockMode) } }
    /// Delete a volume's download once it's read to the end, when it's still on the NAS.
    var removeFinishedDownloads: Bool { didSet { defaults.set(removeFinishedDownloads, forKey: Key.removeFinished) } }
    var pageFilter: PageFilter { didSet { defaults.set(pageFilter.rawValue, forKey: Key.pageFilter) } }
    /// Volumes a year to aim for, drawn as a ring on Stats. 0 hides it.
    var yearlyGoal: Int { didSet { defaults.set(yearlyGoal, forKey: Key.yearlyGoal) } }
    /// Identifies this device's slot in the synced activity totals. Stable across launches.
    @ObservationIgnored let deviceID: String
    /// Light-novel typography and navigation, saved on this device.
    var novelFont: NovelFont { didSet { defaults.set(novelFont.rawValue, forKey: "reader.novelFont") } }
    var novelLineSpacing: Double { didSet { defaults.set(novelLineSpacing, forKey: "reader.novelLineSpacing") } }
    var novelMargin: Double { didSet { defaults.set(novelMargin, forKey: "reader.novelMargin") } }
    var novelPaged: Bool { didSet { defaults.set(novelPaged, forKey: "reader.novelPaged") } }
    var novelFontScale: Double { didSet { defaults.set(novelFontScale, forKey: Key.novelFontScale) } }
    var librarySort: LibrarySort { didSet { defaults.set(librarySort.rawValue, forKey: Key.sort) } }
    var libraryLayout: LibraryLayout { didSet { defaults.set(libraryLayout.rawValue, forKey: Key.layout) } }
    var showFinished: Bool { didSet { defaults.set(showFinished, forKey: Key.showFinished) } }
    /// Scan only the app's own folder and ignore every share and picked folder, so the app can
    /// be photographed with a generated library instead of someone's real one. Set it here or
    /// pass `-MangoDemoMode YES` at launch; either way the user's sources are left untouched,
    /// just unscanned.
    var demoMode: Bool { didSet { defaults.set(demoMode, forKey: Key.demoMode) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaultDirection = ReadingDirection(rawValue: defaults.string(forKey: Key.direction) ?? "") ?? .rightToLeft
        defaultMode = ReaderMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .paged
        pageFit = PageFit(rawValue: defaults.string(forKey: Key.fit) ?? "") ?? .screen
        spreadMode = SpreadMode(rawValue: defaults.string(forKey: Key.spread) ?? "") ?? .auto
        prefetchCount = defaults.object(forKey: Key.prefetch) as? Int ?? 3
        // Carried over from the earlier single-axis setting, and before that a boolean, so an
        // existing choice isn't silently reset. Only the horizontal axis inherits it — the
        // vertical default changed deliberately.
        let legacyMovesPage = defaults.object(forKey: Key.legacyDragMovesPage) as? Bool
        let legacyAxis = PanDirection(rawValue: defaults.string(forKey: Key.legacySingleAxis) ?? "")
            ?? (legacyMovesPage == true ? .movesPage : nil)
        horizontalPan = PanDirection(rawValue: defaults.string(forKey: Key.horizontalPan) ?? "")
            ?? legacyAxis ?? PanAxes.standard.horizontal
        verticalPan = PanDirection(rawValue: defaults.string(forKey: Key.verticalPan) ?? "")
            ?? PanAxes.standard.vertical
        tapToTurn = defaults.object(forKey: Key.tapToTurn) as? Bool ?? true
        keepScreenAwake = defaults.object(forKey: Key.keepAwake) as? Bool ?? true
        blackBackground = defaults.object(forKey: Key.blackBg) as? Bool ?? true
        cropMargins = defaults.object(forKey: Key.cropMargins) as? Bool ?? false
        lockMode = LockMode(rawValue: defaults.string(forKey: Key.lockMode) ?? "") ?? .off
        removeFinishedDownloads = defaults.object(forKey: Key.removeFinished) as? Bool ?? false
        pageFilter = PageFilter(rawValue: defaults.string(forKey: Key.pageFilter) ?? "") ?? .none
        novelFont = NovelFont(rawValue: defaults.string(forKey: "reader.novelFont") ?? "") ?? .book
        novelLineSpacing = defaults.object(forKey: "reader.novelLineSpacing") as? Double ?? 1.6
        novelMargin = defaults.object(forKey: "reader.novelMargin") as? Double ?? 22
        novelPaged = defaults.object(forKey: "reader.novelPaged") as? Bool ?? true
        novelFontScale = defaults.object(forKey: Key.novelFontScale) as? Double ?? 1.0
        yearlyGoal = defaults.object(forKey: Key.yearlyGoal) as? Int ?? 50
        if let existing = defaults.string(forKey: Key.deviceID) {
            deviceID = existing
        } else {
            let fresh = UUID().uuidString
            defaults.set(fresh, forKey: Key.deviceID)
            deviceID = fresh
        }
        librarySort = LibrarySort(rawValue: defaults.string(forKey: Key.sort) ?? "") ?? .recent
        libraryLayout = LibraryLayout(rawValue: defaults.string(forKey: Key.layout) ?? "") ?? .grid
        showFinished = defaults.object(forKey: Key.showFinished) as? Bool ?? true
        // A launch argument writes straight into UserDefaults, so this covers both routes.
        demoMode = defaults.object(forKey: Key.demoMode) as? Bool ?? false
    }

    private enum Key {
        static let direction = "reader.direction"
        static let mode = "reader.mode"
        static let fit = "reader.pageFit"
        static let spread = "reader.spreadMode"
        static let prefetch = "reader.prefetchCount"
        static let horizontalPan = "reader.horizontalPan"
        static let verticalPan = "reader.verticalPan"
        static let legacySingleAxis = "reader.panDirection"
        static let legacyDragMovesPage = "reader.dragMovesPage"
        static let tapToTurn = "reader.tapToTurn"
        static let keepAwake = "reader.keepScreenAwake"
        static let blackBg = "reader.blackBackground"
        static let cropMargins = "reader.cropMargins"
        static let lockMode = "privacy.lockMode"
        static let removeFinished = "downloads.removeFinished"
        static let pageFilter = "reader.pageFilter"
        static let novelFontScale = "reader.novelFontScale"
        static let yearlyGoal = "stats.yearlyGoal"
        static let deviceID = "sync.deviceID"
        static let sort = "library.sort"
        static let layout = "library.layout"
        static let showFinished = "library.showFinished"
        static let demoMode = "MangoDemoMode"
    }
}

/// The lock (ShelfKit's `AppLock`) reads and saves its mode here, under `privacy.lockMode`.
extension AppSettings: LockSettings {}
