import XCTest
@testable import CodeFlightApp

final class SplitSizingTests: XCTestCase {
    func testResetOnlyRemovesLayoutPreferences() {
        let suite = "layout-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(480, forKey: "layout.split.history.navigator")
        defaults.set(160, forKey: "layout.split.runSettings.command")
        defaults.set(0.7, forKey: "layout.diff.leftFraction")
        defaults.set(400, forKey: "sidebarWidth")
        defaults.set(350, forKey: "bottomToolHeight")
        defaults.set("dark", forKey: "theme")
        defaults.set("configuration-id", forKey: "run.selected.project")
        WorkbenchLayout.reset(defaults: defaults)
        XCTAssertNil(defaults.object(forKey: "layout.split.history.navigator"))
        XCTAssertNil(defaults.object(forKey: "layout.split.runSettings.command"))
        XCTAssertNil(defaults.object(forKey: "layout.diff.leftFraction"))
        XCTAssertNil(defaults.object(forKey: "sidebarWidth"))
        XCTAssertNil(defaults.object(forKey: "bottomToolHeight"))
        XCTAssertEqual(defaults.string(forKey: "theme"), "dark")
        XCTAssertEqual(defaults.string(forKey: "run.selected.project"), "configuration-id")
    }

    func testWindowShrinkFitsBothMinimumsWithoutLosingPreferredSize() {
        let preferred: CGFloat = 700
        let small = SplitSizing.bounds(extent: 900, minimum: 180, otherMinimum: 360)
        let fitted = SplitSizing.fitted(preferred, to: small)
        XCTAssertEqual(fitted, 535)
        XCTAssertEqual(900 - SplitSizing.divider - fitted, 360)
        let enlarged = SplitSizing.bounds(extent: 1600, minimum: 180, otherMinimum: 360)
        XCTAssertEqual(SplitSizing.fitted(preferred, to: enlarged), preferred)
    }

    func testMinimumsAndInvalidSavedValuesNeverCreateNegativeOrNonfiniteSizes() {
        let bounds = SplitSizing.bounds(extent: 720, minimum: 160, otherMinimum: 180)
        XCTAssertEqual(SplitSizing.fitted(-200, to: bounds), 160)
        XCTAssertEqual(SplitSizing.fitted(.infinity, to: bounds), 160)
        XCTAssertEqual(SplitSizing.fitted(.nan, to: bounds), 160)
        XCTAssertEqual(SplitSizing.fitted(10000, to: bounds), 535)
        let undersized = SplitSizing.bounds(extent: 100, minimum: 160, otherMinimum: 180)
        XCTAssertEqual(undersized.lowerBound, 160)
        XCTAssertEqual(undersized.upperBound, 160)
    }
}
