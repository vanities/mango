import CoreGraphics
import Foundation
import os

/// Crop margins: finds the plain border scans carry — white paper, black bleed — so the art can
/// fill the screen.
///
/// It must never cut art, so every rule leans towards leaving a page alone. A side is only cut
/// when its edge is near-white or near-black *and* flat across the whole edge, and when that
/// band ends before `maxCutFraction` of the page — a flat band that runs further is more likely
/// a quiet panel or a night sky than paper, so that side keeps all of it.
enum MarginTrimmer {
    /// The most of one side that can be paper rather than art.
    static let maxCutFraction = 0.2
    /// Analysis runs on a copy this big on its longest side — plenty to find an edge.
    private static let analysisPixels = 400
    /// How far a margin pixel may stray from the side's colour, out of 255.
    private static let tolerance = 20
    /// The share of a row or column that must match for it to count as margin (dust, specks).
    private static let matchShare = 0.97
    /// Kept inside the found edge, as a share of the page, so anti-aliased linework isn't clipped.
    private static let padding = 0.01

    /// The part of the page worth keeping, in the image's own pixels (top-left origin), or nil
    /// when there's nothing worth cutting.
    static func trimRect(for image: CGImage) -> CGRect? {
        let scale = min(1, Double(analysisPixels) / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let gray = grayscale(image, width: width, height: height) else { return nil }
        func pixel(_ x: Int, _ y: Int) -> Int { Int(gray[y * width + x]) }

        let top = band(count: height, length: width) { line, i in pixel(i, line) }
        let bottom = band(count: height, length: width) { line, i in pixel(i, height - 1 - line) }
        let left = band(count: width, length: height) { line, i in pixel(line, i) }
        let right = band(count: width, length: height) { line, i in pixel(width - 1 - line, i) }
        guard top + bottom + left + right > 0 else { return nil }

        let padX = Int((Double(width) * padding).rounded(.up)), padY = Int((Double(height) * padding).rounded(.up))
        let x0 = max(0, left - padX), y0 = max(0, top - padY)
        let x1 = min(width, width - right + padX), y1 = min(height, height - bottom + padY)
        guard x1 > x0, y1 > y0, (x0, y0, x1, y1) != (0, 0, width, height) else { return nil }
        let inverse = 1 / scale
        return CGRect(x: Double(x0) * inverse, y: Double(y0) * inverse,
                      width: Double(x1 - x0) * inverse, height: Double(y1 - y0) * inverse).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    /// The page with its margins cut, or the page itself when there's nothing to cut.
    static func trim(_ image: CGImage) -> CGImage {
        let sw = Stopwatch()
        guard let rect = trimRect(for: image), let cropped = image.cropping(to: rect) else { return image }
        Logger.pages.debug("[trim] \(image.width)x\(image.height) → \(cropped.width)x\(cropped.height) in \(sw.ms, format: .fixed(precision: 1))ms")
        return cropped
    }

    /// How many lines in from one side are flat margin: 0 when the edge isn't paper-coloured,
    /// isn't flat, or the flat band runs past the cap.
    private static func band(count: Int, length: Int, value: (_ line: Int, _ index: Int) -> Int) -> Int {
        guard count > 0, length > 0 else { return 0 }
        let edge = (0..<length).map { value(0, $0) }.sorted()[length / 2]
        guard edge >= 215 || edge <= 40 else { return 0 }
        let limit = Int(Double(count) * maxCutFraction)
        var lines = 0
        while lines < count {
            var matches = 0
            for index in 0..<length where abs(value(lines, index) - edge) <= tolerance { matches += 1 }
            guard Double(matches) >= Double(length) * matchShare else { break }
            lines += 1
            if lines > limit { return 0 }
        }
        return lines
    }

    private static func grayscale(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
