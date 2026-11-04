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

    /// The text slot plus fixed chrome: 8pt padding per side, the chevron
    /// and the 5pt gap. Measured once so a layout change shows up as a diff.
    private let chrome: CGFloat = 30

    @MainActor
    func testLongNameIsBoundedByTheMeasuredSlot() {
        let name = "IDEA Test: SysUserControllerTest.shouldKeepOriginalPhoneWhenMaskedPhoneSubmitted"
        let width = WorkbenchChipMetrics.labelWidth(name, font: .systemFont(ofSize: 11, weight: .medium), minimum: 90, maximum: 200)
        XCTAssertEqual(width, 200)
        let measured = fittingWidth(RunConfigurationChipLabel(name: name, width: width))
        XCTAssertLessThanOrEqual(measured, width + chrome)
        XCTAssertGreaterThan(measured, width)
    }

    @MainActor
    func testShortNameStaysCompact() {
        let name = "npm dev"
        let width = WorkbenchChipMetrics.labelWidth(name, font: .systemFont(ofSize: 11, weight: .medium), minimum: 90, maximum: 200)
        XCTAssertEqual(width, 90)
        let measured = fittingWidth(RunConfigurationChipLabel(name: name, width: width))
        XCTAssertLessThanOrEqual(measured, 90 + chrome + 1)
    }
}
