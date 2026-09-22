import Foundation
import os

/// iCloud key-value storage for the little that's worth having on every device: where you are
/// in each book, and (as they're added) ratings, bookmarks and the reading log.
///
/// Key-value storage, not CloudKit: it's the user's own iCloud, there's no schema or server of
/// ours, and a JSON blob per kind of thing fits comfortably. No-ops when the entitlement is
/// missing — the app still works, it just doesn't sync.
@MainActor
final class CloudSync {
    enum Key: String, CaseIterable {
        case progress = "progress.v1"
        /// syncKey → stars, no dates: a cleared rating came back from it. Read until `ratingsV2`
        /// exists, never written.
        case ratings = "ratings.v1"
        /// syncKey → the latest set or clear, with its time.
        case ratingsV2 = "ratings.v2"
        case bookmarks = "bookmarks.v1"
        /// Bookmark id → when it was deleted, so a deletion reaches every device.
        case deletedBookmarks = "bookmarks.deleted.v1"
        case readingLog = "readinglog.v1"
        /// Device ID → that device's day totals. Each device writes only its own slot, so
        /// adding them up never double-counts.
        case activity = "activity.v1"
        /// syncKey → the newest cover choice for that file (a Find Cover URL, or back to page one).
        case covers = "covers.v1"
    }

    private let store = NSUbiquitousKeyValueStore.default
    /// KVS caps a single value at about 1 MB; stay well clear of it.
    private static let maxBytes = 900_000
    private var observer: (any NSObjectProtocol)?

    /// Another device changed something.
    var onExternalChange: (() -> Void)?

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store, queue: .main
        ) { [weak self] note in
            let reason = (note.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int) ?? -1
            Logger.store.info("[cloud] external change (reason \(reason))")
            MainActor.assumeIsolated { self?.onExternalChange?() }
        }
        let ok = store.synchronize()
        Logger.store.info("[cloud] started, synchronize=\(ok)")
    }

    func load<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        guard let data = store.data(forKey: key.rawValue) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            Logger.store.error("[cloud] \(key.rawValue, privacy: .public) undecodable (\(data.count)B): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func save<T: Encodable>(_ value: T, _ key: Key) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        guard data.count <= Self.maxBytes else {
            Logger.store.error("[cloud] \(key.rawValue, privacy: .public) is \(data.count)B, over the KVS limit — not syncing")
            return
        }
        // Skip identical writes: every page turn saves, and KVS rate-limits chatty apps.
        if store.data(forKey: key.rawValue) == data { return }
        store.set(data, forKey: key.rawValue)
        store.synchronize()
    }
}
