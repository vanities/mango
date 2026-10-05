import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Mango

@MainActor
final class ReaderResizeTests: XCTestCase {
    func testDisplayTransitionsKeepThePageAndDecodeForTheNewViewport() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 2400, height: 3200,
                                            bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(gray: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2400, height: 3200))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let file = folder.appending(path: "Resize.cbz")
        try ZipTestBuilder.make((0..<8).map {
            .init(name: "page-\($0).png", data: data as Data, deflate: false)
        }).write(to: file)
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        let library = LibraryModel(store: LibraryStore(directory: folder.appending(path: "State")),
                                   covers: CoverStore(directory: folder.appending(path: "Covers"),
                                                      customDirectory: folder.appending(path: "Custom")),
                                   settings: settings)
        library.addOpenedFile(file)
        for _ in 0..<200 where library.requestedComic == nil || library.isScanning {
            try await Task.sleep(for: .milliseconds(10))
        }
        let engine = ReaderEngine(comic: try XCTUnwrap(library.requestedComic), library: library, settings: settings)
        await engine.open(screenPixels: CGSize(width: 390, height: 700))
        defer { engine.close() }
        XCTAssertNil(engine.openError)
        engine.goToPage(4)
        let narrowImage = await engine.image(at: 4)
        let narrow = try XCTUnwrap(narrowImage)
        engine.updateViewport(CGSize(width: 1400, height: 1000))
        XCTAssertTrue(engine.groups[engine.groupIndex].contains(4), "The same page stays visible in a spread")
        let wideImage = await engine.image(at: 4)
        let wide = try XCTUnwrap(wideImage)
        XCTAssertGreaterThan(wide.width, narrow.width, "Opening the display must request a sharper decode")
        engine.updateViewport(CGSize(width: 390, height: 700))
        XCTAssertEqual(engine.currentPage, 4, "Closing the display must return to the page that was open")
    }
}
