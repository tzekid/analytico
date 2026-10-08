import Foundation

/// What a view's period is called, with the workspace's rules: one day reads
/// hour by hour, a period still running is compared up to the same time,
/// and every comparison names its dates. Dates are the instance's (UTC);
/// words follow the reader's locale.
public struct PeriodWording: Sendable {
    /// First and last day of the period, at midnight UTC.
    public let start: Date
    public let end: Date
    public let now: Date
    /// The rolling "last 24 hours" preset.
    public let rolling: Bool
    let locale: Locale

    public init?(from: String, to: String, rolling: Bool = false, now: Date = .now, locale: Locale = .current) {
        guard let start = try? Date(from + "T00:00:00Z", strategy: .iso8601), let end = try? Date(to + "T00:00:00Z", strategy: .iso8601) else { return nil }
        self.start = start
        self.end = end
        self.now = now
        self.rolling = rolling
        self.locale = locale
    }

    private static let day: TimeInterval = 86_400
    private var days: Int { Int(((end.timeIntervalSince(start)) / Self.day).rounded()) + 1 }
    private var today: Date { Date(timeIntervalSince1970: (now.timeIntervalSince1970 / Self.day).rounded(.down) * Self.day) }

    /// A single day, shown hour by hour.
    public var oneDay: Bool { !rolling && start == end }
    public var isToday: Bool { oneDay && start == today }
    /// The period includes now, so its last bucket is still filling up.
    public var running: Bool { rolling || end >= today }

    /// Days elapsed, for per-day averages: a running period counts only what has happened.
    public var elapsedDays: Double {
        if rolling { return 1 }
        let until = min(end.addingTimeInterval(Self.day), max(now, start.addingTimeInterval(3600)))
        return max(1, until.timeIntervalSince(start) / Self.day)
    }

    /// "Wed 30 Sep 2026, hour by hour", "Today so far, until 14:40", "1–30 Sep 2026".
    public var title: String {
        if rolling { return "Last 24 hours" }
        if isToday { return "Today so far, until \(clock(now))" }
        if oneDay { return "\(dayName(start, year: true)) · hour by hour" }
        return span(start, end, year: true)
    }

    /// "vs Tue 29 Sep", "vs yesterday by 14:40", "vs 2–31 Aug".
    public var versus: String {
        if rolling { return "vs the previous 24 hours" }
        if isToday { return "vs yesterday by \(clock(now))" }
        return "vs " + previous
    }

    /// Legend for this period: "Today", "Wed 30 Sep", "1–30 Sep".
    public var this: String {
        if rolling { return "Last 24 hours" }
        if isToday { return "Today" }
        if oneDay { return dayName(start, year: otherYear(start)) }
        return span(start, end, year: otherYear(end))
    }

    /// Legend for the period compared with: "Yesterday", "Tue 29 Sep", "2–31 Aug".
    public var previous: String {
        if rolling { return "Previous 24 hours" }
        if isToday { return "Yesterday" }
        let before = start.addingTimeInterval(-Double(days) * Self.day)
        let last = start.addingTimeInterval(-Self.day)
        if oneDay { return dayName(before, year: otherYear(before)) }
        return span(before, last, year: otherYear(last))
    }

    /// The period button: "Today", "Yesterday", "30 Sep", "1–30 Sep".
    public var button: String {
        if isToday { return "Today" }
        if oneDay && start == today.addingTimeInterval(-Self.day) { return "Yesterday" }
        if oneDay { return start.formatted(style.day().month(.abbreviated)) + (otherYear(start) ? " " + start.formatted(style.year()) : "") }
        return span(start, end, year: otherYear(end))
    }

    /// "on Wed 30 Sep 2026", "between 1 and 31 Jan 2025" (as "1–31 Jan 2025").
    public var between: String {
        oneDay ? "on " + dayName(start, year: true) : "in " + span(start, end, year: true)
    }

    private var style: Date.FormatStyle { Date.FormatStyle(locale: locale, timeZone: .gmt) }

    private func otherYear(_ date: Date) -> Bool {
        Calendar.utc.component(.year, from: date) != Calendar.utc.component(.year, from: now)
    }

    private func dayName(_ date: Date, year: Bool) -> String {
        var format = style.weekday(.abbreviated).day().month(.abbreviated)
        if year { format = format.year() }
        return date.formatted(format)
    }

    private func span(_ first: Date, _ last: Date, year: Bool) -> String {
        if first == last { return dayName(first, year: year) }
        var format = Date.IntervalFormatStyle(locale: locale, timeZone: .gmt).day().month(.abbreviated)
        if year { format = format.year() }
        return (first..<last).formatted(format)
    }

    private func clock(_ date: Date) -> String {
        date.formatted(style.hour().minute())
    }
}

extension Calendar {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }()
}
