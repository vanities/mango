import XCTest
@testable import Mango

final class HiddenContentSessionTests: XCTestCase {
    func testNewSessionAlwaysStartsLocked() {
        XCTAssertFalse(HiddenContentSession().isUnlocked)
    }

    func testUnlockExpiresAtThreeHoursWithoutActivity() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var session = HiddenContentSession()
        session.unlock(at: start)
        XCTAssertFalse(session.expire(at: start.addingTimeInterval(10_799)))
        XCTAssertTrue(session.isUnlocked)
        XCTAssertTrue(session.expire(at: start.addingTimeInterval(10_800)))
        XCTAssertFalse(session.isUnlocked)
    }

    func testActivityExtendsAnExistingSession() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var session = HiddenContentSession()
        session.unlock(at: start)
        session.recordActivity(at: start.addingTimeInterval(7_200))
        XCTAssertFalse(session.expire(at: start.addingTimeInterval(10_800)))
        XCTAssertTrue(session.expire(at: start.addingTimeInterval(18_000)))
    }

    func testReturningAfterDeadlineDoesNotUnlock() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var session = HiddenContentSession()
        session.unlock(at: start)
        session.recordActivity(at: start.addingTimeInterval(10_800))
        XCTAssertFalse(session.isUnlocked)
        session.recordActivity(at: start.addingTimeInterval(10_801))
        XCTAssertFalse(session.isUnlocked)
    }

    func testLockRequiresAnotherExplicitUnlock() {
        var session = HiddenContentSession()
        session.unlock()
        session.lock()
        session.recordActivity()
        XCTAssertFalse(session.isUnlocked)
        session.unlock()
        XCTAssertTrue(session.isUnlocked)
    }
}
