import CoreGraphics
import XCTest
@testable import Mango

/// Crop margins cuts the plain paper border scans carry so the art fills the screen. It must
/// never cut art: when in doubt, it leaves the page alone.
final class MarginTrimmerTests: XCTestCase {
    /// A page of `background` with a block of `ink` at `content` (top-left origin, in pixels).
    private func page(width: Int = 800, height: Int = 1200, background: CGFloat, ink: CGFloat,
                      content: CGRect, noise: Bool = false) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(CGColor(gray: background, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if noise {
            // Scanned paper: a gentle gradient, not a flat colour.
            for row in 0..<height {
                let shade = background - CGFloat(row) / CGFloat(height) * 0.3
                context.setFillColor(CGColor(gray: shade, alpha: 1))
                context.fill(CGRect(x: 0, y: row, width: width, height: 1))
            }
        }
        context.setFillColor(CGColor(gray: ink, alpha: 1))
        // CG's origin is bottom-left; flip the top-left rect.
        context.fill(CGRect(x: content.minX, y: CGFloat(height) - content.maxY, width: content.width, height: content.height))
        return context.makeImage()!
    }

    func testWhitePaperAroundTheArtIsCut() throws {
        let content = CGRect(x: 80, y: 100, width: 640, height: 1000)
        let rect = try XCTUnwrap(MarginTrimmer.trimRect(for: page(background: 1, ink: 0.1, content: content)))
        // Within a few pixels (analysis runs on a downscaled copy, and keeps a little padding).
        XCTAssertEqual(rect.minX, content.minX, accuracy: 16)
        XCTAssertEqual(rect.minY, content.minY, accuracy: 16)
        XCTAssertEqual(rect.maxX, content.maxX, accuracy: 16)
        XCTAssertEqual(rect.maxY, content.maxY, accuracy: 16)
        XCTAssertTrue(rect.contains(content.insetBy(dx: 12, dy: 12)), "never into the art")
    }

    func testBlackBleedIsCutToo() throws {
        let content = CGRect(x: 60, y: 60, width: 680, height: 1080)
        let rect = try XCTUnwrap(MarginTrimmer.trimRect(for: page(background: 0, ink: 0.8, content: content)))
        XCTAssertEqual(rect.minX, 60, accuracy: 16)
    }

    func testArtToTheEdgeIsLeftAlone() {
        let fullBleed = page(background: 0.5, ink: 0.1, content: CGRect(x: 0, y: 0, width: 800, height: 1200))
        XCTAssertNil(MarginTrimmer.trimRect(for: fullBleed))
    }

    /// A band past the cap is more likely a quiet or dark panel than paper: that side keeps it
    /// all, rather than being cut to the cap and losing art.
    func testABandPastTheCapIsLeftWhole() {
        let quietPanel = CGRect(x: 0, y: 0, width: 800, height: 500)   // bottom 58% blank
        XCTAssertNil(MarginTrimmer.trimRect(for: page(background: 1, ink: 0.1, content: quietPanel)))
    }

    func testAMarginUnderTheCapIsCut() throws {
        let content = CGRect(x: 0, y: 0, width: 800, height: 1050)    // bottom 12.5% paper
        let rect = try XCTUnwrap(MarginTrimmer.trimRect(for: page(background: 1, ink: 0.1, content: content)))
        XCTAssertEqual(rect.maxY, 1050, accuracy: 16)
        XCTAssertEqual(rect.minY, 0, accuracy: 1, "a side with no margin isn't touched")
    }

    /// Screentone and texture aren't a flat border.
    func testTextureIsNotAMargin() {
        let context = CGContext(data: nil, width: 400, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        var seed: UInt32 = 7
        for y in stride(from: 0, to: 600, by: 2) {
            for x in stride(from: 0, to: 400, by: 2) {
                seed = seed &* 1_103_515_245 &+ 12_345
                context.setFillColor(CGColor(gray: 0.6 + CGFloat(seed >> 24) / 255 * 0.4, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 2, height: 2))
            }
        }
        XCTAssertNil(MarginTrimmer.trimRect(for: context.makeImage()!))
    }

    func testCroppingKeepsTheArt() {
        let content = CGRect(x: 80, y: 100, width: 640, height: 1000)
        let trimmed = MarginTrimmer.trim(page(background: 1, ink: 0.1, content: content))
        XCTAssertLessThan(trimmed.width, 800)
        XCTAssertGreaterThanOrEqual(trimmed.width, 640)
        XCTAssertGreaterThanOrEqual(trimmed.height, 1000)
    }

    func testAPageWithNothingToCutComesBackUnchanged() {
        let fullBleed = page(background: 0.5, ink: 0.1, content: CGRect(x: 0, y: 0, width: 800, height: 1200))
        XCTAssertTrue(MarginTrimmer.trim(fullBleed) === fullBleed)
    }
}
