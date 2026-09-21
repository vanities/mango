import Foundation

/// Shelves that belong together — JoJo's parts, the Mushoku Tensei novels — shown as one stack.
struct SeriesGroup: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    /// In reading order: by part number when the names have one, else by name.
    var members: [Series]

    var isNovel: Bool { members.first?.isNovel ?? false }
    var volumeCount: Int { members.reduce(0) { $0 + $1.volumeCount } }
}

/// One thing in the library grid: a shelf, or a stack of them.
enum ShelfItem: Identifiable, Hashable, Sendable {
    case series(Series)
    case group(SeriesGroup)

    var id: String {
        switch self {
        case .series(let series): series.id
        case .group(let group): group.id
        }
    }
}

/// Decides which shelves stack together. Pure, so the rules are tested on real names.
///
/// - **Parts**: "JoJo's Bizarre Adventure Part 4 - Diamond is Unbreakable" is part 4 of JoJo's
///   Bizarre Adventure. A shelf named only "Part 2 - Battle Tendency" joins the one franchise in
///   the library that numbers its parts, unless that franchise already has a part 2 — with two
///   such franchises it could be either, so it stays out.
/// - **Shared prefix**: "Mushoku Tensei - Jobless Reincarnation" and "Mushoku Tensei - Redundant
///   Reincarnation" stack as Mushoku Tensei. A prefix only one shelf has is just a name.
/// - The user's choice (`manual`: shelf id → group name, "" for "not in a group") always wins.
///
/// A group needs two shelves. Call it per medium: manga and novels never share a stack.
enum SeriesGrouping {
    static let groupPrefix = "group|"

    /// "JoJo's Bizarre Adventure Part 4 - Diamond is Unbreakable" → ("JoJo's Bizarre Adventure", 4);
    /// "Part 2 - Battle Tendency" → ("", 2).
    static func part(of name: String) -> (franchise: String, part: Double)? {
        let pattern = #"(?i)^(.*?)\s*\bpart\s+(\d{1,3}(?:\.\d+)?)\b\s*(?:[:\-–,]\s*.*)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let franchiseRange = Range(match.range(at: 1), in: name),
              let partRange = Range(match.range(at: 2), in: name),
              let part = Double(name[partRange])
        else { return nil }
        let franchise = String(name[franchiseRange]).trimmingCharacters(in: CharacterSet(charactersIn: " -–:,"))
        return (franchise, part)
    }

    /// "Mushoku Tensei - Jobless Reincarnation" → "Mushoku Tensei".
    static func prefix(of name: String) -> String? {
        guard let range = name.range(of: #"\s+[-–]\s+"#, options: .regularExpression) else { return nil }
        let prefix = String(name[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        return prefix.isEmpty ? nil : prefix
    }

    /// A member's name inside its stack, without the stack's name in front: in "JoJo's Bizarre
    /// Adventure", "JoJo's Bizarre Adventure Part 1 - Phantom Blood" reads "Part 1 - Phantom Blood".
    static func shortName(of member: String, in group: String) -> String {
        guard member.count > group.count, member.lowercased().hasPrefix(group.lowercased()) else { return member }
        let rest = member.dropFirst(group.count).trimmingCharacters(in: CharacterSet(charactersIn: " -–:,"))
        return rest.isEmpty ? member : rest
    }

    static func groupID(name: String, isNovel: Bool) -> String {
        groupPrefix + (isNovel ? "novel|" : "comic|") + SeriesGrouper.key(forName: name)
    }

    /// Stacks what belongs together; everything else stays a shelf. Groups take the place of
    /// their first member, so the library's sort order holds.
    static func arrange(_ shelves: [Series], manual: [String: String]) -> [ShelfItem] {
        struct Assignment { var name: String; var part: Double? }
        var assigned: [String: Assignment] = [:]
        var parts: [String: [(id: String, name: String, part: Double)]] = [:]
        var orphans: [(id: String, part: Double)] = []
        var prefixes: [String: [(id: String, name: String)]] = [:]

        for shelf in shelves {
            if let chosen = manual[shelf.id] {
                if !chosen.isEmpty { assigned[shelf.id] = Assignment(name: chosen, part: part(of: shelf.name)?.part) }
                continue
            }
            if let found = part(of: shelf.name) {
                if found.franchise.isEmpty {
                    orphans.append((shelf.id, found.part))
                } else {
                    parts[SeriesGrouper.key(forName: found.franchise), default: []].append((shelf.id, found.franchise, found.part))
                }
            } else if let found = prefix(of: shelf.name) {
                prefixes[SeriesGrouper.key(forName: found), default: []].append((shelf.id, found))
            } else {
                // A shelf named just "Mushoku Tensei" belongs with "Mushoku Tensei - …".
                prefixes[SeriesGrouper.key(forName: shelf.name), default: []].append((shelf.id, shelf.name))
            }
        }

        // A bare "Part N - …" joins the one numbered franchise, if its N is free there.
        if parts.count == 1, let (key, members) = parts.first {
            let taken = Set(members.map(\.part))
            for orphan in orphans where !taken.contains(orphan.part) {
                parts[key, default: []].append((orphan.id, members[0].name, orphan.part))
            }
        }
        for members in parts.values where members.count >= 2 {
            for member in members { assigned[member.id] = Assignment(name: members[0].name, part: member.part) }
        }
        for members in prefixes.values where members.count >= 2 {
            let name = members.first { prefix(of: $0.name) == nil }?.name ?? members[0].name
            for member in members where assigned[member.id] == nil { assigned[member.id] = Assignment(name: name, part: nil) }
        }

        // Build the stacks, then lay the grid out in the shelves' own order.
        var groups: [String: SeriesGroup] = [:]
        var orderInGroup: [String: Double] = [:]
        for shelf in shelves {
            guard let assignment = assigned[shelf.id] else { continue }
            let id = groupID(name: assignment.name, isNovel: shelf.isNovel)
            groups[id, default: SeriesGroup(id: id, name: assignment.name, members: [])].members.append(shelf)
            orderInGroup[shelf.id] = assignment.part ?? .infinity
        }
        for (id, group) in groups {
            groups[id]?.members = group.members.sorted { lhs, rhs in
                let (left, right) = (orderInGroup[lhs.id] ?? .infinity, orderInGroup[rhs.id] ?? .infinity)
                if left != right { return left < right }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
        var items: [ShelfItem] = []
        var placed = Set<String>()
        for shelf in shelves {
            if let assignment = assigned[shelf.id],
               let group = groups[groupID(name: assignment.name, isNovel: shelf.isNovel)], group.members.count >= 2 {
                if placed.insert(group.id).inserted { items.append(.group(group)) }
            } else {
                items.append(.series(shelf))
            }
        }
        return items
    }
}
