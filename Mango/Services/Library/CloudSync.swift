import Foundation
import ShelfKit

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

    /// The rules (skip a write that changes nothing, stay under iCloud's size cap) are
    /// ShelfKit's, shared with Earmark.
    private let store = CloudKeyValueStore()

    /// Another device changed something.
    var onExternalChange: (() -> Void)? {
        get { store.onExternalChange }
        set { store.onExternalChange = newValue }
    }

    func start() {
        store.start()
    }

    func load<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        store.load(type, key: key.rawValue)
    }

    func save<T: Encodable>(_ value: T, _ key: Key) {
        store.save(value, key: key.rawValue)
    }
}
