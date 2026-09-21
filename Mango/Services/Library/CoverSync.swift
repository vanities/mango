import Foundation

/// A cover picked on one device, as the others learn of it: where it came from (so they can
/// fetch the same image) and when, so the newest choice wins. Keyed by the comic's file
/// (`Comic.syncKey`), which is what matches across devices.
struct CoverChoice: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// A Find Cover pick: every device fetches the same URL.
        case online
        /// Back to page one.
        case original
        /// From Photos or Files — nothing to fetch elsewhere, so other devices keep their own.
        case device
    }

    var kind: Kind
    var url: String?
    var chosenAt: Date

    static func online(_ url: String, at date: Date = .now) -> CoverChoice { CoverChoice(kind: .online, url: url, chosenAt: date) }
    static func original(at date: Date = .now) -> CoverChoice { CoverChoice(kind: .original, url: nil, chosenAt: date) }
    static func device(at date: Date = .now) -> CoverChoice { CoverChoice(kind: .device, url: nil, chosenAt: date) }
}

/// Newest choice per file wins, both ways. Pure, so the rules are tested.
enum CoverSync {
    /// Choices another device made after this one last applied anything for that file.
    static func pending(cloud: [String: CoverChoice], applied: [String: CoverChoice]) -> [String: CoverChoice] {
        cloud.filter { key, choice in choice.chosenAt > (applied[key]?.chosenAt ?? .distantPast) }
    }

    /// What goes up: the cloud's choices, with this device's newer ones laid over them.
    static func snapshot(local: [String: CoverChoice], cloud: [String: CoverChoice]) -> [String: CoverChoice] {
        var out = cloud
        for (key, choice) in local where choice.chosenAt > (cloud[key]?.chosenAt ?? .distantPast) { out[key] = choice }
        return out
    }
}
