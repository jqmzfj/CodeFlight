import Foundation

/// Date presets mirror the Git log filters in JetBrains IDEs. Bounds are
/// rendered as local calendar days so Git evaluates them against the same
/// date the log shows, regardless of the machine's time zone.
struct GitHistoryDateFilter: Equatable {
    enum Preset: String, CaseIterable, Identifiable {
        case all, today, lastWeek, lastMonth, lastQuarter, custom
        var id: String { rawValue }
    }

    var preset: Preset = .all
    var customStart: Date = Date()
    var customEnd: Date = Date()

    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
    }

    /// `until` is exclusive in Git, so a custom range adds one day to include
    /// the whole end date. Presets only need a lower bound.
    func bounds(now: Date = Date(), calendar: Calendar = .current) -> (since: String?, until: String?) {
        let today = calendar.startOfDay(for: now)
        func daysAgo(_ days: Int) -> Date { calendar.date(byAdding: .day, value: -days, to: today) ?? today }
        switch preset {
        case .all:
            return (nil, nil)
        case .today:
            return (Self.day(today, calendar: calendar), nil)
        case .lastWeek:
            return (Self.day(daysAgo(6), calendar: calendar), nil)
        case .lastMonth:
            return (Self.day(daysAgo(29), calendar: calendar), nil)
        case .lastQuarter:
            return (Self.day(daysAgo(89), calendar: calendar), nil)
        case .custom:
            let start = calendar.startOfDay(for: min(customStart, customEnd))
            let end = calendar.startOfDay(for: max(customStart, customEnd))
            let exclusiveEnd = calendar.date(byAdding: .day, value: 1, to: end) ?? end
            return (Self.day(start, calendar: calendar), Self.day(exclusiveEnd, calendar: calendar))
        }
    }

    /// A custom range should keep the day the user picked, not the time of day
    /// the sheet happened to open.
    mutating func normalizeCustomDates(calendar: Calendar = .current) {
        customStart = calendar.startOfDay(for: customStart)
        customEnd = calendar.startOfDay(for: customEnd)
    }
}
