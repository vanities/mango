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
    private let maxPixel: Int
    /// How many decoded pages to keep. Small on purpose — a page is megabytes, not kilobytes.
    private let capacity: Int

    private var cache: [Int: CGImage] = [:]
    /// Most-recently-used last.
    private var recency: [Int] = []
    private var inFlight: [Int: Task<CGImage, any Error>] = [:]
    /// Pages that turned out to be wider than they are tall — a double-page spread that should
    /// be shown on its own rather than paired with a neighbour.
    private(set) var widePages: Set<Int> = []

    var pageCount: Int { archive.pageCount }

    init(archive: any ComicArchive, maxPixel: Int, capacity: Int) {
        self.archive = archive
        self.maxPixel = maxPixel
        self.capacity = max(3, capacity)
    }

    nonisolated func pageName(at index: Int) -> String { archive.pageName(at: index) }

    // MARK: Loading

    func page(at index: Int) async throws -> CGImage {
        if let hit = cache[index] {
            touch(index)
            return hit
        }
        if let existing = inFlight[index] {
            return try await existing.value
        }
        let task = Task<CGImage, any Error> { [archive, maxPixel] in
            try await archive.page(at: index, maxPixel: maxPixel)
        }
        inFlight[index] = task
        defer { inFlight[index] = nil }
        let image = try await task.value
        store(image, at: index)
        return image
    }

    /// Kicks off decodes for the pages either side of `index` and drops what's now far away.
    /// Fire-and-forget: failures here are the reader's problem when it actually asks for the page.
    func prefetch(around index: Int, ahead: Int, behind: Int = 1) {
        let wanted = pagesToKeep(around: index, ahead: ahead, behind: behind)
        for target in wanted where cache[target] == nil && inFlight[target] == nil {
            let task = Task<CGImage, any Error> { [archive, maxPixel] in
                try await archive.page(at: target, maxPixel: maxPixel)
            }
            inFlight[target] = task
            Task { await self.absorb(task, at: target) }
        }
        evict(keeping: Set(wanted))
    }

    private func pagesToKeep(around index: Int, ahead: Int, behind: Int) -> [Int] {
        let range = (index - behind)...(index + ahead)
        return range.filter { $0 >= 0 && $0 < archive.pageCount }
    }

    /// Files a prefetch's result once it lands. A failure is deliberately swallowed: the reader
    /// will ask for the page properly when it gets there, and that call reports the error.
    private func absorb(_ task: Task<CGImage, any Error>, at index: Int) async {
        defer { inFlight[index] = nil }
        guard let image = try? await task.value else { return }
        store(image, at: index)
    }

    private func store(_ image: CGImage, at index: Int) {
        cache[index] = image
        if image.width > image.height { widePages.insert(index) }
        touch(index)
        evict(keeping: [])
    }

    private func touch(_ index: Int) {
        recency.removeAll { $0 == index }
        recency.append(index)
    }

    /// Trims to `capacity`, never dropping a page the reader just asked to keep.
    private func evict(keeping protected: Set<Int>) {
        guard cache.count > capacity else { return }
        var dropped = 0
        for index in recency where cache.count > capacity {
            guard !protected.contains(index) else { continue }
            cache[index] = nil
            recency.removeAll { $0 == index }
            dropped += 1
        }
        if dropped > 0 {
            Logger.pages.debug("[cache] evicted \(dropped) page(s), holding \(self.cache.count)/\(self.capacity)")
        }
    }

    /// Everything but the page on screen — called on a memory warning.
    func purge(keeping index: Int) {
        let kept = cache[index]
        let before = cache.count
        cache.removeAll(keepingCapacity: false)
        recency.removeAll()
        if let kept {
            cache[index] = kept
            recency = [index]
        }
        Logger.pages.notice("[cache] purged under memory pressure: \(before) → \(self.cache.count)")
    }

    func cancelAll() {
        for task in inFlight.values { task.cancel() }
        inFlight.removeAll()
    }
}
