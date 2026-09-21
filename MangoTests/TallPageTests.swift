import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Mango

/// Long-strip (webtoon / manhwa) pages are one very tall image. The decoder has to size them by
/// width, or a readable strip becomes a blurry sliver.
final class TallPageTests: XCTestCase {
    /// A gray page, optionally with its top `redRows` rows red — for telling top from bottom.
    private func png(width: Int, height: Int, redRows: Int = 0) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if redRows > 0 {
            // CG's origin is bottom-left, so the top rows are the highest y.
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: height - redRows, width: width, height: redRows))
        }
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return out as Data
    }

    /// Whether the pixel at (x, y) — (0, 0) being the top-left as displayed — is red.
    private func isRed(_ image: CGImage, x: Int, y: Int) -> Bool {
        var rgba = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Shift the image so the wanted pixel lands on the context's only pixel.
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return rgba[0] > 200 && rgba[1] < 60 && rgba[2] < 60
    }

    private func cbz(_ sizes: [(width: Int, height: Int)]) -> Data {
        ZipTestBuilder.make(sizes.enumerated().map { offset, size in
            .init(name: String(format: "%03d.png", offset + 1), data: png(width: size.width, height: size.height), deflate: false)
        })
    }

    /// The bug being fixed: bounding the longest edge makes a tall strip absurdly narrow.
    func testLongestEdgeSizingStarvesATallStrip() throws {
        let strip = png(width: 800, height: 12_000)
        let image = try XCTUnwrap(ImageDecoder.decode(strip, sizing: .fitScreen(maxPixel: 4096)))
        XCTAssertLessThan(image.width, 300, "this is the blurry sliver — why fitWidth exists")
    }

    func testWidthSizingKeepsATallStripSharp() throws {
        let strip = png(width: 800, height: 12_000)
        let image = try XCTUnwrap(ImageDecoder.decode(strip, sizing: .fitWidth(pixels: 1320)))
        XCTAssertEqual(image.width, 800, "never upscaled past the source")
        XCTAssertEqual(image.height, 12_000)
    }

    func testWidthSizingDownscalesAWideSource() throws {
        let strip = png(width: 2000, height: 6000)
        let image = try XCTUnwrap(ImageDecoder.decode(strip, sizing: .fitWidth(pixels: 1000)))
        XCTAssertEqual(image.width, 1000)
        XCTAssertEqual(image.height, 3000)
    }

    /// A pathological strip must not decode to hundreds of megabytes.
    func testWidthSizingRespectsTheMemoryBudget() throws {
        let strip = png(width: 1200, height: 40_000)
        let image = try XCTUnwrap(ImageDecoder.decode(strip, sizing: .fitWidth(pixels: 1200)))
        XCTAssertLessThanOrEqual(image.width * image.height * 4, ImageDecoder.decodeBudgetBytes)
    }

    // MARK: Tiling

    /// GPUs won't draw a texture taller than their limit; tall pages are drawn as stacked tiles.
    func testTallImagesAreTiled() throws {
        let image = try XCTUnwrap(ImageDecoder.decode(png(width: 800, height: 12_000), sizing: .fitWidth(pixels: 800)))
        let tiles = ImageDecoder.tiles(of: image)
        XCTAssertEqual(tiles.count, 3)
        XCTAssertTrue(tiles.allSatisfy { $0.height <= ImageDecoder.maxTileHeight })
        XCTAssertEqual(tiles.reduce(0) { $0 + $1.height }, 12_000, "no rows lost or duplicated")
        XCTAssertTrue(tiles.allSatisfy { $0.width == 800 })
    }

    /// Tiles stack top-down, so the first one has to be the top of the page.
    func testTheFirstTileIsTheTopOfThePage() throws {
        let image = try XCTUnwrap(ImageDecoder.decode(png(width: 800, height: 12_000, redRows: 100), sizing: .fitWidth(pixels: 800)))
        let tiles = ImageDecoder.tiles(of: image)
        XCTAssertTrue(isRed(tiles[0], x: 400, y: 10))
        XCTAssertFalse(isRed(tiles[2], x: 400, y: 10))
    }

    func testNormalPagesAreOneTile() throws {
        let image = try XCTUnwrap(ImageDecoder.decode(png(width: 800, height: 1200), sizing: .fitWidth(pixels: 800)))
        XCTAssertEqual(ImageDecoder.tiles(of: image).count, 1)
    }

    // MARK: Detection

    func testLongStripDetection() {
        XCTAssertTrue(PageShape.isLongStrip(width: 800, height: 12_000))
        XCTAssertTrue(PageShape.isLongStrip(width: 690, height: 2_400))
        XCTAssertFalse(PageShape.isLongStrip(width: 800, height: 1_200), "an ordinary page")
        XCTAssertFalse(PageShape.isLongStrip(width: 1600, height: 1_200), "a two-page spread")
        XCTAssertFalse(PageShape.isLongStrip(width: 0, height: 100))
    }

    /// One tall page in an ordinary volume (a vertical splash) isn't a webtoon.
    func testMostPagesHaveToBeTallToCountAsAStrip() {
        let mostlyNormal = [CGSize(width: 800, height: 1200), CGSize(width: 800, height: 1200), CGSize(width: 800, height: 4000)]
        XCTAssertFalse(PageShape.looksLikeLongStrip(mostlyNormal))
        let strip = [CGSize(width: 800, height: 9000), CGSize(width: 800, height: 8000), CGSize(width: 800, height: 1200)]
        XCTAssertTrue(PageShape.looksLikeLongStrip(strip))
        XCTAssertFalse(PageShape.looksLikeLongStrip([]))
    }

    func testWidthFirstSizeNeverUpscalesAndStaysInBudget() {
        XCTAssertEqual(ImageDecoder.widthFirstSize(of: CGSize(width: 800, height: 12_000), width: 1320),
                       CGSize(width: 800, height: 12_000))
        XCTAssertEqual(ImageDecoder.widthFirstSize(of: CGSize(width: 2000, height: 6000), width: 1000),
                       CGSize(width: 1000, height: 3000))
        let huge = ImageDecoder.widthFirstSize(of: CGSize(width: 1200, height: 40_000), width: 1200)
        XCTAssertLessThanOrEqual(huge.width * huge.height * 4, Double(ImageDecoder.decodeBudgetBytes))
    }

    // MARK: Opening a book

    /// Detection runs on every open of every book, so on a NAS it must cost nothing: it reads
    /// only the page you're opening on, and that page is then decoded from those same bytes
    /// rather than fetched twice.
    func testDetectingAnOrdinaryBookReadsOnlyTheOpeningPageAndReusesIt() async throws {
        let zip = cbz(Array(repeating: (width: 800, height: 1200), count: 6))
        let counting = CountingReader(DataReader(zip))
        let archive = try await ZipComicArchive.open(reader: counting, displayName: "Ordinary")
        let loader = PageLoader(archive: archive, capacity: 5)
        let pageBytes = png(width: 800, height: 1200).count
        let beforePeek = await counting.bytesRead

        let isStrip = await loader.looksLikeLongStrip(from: 2)
        XCTAssertFalse(isStrip)
        let afterPeek = await counting.bytesRead
        XCTAssertGreaterThanOrEqual(afterPeek - beforePeek, pageBytes)
        XCTAssertLessThan(afterPeek - beforePeek, pageBytes * 2, "one page read, not three")

        _ = try await loader.page(at: 2, sizing: .fitScreen(maxPixel: 2000))
        let afterDecode = await counting.bytesRead
        XCTAssertEqual(afterDecode, afterPeek, "the opening page is decoded from the peeked bytes, not read again")
    }

    func testATallOpeningPageIsConfirmedAgainstTheNextTwo() async throws {
        let zip = cbz(Array(repeating: (width: 800, height: 7200), count: 6))
        let counting = CountingReader(DataReader(zip))
        let archive = try await ZipComicArchive.open(reader: counting, displayName: "Strip")
        let loader = PageLoader(archive: archive, capacity: 5)

        let isStrip = await loader.looksLikeLongStrip(from: 0)
        XCTAssertTrue(isStrip)
        let afterPeek = await counting.bytesRead
        for index in 0..<3 {
            let page = try await loader.page(at: index, sizing: .fitWidth(pixels: 800))
            XCTAssertEqual(page.width, 800, "decoded width-first, sharp")
        }
        let afterDecode = await counting.bytesRead
        XCTAssertEqual(afterDecode, afterPeek, "all three sampled pages reuse their bytes")
    }

    /// A vertical splash as page one of an ordinary volume mustn't flip it into scroll mode.
    func testATallSplashPageDoesNotMakeABookAStrip() async throws {
        let zip = cbz([(width: 800, height: 4000), (width: 800, height: 1200), (width: 800, height: 1200)])
        let archive = try await ZipComicArchive.open(reader: DataReader(zip), displayName: "Splash")
        let isStrip = await PageLoader(archive: archive, capacity: 5).looksLikeLongStrip(from: 0)
        XCTAssertFalse(isStrip)
    }

    /// Switching layout mid-read must never hand back a page decoded for the other layout —
    /// for a strip, that's the blurry sliver.
    func testAPageDecodedForOneLayoutIsNeverServedToTheOther() async throws {
        let zip = cbz([(width: 800, height: 7200)])
        let archive = try await ZipComicArchive.open(reader: DataReader(zip), displayName: "Strip")
        let loader = PageLoader(archive: archive, capacity: 5)
        let paged = try await loader.page(at: 0, sizing: .fitScreen(maxPixel: 2000))
        XCTAssertLessThan(paged.width, 300)
        let strip = try await loader.page(at: 0, sizing: .fitWidth(pixels: 800))
        XCTAssertEqual(strip.width, 800)
    }

    // MARK: PDF

    private func pdf(width: Double, height: Double) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(box)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// A PDF knows its page sizes outright, and renders a strip straight to width instead of
    /// going through an oversized bitmap.
    func testPDFStripsAreDetectedAndRenderedToWidth() async throws {
        let archive = try PDFComicArchive.open(data: pdf(width: 800, height: 7200), displayName: "Strip.pdf")
        let known = await archive.knownPageSize(at: 0)
        let size = try XCTUnwrap(known)
        XCTAssertTrue(PageShape.isLongStrip(width: size.width, height: size.height))
        let page = try await archive.page(at: 0, sizing: .fitWidth(pixels: 1000))
        XCTAssertEqual(page.width, 1000, accuracy: 2)
        XCTAssertEqual(page.height, 9000, accuracy: 4)
    }

    // MARK: Covers

    /// A strip's cover is its top, cut to a book's shape — shrinking the whole 1:9 page into
    /// 600 pixels would leave a 67-pixel-wide smear.
    func testAStripCoverIsTheTopOfThePageAtFullCoverWidth() throws {
        let cover = try XCTUnwrap(CoverStore.coverImage(from: png(width: 800, height: 7200, redRows: 600)))
        XCTAssertEqual(cover.width, 400)
        XCTAssertEqual(cover.height, 600)
        XCTAssertTrue(isRed(cover, x: 200, y: 10), "the top of the strip, not the middle")
        XCTAssertFalse(isRed(cover, x: 200, y: 590))
    }

    func testAnOrdinaryCoverIsTheWholePage() throws {
        let cover = try XCTUnwrap(CoverStore.coverImage(from: png(width: 800, height: 1200)))
        XCTAssertEqual(cover.width, 400)
        XCTAssertEqual(cover.height, CoverStore.maxPixel)
    }

    // MARK: Sizing a whole strip

    /// Noise, so the JPEG is far bigger than the size probe and the probe is actually tested.
    private func noisyJPEG(width: Int, height: Int) -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt32 = 0x9E37_79B9
        for index in pixels.indices {
            seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5
            pixels[index] = UInt8(truncatingIfNeeded: seed)
        }
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return out as Data
    }

    /// A strip is laid out from every page's height before any page loads, so a page arriving
    /// never shoves the ones below it. That means sizing pages without reading them: a JPEG
    /// states its size in its first few KB, stored or deflated.
    func testPageSizeReadsOnlyTheStartOfAnEntry() async throws {
        let page = noisyJPEG(width: 400, height: 3000)
        XCTAssertGreaterThan(page.count, ZipComicArchive.sizeProbeBytes * 4, "the page must dwarf the probe")
        for deflate in [false, true] {
            let zip = ZipTestBuilder.make([
                .init(name: "001.jpg", data: page, deflate: deflate),
                .init(name: "002.jpg", data: page, deflate: deflate),
            ])
            let counting = CountingReader(DataReader(zip))
            let archive = try await ZipComicArchive.open(reader: counting, displayName: "Strip")
            let before = await counting.bytesRead
            let size = await archive.pageSize(at: 1)
            XCTAssertEqual(size, CGSize(width: 400, height: 3000), "deflate=\(deflate)")
            let cost = await counting.bytesRead - before
            XCTAssertLessThanOrEqual(cost, ZipComicArchive.sizeProbeBytes + 1024, "deflate=\(deflate)")
        }
    }

    /// Tiny pages are shorter than the probe; reading them whole is fine, but it mustn't run
    /// past the entry or trip over the next one.
    func testPageSizeOfAPageSmallerThanTheProbe() async throws {
        let zip = cbz([(width: 800, height: 7200), (width: 800, height: 1200)])
        let archive = try await ZipComicArchive.open(reader: DataReader(zip), displayName: "Small")
        let first = await archive.pageSize(at: 0)
        let last = await archive.pageSize(at: 1)
        XCTAssertEqual(first, CGSize(width: 800, height: 7200))
        XCTAssertEqual(last, CGSize(width: 800, height: 1200))
    }

    func testImageHeadersParseFromATruncatedFile() throws {
        let page = noisyJPEG(width: 400, height: 3000)
        XCTAssertEqual(ImageDecoder.pixelSize(of: page.prefix(4096)), CGSize(width: 400, height: 3000))
        XCTAssertEqual(ImageDecoder.pixelSize(of: png(width: 800, height: 7200).prefix(64)), CGSize(width: 800, height: 7200))
    }

    /// WebP from ImageIO's own encoder when it has one; the hand-built headers cover all three
    /// chunk kinds regardless.
    func testWebPHeaders() throws {
        func riff(_ chunk: String, _ payload: [UInt8]) -> Data {
            Data("RIFF".utf8) + Data([0, 0, 0, 0]) + Data("WEBP".utf8) + Data(chunk.utf8) + Data([0, 0, 0, 0]) + Data(payload)
        }
        // VP8: frame tag, start code, 690 x 5000 as 14-bit little-endian.
        let lossy = riff("VP8 ", [0, 0, 0, 0x9D, 0x01, 0x2A, 0xB2, 0x02, 0x88, 0x13])
        XCTAssertEqual(HeaderSize.webP(lossy), CGSize(width: 690, height: 5000))
        // VP8L: signature, then (690 - 1) | (5000 - 1) << 14.
        let packed: UInt32 = 689 | 4999 << 14
        let lossless = riff("VP8L", [0x2F, UInt8(packed & 0xFF), UInt8(packed >> 8 & 0xFF), UInt8(packed >> 16 & 0xFF), UInt8(packed >> 24), 0, 0, 0, 0, 0])
        XCTAssertEqual(HeaderSize.webP(lossless), CGSize(width: 690, height: 5000))
        // VP8X: flags, reserved, then 24-bit (size - 1) fields.
        let extended = riff("VP8X", [0, 0, 0, 0, 0xB1, 0x02, 0x00, 0x87, 0x13, 0x00])
        XCTAssertEqual(HeaderSize.webP(extended), CGSize(width: 690, height: 5000))
        XCTAssertNil(HeaderSize.webP(Data("not an image at all, not even close".utf8)))
    }

    func testAPrefixOfADeflateStreamInflatesAsFarAsItGoes() throws {
        let original = noisyJPEG(width: 400, height: 3000)
        let deflated = ZipTestBuilder.deflate(original)
        let prefix = ZipReader.inflatePrefix(deflated.prefix(8192), maxOutput: 64 * 1024)
        XCTAssertGreaterThan(prefix.count, 4096)
        XCTAssertEqual(prefix, original.prefix(prefix.count), "a true prefix of the original bytes")
    }

    func testFolderPagesAreSizedFromTheirHeaders() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "mango-strip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try png(width: 690, height: 5000).write(to: folder.appending(path: "001.png"))
        let archive = try FolderComicArchive.open(folder: folder, displayName: "Loose")
        let size = await archive.pageSize(at: 0)
        XCTAssertEqual(size, CGSize(width: 690, height: 5000))
    }
}
