import XCTest
@testable import CodeFlightApp

@MainActor
final class SheetDraftProtectionTests: XCTestCase {
    func testCancelKeepsNavigationPendingUntilExplicitDiscard() {
        let protection = SheetDraftGuard()
        var navigations: [String] = []
        protection.request(dirty: true) { navigations.append("first") }
        XCTAssertTrue(protection.isPresented)
        XCTAssertTrue(navigations.isEmpty)
        // A second shortcut must not replace the action being confirmed.
        protection.request(dirty: true) { navigations.append("second") }
        protection.cancel()
        XCTAssertFalse(protection.isPresented)
        XCTAssertTrue(navigations.isEmpty)
        protection.discard()
        XCTAssertTrue(navigations.isEmpty)
        protection.request(dirty: true) { navigations.append("confirmed") }
        protection.discard()
        protection.discard()
        XCTAssertEqual(navigations, ["confirmed"])
    }

    func testCleanNavigationAfterCancelledDraftHasNoStaleAction() {
        let protection = SheetDraftGuard()
        var selected = "draft"
        protection.request(dirty: true) { selected = "discarded" }
        protection.cancel()
        protection.request(dirty: false) { selected = "saved" }
        XCTAssertEqual(selected, "saved")
        XCTAssertFalse(protection.isPresented)
        protection.discard()
        XCTAssertEqual(selected, "saved")
    }
}
