import Foundation

/// Formats times and days in the *creator's* time zone, so a client in another zone still sees
/// exactly when the shoot happens.
final class SlotFormatter {
    let timeZone: TimeZone
    let calendar: Calendar

    private let timeFormatter: DateFormatter
    private let weekdayFormatter: DateFormatter
    private let monthDayFormatter: DateFormatter
    private let monthFormatter: DateFormatter
    private let fullDayFormatter: DateFormatter

    init(timeZone: TimeZone, locale: Locale = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale

        func make(_ template: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter
        }

        self.timeZone = timeZone
        self.calendar = calendar
        timeFormatter = make("jm")
        weekdayFormatter = make("EEE")
        monthDayFormatter = make("MMMd")
        monthFormatter = make("MMM")
        fullDayFormatter = make("EEEEMMMMd")
    }

    convenience init(settings: AvailabilitySettings, locale: Locale = .current) {
        self.init(timeZone: settings.timeZone, locale: locale)
    }

    func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    func timeRange(start: Date, end: Date) -> String { "\(time(start)) – \(time(end))" }

    /// "Thursday, December 4"
    func fullDay(_ date: Date) -> String { fullDayFormatter.string(from: date) }

    func weekdayShort(_ day: CalendarDay) -> String {
        guard let noon = day.date(atMinute: 12 * 60, in: calendar) else { return "" }
        return weekdayFormatter.string(from: noon)
    }

    func monthDay(_ day: CalendarDay) -> String {
        guard let noon = day.date(atMinute: 12 * 60, in: calendar) else { return "" }
        return monthDayFormatter.string(from: noon)
    }

    /// "Dec"
    func monthShort(_ day: CalendarDay) -> String {
        guard let noon = day.date(atMinute: 12 * 60, in: calendar) else { return "" }
        return monthFormatter.string(from: noon)
    }

    /// "Today", "Tomorrow", then the weekday.
    func dayName(_ day: CalendarDay, relativeTo now: Date) -> String {
        let today = CalendarDay(now, calendar: calendar)
        if day == today { return "Today" }
        if day == today.adding(days: 1, in: calendar) { return "Tomorrow" }
        return weekdayShort(day)
    }

    /// "Today · 3:30 PM", "Thu · 10:30 AM", or "Dec 4 · 10:30 AM" when more than a week away.
    func chipLabel(for start: Date, relativeTo now: Date) -> String {
        let day = CalendarDay(start, calendar: calendar)
        let today = CalendarDay(now, calendar: calendar)
        let daysAway = today.date(atMinute: 12 * 60, in: calendar).flatMap { from in
            day.date(atMinute: 12 * 60, in: calendar).flatMap { to in
                calendar.dateComponents([.day], from: from, to: to).day
            }
        } ?? 0
        let lead = daysAway <= 6 ? dayName(day, relativeTo: now) : monthDay(day)
        return "\(lead) · \(time(start))"
    }

    /// Shown when the creator's time zone differs from the device's.
    var zoneNote: String? {
        guard timeZone.identifier != TimeZone.current.identifier else { return nil }
        let name = timeZone.localizedName(for: .generic, locale: .current) ?? timeZone.identifier
        return "Times are shown in \(name)."
    }
}
