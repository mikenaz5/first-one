import Foundation

// MARK: - Calendar day

/// A calendar date with no time or time zone ("2026-12-24"). Blackout dates use this so
/// they mean the same day wherever the person happens to be.
struct CalendarDay: Hashable, Comparable, Codable {
    var year: Int
    var month: Int
    var day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(_ date: Date, calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    init?(isoString: String) {
        let parts = isoString.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    var isoString: String { String(format: "%04d-%02d-%02d", year, month, day) }

    static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// The instant at `minute` minutes past local midnight on this day.
    func date(atMinute minute: Int = 0, in calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: minute / 60, minute: minute % 60))
    }

    /// 1 = Sunday ... 7 = Saturday, matching `Calendar`'s Gregorian weekday numbers.
    func weekday(in calendar: Calendar) -> Int {
        guard let noon = date(atMinute: 12 * 60, in: calendar) else { return 1 }
        return calendar.component(.weekday, from: noon)
    }

    func adding(days: Int, in calendar: Calendar) -> CalendarDay {
        // Anchor at noon so daylight-saving shifts can't push us onto the wrong date.
        guard let noon = date(atMinute: 12 * 60, in: calendar),
              let moved = calendar.date(byAdding: .day, value: days, to: noon)
        else { return self }
        return CalendarDay(moved, calendar: calendar)
    }

    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = CalendarDay(isoString: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad day: \(text)"))
        }
        self = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(isoString)
    }
}

// MARK: - Settings

struct TimeWindow: Codable, Equatable, Hashable {
    /// Minutes after local midnight. 540 = 9:00.
    var startMinute: Int
    var endMinute: Int

    var isValid: Bool { startMinute >= 0 && endMinute <= 1440 && startMinute < endMinute }
}

struct DayHours: Codable, Equatable, Hashable, Identifiable {
    /// 1 = Sunday ... 7 = Saturday.
    var weekday: Int
    var window: TimeWindow
    var id: Int { weekday }
}

struct BlackoutRange: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var start: CalendarDay
    var end: CalendarDay
    var reason: String

    init(id: UUID = UUID(), start: CalendarDay, end: CalendarDay, reason: String = "") {
        self.id = id
        self.start = start
        self.end = end
        self.reason = reason
    }

    func contains(_ day: CalendarDay) -> Bool { start <= day && day <= end }
}

struct AvailabilitySettings: Codable, Equatable {
    var timeZoneID: String
    /// Open days only. A weekday with no entry is closed.
    var weekly: [DayHours]
    var blackouts: [BlackoutRange]
    var minNoticeHours: Int
    var maxAdvanceDays: Int
    /// Required gap after each booking.
    var bufferMinutes: Int
    /// How far apart start times are offered.
    var slotIntervalMinutes: Int

    static let minNoticeOptions = [0, 2, 4, 12, 24, 48, 72, 168]
    static let advanceOptions = [30, 60, 90, 180, 365]
    static let bufferOptions = [0, 15, 30, 45, 60, 90, 120]
    static let slotIntervalOptions = [15, 30, 60]

    /// Monday to Friday, 9:00 to 17:00.
    static func standard(timeZone: TimeZone = .current) -> AvailabilitySettings {
        AvailabilitySettings(
            timeZoneID: timeZone.identifier,
            weekly: (2...6).map { DayHours(weekday: $0, window: TimeWindow(startMinute: 9 * 60, endMinute: 17 * 60)) },
            blackouts: [],
            minNoticeHours: 24,
            maxAdvanceDays: 180,
            bufferMinutes: 30,
            slotIntervalMinutes: 30
        )
    }

    /// No open days. What clients see for a creator who hasn't set their hours yet.
    static func closed(timeZone: TimeZone = .current) -> AvailabilitySettings {
        var settings = standard(timeZone: timeZone)
        settings.weekly = []
        return settings
    }

    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }

    /// A Gregorian calendar fixed to the creator's time zone. Every slot is computed in it.
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    func window(forWeekday weekday: Int) -> TimeWindow? {
        weekly.first { $0.weekday == weekday }?.window
    }

    func isBlackedOut(_ day: CalendarDay) -> Bool {
        blackouts.contains { $0.contains(day) }
    }

    var hasOpenDay: Bool { weekly.contains { $0.window.isValid } }

    struct WeekdayGroup: Equatable {
        var weekdays: [Int]
        var window: TimeWindow
    }

    /// Open days merged into runs that share hours, in week order starting at `firstWeekday`.
    /// Monday to Friday 9 to 5 becomes one group.
    func openDayGroups(firstWeekday: Int = 1) -> [WeekdayGroup] {
        let ordered = (0..<7).map { (firstWeekday - 1 + $0) % 7 + 1 }
        var groups: [WeekdayGroup] = []
        for weekday in ordered {
            guard let window = self.window(forWeekday: weekday), window.isValid else { continue }
            if let last = groups.last, last.window == window,
               let previous = last.weekdays.last, ordered.firstIndex(of: weekday) == ordered.firstIndex(of: previous).map({ $0 + 1 }) {
                groups[groups.count - 1].weekdays.append(weekday)
            } else {
                groups.append(WeekdayGroup(weekdays: [weekday], window: window))
            }
        }
        return groups
    }

    var isValid: Bool {
        weekly.allSatisfy { (1...7).contains($0.weekday) && $0.window.isValid }
            && Set(weekly.map(\.weekday)).count == weekly.count
            && (0...720).contains(minNoticeHours)
            && (1...730).contains(maxAdvanceDays)
            && (0...240).contains(bufferMinutes)
            && Self.slotIntervalOptions.contains(slotIntervalMinutes)
            && blackouts.allSatisfy { $0.start <= $0.end }
    }
}

// MARK: - Schedule seen by clients

struct TimeSlot: Identifiable, Hashable {
    let start: Date
    /// End of the shoot itself (the buffer after it isn't included).
    let end: Date
    var id: Date { start }
}

/// What a client's device needs to work out open times. It deliberately contains no
/// details of anyone else's bookings, only blocked time ranges.
struct CreatorSchedule: Codable, Equatable {
    var settings: AvailabilitySettings
    /// Confirmed and held bookings, each already extended by the buffer that follows it.
    var bookedRanges: [DateInterval]
    /// Busy time imported from the creator's Apple Calendar (raw, without buffer).
    var externalBusy: [DateInterval]
    /// For a company: its people and when each is free. When present, times are offered by `TeamAvailability`.
    var team: TeamSchedule? = nil
}

// MARK: - Interval helpers

enum IntervalMath {
    /// Half-open overlap: ranges that merely touch don't conflict, matching Postgres `[)`.
    static func overlaps(_ a: DateInterval, _ b: DateInterval) -> Bool {
        a.start < b.end && b.start < a.end
    }

    /// Sorts and merges overlapping or touching intervals.
    static func merge(_ intervals: [DateInterval]) -> [DateInterval] {
        let sorted = intervals.sorted { $0.start < $1.start }
        var merged: [DateInterval] = []
        for interval in sorted {
            if let last = merged.last, interval.start <= last.end {
                if interval.end > last.end {
                    merged[merged.count - 1] = DateInterval(start: last.start, end: interval.end)
                }
            } else {
                merged.append(interval)
            }
        }
        return merged
    }
}

// MARK: - Engine

/// Works out which start times are bookable. The same function backs the booking screen
/// and, for the on-device backend, the final check at booking time, so what a client sees
/// is exactly what the server accepts.
enum AvailabilityEngine {
    /// Today (in the creator's time zone) through `maxAdvanceDays` from now.
    static func bookableDays(now: Date, settings: AvailabilitySettings) -> ClosedRange<CalendarDay> {
        let calendar = settings.calendar
        let today = CalendarDay(now, calendar: calendar)
        return today...today.adding(days: settings.maxAdvanceDays, in: calendar)
    }

    static func slots(
        on day: CalendarDay,
        durationMinutes: Int,
        schedule: CreatorSchedule,
        now: Date
    ) -> [TimeSlot] {
        if let team = schedule.team {
            return TeamAvailability.slots(on: day, durationMinutes: durationMinutes, team: team, now: now)
        }
        let settings = schedule.settings
        let calendar = settings.calendar
        guard durationMinutes > 0, settings.slotIntervalMinutes > 0 else { return [] }
        guard bookableDays(now: now, settings: settings).contains(day) else { return [] }
        guard !settings.isBlackedOut(day),
              let window = settings.window(forWeekday: day.weekday(in: calendar)),
              window.isValid
        else { return [] }

        let earliest = now.addingTimeInterval(TimeInterval(settings.minNoticeHours) * 3600)
        let buffer = TimeInterval(settings.bufferMinutes) * 60
        let external = schedule.externalBusy.map { DateInterval(start: $0.start, end: $0.end.addingTimeInterval(buffer)) }
        let blockers = schedule.bookedRanges + external

        var result: [TimeSlot] = []
        var minute = window.startMinute
        while minute + durationMinutes <= window.endMinute {
            defer { minute += settings.slotIntervalMinutes }

            // Skip start times that don't exist on this day. On a spring-forward day 2:00 AM is
            // missing and would otherwise silently become 3:00 AM, offering that slot twice.
            guard let start = day.date(atMinute: minute, in: calendar),
                  CalendarDay(start, calendar: calendar) == day,
                  minuteOfDay(start, calendar: calendar) == minute,
                  start >= earliest
            else { continue }

            let end = start.addingTimeInterval(TimeInterval(durationMinutes) * 60)
            // The new booking occupies its shoot time plus the buffer after it.
            let occupied = DateInterval(start: start, end: end.addingTimeInterval(buffer))
            if blockers.contains(where: { IntervalMath.overlaps($0, occupied) }) { continue }

            result.append(TimeSlot(start: start, end: end))
        }
        return result
    }

    private static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// True if `start` is exactly one of the offered start times.
    static func isAvailable(start: Date, durationMinutes: Int, schedule: CreatorSchedule, now: Date) -> Bool {
        let day = CalendarDay(start, calendar: schedule.settings.calendar)
        return slots(on: day, durationMinutes: durationMinutes, schedule: schedule, now: now)
            .contains { $0.start == start }
    }

    /// Every bookable day with its slots, in order. Days with no slots are omitted.
    static func availableDays(
        durationMinutes: Int,
        schedule: CreatorSchedule,
        now: Date,
        limit: Int? = nil
    ) -> [(day: CalendarDay, slots: [TimeSlot])] {
        let calendar = schedule.settings.calendar
        let range = bookableDays(now: now, settings: schedule.settings)
        var found: [(day: CalendarDay, slots: [TimeSlot])] = []
        var day = range.lowerBound
        while day <= range.upperBound {
            let daySlots = slots(on: day, durationMinutes: durationMinutes, schedule: schedule, now: now)
            if !daySlots.isEmpty {
                found.append((day, daySlots))
                if let limit, found.count >= limit { break }
            }
            day = day.adding(days: 1, in: calendar)
        }
        return found
    }

    /// The first slot of each of the next few open days. Gives variety ("Today 3:30 PM,
    /// Tomorrow 9:00 AM, Thu 10:30 AM") instead of four morning slots on one day.
    static func soonest(count: Int, durationMinutes: Int, schedule: CreatorSchedule, now: Date) -> [TimeSlot] {
        availableDays(durationMinutes: durationMinutes, schedule: schedule, now: now, limit: count)
            .compactMap { $0.slots.first }
    }
}
