import Foundation

/// A temporary reveal, deliberately kept out of LibraryState and UserDefaults.
struct HiddenContentSession: Sendable {
    static let inactivityLimit: TimeInterval = 3 * 60 * 60
    private(set) var lastActivity: Date?
    var isUnlocked: Bool { lastActivity != nil }

    mutating func unlock(at now: Date = .now) { lastActivity = now }
    mutating func lock() { lastActivity = nil }

    /// Check before recording activity so returning after the deadline cannot revive a reveal.
    @discardableResult
    mutating func expire(at now: Date = .now) -> Bool {
        guard let lastActivity, now.timeIntervalSince(lastActivity) >= Self.inactivityLimit else { return false }
        lock()
        return true
    }

    mutating func recordActivity(at now: Date = .now) {
        guard !expire(at: now), isUnlocked else { return }
        lastActivity = now
    }
}
