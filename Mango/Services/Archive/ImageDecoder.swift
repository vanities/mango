import CoreGraphics
import Foundation
import ImageIO
import os

/// How a page should be sized when it's decoded.
enum PageSizing: Hashable, Sendable {
    /// Bound the longest edge — right for a page shown whole on one screen.
    case fitScreen(maxPixel: Int)
    /// Bound the width and let the height run — right for a long strip scrolled vertically,
    /// where bounding the longest edge would make an 800×12000 strip 273 pixels wide.
    case fitWidth(pixels: Int)
}

/// Turns encoded page bytes into a bitmap sized for the screen.
///
/// Full-size decoding is the fastest way to run a reader out of memory: a 2,000×3,000 page is
/// 24 MB decoded, and prefetching a handful of those on a phone gets the app killed. Every page
/// goes through `CGImageSourceCreateThumbnailAtIndex`, which decodes straight to the target size
/// instead of decoding full-size and then shrinking.
enum ImageDecoder {
    /// Longest-edge cap for a whole page on screen: sharp under a little zoom, and one page can
    /// never pass ~64 MB decoded.
    static let maxPixelCap = 4096
    /// The most one decoded page may weigh. Long strips are sized against this rather than an
    /// edge length, because their whole point is to be very tall.
    static let decodeBudgetBytes = 64 * 1024 * 1024
    /// Tallest slice drawn as a single image. GPUs refuse textures past 8–16K; 4K is safe on
    /// every device and keeps each slice cheap for the lazy stack to create and discard.
    static let maxTileHeight = 4096

    static func decode(_ data: Data, sizing: PageSizing) -> CGImage? {
        switch sizing {
        case .fitScreen(let maxPixel):
            return downsample(data, maxPixel: maxPixel)
        case .fitWidth(let pixels):
            return decodeToWidth(data, width: pixels)
        }
    }

    static func downsample(_ data: Data, maxPixel: Int) -> CGImage? {
        thumbnail(data, maxPixel: min(maxPixel, maxPixelCap))
    }

    private static func decodeToWidth(_ data: Data, width: Int) -> CGImage? {
        guard let size = pixelSize(of: data), size.width > 0, size.height > 0 else {
            return thumbnail(data, maxPixel: maxPixelCap)
        }
        let target = widthFirstSize(of: size, width: width)
        // The thumbnail API bounds the longest edge, so hand it whichever edge that is.
        return thumbnail(data, maxPixel: max(1, Int(max(target.width, target.height))))
    }

    /// Width-first sizing: as wide as asked but never wider than the source (upscaling adds
    /// bytes, not detail), as tall as that makes it, then shrunk only if it would bust the budget.
    static func widthFirstSize(of source: CGSize, width: Int) -> CGSize {
        guard source.width > 0, source.height > 0 else { return .zero }
        var targetWidth = min(Double(width), source.width)
        var targetHeight = source.height * targetWidth / source.width
        let bytes = targetWidth * targetHeight * 4
        if bytes > Double(decodeBudgetBytes) {
            let shrink = (Double(decodeBudgetBytes) / bytes).squareRoot()
            targetWidth *= shrink
            targetHeight *= shrink
        }
        return CGSize(width: targetWidth.rounded(.down), height: targetHeight.rounded(.down))
    }

    private static func thumbnail(_ data: Data, maxPixel: Int) -> CGImage? {
        let sw = Stopwatch()
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            Logger.pages.error("[decode] not a decodable image (\(data.count) bytes)")
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as [CFString: Any] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            Logger.pages.error("[decode] thumbnail failed (\(data.count) bytes)")
            return nil
        }
        Logger.pages.debug("[decode] \(data.count)B → \(image.width)x\(image.height) in \(sw.ms, format: .fixed(precision: 1))ms")
        return image
    }

    /// Longest edge of a page-grid thumbnail.
    static let thumbnailPixels = 300

    /// A page-grid thumbnail: the page shrunk whole, or for a long strip its top, cut to a
    /// page's shape — a whole strip at thumbnail size is a sliver.
    static func thumbnail(from data: Data) -> CGImage? {
        guard let size = pixelSize(of: data), PageShape.isLongStrip(width: size.width, height: size.height),
              let strip = decode(data, sizing: .fitWidth(pixels: thumbnailPixels * 2 / 3))
        else { return downsample(data, maxPixel: thumbnailPixels) }
        return strip.cropping(to: CGRect(x: 0, y: 0, width: strip.width, height: min(strip.height, strip.width * 3 / 2))) ?? strip
    }

    /// Pixel dimensions from the header, without decoding a single pixel. Works on a file's first
    /// few KB as well as the whole thing — the header is all it needs.
    static func pixelSize(of data: Data) -> CGSize? {
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let size = pixelSize(from: properties) {
            return size
        }
        // ImageIO's PNG reader gives up on a cut-short file, but PNG and WebP keep their size at a
        // fixed spot in the first 30 bytes, so read it from there.
        return HeaderSize.png(data) ?? HeaderSize.webP(data)
    }

    static func pixelSize(from properties: [CFString: Any]) -> CGSize? {
        guard let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        // EXIF orientations 5–8 are rotated a quarter turn: width and height swap on screen.
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// Slices a tall image into stacked tiles no taller than `maxTileHeight`. `cropping(to:)`
    /// shares the original's pixels, so this costs no extra memory.
    static func tiles(of image: CGImage) -> [CGImage] {
        guard image.height > maxTileHeight else { return [image] }
        var tiles: [CGImage] = []
        var y = 0
        while y < image.height {
            let height = min(maxTileHeight, image.height - y)
            if let tile = image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: height)) {
                tiles.append(tile)
            }
            y += height
        }
        return tiles
    }
}

/// Telling a long-strip (webtoon, manhwa) apart from an ordinary comic by the shape of its pages.
enum PageShape {
    /// An ordinary page is about 1.4 times taller than wide. Past 2.2 it's a strip.
    static let longStripRatio = 2.2

    static func isLongStrip(width: Double, height: Double) -> Bool {
        guard width > 0 else { return false }
        return height / width >= longStripRatio
    }

    /// Most pages have to be tall — one vertical splash page in an ordinary volume isn't a
    /// webtoon, and shouldn't flip the whole book into continuous scroll.
    static func looksLikeLongStrip(_ sizes: [CGSize]) -> Bool {
        guard !sizes.isEmpty else { return false }
        let tall = sizes.count { isLongStrip(width: $0.width, height: $0.height) }
        return Double(tall) / Double(sizes.count) > 0.5
    }
}

/// Image sizes read straight from the bytes, for formats that put them at a fixed offset.
enum HeaderSize {
    static func png(_ data: Data) -> CGSize? {
        let bytes = [UInt8](data.prefix(24))
        guard bytes.count == 24, bytes[0...7] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
              bytes[12...15] == [0x49, 0x48, 0x44, 0x52] // IHDR
        else { return nil }
        let width = bigEndian(bytes, 16), height = bigEndian(bytes, 20)
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: Int(width), height: Int(height))
    }

    static func webP(_ data: Data) -> CGSize? {
        let bytes = [UInt8](data.prefix(30))
        guard bytes.count == 30, bytes[0...3] == [0x52, 0x49, 0x46, 0x46], bytes[8...11] == [0x57, 0x45, 0x42, 0x50] else {
            return nil
        }
        switch String(bytes: bytes[12...15], encoding: .ascii) {
        case "VP8 ":
            // Lossy: 14-bit dimensions after the frame tag and the 9D 01 2A start code.
            guard bytes[23...25] == [0x9D, 0x01, 0x2A] else { return nil }
            return CGSize(width: Int(littleEndian16(bytes, 26) & 0x3FFF), height: Int(littleEndian16(bytes, 28) & 0x3FFF))
        case "VP8L":
            // Lossless: after the 0x2F signature, two 14-bit (size - 1) fields packed together.
            guard bytes[20] == 0x2F else { return nil }
            let bits = UInt32(bytes[21]) | UInt32(bytes[22]) << 8 | UInt32(bytes[23]) << 16 | UInt32(bytes[24]) << 24
            return CGSize(width: Int(bits & 0x3FFF) + 1, height: Int((bits >> 14) & 0x3FFF) + 1)
        case "VP8X":
            // Extended: 24-bit (size - 1) canvas fields.
            let width = Int(bytes[24]) | Int(bytes[25]) << 8 | Int(bytes[26]) << 16
            let height = Int(bytes[27]) | Int(bytes[28]) << 8 | Int(bytes[29]) << 16
            return CGSize(width: width + 1, height: height + 1)
        default:
            return nil
        }
    }

    private static func bigEndian(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }

    private static func littleEndian16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }
}
