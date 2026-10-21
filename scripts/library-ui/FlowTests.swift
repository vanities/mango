import XCTest

@MainActor
final class FlowTests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: ProcessInfo.processInfo.environment["MANGO_QA_BUNDLE"] ?? "com.vanities.mangoqa")
    override func setUpWithError() throws {
        continueAfterFailure = false
        if let orientation = ProcessInfo.processInfo.environment["QA_ORIENTATION"] {
            XCUIDevice.shared.orientation = orientation == "landscape" ? .landscapeLeft : .portrait
        }
        app.terminate()
        app.launch()
        assertWindowOrientation()
    }

    private func assertWindowOrientation() {
        if let orientation = ProcessInfo.processInfo.environment["QA_ORIENTATION"] {
            let geometry = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                MainActor.assumeIsolated {
                    let frame = self.app.windows.firstMatch.frame
                    return frame.width > 0 && (orientation == "landscape" ? frame.width > frame.height : frame.height > frame.width)
                }
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [geometry], timeout: 10), .completed)
            print("LIBRARY_UI_WINDOW: \(app.windows.firstMatch.frame)")
        }
    }
    func tap(_ label: String) {
        let button = app.buttons[label].firstMatch
        let readerControls = ["Close", "Bookmark this spot", "Remove bookmark", "Chapters and reading settings",
                              "Smaller text", "Larger text", "Previous chapter", "Next chapter", "Undo position jump"]
        if readerControls.contains(label), button.exists, !button.isHittable, app.webViews.firstMatch.exists {
            wakeNovelControls()
        }
        if button.exists && button.isHittable {
            button.tap()
            return
        }
        XCTAssertTrue(button.waitForExistence(timeout: 10), "Missing button: \(label)\n\(app.debugDescription)")
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 30), .completed, app.debugDescription)
        button.tap()
    }
    func tools() {
        tap("More")
        // iPadOS can put the app's More menu inside its own toolbar overflow menu.
        if !app.buttons["Library tools…"].exists {
            let submenu = app.collectionViews.buttons["More"].firstMatch
            if submenu.exists { submenu.tap() }
        }
        tap("Library tools…")
    }

    private func selectNavigation(_ label: String) {
        let name = NSPredicate(format: "label == %@", label)
        if let button = app.buttons.matching(name).allElementsBoundByIndex.first(where: { $0.isHittable }) {
            button.tap()
            XCTAssertTrue(button.isSelected, app.debugDescription)
        } else {
            let cell = app.cells.matching(name).firstMatch
            XCTAssertTrue(cell.waitForExistence(timeout: 5) && cell.isHittable, app.debugDescription)
            cell.tap()
            XCTAssertTrue(cell.isSelected, app.debugDescription)
        }
    }
    func testBackupExportAndRestorePreview() {
        tools()
        tap("Backup and restore")
        tap("Export backup…")
        tap("Save")
        if app.buttons["Replace"].waitForExistence(timeout: 1) { tap("Replace") }
        tap("Choose backup to restore…")
        let backup = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "Mango-backup")).firstMatch
        if !backup.waitForExistence(timeout: 2) {
            if app.buttons["Browse"].exists { tap("Browse") }
            let local = app.cells.matching(NSPredicate(format: "label IN %@", ["On My iPhone", "On My iPad"])).firstMatch
            XCTAssertTrue(local.waitForExistence(timeout: 10), app.debugDescription)
            local.tap()
            let folder = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@ AND NOT label CONTAINS %@", "Mango", "backup")).firstMatch
            XCTAssertTrue(folder.waitForExistence(timeout: 10), app.debugDescription)
            folder.tap()
        }
        XCTAssertTrue(backup.waitForExistence(timeout: 10), app.debugDescription)
        backup.tap()
        XCTAssertTrue(app.buttons["Restore missing state"].waitForExistence(timeout: 10), app.debugDescription)
        tap("Restore missing state")
        XCTAssertTrue(app.staticTexts["Restore complete."].waitForExistence(timeout: 10))
    }
    func testNovelChapterSearch() {
        tap("Novels")
        openNovelShelf()
        let start = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Continue' OR label BEGINSWITH 'Start' OR label BEGINSWITH 'Read'")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10), app.debugDescription)
        start.tap()
        tap("Chapters and reading settings")
        tap("Find in this chapter")
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        app.searchFields.firstMatch.tap()
        let keyboardTip = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Speed up your typing")).firstMatch
        if keyboardTip.waitForExistence(timeout: 2) { tap("Continue") }
        app.searchFields.firstMatch.typeText("the")
        XCTAssertEqual(app.searchFields.firstMatch.value as? String, "the")
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Novel chapter search"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func openNovelShelf() {
        let shelf = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Ashfall Almanac")).firstMatch
        XCTAssertTrue(shelf.waitForExistence(timeout: 10), app.debugDescription)
        shelf.tap()
    }

    private func wakeNovelControls() {
        if app.buttons["Close"].firstMatch.isHittable { return }
        app.webViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    func testNovelChapterBookmarkBackgroundAndRelaunch() {
        tap("Novels")
        openNovelShelf()
        let start = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Continue' OR label BEGINSWITH 'Start' OR label BEGINSWITH 'Read'")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10), app.debugDescription)
        start.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        wakeNovelControls()
        tap("Chapters and reading settings")
        XCTAssertTrue(app.navigationBars["Reading"].waitForExistence(timeout: 10), app.debugDescription)
        for _ in 0..<4 where !app.buttons["Chapter 3"].firstMatch.isHittable {
            app.collectionViews.element(boundBy: app.collectionViews.count - 1).swipeUp()
        }
        tap("Chapter 3")
        wakeNovelControls()
        let position = app.staticTexts["Chapter 3 of 7"].firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 10), app.debugDescription)
        if app.buttons["Bookmark this spot"].firstMatch.exists { tap("Bookmark this spot") }
        XCTAssertTrue(app.buttons["Remove bookmark"].firstMatch.waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.terminate()
        app.launch()
        assertWindowOrientation()
        tap("Novels")
        openNovelShelf()
        let resume = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Continue' OR label BEGINSWITH 'Start' OR label BEGINSWITH 'Read'")).firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 10), app.debugDescription)
        resume.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        wakeNovelControls()
        XCTAssertTrue(app.staticTexts["Chapter 3 of 7"].firstMatch.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["Remove bookmark"].firstMatch.exists, app.debugDescription)
        assertWindowOrientation()
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Novel resumed after Home and process termination"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        wakeNovelControls()
        tap("Close")
    }

    func testAllLibraryTabsOpen() {
        for label in ["Stats", "Sources", "Settings", "Library"] {
            selectNavigation(label)
            XCTAssertTrue(app.navigationBars[label].waitForExistence(timeout: 10), app.debugDescription)
            let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screen.name = label
            screen.lifetime = .keepAlways
            add(screen)
            if label == "Sources" {
                // The sidebar has its own collection; scroll the wider Sources detail.
                let detail = app.collectionViews.allElementsBoundByIndex.max { $0.frame.width < $1.frame.width }
                XCTAssertNotNil(detail, app.debugDescription)
                detail?.swipeUp()
                detail?.swipeUp()
                let tips = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                tips.name = "Sources Files tips"
                tips.lifetime = .keepAlways
                add(tips)
                // Scrolling back also expands the system's minimized tab bar.
                detail?.swipeDown()
            }
        }
    }
}
