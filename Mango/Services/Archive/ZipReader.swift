import Compression
import Foundation
import os

/// One file inside a zip, as described by the central directory.
struct ZipEntry: Sendable, Hashable {
    var name: String
    var compressedSize: Int64
    var uncompressedSize: Int64
    /// 0 = stored, 8 = deflate. Comic archives are overwhelmingly one of those two: JPEGs
    /// don't compress, so most zippers store them outright.
    var method: UInt16
    var localHeaderOffset: Int64
    var crc32: UInt32

    var isDirectory: Bool { name.hasSuffix("/") || name.hasSuffix("\\") }
}

enum ZipError: LocalizedError {
    case notAZip
    case unsupportedMethod(UInt16, entry: String)
    case corruptCentralDirectory(String)
    case inflateFailed(entry: String)
    case encrypted(entry: String)

    var errorDescription: String? {
        switch self {
        case .notAZip: "This isn't a zip archive — no end-of-central-directory record."
        case .unsupportedMethod(let m, let entry): "\(entry) uses zip compression method \(m), which Mango can't read."
        case .corruptCentralDirectory(let why): "The archive's index is damaged: \(why)"
        case .inflateFailed(let entry): "Couldn't decompress \(entry)."
        case .encrypted(let entry): "\(entry) is password-protected."
        }
    }
}

/// A zip reader built on ranged reads, so it works identically on a local file and on a file
/// sitting on an SMB share. It reads the tail to find the index, the index to find the entries,
/// and then one entry at a time — which for a comic means one page at a time.
enum ZipReader {
    private static let eocdSignature: UInt32 = 0x0605_4B50
    private static let eocd64LocatorSignature: UInt32 = 0x0706_4B50
    private static let eocd64Signature: UInt32 = 0x0606_4B50
    private static let centralSignature: UInt32 = 0x0201_4B50
    private static let localSignature: UInt32 = 0x0403_4B50

    /// Max size of an end-of-central-directory record: 22 fixed bytes + a 65,535-byte comment.
    private static let maxEOCDSize = 22 + 65_535
    /// Almost no zip carries a trailing comment, so the index is within a few hundred bytes of
    /// the end. Probing small first matters over SMB: pulling 64 KB to open every comic is real
    /// latency on a share, and it's wasted 99% of the time.
    private static let shortTailProbe = 4_096

    // MARK: Reading the index

    static func readCentralDirectory(_ reader: any RandomAccessReader) async throws -> [ZipEntry] {
        let sw = Stopwatch()
        let total = try await reader.length()
        guard total >= 22 else { throw ZipError.notAZip }

        // Two probes: a small tail that covers the overwhelming majority of archives, then the
        // full 64 KB window for the rare one with a comment. A probe that finds an EOCD whose
        // numbers don't add up is treated as a miss, so a false signature in page data can't
        // stop the bigger probe from finding the real record.
        var tail: [UInt8] = []
        var tailOffset: Int64 = 0
        var located: EndRecord?
        for probe in [shortTailProbe, maxEOCDSize + 20] {
            let size = Int(min(Int64(probe), total))
            let (data, offset) = try await reader.readTail(size)
            tail = [UInt8](data)
            tailOffset = offset
            located = try await locate(in: tail, total: total, reader: reader)
            if located != nil || Int64(size) >= total { break }
        }
        guard let end = located else { throw ZipError.notAZip }
        let entryCount = end.entryCount
        let cdSize = end.size
        let cdOffset = end.offset

        // The index is usually already inside the tail we fetched; only go back to the file when
        // it isn't. On a NAS that saves a whole round trip for a small archive.
        let central: [UInt8]
        if cdOffset >= tailOffset, cdOffset + cdSize <= tailOffset + Int64(tail.count) {
            let start = Int(cdOffset - tailOffset)
            central = Array(tail[start..<(start + Int(cdSize))])
        } else {
            central = [UInt8](try await reader.read(offset: cdOffset, count: Int(cdSize)))
        }

        let entries = try parseCentralDirectory(central, expectedCount: entryCount)
        Logger.archive.info("[zip] index read: entries=\(entries.count) cdBytes=\(cdSize) fileBytes=\(total) in \(sw.ms, format: .fixed(precision: 1))ms")
        return entries
    }

    private struct EndRecord {
        var entryCount: Int
        var size: Int64
        var offset: Int64
    }

    /// Finds and validates the end-of-central-directory record inside a tail buffer, following
    /// the ZIP64 locator when the 32-bit fields have saturated. Returns nil when this buffer
    /// doesn't hold a usable record — the caller then probes wider.
    private static func locate(in tail: [UInt8], total: Int64, reader: any RandomAccessReader) async throws -> EndRecord? {
        guard let eocdIndex = lastIndex(of: eocdSignature, in: tail) else { return nil }
        var entryCount = Int(u16(tail, eocdIndex + 10))
        var size = Int64(u32(tail, eocdIndex + 12))
        var offset = Int64(u32(tail, eocdIndex + 16))

        // ZIP64: the 32-bit fields saturate and the real values live in a separate record,
        // pointed at by a locator sitting immediately before the EOCD.
        if entryCount == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF {
            let locatorIndex = eocdIndex - 20
            guard locatorIndex >= 0, u32(tail, locatorIndex) == eocd64LocatorSignature else { return nil }
            let eocd64Offset = Int64(bitPattern: u64(tail, locatorIndex + 8))
            guard eocd64Offset >= 0, eocd64Offset + 56 <= total else { return nil }
            let record = [UInt8](try await reader.read(offset: eocd64Offset, count: 56))
            guard record.count >= 56, u32(record, 0) == eocd64Signature else { return nil }
            entryCount = Int(u64(record, 32))
            size = Int64(bitPattern: u64(record, 40))
            offset = Int64(bitPattern: u64(record, 48))
        }

        guard offset >= 0, size > 0, offset + size <= total else { return nil }
        return EndRecord(entryCount: entryCount, size: size, offset: offset)
    }

    private static func parseCentralDirectory(_ bytes: [UInt8], expectedCount: Int) throws -> [ZipEntry] {
        var entries: [ZipEntry] = []
        entries.reserveCapacity(expectedCount)
        var i = 0
        while i + 46 <= bytes.count, u32(bytes, i) == centralSignature {
            let flags = u16(bytes, i + 8)
            let method = u16(bytes, i + 10)
            let crc = u32(bytes, i + 16)
            var compressed = Int64(u32(bytes, i + 20))
            var uncompressed = Int64(u32(bytes, i + 24))
            let nameLength = Int(u16(bytes, i + 28))
            let extraLength = Int(u16(bytes, i + 30))
            let commentLength = Int(u16(bytes, i + 32))
            var localOffset = Int64(u32(bytes, i + 42))

            let nameStart = i + 46
            let extraStart = nameStart + nameLength
            let next = extraStart + extraLength + commentLength
            guard next <= bytes.count else {
                throw ZipError.corruptCentralDirectory("entry \(entries.count) runs past the index")
            }

            // Filenames are UTF-8 when bit 11 is set, CP437 otherwise. Japanese CBZ names written
            // by older Windows tools are frequently neither, so fall back rather than drop a page.
            let nameBytes = Array(bytes[nameStart..<extraStart])
            let name = decodeName(nameBytes, utf8Flag: flags & 0x0800 != 0)

            // ZIP64 extended information (header id 0x0001) replaces whichever 32-bit fields saturated.
            if compressed == 0xFFFF_FFFF || uncompressed == 0xFFFF_FFFF || localOffset == 0xFFFF_FFFF {
                var e = extraStart
                while e + 4 <= extraStart + extraLength {
                    let headerID = u16(bytes, e)
                    let size = Int(u16(bytes, e + 2))
                    var f = e + 4
                    if headerID == 0x0001 {
                        if uncompressed == 0xFFFF_FFFF, f + 8 <= bytes.count { uncompressed = Int64(bitPattern: u64(bytes, f)); f += 8 }
                        if compressed == 0xFFFF_FFFF, f + 8 <= bytes.count { compressed = Int64(bitPattern: u64(bytes, f)); f += 8 }
                        if localOffset == 0xFFFF_FFFF, f + 8 <= bytes.count { localOffset = Int64(bitPattern: u64(bytes, f)) }
                        break
                    }
                    e += 4 + size
                }
            }

            // Bit 0 = the entry is encrypted. Record it and let the page read fail with a clear message.
            if flags & 0x0001 != 0 {
                Logger.archive.error("[zip] \(name, privacy: .public) is encrypted — skipping")
            } else {
                entries.append(ZipEntry(name: name, compressedSize: compressed, uncompressedSize: uncompressed,
                                        method: method, localHeaderOffset: localOffset, crc32: crc))
            }
            i = next
        }
        guard !entries.isEmpty else { throw ZipError.corruptCentralDirectory("no readable entries") }
        return entries
    }

    // MARK: Reading one entry

    /// Fetches and decompresses a single entry. Two reads on a cold archive: the local header
    /// (whose name/extra lengths can differ from the central directory's, so the data offset has
    /// to come from here) and the data itself.
    static func read(_ entry: ZipEntry, from reader: any RandomAccessReader) async throws -> Data {
        let sw = Stopwatch()
        let header = [UInt8](try await reader.read(offset: entry.localHeaderOffset, count: 30))
        guard header.count >= 30, u32(header, 0) == localSignature else {
            throw ZipError.corruptCentralDirectory("no local header for \(entry.name) at \(entry.localHeaderOffset)")
        }
        let nameLength = Int(u16(header, 26))
        let extraLength = Int(u16(header, 28))
        let dataOffset = entry.localHeaderOffset + 30 + Int64(nameLength + extraLength)

        let compressed = try await reader.read(offset: dataOffset, count: Int(entry.compressedSize))
        guard compressed.count == Int(entry.compressedSize) else {
            throw ReaderError.shortRead(offset: dataOffset, wanted: Int(entry.compressedSize), got: compressed.count)
        }

        let out: Data
        switch entry.method {
        case 0:
            out = compressed
        case 8:
            out = try inflate(compressed, expectedSize: Int(entry.uncompressedSize), entryName: entry.name)
        default:
            throw ZipError.unsupportedMethod(entry.method, entry: entry.name)
        }
        Logger.archive.debug("[zip] read \(entry.name, privacy: .public) method=\(entry.method) \(entry.compressedSize)→\(out.count)B in \(sw.ms, format: .fixed(precision: 1))ms")
        return out
    }

    // MARK: Deflate

    /// Apple's `COMPRESSION_ZLIB` is raw DEFLATE (RFC 1951) — exactly what zip method 8 stores,
    /// no zlib wrapper to strip.
    static func inflate(_ input: Data, expectedSize: Int, entryName: String = "entry") throws -> Data {
        guard !input.isEmpty else { return Data() }
        if expectedSize > 0, let out = inflateFixed(input, size: expectedSize), out.count == expectedSize {
            return out
        }
        // Unknown or wrong declared size (streamed entries with a data descriptor) — grow instead.
        guard let out = inflateStreaming(input) else { throw ZipError.inflateFailed(entry: entryName) }
        return out
    }

    private static func inflateFixed(_ input: Data, size: Int) -> Data? {
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return input.withUnsafeBytes { src -> Int in
                guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dstBase, size, srcBase, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written == size ? out : nil
    }

    private static func inflateStreaming(_ input: Data) -> Data? {
        let bufferSize = 256 * 1024
        let streamPointer = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { streamPointer.deallocate() }
        guard compression_stream_init(streamPointer, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return nil
        }
        defer { compression_stream_destroy(streamPointer) }

        let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { destination.deallocate() }

        var output = Data()
        return input.withUnsafeBytes { src -> Data? in
            guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return nil }
            streamPointer.pointee.src_ptr = srcBase
            streamPointer.pointee.src_size = input.count
            while true {
                streamPointer.pointee.dst_ptr = destination
                streamPointer.pointee.dst_size = bufferSize
                let status = compression_stream_process(streamPointer, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = bufferSize - streamPointer.pointee.dst_size
                if produced > 0 { output.append(destination, count: produced) }
                switch status {
                case COMPRESSION_STATUS_OK:
                    continue
                case COMPRESSION_STATUS_END:
                    return output
                default:
                    return nil
                }
            }
        }
    }

    // MARK: Byte helpers

    private static func lastIndex(of signature: UInt32, in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        var i = bytes.count - 4
        while i >= 0 {
            if u32(bytes, i) == signature { return i }
            i -= 1
        }
        return nil
    }

    private static func decodeName(_ bytes: [UInt8], utf8Flag: Bool) -> String {
        if utf8Flag, let s = String(bytes: bytes, encoding: .utf8) { return s }
        if let s = String(bytes: bytes, encoding: .utf8) { return s }
        // CP437 is the zip spec's fallback; Shift-JIS shows up in manga archives from Japanese tools.
        if let s = String(bytes: bytes, encoding: .shiftJIS) { return s }
        // Last resort: lossy UTF-8, so a page with an undecodable name is still readable
        // rather than silently dropped from the archive.
        if let s = String(bytes: bytes, encoding: .isoLatin1) { return s }
        return bytes.map { String(UnicodeScalar($0)) }.joined()
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        guard i + 2 <= b.count else { return 0 }
        return UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    private static func u64(_ b: [UInt8], _ i: Int) -> UInt64 {
        guard i + 8 <= b.count else { return 0 }
        var value: UInt64 = 0
        for shift in 0..<8 { value |= UInt64(b[i + shift]) << (8 * UInt64(shift)) }
        return value
    }
}
