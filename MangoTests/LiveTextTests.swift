import SwiftUI
import VisionKit
import XCTest
@testable import Mango

@MainActor
final class LiveTextTests: XCTestCase {
    func testRecognizedPageEnablesSelectionAndBlankPageHasNoResults() async throws {
        guard ImageAnalyzer.isSupported else { throw XCTSkip("Live Text requires supported hardware") }
        let size = CGSize(width: 1200, height: 800)
        let renderer = UIGraphicsImageRenderer(size: size)
        let page = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            ("MANGO LIBRARY\nSelect text on this page." as NSString).draw(
                in: CGRect(x: 80, y: 150, width: 1040, height: 500),
                withAttributes: [.font: UIFont.systemFont(ofSize: 64), .foregroundColor: UIColor.black])
        }
        let analyzer = ImageAnalyzer()
        let analysis = try await analyzer.analyze(page, configuration: .init([.text]))
        XCTAssertTrue(analysis.hasResults(for: .text))
        XCTAssertTrue(analysis.transcript.contains("MANGO LIBRARY"), analysis.transcript)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: LiveTextImage(image: page, analysis: analysis))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        func imageView(in view: UIView) -> UIImageView? {
            if let image = view as? UIImageView { return image }
            return view.subviews.lazy.compactMap { imageView(in: $0) }.first
        }
        let view = try XCTUnwrap(imageView(in: host.view))
        let interaction = try XCTUnwrap(view.interactions.first { $0 is ImageAnalysisInteraction } as? ImageAnalysisInteraction)
        XCTAssertTrue(view.isUserInteractionEnabled)
        XCTAssertEqual(interaction.preferredInteractionTypes, .textSelection)
        XCTAssertNotNil(interaction.analysis)
        let blank = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let empty = try await analyzer.analyze(blank, configuration: .init([.text]))
        XCTAssertFalse(empty.hasResults(for: .text))
    }
}
