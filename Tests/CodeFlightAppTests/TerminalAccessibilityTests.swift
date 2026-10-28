import XCTest
import AppKit
import SwiftTerm
@testable import CodeFlightApp

@MainActor
final class TerminalAccessibilityTests: XCTestCase {
    private func view() -> WorkbenchTerminalView {
        _ = NSApplication.shared
        let view = WorkbenchTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 180), font: .monospacedSystemFont(ofSize: 12, weight: .regular), options: TerminalOptions(scrollback: 2000))
        view.configureAccessibility(title: "Terminal 1", language: .chinese)
        return view
    }
    private func text(_ view: WorkbenchTerminalView) -> String { view.accessibilityValue() as? String ?? "" }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Terminal accessibility did not update")
    }

    func testVisibleUnicodeTextExposesConsistentUTF16RangesAndLineQueries() async throws {
        let view = view()
        view.feed(text: "\u{1b}[2J\u{1b}[H中文🙂e\u{301}\r\nsecond")
        try await wait { self.text(view).contains("second") }
        let value = text(view) as NSString
        XCTAssertTrue(value.hasPrefix("中文🙂e\u{301}\nsecond"))
        XCTAssertEqual(view.accessibilityRole(), .textArea)
        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityNumberOfCharacters(), value.length)
        XCTAssertEqual(view.accessibilityVisibleCharacterRange(), NSRange(location: 0, length: value.length))
        let first = view.accessibilityRange(forLine: 0)
        XCTAssertEqual(view.accessibilityString(for: first), "中文🙂e\u{301}\n")
        let second = value.range(of: "second")
        XCTAssertEqual(view.accessibilityLine(for: second.location), 1)
        XCTAssertEqual(view.accessibilityString(for: second), "second")
        XCTAssertNil(view.accessibilityString(for: NSRange(location: NSNotFound, length: 0)))
        XCTAssertNil(view.accessibilityString(for: NSRange(location: value.length, length: Int.max)))
        XCTAssertEqual(view.accessibilityRange(forLine: -1).location, NSNotFound)
        XCTAssertEqual(view.accessibilityRange(forLine: Int.max).location, NSNotFound)
        XCTAssertEqual(view.accessibilityLine(for: -1), NSNotFound)
        XCTAssertEqual(view.accessibilityLine(for: value.length + 1), NSNotFound)
        XCTAssertFalse(view.isAccessibilitySelectorAllowed(NSSelectorFromString("setAccessibilityValue:")))
    }

    func testHistoryDoesNotBecomeAnUnboundedAccessibilityDocumentAndSessionsStayIndependent() async throws {
        let first = view(), second = view()
        first.feed(text: "PRIVATE_OLD_MARKER\r\n" + String(repeating: "filler\r\n", count: 300) + "VISIBLE_MARKER")
        second.feed(text: "OTHER_SESSION")
        try await wait { self.text(first).contains("VISIBLE_MARKER") && self.text(second).contains("OTHER_SESSION") }
        let visible = text(first)
        XCTAssertFalse(visible.contains("PRIVATE_OLD_MARKER"))
        XCTAssertFalse(visible.contains("OTHER_SESSION"))
        XCTAssertLessThanOrEqual(visible.split(separator: "\n", omittingEmptySubsequences: false).count, first.terminalDimensions.rows)
        XCTAssertLessThan(visible.utf8.count, 2000)
        first.feed(text: "\r\nUPDATED")
        try await wait { self.text(first).contains("UPDATED") }
        XCTAssertFalse(text(second).contains("UPDATED"))
        first.feed(text: "\u{1b}[?1049h\u{1b}[HALTERNATE_ONLY")
        try await wait { self.text(first).contains("ALTERNATE_ONLY") }
        XCTAssertFalse(text(first).contains("VISIBLE_MARKER"))
        first.feed(text: "\u{1b}[?1049l")
        try await wait { self.text(first).contains("UPDATED") }
        XCTAssertFalse(text(first).contains("ALTERNATE_ONLY"))
    }

    func testAccessibilityFocusReachesNativeInputAndLanguageChangesWithoutResettingText() async throws {
        let view = view()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 180), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        view.feed(text: "keep this text")
        try await wait { self.text(view).contains("keep this text") }
        view.setAccessibilityFocused(true)
        XCTAssertTrue(window.firstResponder === view)
        XCTAssertTrue(view.isAccessibilityFocused())
        XCTAssertEqual(view.accessibilityLabel(), "终端 — Terminal 1")
        view.configureAccessibility(title: "Build Shell", language: .english)
        XCTAssertEqual(view.accessibilityLabel(), "Terminal — Build Shell")
        XCTAssertTrue(view.accessibilityHelp()?.contains("visible terminal screen") == true)
        XCTAssertTrue(text(view).contains("keep this text"))
    }
}
