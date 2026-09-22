import Foundation
import os

/// Moves a comic's files from a folder the user picked into Mango's own folder: copy, check
/// every file arrived whole, and only then remove the originals. A different file already at
/// the destination is never overwritten; the same file already there is just not copied again.
enum LocalMove {
    struct File: Sendable {
        let source: URL
        let destination: URL
        let size: Int64
    }

    enum Failure: LocalizedError {
        /// A different file of the same name is already in Mango's folder.
        case differentFileThere(String)
        /// A copy came out the wrong size; the original was kept.
        case incomplete(String)
        case cancelled
        /// Copied and checked, but the folder wouldn't let go of these originals.
        case originalsLeft(Int)

        var errorDescription: String? {
            switch self {
            case .differentFileThere(let name): "A different \(name) is already in Mango's folder, so nothing was moved."
            case .incomplete(let name): "\(name) didn't copy completely. The original is untouched."
            case .cancelled: "Cancelled. The original is untouched."
            case .originalsLeft(let count): "Moved into Mango, but \(count) original file\(count == 1 ? "" : "s") couldn't be removed from the folder."
            }
        }
    }

    static let chunkBytes = 4 * 1024 * 1024

    /// Copies each file into place, checks sizes, then removes the originals — and the folder
    /// they were in, when that's now empty and it's `emptiedFolder`. Throws before touching an
    /// original if anything is off.
    static func run(_ files: [File], emptiedFolder: URL? = nil,
                    progress: @Sendable (Int64) -> Void, isCancelled: @Sendable () -> Bool) throws {
        let fileManager = FileManager.default
        for file in files where exists(file.destination) && size(of: file.destination) != file.size {
            throw Failure.differentFileThere(file.destination.lastPathComponent)
        }
        var done: Int64 = 0
        for file in files {
            if isCancelled() { throw Failure.cancelled }
            if exists(file.destination) {
                done += file.size
                progress(done)
                continue
            }
            try fileManager.createDirectory(at: file.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let partial = file.destination.appendingPathExtension("part")
            try? fileManager.removeItem(at: partial)
            let base = done
            do {
                try copy(from: file.source, to: partial, progress: { progress(base + $0) }, isCancelled: isCancelled)
            } catch {
                try? fileManager.removeItem(at: partial)
                throw error
            }
            guard size(of: partial) == file.size else {
                try? fileManager.removeItem(at: partial)
                throw Failure.incomplete(file.source.lastPathComponent)
            }
            try fileManager.moveItem(at: partial, to: file.destination)
            done += file.size
            progress(done)
        }
        // Every file is in Mango's folder at its size: only now do the originals go.
        var left = 0
        for file in files {
            do {
                try fileManager.removeItem(at: file.source)
            } catch {
                left += 1
                Logger.downloads.error("[move] couldn't remove original \(file.source.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        if let emptiedFolder, let rest = try? fileManager.contentsOfDirectory(atPath: emptiedFolder.path(percentEncoded: false)),
           rest.allSatisfy({ $0.hasPrefix(".") }) {
            try? fileManager.removeItem(at: emptiedFolder)
        }
        if left > 0 { throw Failure.originalsLeft(left) }
    }

    private static func copy(from source: URL, to destination: URL, progress: (Int64) -> Void, isCancelled: () -> Bool) throws {
        guard FileManager.default.createFile(atPath: destination.path(percentEncoded: false), contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }
        var copied: Int64 = 0
        while let chunk = try reader.read(upToCount: chunkBytes), !chunk.isEmpty {
            if isCancelled() { throw Failure.cancelled }
            try writer.write(contentsOf: chunk)
            copied += Int64(chunk.count)
            progress(copied)
        }
        try writer.synchronize()
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private static func size(of url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1)
    }
}
