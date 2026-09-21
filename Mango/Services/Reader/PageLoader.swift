import CoreGraphics
import Foundation
import os

/// Decodes pages out of an open archive, keeps a few around, and fetches ahead of the reader.
///
/// The two things that make or break a comic reader are both here: page turns have to feel
/// instant (so decode ahead), and the app must not get killed for holding a dozen 24 MB bitmaps
/// (so cap what's kept and drop the pages behind you first).
actor PageLoader {
    private let archive: any ComicArchive
    /// How many decoded pages to keep. Small on purpose — a page is megabytes, not kilobytes.
    private let capacity: Int
    /// And a ceiling on what they weigh together. Counting pages alone isn't enough: one long
    /// strip can decode to 40 MB, and a handful of those is enough to get the app killed.
    private let byteBudget = 160 * 1024 * 1024

    /// A decoded page is only right for the layout it was sized for, so the sizing is part of
    /// the key. Switching layout can never be handed a page decoded for the other one — for a
    /// long strip, that's a blurry sliver — however the requests happen to be ordered.
    private struct Key: Hashable {
        let index: Int
        let sizing: PageSizing
        /// Margins cropped (Crop margins) — a different picture from the same page.
        var trim = false
    }

    private var cache: [Key: CGImage] = [:]
    /// Most-recently-used last.
    private var recency: [Key] = []
    private var inFlight: [Key: Task<CGImage, any Error>] = [:]
    /// Bytes read to check a page's shape before anything was drawn, kept for the decode that
    /// follows so the page isn't fetched twice. Consumed by that decode.
    private var peeked: [Int: Data] = [:]
    /// Every page size learned so far, from peeks and header reads — each page is sized once.
    private var sizes: [Int: CGSize] = [:]
    /// Small copies for the page grid, apart from the page cache so browsing thumbnails never
    /// evicts the pages being read. Oldest dropped first.
    private var thumbnails: [Int: CGImage] = [:]
    private var thumbnailOrder: [Int] = []
    private let thumbnailCapacity = 120
    /// Pages that turned out to be wider than they are tall — a double-page spread that should
    /// be shown on its own rather than paired with a neighbour.
    private(set) var widePages: Set<Int> = []

    var pageCount: Int { archive.pageCount }

    init(archive: any ComicArchive, capacity: Int) {
        self.archive = archive
        self.capacity = max(3, capacity)
    }

    nonisolated func pageName(at index: Int) -> String { archive.pageName(at: index) }

    // MARK: Shape

    /// Whether this book reads as a long strip, judged from the page the reader opens on — plus
    /// the next two, only if that one is tall. It runs on every open, so it's built to cost an
    /// ordinary book nothing: one page read, which is the page about to be drawn anyway, and
    /// whose bytes the first decode reuses.
    func looksLikeLongStrip(from index: Int) async -> Bool {
        let sw = Stopwatch()
        let start = max(0, index)
        var sizes: [CGSize] = []
        for target in start..<min(start + 3, archive.pageCount) {
            guard let size = await size(of: target) else { continue }
            sizes.append(size)
            // An ordinary opening page settles it — by far the common case.
            if sizes.count == 1, !PageShape.isLongStrip(width: size.width, height: size.height) { break }
        }
        let verdict = PageShape.looksLikeLongStrip(sizes)
        Logger.pages.info("[shape] sampled \(sizes.count) page(s) from \(start + 1): longStrip=\(verdict) in \(sw.ms, format: .fixed(precision: 1))ms")
        return verdict
    }

    private func size(of index: Int) async -> CGSize? {
        if let known = sizes[index] { return known }
        if let known = await archive.knownPageSize(at: index) {
            sizes[index] = known
            return known
        }
        guard let data = try? await archive.pageData(at: index) else { return nil }
        peeked[index] = data
        let size = ImageDecoder.pixelSize(of: data)
        sizes[index] = size
        return size
    }

    /// A page's size for laying out a strip — from what's already known, else a header read.
    func pageSize(at index: Int) async -> CGSize? {
        guard index >= 0, index < archive.pageCount else { return nil }
        if let known = sizes[index] { return known }
        let size = await archive.pageSize(at: index)
        sizes[index] = size
        return size
    }

    // MARK: Loading

    func page(at index: Int, sizing: PageSizing, trim: Bool = false) async throws -> CGImage {
        let key = Key(index: index, sizing: sizing, trim: trim)
        if let hit = cache[key] {
            touch(key)
            return hit
        }
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = decodeTask(for: key)
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let image = try await task.value
        store(image, for: key)
        return image
    }

    /// Kicks off decodes for the pages either side of `index` and drops what's now far away.
    /// Fire-and-forget: failures here are the reader's problem when it actually asks for the page.
    /// A prefetch is also the reader saying which layout is current, so pages sized for another
    /// one are dropped.
    func prefetch(around index: Int, ahead: Int, behind: Int = 1, sizing: PageSizing, trim: Bool = false) {
        dropPages(notMatching: sizing, trim: trim)
        let wanted = pagesToKeep(around: index, ahead: ahead, behind: behind).map { Key(index: $0, sizing: sizing, trim: trim) }
        for key in wanted where cache[key] == nil && inFlight[key] == nil {
            let task = decodeTask(for: key)
            inFlight[key] = task
            Task { await self.absorb(task, for: key) }
        }
        evict(keeping: Set(wanted))
    }

    private func decodeTask(for key: Key) -> Task<CGImage, any Error> {
        let bytes = peeked.removeValue(forKey: key.index)
        return Task { [archive] in
            try await Self.decode(archive, key, peeked: bytes)
        }
    }

    private static func decode(_ archive: any ComicArchive, _ key: Key, peeked: Data?) async throws -> CGImage {
        let image: CGImage
        if let peeked {
            // Only image containers get peeked (a PDF knows its sizes), and for those decoding the
            // bytes is exactly what the archive would have done after reading them again.
            guard let decoded = ImageDecoder.decode(peeked, sizing: key.sizing) else {
                throw ArchiveError.undecodable(page: archive.pageName(at: key.index))
            }
            image = decoded
        } else {
            image = try await archive.page(at: key.index, sizing: key.sizing)
        }
        return key.trim ? MarginTrimmer.trim(image) : image
    }

    private func dropPages(notMatching sizing: PageSizing, trim: Bool) {
        let stale = cache.keys.filter { $0.sizing != sizing || $0.trim != trim }
        guard !stale.isEmpty else { return }
        for key in stale { cache[key] = nil }
        recency.removeAll { $0.sizing != sizing || $0.trim != trim }
        Logger.pages.info("[cache] layout or crop changed, dropped \(stale.count) page(s) made for the old one")
    }

    // MARK: Thumbnails

    /// A small copy of a page for the page grid. On a NAS this reads the page, so the grid asks
    /// only for the cells on screen.
    func thumbnail(at index: Int) async -> CGImage? {
        if let hit = thumbnails[index] { return hit }
        let image: CGImage?
        if await archive.knownPageSize(at: index) != nil {
            image = try? await archive.page(at: index, maxPixel: ImageDecoder.thumbnailPixels)
        } else {
            var data = peeked[index]
            if data == nil { data = try? await archive.pageData(at: index) }
            image = data.flatMap(ImageDecoder.thumbnail(from:))
        }
        guard let image else { return nil }
        thumbnails[index] = image
        thumbnailOrder.append(index)
        if thumbnailOrder.count > thumbnailCapacity {
            thumbnails[thumbnailOrder.removeFirst()] = nil
        }
        return image
    }

    private func pagesToKeep(around index: Int, ahead: Int, behind: Int) -> [Int] {
        let range = (index - behind)...(index + ahead)
        return range.filter { $0 >= 0 && $0 < archive.pageCount }
    }

    /// Files a prefetch's result once it lands. A failure is deliberately swallowed: the reader
    /// will ask for the page properly when it gets there, and that call reports the error.
    private func absorb(_ task: Task<CGImage, any Error>, for key: Key) async {
        defer { inFlight[key] = nil }
        guard let image = try? await task.value else { return }
        store(image, for: key)
    }

    private func store(_ image: CGImage, for key: Key) {
        cache[key] = image
        if image.width > image.height { widePages.insert(key.index) }
        touch(key)
        evict(keeping: [])
    }

    private func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }

    private var cachedBytes: Int {
        cache.values.reduce(0) { $0 + $1.bytesPerRow * $1.height }
    }

    /// Trims to `capacity` pages and `byteBudget` bytes, oldest first, never dropping a page
    /// the reader just asked to keep.
    private func evict(keeping protected: Set<Key>) {
        guard cache.count > capacity || cachedBytes > byteBudget else { return }
        var dropped = 0
        for key in recency where cache.count > capacity || cachedBytes > byteBudget {
            guard !protected.contains(key) else { continue }
            cache[key] = nil
            recency.removeAll { $0 == key }
            dropped += 1
        }
        if dropped > 0 {
            Logger.pages.debug("[cache] evicted \(dropped) page(s), holding \(self.cache.count)/\(self.capacity)")
        }
    }

    /// Everything but the page on screen — called on a memory warning.
    func purge(keeping index: Int) {
        let before = cache.count
        let kept = cache.filter { $0.key.index == index }
        cache = kept
        recency.removeAll { $0.index != index }
        peeked.removeAll()
        thumbnails.removeAll()
        thumbnailOrder.removeAll()
        Logger.pages.notice("[cache] purged under memory pressure: \(before) → \(self.cache.count)")
    }

    func cancelAll() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }
}
