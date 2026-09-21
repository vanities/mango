import Foundation
import os

/// Random access to a file's bytes, wherever it lives.
///
/// This is the seam that makes reading a comic off a NAS work the same as reading one off
/// disk: a `.cbz` is a zip, a zip's index lives at the *end* of the file, and every page is
/// an independently addressable run of bytes. Given ranged reads, `ZipReader` never has to
/// download a 400 MB volume to show page one.
protocol RandomAccessReader: Sendable {
    /// Total size in bytes.
    func length() async throws -> Int64
    /// Exactly `count` bytes starting at `offset`, or fewer at end of file.
    func read(offset: Int64, count: Int) async throws -> Data
}

extension RandomAccessReader {
    /// Reads the last `count` bytes (or the whole file if it's smaller), plus the offset they start at.
    func readTail(_ count: Int) async throws -> (data: Data, offset: Int64) {
        let total = try await length()
        let size = Int64(min(Int64(count), total))
        let offset = total - size
        return (try await read(offset: offset, count: Int(size)), offset)
    }
}

enum ReaderError: LocalizedError {
    case cannotOpen(String)
    case shortRead(offset: Int64, wanted: Int, got: Int)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let path): "Couldn't open \(path)."
        case .shortRead(let offset, let wanted, let got):
            "Read \(got) of \(wanted) bytes at \(offset) — the file may be truncated."
        }
    }
}

/// A file on disk (app Documents, or inside a security-scoped folder the caller is keeping open).
actor LocalFileReader: RandomAccessReader {
    private let url: URL
    private var handle: FileHandle?
    private var cachedLength: Int64?

    init(url: URL) {
        self.url = url
    }

    deinit {
        try? handle?.close()
    }

    private func openedHandle() throws -> FileHandle {
        if let handle { return handle }
        guard let opened = try? FileHandle(forReadingFrom: url) else {
            throw ReaderError.cannotOpen(url.lastPathComponent)
        }
        handle = opened
        return opened
    }

    func length() async throws -> Int64 {
        if let cachedLength { return cachedLength }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let size = Int64(values.fileSize ?? 0)
        cachedLength = size
        return size
    }

    func read(offset: Int64, count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        let handle = try openedHandle()
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: count) ?? Data()
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}

/// A file on an SMB share. Every read is a bounded ranged read — never an open-ended stream,
/// because aborting an AMSMB2 stream from inside its callback crashes libsmb2 (Earmark, hard way).
struct RemoteFileReader: RandomAccessReader {
    let client: NASClient
    /// Path relative to the server's library root.
    let relativePath: String
    let knownLength: Int64?

    init(client: NASClient, relativePath: String, knownLength: Int64? = nil) {
        self.client = client
        self.relativePath = relativePath
        self.knownLength = knownLength
    }

    func length() async throws -> Int64 {
        if let knownLength, knownLength > 0 { return knownLength }
        return try await client.fileSize(relativePath)
    }

    func read(offset: Int64, count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        let sw = Stopwatch()
        let sink = ChunkSink(limit: count)
        try await client.read(relativePath, offset: offset, length: Int64(count)) { chunk in
            sink.append(chunk)
        }
        let buffer = sink.take()
        Logger.nas.debug("[nas:read] \(relativePath, privacy: .public) offset=\(offset) want=\(count) got=\(buffer.count) in \(sw.ms, format: .fixed(precision: 0))ms")
        return buffer
    }
}

/// Collects the chunks AMSMB2 delivers on its own queue. Locked rather than captured as a
/// plain `var`: the callback is `@Sendable`, and the compiler is right that appending to a
/// captured local from another thread is a race waiting to happen.
private final class ChunkSink: Sendable {
    private let limit: Int
    private let buffer = OSAllocatedUnfairLock(initialState: Data())

    init(limit: Int) {
        self.limit = limit
        buffer.withLock { $0.reserveCapacity(limit) }
    }

    /// Returns false once enough bytes have arrived, which stops the read between chunks —
    /// never mid-chunk, which is what crashes libsmb2.
    func append(_ chunk: Data) -> Bool {
        buffer.withLock { data in
            data.append(chunk)
            return data.count < limit
        }
    }

    func take() -> Data {
        buffer.withLock { data in
            data.count > limit ? Data(data.prefix(limit)) : data
        }
    }
}

/// Bytes already in memory — used by tests and by the PDF path, which needs the whole document.
struct DataReader: RandomAccessReader {
    let data: Data

    init(_ data: Data) { self.data = data }

    func length() async throws -> Int64 { Int64(data.count) }

    func read(offset: Int64, count: Int) async throws -> Data {
        guard offset >= 0, offset < Int64(data.count), count > 0 else { return Data() }
        let start = data.index(data.startIndex, offsetBy: Int(offset))
        let end = data.index(start, offsetBy: min(count, data.count - Int(offset)))
        return Data(data[start..<end])
    }
}
