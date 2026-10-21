import XCTest

@MainActor
final class NASReaderFlowTests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.vanities.mangonasreaderqa")

    func testPagedChapterServiceLossShowsRetryAndRestoresPosition() async throws {
        try await chapterServiceLoss(scrolling: false)
    }

    func testScrollingChapterServiceLossShowsRetryAndRestoresPosition() async throws {
        try await chapterServiceLoss(scrolling: true)
    }

    func testFailedChapterCanBeSkippedRetriedAndUndone() async throws {
        try await chapterServiceLoss(scrolling: false, skipFailedChapter: true)
    }

    private func chapterServiceLoss(scrolling: Bool, skipFailedChapter: Bool = false) async throws {
        // Failed checkpoints return normally: XCTest's synchronous failure interruption
        // cannot run an async main-actor teardown while this async test owns that actor.
        continueAfterFailure = true
        let landscape = ProcessInfo.processInfo.environment["QA_ORIENTATION"] == "landscape"
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        app.terminate()
        let service = try FixtureServiceControl()
        try await service.setRunning(true)
        app.launchArguments = scrolling ? ["--scrolling"] : []
        app.launch()
        verifyWindow(landscape: landscape)
        app.buttons["Open generated remote novel"].tap()
        let prose = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Chapter 1, paragraph 0")).firstMatch
        let opened = prose.waitForExistence(timeout: 15)
        XCTAssertTrue(opened, app.debugDescription)
        guard opened else { return }
        let next = app.buttons["Next chapter"]
        if !next.isHittable { app.webViews.firstMatch.tap() }
        XCTAssertTrue(next.isHittable, app.debugDescription)
        let stopped = try await service.setRunning(false)
        next.tap()
        let retry = app.buttons["Retry"]
        let canRetry = retry.waitForExistence(timeout: 12)
        capture("Chapter failure with Retry")
        XCTAssertTrue(canRetry, "Chapter read failure needs a recovery control.\n\(app.debugDescription)")
        guard canRetry else { return }
        XCTAssertTrue(app.staticTexts["Couldn't load this chapter"].exists)
        if skipFailedChapter {
            app.buttons["Next chapter"].tap()
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Chapter 3 of 24")).firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(retry.waitForExistence(timeout: 10), app.debugDescription)
        }
        retry.tap() // A retry before the source recovers must remain recoverable.
        XCTAssertTrue(retry.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Couldn't load this chapter"].exists)
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        let restarted = try await service.setRunning(true)
        XCTAssertGreaterThan(restarted.generation, stopped.generation)
        retry.tap()
        let chapter = skipFailedChapter ? 3 : 2
        let recovered = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Chapter \(chapter), paragraph 0")).firstMatch
        XCTAssertTrue(recovered.waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(retry.exists)
        capture("Recovered chapter \(chapter)")
        if skipFailedChapter {
            let undo = app.buttons["Undo position jump"]
            if !undo.isHittable { app.webViews.firstMatch.tap() }
            undo.tap()
            let previous = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Chapter 2, paragraph 0")).firstMatch
            XCTAssertTrue(previous.waitForExistence(timeout: 10), "Retry must retain the navigation history")
            if !app.buttons["Next chapter"].isHittable { app.webViews.firstMatch.tap() }
            app.buttons["Next chapter"].tap()
            XCTAssertTrue(recovered.waitForExistence(timeout: 10))
        }
        app.terminate()
        app.launchArguments += ["--resume"]
        app.launch()
        verifyWindow(landscape: landscape)
        app.buttons["Open generated remote novel"].tap()
        XCTAssertTrue(recovered.waitForExistence(timeout: 15), "The failed chapter's target position must survive relaunch.\n\(app.debugDescription)")
        capture("Chapter \(chapter) after relaunch")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func verifyWindow(landscape: Bool) {
        let geometry = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            MainActor.assumeIsolated {
                let frame = self.app.windows.firstMatch.frame
                return frame.width > 0 && (landscape ? frame.width > frame.height : frame.height > frame.width)
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [geometry], timeout: 10), .completed)
        print("READER_UI_WINDOW: \(app.windows.firstMatch.frame)")
    }
}
