import CryptoKit
import Foundation
import os

/// Size plus a SHA-256 of the first and last 256 KB — Earmark's fingerprint. Fast for hundreds
/// of volumes, and a match means the same file whatever it's called or wherever it sits.
struct ComicFingerprint: Hashable, Sendable {
    var size: Int64
    var digest: String
}

/// One comic in more than one place on this device.
struct DuplicateSet: Identifiable, Hashable, Sendable {
    let id: String
    /// Oldest first — the copy most likely to be the one meant to stay.
    var copies: [Comic]
    /// What deleting every copy but one would free.
    var wastedBytes: Int64
}

/// Finds comics that are on this device more than once. Pure apart from reading the files, so
/// the grouping is tested on its own.
enum DuplicateFinder {
    static let sampleBytes = 256 * 1024

    static func fingerprint(of url: URL) throws -> ComicFingerprint {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory), isDirectory.boolValue {
            return try folderFingerprint(url)
        }
        let size = Int64((try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        hasher.update(data: try handle.read(upToCount: sampleBytes) ?? Data())
        if size > Int64(sampleBytes) * 2 {
            try handle.seek(toOffset: UInt64(size - Int64(sampleBytes)))
            hasher.update(data: try handle.read(upToCount: sampleBytes) ?? Data())
        }
        withUnsafeBytes(of: size) { hasher.update(bufferPointer: $0) }
        return ComicFingerprint(size: size, digest: hex(hasher.finalize()))
    }

    /// A folder of loose pages is the same comic as another when its pages have the same names
    /// and sizes — reading every image to be sure would cost more than it could catch.
    static func folderFingerprint(_ url: URL) throws -> ComicFingerprint {
        let pages = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey],
                                                                 options: [.skipsHiddenFiles])
        var hasher = SHA256()
        var total: Int64 = 0
        for page in pages.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let size = Int64((try? page.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            total += size
            hasher.update(data: Data("\(page.lastPathComponent):\(size)\n".utf8))
        }
        return ComicFingerprint(size: total, digest: "folder:" + hex(hasher.finalize()))
    }

    /// Comics sharing a fingerprint, two or more to a set, the most space to win back first.
    static func sets(of printed: [(comic: Comic, fingerprint: ComicFingerprint)]) -> [DuplicateSet] {
        Dictionary(grouping: printed, by: \.fingerprint).values
            .filter { $0.count >= 2 }
            .map { matches in
                let copies = matches.map(\.comic).sorted { ($0.addedAt, $0.id) < ($1.addedAt, $1.id) }
                return DuplicateSet(id: copies[0].id, copies: copies,
                                    wastedBytes: copies.dropFirst().reduce(0) { $0 + $1.totalBytes })
            }
            .sorted { ($0.wastedBytes, $0.id) > ($1.wastedBytes, $1.id) }
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension URL {
    /// Whether this file is somewhere inside `folder` (not the folder itself). A directory URL's
    /// path can end in "/" or not; comparing with one added unconditionally refused every file.
    func isInside(_ folder: URL) -> Bool {
        var base = folder.standardizedFileURL.path(percentEncoded: false)
        if !base.hasSuffix("/") { base += "/" }
        let path = standardizedFileURL.path(percentEncoded: false)
        return path.hasPrefix(base) && path.count > base.count
    }
}
