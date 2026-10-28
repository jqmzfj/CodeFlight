import XCTest
import AppKit
@testable import CodeFlightApp

final class GitDiffHorizontalScrollTests: XCTestCase {
    func testColumnsScrollIndependentlyKeepDiscoveredWidthsAndFitAfterResize() {
        var state = GitDiffHorizontalState()
        state.record([.old: 1000, .new: 600])
        state.set(.old, offset: 500, column: 300)
        state.set(.new, offset: 200, column: 400)
        XCTAssertEqual(state.offset(.old, column: 300), 500)
        XCTAssertEqual(state.offset(.new, column: 400), 200)
        state.record([.old: 50, .new: .nan])
        XCTAssertEqual(state.widths[.old], 1000, "Virtualizing away a long row must not shrink its scroll range")
        state.set(.old, offset: .infinity, column: 300)
        XCTAssertEqual(state.offset(.old, column: 300), 0)
        state.set(.old, offset: 10000, column: 300)
        XCTAssertEqual(state.offset(.old, column: 300), 758)
        state.fit(old: 1200, new: 800)
        XCTAssertEqual(state.offset(.old, column: 300), 0, "Expanding to show the whole line must reset the stored offset")
        XCTAssertEqual(state.offset(.new, column: 400), 0)
        let fresh = GitDiffHorizontalState()
        XCTAssertEqual(fresh.maximum(.old, column: 300), 0)
    }

    func testHorizontalRoutingLeavesVerticalAndDiagonalVerticalGesturesAlone() {
        XCTAssertNil(GitDiffHorizontalState.horizontalDelta(x: 0, y: -20, shift: false))
        XCTAssertNil(GitDiffHorizontalState.horizontalDelta(x: 2, y: -20, shift: false))
        XCTAssertNil(GitDiffHorizontalState.horizontalDelta(x: 2, y: 2, shift: false))
        XCTAssertNil(GitDiffHorizontalState.horizontalDelta(x: .nan, y: 0, shift: false))
        XCTAssertEqual(GitDiffHorizontalState.horizontalDelta(x: -20, y: 1, shift: false), 20)
        XCTAssertEqual(GitDiffHorizontalState.horizontalDelta(x: 20, y: 0, shift: true), -20)
        XCTAssertEqual(GitDiffHorizontalState.horizontalDelta(x: 0, y: -20, shift: true), 20)
        XCTAssertNil(GitDiffHorizontalState.horizontalDelta(x: 0, y: 0, shift: true))
    }

    @MainActor func testNativeScrollerKeyboardAndAccessibilityAreBoundedAndReportPosition() throws {
        let scroller = GitDiffScroller(frame: NSRect(x: 0, y: 0, width: 300, height: 14))
        scroller.isEnabled = true; scroller.maximum = 100; scroller.viewport = 250
        var values: [CGFloat] = []
        scroller.change = { values.append($0) }
        XCTAssertTrue(scroller.accessibilityPerformIncrement())
        XCTAssertEqual(values.last, 24)
        XCTAssertEqual(scroller.doubleValue, 0.24, accuracy: 0.001)
        let end = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 119))
        scroller.keyDown(with: end)
        XCTAssertEqual(values.last, 100)
        XCTAssertTrue(scroller.accessibilityPerformIncrement())
        XCTAssertEqual(values.last, 100)
        XCTAssertTrue(scroller.accessibilityPerformDecrement())
        XCTAssertEqual(values.last, 76)
        let home = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 115))
        scroller.keyDown(with: home)
        XCTAssertEqual(values.last, 0)
        scroller.isEnabled = false
        XCTAssertFalse(scroller.accessibilityPerformIncrement())
    }
    @MainActor func testGestureObserverIsInstalledOnlyWhileAttachedToItsWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let view = GitDiffGestureView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertFalse(view.isMonitoring)
        window.contentView?.addSubview(view)
        XCTAssertTrue(view.isMonitoring)
        view.removeFromSuperview()
        XCTAssertFalse(view.isMonitoring, "Closing a diff must release its event observer")
        window.contentView?.addSubview(view)
        XCTAssertTrue(view.isMonitoring)
        view.stop()
        XCTAssertFalse(view.isMonitoring)
        view.removeFromSuperview()
    }

}
