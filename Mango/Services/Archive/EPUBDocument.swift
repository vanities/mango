import CoreGraphics
import Foundation
import os

/// An opened EPUB, read straight out of the zip.
///
/// Nothing is extracted to disk. An EPUB is a zip, so the same `ZipReader` that opens a `.cbz`
/// opens this, and `EPUBSchemeHandler` serves each chapter and image to the web view on demand
/// — which means reading a light novel off the NAS pulls the chapter you're on, not the 23 MB
/// book.
actor EPUBDocument {
    nonisolated let package: EPUBPackage
    nonisolated let displayName: String

    private let reader: any RandomAccessReader
    /// Entry path → zip entry, so a resource request is a dictionary hit plus one ranged read.
    private let entries: [String: ZipEntry]

    nonisolated var spine: [EPUBSpineItem] { package.spine }
    nonisolated var chapterCount: Int { package.spine.count }

    private init(package: EPUBPackage, displayName: String, reader: any RandomAccessReader, entries: [String: ZipEntry]) {
        self.package = package
        self.displayName = displayName
        self.reader = reader
        self.entries = entries
    }

    static func open(reader: any RandomAccessReader, displayName: String) async throws -> EPUBDocument {
        let sw = Stopwatch()
        let all = try await ZipReader.readCentralDirectory(reader)
        var entries: [String: ZipEntry] = [:]
        for entry in all where !entry.isDirectory {
            entries[entry.name] = entry
        }

        guard let containerEntry = entries["META-INF/container.xml"] else { throw EPUBError.noContainer }
        let containerData = try await ZipReader.read(containerEntry, from: reader)
        let opfPath = try EPUBParser.parseContainer(containerData)

        guard let opfEntry = entries[opfPath] else { throw EPUBError.noRootfile }
        let opfData = try await ZipReader.read(opfEntry, from: reader)
        let package = EPUBParser.parsePackage(opfData, opfPath: opfPath)
        guard !package.isEmpty else { throw EPUBError.noSpine(displayName) }

        Logger.archive.info("[epub] opened \(displayName, privacy: .public) chapters=\(package.spine.count) entries=\(entries.count) in \(sw.ms, format: .fixed(precision: 0))ms")
        return EPUBDocument(package: package, displayName: displayName, reader: reader, entries: entries)
    }

    /// Raw bytes of one file inside the book. Returns nil for anything the book doesn't contain,
    /// so a chapter referencing a missing image degrades instead of failing the whole page.
    func data(at path: String) async -> Data? {
        guard let entry = entries[path] else {
            Logger.archive.debug("[epub] no entry for \(path, privacy: .public)")
            return nil
        }
        return try? await ZipReader.read(entry, from: reader)
    }

    func chapterHTML(at index: Int) async -> Data? {
        guard package.spine.indices.contains(index) else { return nil }
        return await data(at: package.spine[index].path)
    }

    /// The book's declared cover, decoded for the library grid.
    func coverImage(maxPixel: Int) async -> CGImage? {
        guard let path = package.coverPath, let bytes = await data(at: path) else { return nil }
        return ImageDecoder.downsample(bytes, maxPixel: maxPixel)
    }

    /// Rough size of each chapter, used to weight progress across a book — chapter 1 of 40
    /// being 2% of a book is only true if the chapters are the same length, and they never are.
    func chapterWeights() -> [Double] {
        let sizes = package.spine.map { Double(entries[$0.path]?.uncompressedSize ?? 1) }
        let total = sizes.reduce(0, +)
        guard total > 0 else { return Array(repeating: 1.0 / Double(max(1, sizes.count)), count: sizes.count) }
        return sizes.map { $0 / total }
    }
}
