import Foundation

/// One person's day on the team calendar: when they work, what takes that time, and what is left of it. Pure, so the
/// screen only draws what this says.
struct MemberDayLayout: Equatable {
    /// Their hours that day, or nil when they don't work (a day off, or someone who doesn't take bookings).
    var working: DateInterval?
    /// Time they can't give: their own calendar, bookings they have as an individual, and the company's bookings with
    /// the buffer after each. Merged, and cut to the day.
    var taken: [DateInterval]
    /// What is left of the working hours.
    var free: [DateInterval]
    /// The company's bookings that touch this day.
    var bookings: [CalendarBooking]

    static let off = MemberDayLayout(working: nil, taken: [], free: [], bookings: [])

    static func make(member: MemberCalendar, on day: Date, timeZone: TimeZone) -> MemberDayLayout {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let dayStart = calendar.startOfDay(for: day)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return .off }
        let dayRange = DateInterval(start: dayStart, end: dayEnd)

        let weekday = calendar.component(.weekday, from: dayStart)
        var working: DateInterval?
        if let hours = member.weekly.first(where: { $0.weekday == weekday }) {
            let opens = time(atMinute: hours.window.startMinute, on: dayStart, end: dayEnd, calendar: calendar)
            let closes = time(atMinute: hours.window.endMinute, on: dayStart, end: dayEnd, calendar: calendar)
            if opens < closes { working = DateInterval(start: opens, end: closes) }
        }

        let spans = member.busy.map(\.range)
            + member.bookings.map { DateInterval(start: $0.startAt, end: max($0.blockedUntil, $0.endAt)) }
        let taken = IntervalMath.merge(spans).compactMap { span -> DateInterval? in
            guard let clipped = span.intersection(with: dayRange), clipped.duration > 0 else { return nil }
            return clipped
        }

        var free: [DateInterval] = []
        if let working {
            var cursor = working.start
            for span in taken {
                guard span.end > cursor, span.start < working.end else { continue }
                if span.start > cursor { free.append(DateInterval(start: cursor, end: span.start)) }
                cursor = max(cursor, span.end)
            }
            if cursor < working.end { free.append(DateInterval(start: cursor, end: working.end)) }
        }

        let bookings = member.bookings.filter { $0.startAt < dayEnd && max($0.endAt, $0.startAt) > dayStart }
        return MemberDayLayout(working: working, taken: taken, free: free, bookings: bookings)
    }

    /// The wall-clock time `minute` minutes after midnight. Minute 1440 is the end of the day.
    private static func time(atMinute minute: Int, on dayStart: Date, end dayEnd: Date, calendar: Calendar) -> Date {
        if minute >= 1440 { return dayEnd }
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: dayStart) ?? dayStart
    }

    /// The stretch of the day the strips should cover for a group of people: from the earliest start of work or booking
    /// to the latest end, to whole hours, and at least `minimumHours` long. Nil when nobody has anything that day.
    static func axis(for layouts: [MemberDayLayout], timeZone: TimeZone, minimumHours: Int = 6) -> DateInterval? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var starts: [Date] = []
        var ends: [Date] = []
        for layout in layouts {
            if let working = layout.working { starts.append(working.start); ends.append(working.end) }
            for booking in layout.bookings { starts.append(booking.startAt); ends.append(max(booking.blockedUntil, booking.endAt)) }
        }
        guard let first = starts.min(), let last = ends.max() else { return nil }
        var start = calendar.dateInterval(of: .hour, for: first)?.start ?? first
        var end = last
        if let lastHour = calendar.dateInterval(of: .hour, for: last), lastHour.start < last { end = lastHour.end }
        if end.timeIntervalSince(start) < Double(minimumHours) * 3600 {
            end = start.addingTimeInterval(Double(minimumHours) * 3600)
        }
        if end <= start { start = first; end = first.addingTimeInterval(3600) }
        return DateInterval(start: start, end: end)
    }
}
