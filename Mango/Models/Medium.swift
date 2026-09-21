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

    var emptyMessage: String {
        switch self {
        case .manga: "Add a folder or a NAS share in Sources, or drop .cbz files into Mango's folder in the Files app."
        case .novels: "Drop .epub files into Mango's folder in the Files app, or point Mango at a folder that has some."
        }
    }
}
