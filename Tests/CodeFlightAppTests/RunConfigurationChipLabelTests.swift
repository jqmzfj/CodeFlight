import XCTest
import AppKit
import SwiftUI
@testable import CodeFlightApp

final class RunConfigurationChipLabelTests: XCTestCase {
    @MainActor
    private func fittingWidth(_ label: RunConfigurationChipLabel) -> CGFloat {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: label)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    @MainActor
    func testLongNameOccupiesExactlyTheMeasuredSlot() {
        let name = "IDEA Test: SysUserControllerTest.shouldKeepOriginalPhoneWhenMaskedPhoneSubmitted"
        let width = WorkbenchChipMetrics.labelWidth(name, font: .systemFont(ofSize: 11, weight: .medium), minimum: 90, maximum: 200, slack: 4)
        XCTAssertEqual(width, 200)
        let chrome = fittingWidth(RunConfigurationChipLabel(name: "", width: 0))
        let measured = fittingWidth(RunConfigurationChipLabel(name: name, width: width))
        XCTAssertEqual(measured, width + chrome, accuracy: 0.5)
        XCTAssertGreaterThan(measured, width)
    }

    @MainActor
    func testShortNameStaysCompact() {
        let name = "npm dev"
        let width = WorkbenchChipMetrics.labelWidth(name, font: .systemFont(ofSize: 11, weight: .medium), minimum: 90, maximum: 200, slack: 4)
        XCTAssertEqual(width, 90)
        let chrome = fittingWidth(RunConfigurationChipLabel(name: "", width: 0))
        XCTAssertEqual(fittingWidth(RunConfigurationChipLabel(name: name, width: width)), width + chrome, accuracy: 0.5)
    }

    /// Left/right breathing room: 10pt padding per side, a 6pt gap and the
    /// chevron. Guards against the chip collapsing onto its text again.
    @MainActor
    func testChipKeepsHorizontalBreathingRoom() {
        let chrome = fittingWidth(RunConfigurationChipLabel(name: "", width: 0))
        XCTAssertGreaterThanOrEqual(chrome, 33)
    }
}
