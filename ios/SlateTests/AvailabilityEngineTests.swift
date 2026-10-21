import XCTest
@testable import Slate

/// Fixed clock in Chicago so results don't depend on where the tests run.
enum TestClock {
    static let timeZone = TimeZone(identifier: "America/Chicago")!

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static func hours(_ slots: [TimeSlot]) -> [Double] {
        slots.map { slot in
            let parts = calendar.dateComponents([.hour, .minute], from: slot.start)
            return Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
        }
    }
}

final class AvailabilityEngineTests: XCTestCase {
    // 2027-01-04 is a Monday.
    private let monday = CalendarDay(year: 2027, month: 1, day: 4)
    private let now = TestClock.date(2027, 1, 4, 8, 0)

    private func settings(
        notice: Int = 0, advance: Int = 30, buffer: Int = 0, interval: Int = 30
    ) -> AvailabilitySettings {
        var settings = AvailabilitySettings.standard(timeZone: TestClock.timeZone)
        settings.minNoticeHours = notice
        settings.maxAdvanceDays = advance
        settings.bufferMinutes = buffer
        settings.slotIntervalMinutes = interval
        return settings
    }

    private func schedule(
        _ settings: AvailabilitySettings,
        booked: [DateInterval] = [],
        external: [DateInterval] = []
    ) -> CreatorSchedule {
        CreatorSchedule(settings: settings, bookedRanges: booked, externalBusy: external)
    }

    private func slots(
        _ day: CalendarDay, minutes: Int = 60, schedule: CreatorSchedule, now: Date? = nil
    ) -> [TimeSlot] {
        AvailabilityEngine.slots(on: day, durationMinutes: minutes, schedule: schedule, now: now ?? self.now)
    }

    private var tuesday: CalendarDay { monday.adding(days: 1, in: TestClock.calendar) }

    func testFixtureDatesAreWhatTheTestsAssume() {
        XCTAssertEqual(monday.weekday(in: TestClock.calendar), 2)
        XCTAssertEqual(CalendarDay(year: 2027, month: 3, day: 14).weekday(in: TestClock.calendar), 1)
    }

    func testFullDayOfSlots() {
        let result = slots(tuesday, schedule: schedule(settings()))
        let hours = TestClock.hours(result)
        XCTAssertEqual(hours.count, 15)
        XCTAssertEqual(hours.first, 9)
        XCTAssertEqual(hours.last, 16, "A 60-minute shoot must finish by the 17:00 close")
        XCTAssertEqual(result.first.map { $0.end.timeIntervalSince($0.start) }, 3600)
    }

    func testClosedWeekdayHasNoSlots() {
        let saturday = monday.adding(days: 5, in: TestClock.calendar)
        XCTAssertTrue(slots(saturday, schedule: schedule(settings())).isEmpty)
    }

    func testBlackoutRemovesTheDayOnly() {
        var s = settings()
        let wednesday = monday.adding(days: 2, in: TestClock.calendar)
        s.blackouts = [BlackoutRange(start: wednesday, end: wednesday, reason: "Trip")]
        let sched = schedule(s)
        XCTAssertTrue(slots(wednesday, schedule: sched).isEmpty)
        XCTAssertFalse(slots(tuesday, schedule: sched).isEmpty)
        XCTAssertFalse(slots(wednesday.adding(days: 1, in: TestClock.calendar), schedule: sched).isEmpty)
    }

    func testMultiDayBlackoutIsInclusive() {
        var s = settings()
        let wednesday = monday.adding(days: 2, in: TestClock.calendar)
        let friday = monday.adding(days: 4, in: TestClock.calendar)
        s.blackouts = [BlackoutRange(start: wednesday, end: friday)]
        let sched = schedule(s)
        for offset in 2...4 {
            XCTAssertTrue(slots(monday.adding(days: offset, in: TestClock.calendar), schedule: sched).isEmpty, "day +\(offset)")
        }
        XCTAssertFalse(slots(monday.adding(days: 7, in: TestClock.calendar), schedule: sched).isEmpty)
    }

    func testMinimumNoticeTrimsTodaysEarlySlots() {
        let late = TestClock.date(2027, 1, 4, 10, 15)
        let result = slots(monday, schedule: schedule(settings(notice: 2)), now: late)
        XCTAssertEqual(TestClock.hours(result).first, 12.5, "10:15 plus 2 hours is 12:15, so 12:30 is the first start")
    }

    func testMinimumNoticeCanRuleOutAWholeDay() {
        let result = slots(monday, schedule: schedule(settings(notice: 24)), now: now)
        XCTAssertTrue(result.isEmpty, "Monday 8am plus 24h is Tuesday 8am")
        XCTAssertEqual(TestClock.hours(slots(tuesday, schedule: schedule(settings(notice: 24)))).first, 9)
    }

    func testPastDaysAreNeverOffered() {
        let sunday = monday.adding(days: -1, in: TestClock.calendar)
        let friday = monday.adding(days: -3, in: TestClock.calendar)
        XCTAssertTrue(slots(sunday, schedule: schedule(settings())).isEmpty)
        XCTAssertTrue(slots(friday, schedule: schedule(settings())).isEmpty)
    }

    func testMaximumAdvanceBoundary() {
        let sched = schedule(settings(advance: 8)) // Monday + 8 days = the next Tuesday
        XCTAssertFalse(slots(monday.adding(days: 8, in: TestClock.calendar), schedule: sched).isEmpty)
        XCTAssertTrue(slots(monday.adding(days: 9, in: TestClock.calendar), schedule: sched).isEmpty)
    }

    func testBookedRangeBlocksOverlapsAndKeepsTheBufferGap() {
        // A 60 minute booking at 10:00 with a 30 minute buffer occupies [10:00, 11:30).
        let booked = DateInterval(start: TestClock.date(2027, 1, 5, 10, 0), end: TestClock.date(2027, 1, 5, 11, 30))
        let hours = TestClock.hours(slots(tuesday, schedule: schedule(settings(buffer: 30), booked: [booked])))
        XCTAssertEqual(hours.first, 11.5, "Nothing earlier fits: 9:00 plus 60 min plus the 30 min buffer runs into 10:00")
        XCTAssertEqual(hours.last, 16)
        XCTAssertTrue(hours.allSatisfy { $0 >= 11.5 }, "Everything before 11:30 collides with the booking or its buffer")
        XCTAssertFalse(hours.contains(11), "11:00 would sit inside the previous booking's buffer")
    }

    func testBackToBackIsAllowedExactlyWhenTheBufferEnds() {
        let booked = DateInterval(start: TestClock.date(2027, 1, 5, 9, 0), end: TestClock.date(2027, 1, 5, 10, 30))
        let hours = TestClock.hours(slots(tuesday, schedule: schedule(settings(buffer: 30), booked: [booked])))
        XCTAssertEqual(hours.first, 10.5)
    }

    func testBufferAlsoProtectsTheTimeBeforeANextBooking() {
        // Someone is booked 12:00-13:30 (incl. buffer). A new 60 minute booking needs to finish plus buffer by 12:00.
        let booked = DateInterval(start: TestClock.date(2027, 1, 5, 12, 0), end: TestClock.date(2027, 1, 5, 13, 30))
        let hours = TestClock.hours(slots(tuesday, schedule: schedule(settings(buffer: 30), booked: [booked])))
        XCTAssertTrue(hours.contains(10.5), "10:30-11:30 plus buffer ends exactly at 12:00")
        XCTAssertFalse(hours.contains(11), "11:00-12:00 plus buffer overlaps")
    }

    func testExternalBusyTimeGetsTheBufferAfterIt() {
        let busy = DateInterval(start: TestClock.date(2027, 1, 5, 11, 0), end: TestClock.date(2027, 1, 5, 12, 0))
        let hours = TestClock.hours(slots(tuesday, schedule: schedule(settings(buffer: 30), external: [busy])))
        XCTAssertTrue(hours.contains(9.5), "9:30-10:30 plus buffer ends at 11:00, touching but not overlapping")
        XCTAssertFalse(hours.contains(10))
        XCTAssertFalse(hours.contains(12), "Starting right as the event ends leaves no travel gap")
        XCTAssertTrue(hours.contains(12.5))
    }

    func testLongerBookingsNeedLongerOpenTime() {
        let hours = TestClock.hours(slots(tuesday, minutes: 180, schedule: schedule(settings())))
        XCTAssertEqual(hours.last, 14, "Three hours starting 14:00 ends at the 17:00 close")
        XCTAssertFalse(hours.contains(14.5))
    }

    func testDurationLongerThanTheDayHasNoSlots() {
        XCTAssertTrue(slots(tuesday, minutes: 9 * 60, schedule: schedule(settings())).isEmpty)
    }

    func testSlotIntervalControlsTheGrid() {
        let hourly = TestClock.hours(slots(tuesday, schedule: schedule(settings(interval: 60))))
        XCTAssertEqual(hourly.count, 8)
        let quarter = TestClock.hours(slots(tuesday, schedule: schedule(settings(interval: 15))))
        XCTAssertEqual(quarter.count, 29)
    }

    func testIsAvailableAgreesWithSlots() {
        let sched = schedule(settings())
        let start = TestClock.date(2027, 1, 5, 10, 0)
        XCTAssertTrue(AvailabilityEngine.isAvailable(start: start, durationMinutes: 60, schedule: sched, now: now))
        XCTAssertFalse(AvailabilityEngine.isAvailable(start: TestClock.date(2027, 1, 5, 10, 15), durationMinutes: 60, schedule: sched, now: now), "Off the grid")
        XCTAssertFalse(AvailabilityEngine.isAvailable(start: TestClock.date(2027, 1, 5, 16, 30), durationMinutes: 60, schedule: sched, now: now), "Runs past closing")
        XCTAssertFalse(AvailabilityEngine.isAvailable(start: TestClock.date(2027, 1, 9, 10, 0), durationMinutes: 60, schedule: sched, now: now), "Saturday")
    }

    func testClosedCreatorOffersNothing() {
        let closed = schedule(AvailabilitySettings.closed(timeZone: TestClock.timeZone))
        XCTAssertTrue(AvailabilityEngine.availableDays(durationMinutes: 60, schedule: closed, now: now).isEmpty)
    }

    func testSoonestGivesOneSlotPerDay() {
        let soonest = AvailabilityEngine.soonest(count: 3, durationMinutes: 60, schedule: schedule(settings()), now: now)
        XCTAssertEqual(soonest.count, 3)
        let days = soonest.map { CalendarDay($0.start, calendar: TestClock.calendar) }
        XCTAssertEqual(Set(days).count, 3, "Variety across days, not three slots on one day")
        XCTAssertEqual(days, days.sorted())
        XCTAssertEqual(days.first, monday, "Today still has openings at 9:00")
    }

    func testAvailableDaysAreOrderedAndSkipClosedDays() {
        let days = AvailabilityEngine.availableDays(durationMinutes: 60, schedule: schedule(settings()), now: now).map(\.day)
        XCTAssertEqual(days, days.sorted())
        let weekdays = Set(days.map { $0.weekday(in: TestClock.calendar) })
        XCTAssertEqual(weekdays, [2, 3, 4, 5, 6])
    }

    func testSpringForwardDoesNotOfferTheMissingHourTwice() {
        var s = settings(advance: 60, interval: 60)
        s.weekly = [DayHours(weekday: 1, window: TimeWindow(startMinute: 60, endMinute: 240))] // Sundays 1:00-4:00
        let springForward = CalendarDay(year: 2027, month: 3, day: 14)
        let result = slots(springForward, schedule: schedule(s), now: TestClock.date(2027, 3, 12, 12, 0))
        let hours = TestClock.hours(result)
        XCTAssertEqual(hours, [1, 3], "2:00 AM doesn't exist that day, so it must not appear (or turn into a second 3:00)")
        XCTAssertEqual(Set(result.map(\.start)).count, result.count)
    }
}

// MARK: - Day maths

final class CalendarDayTests: XCTestCase {
    func testISORoundTripAndOrdering() {
        let day = CalendarDay(year: 2026, month: 12, day: 24)
        XCTAssertEqual(day.isoString, "2026-12-24")
        XCTAssertEqual(CalendarDay(isoString: "2026-12-24"), day)
        XCTAssertNil(CalendarDay(isoString: "2026-13-01"))
        XCTAssertNil(CalendarDay(isoString: "nonsense"))
        XCTAssertLessThan(day, CalendarDay(year: 2027, month: 1, day: 1))
        XCTAssertLessThan(CalendarDay(year: 2026, month: 2, day: 28), CalendarDay(year: 2026, month: 3, day: 1))
    }

    func testAddingDaysCrossesMonthsAndYears() {
        let calendar = TestClock.calendar
        XCTAssertEqual(CalendarDay(year: 2026, month: 12, day: 31).adding(days: 1, in: calendar), CalendarDay(year: 2027, month: 1, day: 1))
        XCTAssertEqual(CalendarDay(year: 2027, month: 2, day: 28).adding(days: 1, in: calendar), CalendarDay(year: 2027, month: 3, day: 1))
        XCTAssertEqual(CalendarDay(year: 2027, month: 3, day: 1).adding(days: -1, in: calendar), CalendarDay(year: 2027, month: 2, day: 28))
    }

    func testAddingDaysAcrossDaylightSavingKeepsTheDate() {
        let calendar = TestClock.calendar
        XCTAssertEqual(CalendarDay(year: 2027, month: 3, day: 13).adding(days: 1, in: calendar), CalendarDay(year: 2027, month: 3, day: 14))
        XCTAssertEqual(CalendarDay(year: 2027, month: 3, day: 14).adding(days: 1, in: calendar), CalendarDay(year: 2027, month: 3, day: 15))
        XCTAssertEqual(CalendarDay(year: 2027, month: 11, day: 7).adding(days: 1, in: calendar), CalendarDay(year: 2027, month: 11, day: 8))
    }

    func testCodableUsesAPlainDateString() throws {
        let data = try JSONEncoder().encode(["day": CalendarDay(year: 2026, month: 12, day: 24)])
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"day":"2026-12-24"}"#)
        let decoded = try JSONDecoder().decode([String: CalendarDay].self, from: data)
        XCTAssertEqual(decoded["day"], CalendarDay(year: 2026, month: 12, day: 24))
    }
}

final class IntervalMathTests: XCTestCase {
    private func interval(_ a: Int, _ b: Int) -> DateInterval {
        DateInterval(start: Date(timeIntervalSince1970: Double(a)), end: Date(timeIntervalSince1970: Double(b)))
    }

    func testOverlapIsHalfOpen() {
        XCTAssertTrue(IntervalMath.overlaps(interval(0, 10), interval(5, 15)))
        XCTAssertTrue(IntervalMath.overlaps(interval(0, 10), interval(2, 4)))
        XCTAssertFalse(IntervalMath.overlaps(interval(0, 10), interval(10, 20)), "Touching is not overlapping")
        XCTAssertFalse(IntervalMath.overlaps(interval(10, 20), interval(0, 10)))
        XCTAssertFalse(IntervalMath.overlaps(interval(0, 5), interval(6, 9)))
    }

    func testMergeJoinsOverlappingAndTouchingRanges() {
        let merged = IntervalMath.merge([interval(20, 30), interval(0, 10), interval(5, 12), interval(12, 15), interval(40, 50)])
        XCTAssertEqual(merged, [interval(0, 15), interval(20, 30), interval(40, 50)])
    }

    func testMergeKeepsTheLongerEndWhenOneRangeContainsAnother() {
        XCTAssertEqual(IntervalMath.merge([interval(0, 100), interval(10, 20)]), [interval(0, 100)])
    }

    func testMergeOfNothingIsNothing() {
        XCTAssertTrue(IntervalMath.merge([]).isEmpty)
    }
}

// MARK: - Settings

final class AvailabilitySettingsTests: XCTestCase {
    func testStandardIsMondayToFridayNineToFive() {
        let standard = AvailabilitySettings.standard(timeZone: TestClock.timeZone)
        XCTAssertTrue(standard.isValid)
        XCTAssertEqual(standard.weekly.map(\.weekday), [2, 3, 4, 5, 6])
        XCTAssertEqual(standard.window(forWeekday: 2), TimeWindow(startMinute: 540, endMinute: 1020))
        XCTAssertNil(standard.window(forWeekday: 1))
    }

    func testClosedHasNoOpenDays() {
        XCTAssertFalse(AvailabilitySettings.closed().hasOpenDay)
    }

    func testValidationRejectsBadWindowsAndDuplicates() {
        var s = AvailabilitySettings.standard(timeZone: TestClock.timeZone)
        s.weekly[0].window = TimeWindow(startMinute: 600, endMinute: 600)
        XCTAssertFalse(s.isValid)

        s = AvailabilitySettings.standard(timeZone: TestClock.timeZone)
        s.weekly.append(DayHours(weekday: 2, window: TimeWindow(startMinute: 0, endMinute: 60)))
        XCTAssertFalse(s.isValid, "One entry per weekday")

        s = AvailabilitySettings.standard(timeZone: TestClock.timeZone)
        s.slotIntervalMinutes = 20
        XCTAssertFalse(s.isValid)

        s = AvailabilitySettings.standard(timeZone: TestClock.timeZone)
        let day = CalendarDay(year: 2027, month: 1, day: 5)
        s.blackouts = [BlackoutRange(start: day.adding(days: 3, in: TestClock.calendar), end: day)]
        XCTAssertFalse(s.isValid, "A blackout can't end before it starts")
    }

    func testWeekdayGroupingMergesRunsWithTheSameHours() {
        let standard = AvailabilitySettings.standard(timeZone: TestClock.timeZone)
        let groups = standard.openDayGroups(firstWeekday: 1)
        XCTAssertEqual(groups.map(\.weekdays), [[2, 3, 4, 5, 6]])
    }

    func testWeekdayGroupingSplitsOnDifferentHoursOrGaps() {
        var s = AvailabilitySettings.standard(timeZone: TestClock.timeZone)
        s.weekly[3].window = TimeWindow(startMinute: 600, endMinute: 960) // Thursday differs
        XCTAssertEqual(s.openDayGroups(firstWeekday: 1).map(\.weekdays), [[2, 3, 4], [5], [6]])

        s.weekly.removeAll { $0.weekday == 3 } // Tuesday closed
        XCTAssertEqual(s.openDayGroups(firstWeekday: 1).map(\.weekdays), [[2], [4], [5], [6]])
    }

    func testWeekdayGroupingFollowsTheWeekStartAndWrapsAroundTheEnd() {
        var s = AvailabilitySettings.standard(timeZone: TestClock.timeZone)
        let weekend = TimeWindow(startMinute: 600, endMinute: 900)
        s.weekly = [DayHours(weekday: 7, window: weekend), DayHours(weekday: 1, window: weekend)]
        XCTAssertEqual(s.openDayGroups(firstWeekday: 2).map(\.weekdays), [[7, 1]], "With Monday first, Saturday and Sunday are neighbours")
        XCTAssertEqual(s.openDayGroups(firstWeekday: 1).map(\.weekdays), [[1], [7]], "With Sunday first they are at opposite ends")
    }

    func testSettingsSurviveJSON() throws {
        var s = AvailabilitySettings.standard(timeZone: TestClock.timeZone)
        s.blackouts = [BlackoutRange(start: CalendarDay(year: 2026, month: 12, day: 24), end: CalendarDay(year: 2026, month: 12, day: 26), reason: "Holidays")]
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(AvailabilitySettings.self, from: data), s)
    }
}

// MARK: - Formatting

final class SlotFormatterTests: XCTestCase {
    private let formatter = SlotFormatter(timeZone: TestClock.timeZone, locale: Locale(identifier: "en_US_POSIX"))
    private let now = TestClock.date(2027, 1, 5, 12, 0)

    func testChipLabelsUseTodayTomorrowThenWeekday() {
        XCTAssertTrue(formatter.chipLabel(for: TestClock.date(2027, 1, 5, 15, 30), relativeTo: now).hasPrefix("Today"))
        XCTAssertTrue(formatter.chipLabel(for: TestClock.date(2027, 1, 6, 9, 0), relativeTo: now).hasPrefix("Tomorrow"))
        XCTAssertTrue(formatter.chipLabel(for: TestClock.date(2027, 1, 8, 9, 0), relativeTo: now).hasPrefix("Fri"))
        let far = formatter.chipLabel(for: TestClock.date(2027, 1, 20, 9, 0), relativeTo: now)
        XCTAssertTrue(far.hasPrefix("Jan"), far)
        XCTAssertTrue(far.contains("20"), far)
    }

    func testTimesAreShownInTheCreatorsZoneNotTheDevices() {
        // 15:30 Chicago is 21:30 UTC. Formatting must say 3:30, whatever zone this machine is in.
        let text = formatter.time(TestClock.date(2027, 1, 5, 15, 30))
        XCTAssertTrue(text.contains("3:30"), text)
    }

    func testRangeJoinsStartAndEnd() {
        let range = formatter.timeRange(start: TestClock.date(2027, 1, 5, 10, 0), end: TestClock.date(2027, 1, 5, 12, 0))
        XCTAssertTrue(range.contains("10:00"))
        XCTAssertTrue(range.contains("12:00"))
    }

    func testZoneNoteAppearsOnlyWhenZonesDiffer() {
        XCTAssertNil(SlotFormatter(timeZone: .current).zoneNote)
        let other = TimeZone.current.identifier == "Pacific/Auckland" ? "Europe/Paris" : "Pacific/Auckland"
        XCTAssertNotNil(SlotFormatter(timeZone: TimeZone(identifier: other)!).zoneNote)
    }
}
