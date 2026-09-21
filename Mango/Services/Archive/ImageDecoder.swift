import CoreGraphics
import Foundation
import ImageIO
import os

/// Turns encoded page bytes into a bitmap sized for the screen.
///
/// Full-size decoding is the fastest way to run a reader out of memory: a 2,000×3,000 page is
/// 24 MB decoded, and prefetching a handful of those on a phone gets the app killed. Every page
/// goes through `CGImageSourceCreateThumbnailAtIndex`, which decodes straight to the target size
/// instead of decoding full-size and then shrinking.
enum ImageDecoder {
    /// Longest-edge budget: enough to stay sharp when the reader zooms in a bit, capped so one
    /// page can never blow past ~64 MB decoded.
    static let maxPixelCap = 4096

    static func downsample(_ data: Data, maxPixel: Int) -> CGImage? {
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
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixel, maxPixelCap),
        ] as [CFString: Any] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            Logger.pages.error("[decode] thumbnail failed (\(data.count) bytes)")
            return nil
        }
        Logger.pages.debug("[decode] \(data.count)B → \(image.width)x\(image.height) in \(sw.ms, format: .fixed(precision: 1))ms")
        return image
    }

    /// Pixel dimensions without decoding the image. Used to decide whether a page is a
    /// double-page spread (wider than tall) before it's on screen.
    static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }
}
