import XCTest
@testable import Slate

final class CompanyReportTests: XCTestCase {
    private let now = TestClock.date(2027, 1, 20, 12, 0)
    private let theo = UUID()
    private let jun = UUID()
    private var names: [UUID: String] { [theo: "Theo", jun: "Jun"] }
    private var january: DateInterval { ReportRange.thisMonth.interval(now: now, calendar: TestClock.calendar) }

    private func booking(
        _ status: BookingStatus, day: Int, to person: UUID?, total: Int = 200_000, share: Int? = nil, month: Int = 1
    ) -> Booking {
        let start = TestClock.date(2027, month, day, 10, 0)
        return Booking(
            id: UUID(), creatorID: UUID(), clientID: UUID(), creatorName: "Northlight Films", clientName: "Alex",
            packageID: nil, packageName: "Brand film", addOns: [],
            startAt: start, endAt: start.addingTimeInterval(3600), blockedUntil: start.addingTimeInterval(5400),
            timeZoneID: "America/Chicago", currencyCode: "USD", totalCents: total, depositCents: 50_000, status: status,
            notes: "", createdAt: start.addingTimeInterval(-86_400 * 10),
            assignedTo: person, assigneeShareBps: share
        )
    }

    private func report(_ bookings: [Booking], splits: Bool = false) -> CompanyReport {
        CompanyReport.make(bookings: bookings, names: names, range: january, now: now, splits: splits)
    }

    func testBookedEarnedAndCancelledAreCountedSeparately() {
        let result = report([
            booking(.completed, day: 5, to: theo, total: 300_000),
            booking(.completed, day: 8, to: jun, total: 100_000),
            booking(.confirmed, day: 25, to: theo, total: 200_000),
            booking(.cancelled, day: 12, to: jun),
        ])
        XCTAssertEqual(result.booked, 3)
        XCTAssertEqual(result.completed, 2)
        XCTAssertEqual(result.upcoming, 1)
        XCTAssertEqual(result.cancelled, 1)
        XCTAssertEqual(result.bookedCents, 600_000)
        XCTAssertEqual(result.earnedCents, 400_000)
    }

    func testHeldExpiredAndOutOfRangeBookingsDoNotCount() {
        let result = report([
            booking(.held, day: 22, to: theo),
            booking(.expired, day: 22, to: theo),
            booking(.completed, day: 5, to: theo, month: 12),
            booking(.completed, day: 5, to: theo, month: 2),
            booking(.completed, day: 6, to: theo),
        ])
        XCTAssertEqual(result.booked, 1)
        XCTAssertEqual(result.completed, 1)
    }

    func testEachPersonHasALineAndTheTopEarnerIsFirst() {
        let result = report([
            booking(.completed, day: 5, to: jun, total: 100_000),
            booking(.completed, day: 6, to: theo, total: 300_000),
            booking(.completed, day: 7, to: theo, total: 100_000),
        ])
        XCTAssertEqual(result.lines.map(\.name), ["Theo", "Jun"])
        XCTAssertEqual(result.lines.first?.bookings, 2)
        XCTAssertEqual(result.lines.first?.earnedCents, 400_000)
        XCTAssertEqual(result.lines.last?.earnedCents, 100_000)
    }

    func testBookingsNobodyHasYetAreTheLastLine() {
        let result = report([
            booking(.confirmed, day: 24, to: nil),
            booking(.completed, day: 5, to: theo),
        ])
        XCTAssertEqual(result.lines.map(\.name), ["Theo", "Needs a person"])
        XCTAssertNil(result.lines.last?.memberID)
    }

    func testWhatIsOwedFollowsEachBookingsOwnSharePerPerson() {
        let result = report([
            booking(.completed, day: 5, to: theo, total: 300_000, share: 6_000),
            booking(.completed, day: 6, to: theo, total: 100_000, share: 5_000),
            booking(.completed, day: 7, to: jun, total: 200_000, share: 4_000),
            booking(.confirmed, day: 26, to: jun, total: 500_000, share: 4_000),
        ], splits: true)
        XCTAssertEqual(result.lines.first { $0.memberID == theo }?.owedCents, 180_000 + 50_000)
        XCTAssertEqual(result.lines.first { $0.memberID == jun }?.owedCents, 80_000, "Only finished work is owed")
        XCTAssertEqual(result.owedCents, 310_000)
    }

    func testNothingIsOwedWhenThePayoutsAreNotSplit() {
        let result = report([booking(.completed, day: 5, to: theo, total: 300_000, share: 6_000)], splits: false)
        XCTAssertEqual(result.owedCents, 0)
        XCTAssertEqual(result.lines.first?.owedCents, 0)
    }

    func testAShareIsRoundedDownToTheCent() {
        let result = report([booking(.completed, day: 5, to: theo, total: 10_001, share: 3_333)], splits: true)
        XCTAssertEqual(result.owedCents, 3_333)
    }

    func testTheRangesAreWholeMonthsAndTheYear() {
        let calendar = TestClock.calendar
        XCTAssertEqual(ReportRange.thisMonth.interval(now: now, calendar: calendar).start, TestClock.date(2027, 1, 1))
        XCTAssertEqual(ReportRange.thisMonth.interval(now: now, calendar: calendar).end, TestClock.date(2027, 2, 1))
        XCTAssertEqual(ReportRange.lastMonth.interval(now: now, calendar: calendar).start, TestClock.date(2026, 12, 1))
        XCTAssertEqual(ReportRange.lastMonth.interval(now: now, calendar: calendar).end, TestClock.date(2027, 1, 1))
        XCTAssertEqual(ReportRange.thisYear.interval(now: now, calendar: calendar).start, TestClock.date(2027, 1, 1))
        XCTAssertEqual(ReportRange.thisYear.interval(now: now, calendar: calendar).end, TestClock.date(2028, 1, 1))
    }
}
