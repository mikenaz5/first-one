import XCTest
@testable import Slate

final class NoticeFormatTests: XCTestCase {
    private let chicago = TimeZone(identifier: "America/Chicago")!
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    // These are the same instants and wording as the push tests in supabase/function-tests/push.test.ts: the server
    // words notifications for people with a server, and this words reminders for people without one.
    func testAShootIsShownInTheZoneItHappensIn() {
        let start = TestClock.date(2026, 11, 14, 10, 0)
        XCTAssertEqual(NoticeFormat.shootTime(start, in: chicago), "Sat, Nov 14 at 10:00 AM")
        XCTAssertEqual(NoticeFormat.shootTime(start, in: tokyo), "Sun, Nov 15 at 1:00 AM")
    }

    func testMidnightAndNoonAreTwelve() {
        XCTAssertEqual(NoticeFormat.shootTime(TestClock.date(2026, 11, 14, 0, 0), in: chicago), "Sat, Nov 14 at 12:00 AM")
        XCTAssertEqual(NoticeFormat.shootTime(TestClock.date(2026, 11, 14, 12, 5), in: chicago), "Sat, Nov 14 at 12:05 PM")
        XCTAssertEqual(NoticeFormat.shootTime(TestClock.date(2026, 11, 14, 21, 59), in: chicago), "Sat, Nov 14 at 9:59 PM")
    }

    func testDaylightSaving() {
        XCTAssertEqual(NoticeFormat.shootTime(TestClock.date(2026, 3, 8, 3, 30), in: chicago), "Sun, Mar 8 at 3:30 AM")
        XCTAssertEqual(NoticeFormat.shootTime(TestClock.date(2026, 7, 4, 11, 0), in: chicago), "Sat, Jul 4 at 11:00 AM")
    }

    func testDaysAreCountedOnTheCalendarInTheShootsZone() {
        let start = TestClock.date(2026, 11, 14, 10, 0)
        XCTAssertEqual(NoticeFormat.dayLabel(start, relativeTo: TestClock.date(2026, 11, 14, 8, 0), in: chicago), "today")
        XCTAssertEqual(NoticeFormat.dayLabel(start, relativeTo: TestClock.date(2026, 11, 13, 10, 0), in: chicago), "tomorrow")
        XCTAssertEqual(NoticeFormat.dayLabel(start, relativeTo: TestClock.date(2026, 11, 13, 23, 59), in: chicago), "tomorrow")
        XCTAssertEqual(NoticeFormat.dayLabel(start, relativeTo: TestClock.date(2026, 11, 12, 14, 0), in: chicago), "Sat, Nov 14")
    }

    func testTheDayBeforeAClockChangeIsStillTomorrow() {
        // Clocks go forward on Sunday 14 March 2027, so "24 hours before" is 25 hours of wall-clock time earlier.
        let start = TestClock.date(2027, 3, 14, 10, 0)
        let fire = start.addingTimeInterval(-86_400)
        XCTAssertEqual(NoticeFormat.dayLabel(start, relativeTo: fire, in: chicago), "tomorrow")
    }
}

final class ReminderPlannerTests: XCTestCase {
    private let now = TestClock.date(2027, 1, 4, 8, 0)           // Monday
    private let friday = TestClock.date(2027, 1, 22, 10, 0)
    private let creatorID = UUID()
    private let clientID = UUID()

    private func booking(
        status: BookingStatus = .confirmed, start: Date? = nil, createdAt: Date? = nil, hold: Date? = nil,
        creator: UUID? = nil, client: UUID? = nil, package: String = "Portrait session"
    ) -> Booking {
        let start = start ?? friday
        return Booking(
            id: UUID(), creatorID: creator ?? creatorID, clientID: client ?? clientID, creatorName: "Dana Lens", clientName: "Sam Client",
            packageID: nil, packageName: package, addOns: [], startAt: start, endAt: start.addingTimeInterval(3600),
            blockedUntil: start.addingTimeInterval(5400), timeZoneID: "America/Chicago", currencyCode: "USD",
            totalCents: 200_000, depositCents: 50_000, status: status, notes: "", createdAt: createdAt ?? now, holdExpiresAt: hold
        )
    }

    func testAConfirmedShootGetsADayBeforeAndATwoHoursBeforeReminder() throws {
        let b = booking()
        let plan = ReminderPlanner.plan(bookings: [b], userID: creatorID, now: now)

        XCTAssertEqual(plan.count, 2)
        XCTAssertEqual(plan.map(\.fireDate), [TestClock.date(2027, 1, 21, 10, 0), TestClock.date(2027, 1, 22, 8, 0)])
        XCTAssertEqual(plan[0].title, "Shoot tomorrow")
        XCTAssertEqual(plan[0].body, "Portrait session with Sam Client at 10:00 AM")
        XCTAssertEqual(plan[1].title, "Shoot in 2 hours")
        XCTAssertEqual(plan[1].body, "Portrait session with Sam Client at 10:00 AM")
        XCTAssertTrue(plan.allSatisfy { $0.bookingID == b.id })
    }

    func testAClientIsRemindedWhoTheyAreMeeting() {
        let plan = ReminderPlanner.plan(bookings: [booking()], userID: clientID, now: now)
        XCTAssertEqual(plan.first?.body, "Portrait session with Dana Lens at 10:00 AM")
    }

    func testOnlyThePeopleInABookingAreReminded() {
        XCTAssertTrue(ReminderPlanner.plan(bookings: [booking()], userID: UUID(), now: now).isEmpty)
    }

    func testOnlyConfirmedBookingsAreReminded() {
        for status in [BookingStatus.held, .cancelled, .completed, .expired] {
            XCTAssertTrue(ReminderPlanner.plan(bookings: [booking(status: status)], userID: creatorID, now: now).isEmpty, "\(status)")
        }
    }

    func testAHoldThatRanOutIsNotReminded() {
        let lapsed = booking(status: .held, hold: now.addingTimeInterval(-60))
        XCTAssertTrue(ReminderPlanner.plan(bookings: [lapsed], userID: clientID, now: now).isEmpty)
    }

    func testRemindersInThePastAreNotScheduled() {
        // Twenty hours out: the day-before moment has passed, the two-hour one hasn't.
        let soon = booking(start: now.addingTimeInterval(20 * 3600))
        XCTAssertEqual(ReminderPlanner.plan(bookings: [soon], userID: creatorID, now: now).map(\.title), ["Shoot in 2 hours"])
        // An hour out: neither.
        let imminent = booking(start: now.addingTimeInterval(3600))
        XCTAssertTrue(ReminderPlanner.plan(bookings: [imminent], userID: creatorID, now: now).isEmpty)
        // Already started.
        let started = booking(start: now.addingTimeInterval(-600))
        XCTAssertTrue(ReminderPlanner.plan(bookings: [started], userID: creatorID, now: now).isEmpty)
    }

    func testABookingMadeAfterAReminderTimeDoesNotGetThatReminder() {
        // The database does not send a reminder for a moment that came before the booking existed ("tomorrow"
        // would be wrong). Here the booking looks as if it was made on the afternoon of the day before the shoot,
        // which can only happen with a clock that is behind, but the rule must hold either way.
        let dayBefore = friday.addingTimeInterval(-20 * 3600)
        let plan = ReminderPlanner.plan(bookings: [booking(createdAt: dayBefore)], userID: creatorID, now: now)
        XCTAssertEqual(plan.map(\.title), ["Shoot in 2 hours"])
    }

    func testRemindersCanBeSwitchedOff() {
        XCTAssertTrue(ReminderPlanner.plan(bookings: [booking()], userID: creatorID, now: now, enabled: false).isEmpty)
    }

    func testThePlanIsCappedAndSoonestFirst() {
        let bookings = (0..<40).map { booking(start: friday.addingTimeInterval(Double($0) * 7200)) }
        let plan = ReminderPlanner.plan(bookings: bookings, userID: creatorID, now: now)
        XCTAssertEqual(plan.count, ReminderRules.maxPending)
        XCTAssertEqual(plan.map(\.fireDate), plan.map(\.fireDate).sorted())
        let few = ReminderPlanner.plan(bookings: bookings, userID: creatorID, now: now, limit: 3)
        XCTAssertEqual(few, Array(plan.prefix(3)))
    }

    func testIdentifiersAreStableAndDistinct() {
        let b = booking()
        let first = ReminderPlanner.plan(bookings: [b], userID: creatorID, now: now)
        let second = ReminderPlanner.plan(bookings: [b], userID: creatorID, now: now.addingTimeInterval(3600))
        XCTAssertEqual(first.map(\.id), second.map(\.id), "The same reminder keeps its identifier, so it isn't scheduled twice")
        XCTAssertEqual(Set(first.map(\.id)).count, 2)
        XCTAssertTrue(first.allSatisfy { $0.id.hasPrefix(ReminderRules.identifierPrefix) })
        XCTAssertTrue(first[0].id.contains(b.id.uuidString.lowercased()))
    }

    func testTheReminderMomentUsesTheDayInTheShootsZone() {
        let start = TestClock.date(2027, 3, 14, 10, 0)
        let b = booking(start: start)
        let plan = ReminderPlanner.plan(bookings: [b], userID: creatorID, now: now)
        XCTAssertEqual(plan.first?.title, "Shoot tomorrow")
        XCTAssertEqual(plan.first?.fireDate, start.addingTimeInterval(-86_400))
    }

    func testAMissingPackageNameStillReadsWell() {
        let plan = ReminderPlanner.plan(bookings: [booking(package: "  ")], userID: creatorID, now: now)
        XCTAssertEqual(plan.first?.body, "your booking with Sam Client at 10:00 AM")
    }
}

final class LinksAndSettingsTests: XCTestCase {
    func testLinksAreParsed() {
        let id = UUID()
        XCTAssertEqual(AppLink(url: URL(string: "slate://book/Maya-Chen")!), AppLink.creatorPage(handle: "maya-chen"))
        XCTAssertEqual(AppLink(url: URL(string: "slate://booking/\(id.uuidString)")!), AppLink.booking(id))
        XCTAssertEqual(AppLink(url: URL(string: "slate://messages/\(id.uuidString.lowercased())")!), AppLink.messages(id))
        XCTAssertEqual(AppLink(url: URL(string: "slate://booking")!), AppLink.booking(nil))
        XCTAssertEqual(AppLink(url: URL(string: "slate://messages/not-an-id")!), AppLink.messages(nil))
        XCTAssertEqual(AppLink(url: URL(string: "slate://stripe/return")!), AppLink.stripeReturn)
    }

    func testOtherLinksAreIgnored() {
        XCTAssertNil(AppLink(url: URL(string: "https://slate.example/maya")!))
        XCTAssertNil(AppLink(url: URL(string: "slate://unknown/thing")!))
        XCTAssertNil(AppLink(url: URL(string: "slate://book")!))
        XCTAssertNil(AppLink(url: URL(string: "slate://book/")!))
        XCTAssertNil(AppLink(url: URL(string: "other://booking/\(UUID().uuidString)")!))
    }

    func testLinkBuildersRoundTrip() throws {
        let id = UUID()
        XCTAssertEqual(AppLink(url: try XCTUnwrap(AppLink.bookingURL(id))), AppLink.booking(id))
        XCTAssertEqual(AppLink(url: try XCTUnwrap(AppLink.messagesURL(id))), AppLink.messages(id))
    }

    func testATappedNotificationsDestinationIsReadFromItsPayload() {
        let userInfo: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "T", "body": "B"]],
            "slate": ["url": "slate://messages/\(UUID().uuidString)", "kind": "message"],
        ]
        XCTAssertEqual(NotificationRouting.url(fromUserInfo: userInfo)?.host, "messages")
        XCTAssertNil(NotificationRouting.url(fromUserInfo: ["aps": ["badge": 1]]))
        XCTAssertNil(NotificationRouting.url(fromUserInfo: ["slate": "oops"]))
        XCTAssertNil(NotificationRouting.url(fromUserInfo: ["slate": ["kind": "message"]]))
    }

    func testDeviceTokensAreLowercaseHex() {
        XCTAssertEqual(DeviceToken.hex(from: Data([0x01, 0xAB, 0xFF, 0x00])), "01abff00")
        XCTAssertEqual(DeviceToken.hex(from: Data()), "")
        XCTAssertEqual(DeviceToken.hex(from: Data(repeating: 0xAB, count: 32)).count, 64)
    }

    func testPreferencesStartOnAndCanBeReadAndSetByCategory() {
        var prefs = NotificationPreferences()
        XCTAssertTrue(NotificationCategory.allCases.allSatisfy { prefs[$0] })
        prefs[.payments] = false
        XCTAssertFalse(prefs.payments)
        XCTAssertTrue(prefs.bookings && prefs.contracts && prefs.messages && prefs.reminders)
        for category in NotificationCategory.allCases {
            prefs[category] = false
            XCTAssertFalse(prefs[category])
        }
    }

    func testPreferencesReadTheDatabasesJSON() throws {
        let json = #"{"bookings":true,"contracts":false,"payments":true,"messages":false,"reminders":true}"#
        let prefs = try JSONDecoder().decode(NotificationPreferences.self, from: Data(json.utf8))
        XCTAssertEqual(prefs, NotificationPreferences(bookings: true, contracts: false, payments: true, messages: false, reminders: true))
        let sent = try JSONEncoder().encode(prefs)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [String: Bool])
        XCTAssertEqual(Set(keys.keys), ["bookings", "contracts", "payments", "messages", "reminders"])
    }

    func testEveryCategoryHasWordsAndAnIcon() {
        for category in NotificationCategory.allCases {
            XCTAssertFalse(category.title.isEmpty)
            XCTAssertFalse(category.detail.isEmpty)
            XCTAssertFalse(category.systemImage.isEmpty)
        }
        XCTAssertEqual(NotificationCategory.allCases.count, 5)
    }
}
