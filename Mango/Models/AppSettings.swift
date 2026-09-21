import Foundation
import Observation
import SwiftUI

/// Force an appearance regardless of the phone's. Reading at night with the system in light
/// mode is a real thing, so this is worth having rather than deferring to iOS.
enum AppearanceMode: String, CaseIterable, Codable, Sendable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: "Match system"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

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
    /// Tapping the left/right thirds of the screen turns the page.
    var tapToTurn: Bool { didSet { defaults.set(tapToTurn, forKey: Key.tapToTurn) } }
    /// Keep the screen on while reading. People read slower than the 30s auto-lock.
    var keepScreenAwake: Bool { didSet { defaults.set(keepScreenAwake, forKey: Key.keepAwake) } }
    /// Black background behind pages instead of the system one — less halo in the dark.
    var blackBackground: Bool { didSet { defaults.set(blackBackground, forKey: Key.blackBg) } }
    var librarySort: LibrarySort { didSet { defaults.set(librarySort.rawValue, forKey: Key.sort) } }
    var libraryLayout: LibraryLayout { didSet { defaults.set(libraryLayout.rawValue, forKey: Key.layout) } }
    var showFinished: Bool { didSet { defaults.set(showFinished, forKey: Key.showFinished) } }
    var appearance: AppearanceMode { didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaultDirection = ReadingDirection(rawValue: defaults.string(forKey: Key.direction) ?? "") ?? .rightToLeft
        defaultMode = ReaderMode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .paged
        pageFit = PageFit(rawValue: defaults.string(forKey: Key.fit) ?? "") ?? .screen
        spreadMode = SpreadMode(rawValue: defaults.string(forKey: Key.spread) ?? "") ?? .auto
        prefetchCount = defaults.object(forKey: Key.prefetch) as? Int ?? 3
        tapToTurn = defaults.object(forKey: Key.tapToTurn) as? Bool ?? true
        keepScreenAwake = defaults.object(forKey: Key.keepAwake) as? Bool ?? true
        blackBackground = defaults.object(forKey: Key.blackBg) as? Bool ?? true
        librarySort = LibrarySort(rawValue: defaults.string(forKey: Key.sort) ?? "") ?? .recent
        libraryLayout = LibraryLayout(rawValue: defaults.string(forKey: Key.layout) ?? "") ?? .grid
        showFinished = defaults.object(forKey: Key.showFinished) as? Bool ?? true
        appearance = AppearanceMode(rawValue: defaults.string(forKey: Key.appearance) ?? "") ?? .system
    }

    private enum Key {
        static let direction = "reader.direction"
        static let mode = "reader.mode"
        static let fit = "reader.pageFit"
        static let spread = "reader.spreadMode"
        static let prefetch = "reader.prefetchCount"
        static let tapToTurn = "reader.tapToTurn"
        static let keepAwake = "reader.keepScreenAwake"
        static let blackBg = "reader.blackBackground"
        static let sort = "library.sort"
        static let layout = "library.layout"
        static let showFinished = "library.showFinished"
        static let appearance = "appearance.mode"
    }
}
