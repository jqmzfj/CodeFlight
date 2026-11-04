import XCTest
@testable import CodeFlightApp

final class GitHistoryFilterTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }()

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    private func bounds(_ filter: GitHistoryDateFilter, now: String) -> (since: String?, until: String?) {
        filter.bounds(now: date(now), calendar: calendar)
    }

    func testAllDatesHasNoBounds() {
        let result = bounds(GitHistoryDateFilter(), now: "2026-11-04 15:00")
        XCTAssertNil(result.since)
        XCTAssertNil(result.until)
    }

    func testPresetsResolveToLocalCalendarDays() {
        XCTAssertEqual(bounds(GitHistoryDateFilter(preset: .today), now: "2026-11-04 00:05").since, "2026-11-04")
        XCTAssertEqual(bounds(GitHistoryDateFilter(preset: .today), now: "2026-11-04 23:55").since, "2026-11-04")
        XCTAssertEqual(bounds(GitHistoryDateFilter(preset: .lastWeek), now: "2026-11-04 15:00").since, "2026-10-29")
        XCTAssertEqual(bounds(GitHistoryDateFilter(preset: .lastMonth), now: "2026-11-04 15:00").since, "2026-10-06")
        XCTAssertEqual(bounds(GitHistoryDateFilter(preset: .lastQuarter), now: "2026-11-04 15:00").since, "2026-08-07")
        XCTAssertNil(bounds(GitHistoryDateFilter(preset: .lastWeek), now: "2026-11-04 15:00").until)
    }

    func testPresetsCrossMonthAndYearBoundaries() {
        XCTAssertEqual(bounds(GitHistoryDateFilter(preset: .lastWeek), now: "2026-01-03 09:00").since, "2025-12-28")
        XCTAssertEqual(bounds(GitHistoryDateFilter(preset: .today), now: "2026-01-01 00:30").since, "2026-01-01")
    }

    func testCustomRangeIncludesTheWholeEndDay() {
        var filter = GitHistoryDateFilter(preset: .custom)
        filter.customStart = date("2026-10-01 18:00")
        filter.customEnd = date("2026-10-03 09:00")
        let result = bounds(filter, now: "2026-11-04 15:00")
        XCTAssertEqual(result.since, "2026-10-01")
        // Git treats --until as exclusive, so the end date needs one more day.
        XCTAssertEqual(result.until, "2026-10-04")
    }

    func testCustomRangeKeepsASingleDayAndSwapsReversedDates() {
        var single = GitHistoryDateFilter(preset: .custom)
        single.customStart = date("2026-10-05 01:00")
        single.customEnd = date("2026-10-05 22:00")
        XCTAssertEqual(bounds(single, now: "2026-11-04 15:00").since, "2026-10-05")
        XCTAssertEqual(bounds(single, now: "2026-11-04 15:00").until, "2026-10-06")

        var reversed = GitHistoryDateFilter(preset: .custom)
        reversed.customStart = date("2026-10-09 08:00")
        reversed.customEnd = date("2026-10-07 08:00")
        XCTAssertEqual(bounds(reversed, now: "2026-11-04 15:00").since, "2026-10-07")
        XCTAssertEqual(bounds(reversed, now: "2026-11-04 15:00").until, "2026-10-10")
    }

    func testNormalizeCustomDatesDropsTheTimeOfDay() {
        var filter = GitHistoryDateFilter(preset: .custom)
        filter.customStart = date("2026-10-01 18:42")
        filter.customEnd = date("2026-10-03 07:13")
        filter.normalizeCustomDates(calendar: calendar)
        XCTAssertEqual(calendar.component(.hour, from: filter.customStart), 0)
        XCTAssertEqual(calendar.component(.hour, from: filter.customEnd), 0)
        XCTAssertEqual(GitHistoryDateFilter.day(filter.customStart, calendar: calendar), "2026-10-01")
        XCTAssertEqual(GitHistoryDateFilter.day(filter.customEnd, calendar: calendar), "2026-10-03")
    }
}
