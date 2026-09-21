import Foundation

/// A place Mango reads comics from. Files are never copied: a source is a
/// security-scoped bookmark to a folder (or single file) the user picked, or the
/// app's own Documents folder ("Mango's folder in Files" in the Files app).
struct LibrarySource: Identifiable, Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// A folder picked in the Files browser (iCloud Drive, On My iPhone, SMB share, other apps).
        case folder
        /// A single comic handed to us via "Open in Mango".
        case file
        /// The app's own Documents directory. Always present, cannot be removed.
        case appDocuments
        /// A folder on an SMB share (NAS). Reads page-by-page on demand; comics can be downloaded locally.
        case smb
    }

    let id: UUID
    var kind: Kind
    var displayName: String
    /// Security-scoped bookmark data. `nil` for `.appDocuments`.
    var bookmark: Data?
    var addedAt: Date
    var lastScanAt: Date?
    var lastScanBookCount: Int?
    var lastScanFileCount: Int?
    /// Archives the last scan found but can't open (RAR, 7z), by extension.
    var lastScanUnreadable: [String: Int]?
    var lastError: String?
    /// For `.smb` sources: the server this folder lives on.
    var serverID: UUID?

    var isRemovable: Bool { kind != .appDocuments }
    var isRemote: Bool { kind == .smb }

    var systemImage: String {
        switch kind {
        case .folder: "folder.fill"
        case .file: "doc.fill"
        case .appDocuments: "iphone"
        case .smb: "externaldrive.connected.to.line.below"
        }
    }
}
