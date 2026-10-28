import AppKit
import XCTest
@testable import CodeFlightApp

@MainActor
final class SheetWindowSizingTests: XCTestCase {
    @MainActor private struct Host {
        let parent: NSWindow
        let sheet: NSWindow
        let grip: SheetWindowSizing.SizingView
        func close() {
            parent.endSheet(sheet)
            sheet.orderOut(nil); parent.orderOut(nil)
            sheet.close(); parent.close()
        }
    }

    private func host() async throws -> Host {
        _ = NSApplication.shared
        let parent = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false; sheet.isReleasedWhenClosed = false
        let grip = SheetWindowSizing.SizingView(minimum: NSSize(width: 320, height: 240))
        grip.frame = NSRect(x: 380, y: 0, width: 16, height: 16)
        try XCTUnwrap(sheet.contentView).addSubview(grip)
        parent.orderFront(nil)
        parent.beginSheet(sheet, completionHandler: nil)
        for _ in 0..<100 {
            if sheet.isSheet, sheet.contentMinSize.width == 320 { return Host(parent: parent, sheet: sheet, grip: grip) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        parent.endSheet(sheet); sheet.close(); parent.close()
        throw NSError(domain: "SheetWindowSizingTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Sheet did not attach"])
    }

    func testNativeResizeExposesLiveContentSizeAndEnforcesMinimum() async throws {
        let host = try await host(); defer { host.close() }
        host.sheet.setContentSize(NSSize(width: 720, height: 500))
        XCTAssertEqual(host.grip.accessibilityValue() as? String, "720 × 500")
        // Mimic SwiftUI replacing native minimum constraints. The notification
        // path must restore the content minimum independently of grip actions.
        host.sheet.contentMinSize = .zero
        host.sheet.setContentSize(NSSize(width: 100, height: 100))
        XCTAssertEqual(host.grip.accessibilityValue() as? String, "320 × 240")
        XCTAssertTrue(host.grip.accessibilityPerformIncrement())
        XCTAssertEqual(host.grip.accessibilityValue() as? String, "344 × 264")
        XCTAssertTrue(host.grip.accessibilityPerformDecrement())
        XCTAssertEqual(host.grip.accessibilityValue() as? String, "320 × 240")
    }

    private func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
    }

    func testFocusArrowStepsAndTabCanLeaveGrip() async throws {
        let host = try await host(); defer { host.close() }
        XCTAssertTrue(host.grip.canBecomeKeyView)
        host.grip.setAccessibilityFocused(true)
        XCTAssertTrue(host.sheet.firstResponder === host.grip)
        XCTAssertTrue(host.grip.isAccessibilityFocused())
        host.grip.keyDown(with: try key(124, flags: .shift))
        host.grip.keyDown(with: try key(125))
        XCTAssertEqual(host.grip.accessibilityValue() as? String, "424 × 304")
        let field = NSTextField(frame: NSRect(x: 20, y: 30, width: 140, height: 24))
        try XCTUnwrap(host.sheet.contentView).addSubview(field)
        host.grip.nextKeyView = field; field.nextKeyView = host.grip
        host.grip.keyDown(with: try key(48))
        XCTAssertNotNil(field.currentEditor())
        XCTAssertFalse(host.grip.isAccessibilityFocused())
        XCTAssertTrue(host.grip.accessibilityPerformPress())
        host.grip.keyDown(with: try key(48, flags: .shift))
        XCTAssertNotNil(field.currentEditor())
        XCTAssertFalse(host.grip.isAccessibilityFocused())
        // A SwiftUI settings sheet can have only this native key view when
        // system keyboard navigation excludes its buttons. Both Tab routes
        // must release the grip even when AppKit cycles to the same view.
        field.removeFromSuperview()
        host.grip.nextKeyView = host.grip
        for flags: NSEvent.ModifierFlags in [[], .shift] {
            XCTAssertTrue(host.grip.accessibilityPerformPress())
            host.grip.keyDown(with: try key(48, flags: flags))
            XCTAssertFalse(host.grip.isAccessibilityFocused())
        }
    }

    func testOrdinaryWindowIsNotResizedOrConfiguredAsSheet() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let grip = SheetWindowSizing.SizingView(minimum: NSSize(width: 600, height: 400))
        window.contentView = grip
        try await Task.sleep(nanoseconds: 10_000_000)
        let frame = window.frame
        XCTAssertNil(grip.accessibilityValue())
        XCTAssertFalse(grip.canBecomeKeyView)
        XCTAssertFalse(grip.accessibilityPerformPress())
        XCTAssertFalse(grip.accessibilityPerformIncrement())
        grip.keyDown(with: try key(124))
        XCTAssertEqual(window.frame, frame)
        XCTAssertFalse(window.styleMask.contains(.resizable))
    }
}
