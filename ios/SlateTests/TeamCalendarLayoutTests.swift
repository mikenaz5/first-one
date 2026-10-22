import XCTest
@testable import Slate

/// How a person's day is laid out on the team calendar: their hours, what takes them, and what is left.
final class TeamCalendarLayoutTests: XCTestCase {
    private let zone = TestClock.timeZone
    /// 2027-01-06 is a Wednesday.
    private let wednesday = TestClock.date(2027, 1, 6, 12, 0)

    private func member(
        weekly: [DayHours] = [DayHours(weekday: 4, window: TimeWindow(startMinute: 9 * 60, endMinute: 17 * 60))],
        busy: [BusyRange] = [],
        bookings: [CalendarBooking] = []
    ) -> MemberCalendar {
        MemberCalendar(
            userID: UUID(), displayName: "Theo", avatarURL: nil, role: .creator, title: "", bookable: true,
            weekly: weekly, busy: busy, bookings: bookings
        )
    }

    private func booking(_ startHour: Int, _ startMinute: Int = 0, hours: Int = 1, buffer: Int = 30) -> CalendarBooking {
        let start = TestClock.date(2027, 1, 6, startHour, startMinute)
        let end = start.addingTimeInterval(Double(hours) * 3600)
        return CalendarBooking(
            bookingID: UUID(), startAt: start, endAt: end, blockedUntil: end.addingTimeInterval(Double(buffer) * 60),
            status: .confirmed, packageName: "Brand film", clientName: "Alex", requestedMember: false
        )
    }

    private func busy(_ from: (Int, Int), _ to: (Int, Int)) -> BusyRange {
        BusyRange(
            range: DateInterval(start: TestClock.date(2027, 1, 6, from.0, from.1), end: TestClock.date(2027, 1, 6, to.0, to.1)),
            kind: .external
        )
    }

    private func hours(_ intervals: [DateInterval]) -> [[Double]] {
        intervals.map { interval in
            [interval.start, interval.end].map { date in
                let parts = TestClock.calendar.dateComponents([.hour, .minute], from: date)
                return Double(parts.hour ?? 0) + Double(parts.minute ?? 0) / 60
            }
        }
    }

    func testFreeTimeIsWhatIsLeftOfTheWorkingHours() {
        let layout = MemberDayLayout.make(
            member: member(busy: [busy((14, 0), (15, 0))], bookings: [booking(10)]),
            on: wednesday, timeZone: zone
        )
        XCTAssertEqual(layout.working.map { hours([$0]) }, [[9, 17]])
        // The booking holds its buffer: 10:00 to 11:00, kept until 11:30.
        XCTAssertEqual(hours(layout.free), [[9, 10], [11.5, 14], [15, 17]])
        XCTAssertEqual(hours(layout.taken), [[10, 11.5], [14, 15]])
        XCTAssertEqual(layout.bookings.count, 1)
    }

    func testADayOffHasNoWorkingHoursAndNoFreeTime() {
        let saturday = TestClock.date(2027, 1, 9, 12, 0)
        let layout = MemberDayLayout.make(member: member(), on: saturday, timeZone: zone)
        XCTAssertNil(layout.working)
        XCTAssertTrue(layout.free.isEmpty)
    }

    func testBusyTimeOutsideTheWorkingHoursTakesNothingFromThem() {
        let layout = MemberDayLayout.make(member: member(busy: [busy((6, 0), (8, 0)), busy((18, 0), (20, 0))]), on: wednesday, timeZone: zone)
        XCTAssertEqual(hours(layout.free), [[9, 17]])
    }

    func testBusyTimeThatSpansMidnightIsCutToTheDay() {
        let overnight = BusyRange(
            range: DateInterval(start: TestClock.date(2027, 1, 5, 20, 0), end: TestClock.date(2027, 1, 6, 10, 0)),
            kind: .external
        )
        let layout = MemberDayLayout.make(member: member(busy: [overnight]), on: wednesday, timeZone: zone)
        XCTAssertEqual(hours(layout.taken), [[0, 10]])
        XCTAssertEqual(hours(layout.free), [[10, 17]])
    }

    func testOverlappingBusyTimeAndBookingsAreMergedOnce() {
        let layout = MemberDayLayout.make(
            member: member(busy: [busy((10, 30), (12, 0))], bookings: [booking(10)]),
            on: wednesday, timeZone: zone
        )
        XCTAssertEqual(hours(layout.taken), [[10, 12]])
        XCTAssertEqual(hours(layout.free), [[9, 10], [12, 17]])
    }

    func testSomeoneWhoDoesNotTakeBookingsStillShowsTheirBookedTime() {
        let layout = MemberDayLayout.make(member: member(weekly: [], bookings: [booking(13)]), on: wednesday, timeZone: zone)
        XCTAssertNil(layout.working)
        XCTAssertTrue(layout.free.isEmpty)
        XCTAssertEqual(layout.bookings.count, 1)
    }

    func testAWholeDayOpenHasOneFreeStretch() {
        let allDay = [DayHours(weekday: 4, window: TimeWindow(startMinute: 0, endMinute: 1440))]
        let layout = MemberDayLayout.make(member: member(weekly: allDay), on: wednesday, timeZone: zone)
        XCTAssertEqual(layout.free.count, 1)
        XCTAssertEqual(layout.free.first?.duration, 24 * 3600)
    }

    // MARK: Axis

    func testTheAxisCoversEveryonesHoursToTheWholeHour() {
        let early = MemberDayLayout.make(
            member: member(weekly: [DayHours(weekday: 4, window: TimeWindow(startMinute: 8 * 60 + 30, endMinute: 12 * 60))]),
            on: wednesday, timeZone: zone
        )
        let late = MemberDayLayout.make(
            member: member(weekly: [DayHours(weekday: 4, window: TimeWindow(startMinute: 13 * 60, endMinute: 18 * 60 + 15))]),
            on: wednesday, timeZone: zone
        )
        let axis = MemberDayLayout.axis(for: [early, late], timeZone: zone)
        XCTAssertEqual(axis.map { hours([$0]) }, [[8, 19]])
    }

    func testTheAxisIsNeverShorterThanTheMinimum() {
        let short = MemberDayLayout.make(
            member: member(weekly: [DayHours(weekday: 4, window: TimeWindow(startMinute: 9 * 60, endMinute: 10 * 60))]),
            on: wednesday, timeZone: zone
        )
        let axis = MemberDayLayout.axis(for: [short], timeZone: zone, minimumHours: 6)
        XCTAssertEqual(axis?.duration, 6 * 3600)
        XCTAssertEqual(axis.map { hours([$0]) }?.first?.first, 9)
    }

    func testTheAxisIsNilWhenNobodyHasAnythingThatDay() {
        let saturday = TestClock.date(2027, 1, 9, 12, 0)
        let layout = MemberDayLayout.make(member: member(), on: saturday, timeZone: zone)
        XCTAssertNil(MemberDayLayout.axis(for: [layout], timeZone: zone))
        XCTAssertNil(MemberDayLayout.axis(for: [], timeZone: zone))
    }
}
