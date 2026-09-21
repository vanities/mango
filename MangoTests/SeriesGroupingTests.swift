import XCTest
@testable import Mango

/// Shelves that belong together — JoJo's parts, the Mushoku Tensei novels — become one stack.
final class SeriesGroupingTests: XCTestCase {
    private func shelf(_ name: String, novel: Bool = false) -> Series {
        let comic = Comic(id: name, sourceID: UUID(), relativePath: "\(name)/1.\(novel ? "epub" : "cbz")",
                          kind: novel ? .epub : .archive, title: name, series: name, volume: 1, chapter: nil,
                          author: nil, year: nil, subtitle: nil, pageCount: nil, totalBytes: 1, addedAt: Date(), coverID: nil)
        return Series(id: SeriesGrouper.key(for: comic), name: name, comics: [comic])
    }

    private func names(_ items: [ShelfItem]) -> [String] {
        items.map { item in
            switch item {
            case .series(let series): series.name
            case .group(let group): "[\(group.name): \(group.members.map(\.name).joined(separator: " | "))]"
            }
        }
    }

    /// Adam's JoJo: three parts named for the series, three named only "Part N - …".
    func testJoJosPartsBecomeOneStackInPartOrder() {
        let shelves = [
            shelf("Berserk"),
            shelf("JoJo's Bizarre Adventure Part 1 - Phantom Blood Full Color"),
            shelf("Part 2 - Battle Tendency"),
            shelf("JoJo's Bizarre Adventure Part 3 - Stardust Crusaders Full Color"),
            shelf("JoJo's Bizarre Adventure Part 4 - Diamond is Unbreakable Full Color"),
            shelf("Part 5 - Vento Aureo"),
            shelf("Part 7 - Steel Ball Run"),
        ]
        let items = SeriesGrouping.arrange(shelves, manual: [:])
        XCTAssertEqual(items.count, 2)
        guard case .group(let jojo) = items[1] else { return XCTFail("\(names(items))") }
        XCTAssertEqual(jojo.name, "JoJo's Bizarre Adventure")
        XCTAssertEqual(jojo.members.map(\.name), [
            "JoJo's Bizarre Adventure Part 1 - Phantom Blood Full Color", "Part 2 - Battle Tendency",
            "JoJo's Bizarre Adventure Part 3 - Stardust Crusaders Full Color",
            "JoJo's Bizarre Adventure Part 4 - Diamond is Unbreakable Full Color", "Part 5 - Vento Aureo",
            "Part 7 - Steel Ball Run",
        ])
    }

    /// Named the AniList way after Look Up Series, they group the same.
    func testLookedUpNamesGroupToo() {
        let items = SeriesGrouping.arrange([
            shelf("JoJo's Bizarre Adventure Part 5: Golden Wind"),
            shelf("JoJo's Bizarre Adventure Part 6: Stone Ocean"),
        ], manual: [:])
        XCTAssertEqual(names(items), ["[JoJo's Bizarre Adventure: JoJo's Bizarre Adventure Part 5: Golden Wind | JoJo's Bizarre Adventure Part 6: Stone Ocean]"])
    }

    func testNovelsSharingAPrefixBecomeOneStack() {
        let items = SeriesGrouping.arrange([
            shelf("Mushoku Tensei - Jobless Reincarnation", novel: true),
            shelf("Mushoku Tensei - Redundant Reincarnation", novel: true),
            shelf("Frieren - Beyond Journey's End", novel: true),
        ], manual: [:])
        XCTAssertEqual(names(items), [
            "[Mushoku Tensei: Mushoku Tensei - Jobless Reincarnation | Mushoku Tensei - Redundant Reincarnation]",
            "Frieren - Beyond Journey's End",
        ])
    }

    /// One shelf is never a group, and a lone "Part 2 - …" has nothing to join.
    func testNothingGroupsAlone() {
        XCTAssertEqual(names(SeriesGrouping.arrange([shelf("Frieren - Beyond Journey's End"), shelf("Part 2 - Something")],
                                                    manual: [:])),
                       ["Frieren - Beyond Journey's End", "Part 2 - Something"])
    }

    /// With two numbered franchises, a bare "Part 2 - …" could be either: it stays out.
    func testAnAmbiguousPartStaysOut() {
        let items = SeriesGrouping.arrange([
            shelf("JoJo's Bizarre Adventure Part 1 - Phantom Blood"), shelf("JoJo's Bizarre Adventure Part 3 - Stardust Crusaders"),
            shelf("Gantz Part 1"), shelf("Gantz Part 2"), shelf("Part 4 - Mystery"),
        ], manual: [:])
        XCTAssertTrue(names(items).contains("Part 4 - Mystery"))
        XCTAssertEqual(items.count, 3)
    }

    /// A bare part whose number the franchise already has is a different series.
    func testATakenPartNumberStaysOut() {
        let items = SeriesGrouping.arrange([
            shelf("JoJo's Bizarre Adventure Part 1 - Phantom Blood"), shelf("JoJo's Bizarre Adventure Part 2 - Battle Tendency"),
            shelf("Part 2 - Something Else"),
        ], manual: [:])
        XCTAssertTrue(names(items).contains("Part 2 - Something Else"))
    }

    func testInsideAStackMembersDropTheStacksName() {
        XCTAssertEqual(SeriesGrouping.shortName(of: "JoJo's Bizarre Adventure Part 1 - Phantom Blood",
                                                in: "JoJo's Bizarre Adventure"), "Part 1 - Phantom Blood")
        XCTAssertEqual(SeriesGrouping.shortName(of: "JoJo's Bizarre Adventure Part 6: Stone Ocean",
                                                in: "JoJo's Bizarre Adventure"), "Part 6: Stone Ocean")
        XCTAssertEqual(SeriesGrouping.shortName(of: "Part 2 - Battle Tendency", in: "JoJo's Bizarre Adventure"),
                       "Part 2 - Battle Tendency")
        XCTAssertEqual(SeriesGrouping.shortName(of: "Mushoku Tensei - Jobless Reincarnation", in: "Mushoku Tensei"),
                       "Jobless Reincarnation")
        XCTAssertEqual(SeriesGrouping.shortName(of: "Berserk", in: "Berserk"), "Berserk")
    }

    func testTheUsersChoiceWins() {
        let berserk = shelf("Berserk"), gantz = shelf("Gantz"), jobless = shelf("Mushoku Tensei - Jobless Reincarnation")
        let redundant = shelf("Mushoku Tensei - Redundant Reincarnation")
        let items = SeriesGrouping.arrange([berserk, gantz, jobless, redundant], manual: [
            berserk.id: "Dark Fantasy", gantz.id: "Dark Fantasy", redundant.id: "",
        ])
        XCTAssertEqual(names(items), ["[Dark Fantasy: Berserk | Gantz]", "Mushoku Tensei - Jobless Reincarnation",
                                      "Mushoku Tensei - Redundant Reincarnation"],
                       "a shelf taken out of its group leaves the other alone")
    }
}
