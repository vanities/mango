import Foundation

/// The two things Mango reads. They share a library and a NAS and almost nothing else:
/// one is a sequence of page images, the other is reflowable text.
enum Medium: String, CaseIterable, Codable, Sendable {
    case manga
    case novels

    var title: String {
        switch self {
        case .manga: "Manga"
        case .novels: "Novels"
        }
    }

    var systemImage: String {
        switch self {
        case .manga: "book.pages"
        case .novels: "text.book.closed"
        }
    }

    /// The shelf the Library shows when `chosen` is picked. The switch between the two only
    /// appears once both have books, so a library of nothing but light novels would otherwise
    /// open on an empty Manga shelf with no way over to the novels.
    static func shown(chosen: Medium, hasComics: Bool, hasNovels: Bool) -> Medium {
        switch (hasComics, hasNovels) {
        case (false, true): .novels
        case (true, false): .manga
        default: chosen
        }
    }

    var emptyMessage: String {
        switch self {
        case .manga: "Add a folder or a NAS share in Sources, or drop .cbz files into Mango's folder in the Files app."
        case .novels: "Drop .epub files into Mango's folder in the Files app, or point Mango at a folder that has some."
        }
    }
}
