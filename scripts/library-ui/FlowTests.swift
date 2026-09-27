import XCTest

final class FlowTests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "com.vanities.mangoqa")
    override func setUpWithError() throws {
        continueAfterFailure = false
        app.terminate()
        app.launch()
    }
    func tap(_ label: String) {
        let button = app.buttons[label].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "Missing button: \(label)\n\(app.debugDescription)")
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 30), .completed, app.debugDescription)
        button.tap()
    }
    func tools() {
        tap("More")
        tap("Library tools…")
    }
    func testBackupExportAndRestorePreview() {
        tools()
        tap("Backup and restore")
        tap("Export backup…")
        tap("Save")
        tap("Choose backup to restore…")
        tap("Browse")
        let local = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "On My iPhone")).firstMatch
        XCTAssertTrue(local.waitForExistence(timeout: 10), app.debugDescription)
        local.tap()
        let folder = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "Mango")).firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 10), app.debugDescription)
        folder.tap()
        let backup = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Mango-backup")).firstMatch
        XCTAssertTrue(backup.waitForExistence(timeout: 10), app.debugDescription)
        backup.tap()
        XCTAssertTrue(app.buttons["Restore missing state"].waitForExistence(timeout: 10), app.debugDescription)
        tap("Restore missing state")
        XCTAssertTrue(app.staticTexts["Restore complete."].waitForExistence(timeout: 10))
    }
    func testNovelChapterSearch() {
        tap("Novels")
        tap("2, Ashfall Almanac")
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
}
