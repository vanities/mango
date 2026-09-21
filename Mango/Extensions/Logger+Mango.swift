import Foundation
import os

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.vanities.mango"

    static let library = Logger(subsystem: subsystem, category: "library")
    static let scan = Logger(subsystem: subsystem, category: "scan")
    static let archive = Logger(subsystem: subsystem, category: "archive")
    static let pages = Logger(subsystem: subsystem, category: "pages")
    static let reader = Logger(subsystem: subsystem, category: "reader")
    static let cover = Logger(subsystem: subsystem, category: "cover")
    static let bookmarks = Logger(subsystem: subsystem, category: "bookmarks")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let nas = Logger(subsystem: subsystem, category: "nas")
    static let downloads = Logger(subsystem: subsystem, category: "downloads")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}

/// Cheap elapsed-time helper for log lines: `let sw = Stopwatch(); ...; sw.ms`.
struct Stopwatch: Sendable {
    let start = Date()
    var seconds: TimeInterval { Date().timeIntervalSince(start) }
    var ms: Double { seconds * 1000 }
}
