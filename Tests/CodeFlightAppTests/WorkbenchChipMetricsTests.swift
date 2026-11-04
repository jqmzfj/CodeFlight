import XCTest
import AppKit
@testable import CodeFlightApp

final class WorkbenchChipMetricsTests: XCTestCase {
    private let font = NSFont.systemFont(ofSize: 11, weight: .medium)

    private func measured(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    func testShortTextUsesMinimumWidth() {
        XCTAssertEqual(WorkbenchChipMetrics.labelWidth("Run", font: font, minimum: 90, maximum: 200), 90)
        XCTAssertEqual(WorkbenchChipMetrics.labelWidth("", font: font, minimum: 44, maximum: 160), 44)
    }

    func testLongRunConfigurationNameIsClampedToMaximum() {
        let name = "IDEA Test: SysUserControllerTest.shouldKeepOriginalPhoneWhenMaskedPhoneSubmitted"
        XCTAssertGreaterThan(measured(name), 200)
        XCTAssertEqual(WorkbenchChipMetrics.labelWidth(name, font: font, minimum: 90, maximum: 200), 200)
    }

    func testMediumTextKeepsItsMeasuredWidth() {
        let name = "moe-portal build"
        let width = WorkbenchChipMetrics.labelWidth(name, font: font, minimum: 40, maximum: 400)
        XCTAssertEqual(width, measured(name).rounded(.up))
        XCTAssertGreaterThan(width, 40)
        XCTAssertLessThan(width, 400)
    }

    func testWidthNeverDecreasesAsTextGrows() {
        let names = ["a", "npm dev", "IDEA Test: SysUserControllerTest", "IDEA Test: SysUserControllerTest.shouldKeepOriginalPhoneWhenMaskedPhoneSubmitted"]
        let widths = names.map { WorkbenchChipMetrics.labelWidth($0, font: font, minimum: 60, maximum: 200) }
        XCTAssertEqual(widths, widths.sorted())
        XCTAssertEqual(widths.last, 200)
    }
}
