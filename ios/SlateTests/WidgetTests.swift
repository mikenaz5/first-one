import XCTest
@testable import Slate

/// What the home screen widget shows, how the app hands it over, and when it redraws.
final class WidgetSnapshotBuilderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let me = UUID()
    private let other = UUID()

    private func booking(
        _ status: BookingStatus = .confirmed, creator: UUID? = nil, client: UUID? = nil, startsIn hours: Double = 24,
        hours long: Double = 1, name: String = "Portrait session", hold: Date? = nil, clientName: String = "Sam Client"
    ) -> Booking {
        Booking(
            id: UUID(), creatorID: creator ?? other, clientID: client ?? me, creatorName: "Dana Lens", clientName: clientName,
            packageID: nil, packageName: name, addOns: [],
            startAt: now.addingTimeInterval(hours * 3600), endAt: now.addingTimeInterval((hours + long) * 3600),
            blockedUntil: now.addingTimeInterval((hours + long) * 3600 + 1800), timeZoneID: "America/Chicago", currencyCode: "USD",
            totalCents: 200_000, depositCents: 50_000, status: status, notes: "", createdAt: now.addingTimeInterval(-86_400),
            holdExpiresAt: hold
        )
    }

    func testSignedOutShowsNothingPersonal() {
        XCTAssertEqual(WidgetSnapshotBuilder.make(bookings: [booking()], userID: nil, now: now), .signedOut)
        XCTAssertTrue(WidgetSnapshot.signedOut.bookings.isEmpty)
    }

    func testOnlyConfirmedUpcomingBookingsOfThisPersonAppear() {
        let mine = booking()
        let list = [
            mine,
            booking(.held, hold: now.addingTimeInterval(600)),
            booking(.cancelled),
            booking(.completed, startsIn: -48),
            booking(startsIn: -5, hours: 1),
            booking(creator: other, client: other),
        ]
        let snapshot = WidgetSnapshotBuilder.make(bookings: list, userID: me, now: now)
        XCTAssertEqual(snapshot.state, .signedIn)
        XCTAssertEqual(snapshot.bookings.map(\.id), [mine.id])
    }

    func testABookingInProgressStillCounts() {
        let underway = booking(startsIn: -0.5, hours: 2)
        let snapshot = WidgetSnapshotBuilder.make(bookings: [underway], userID: me, now: now)
        XCTAssertEqual(snapshot.bookings.map(\.id), [underway.id])
    }

    func testSoonestFirstAndAtMostThree() {
        let list = [booking(startsIn: 50), booking(startsIn: 10), booking(startsIn: 30), booking(startsIn: 20), booking(startsIn: 40)]
        let snapshot = WidgetSnapshotBuilder.make(bookings: list, userID: me, now: now)
        XCTAssertEqual(snapshot.bookings.count, WidgetSnapshotBuilder.capacity)
        XCTAssertEqual(snapshot.bookings.map { $0.startAt.timeIntervalSince(now) / 3600 }, [10, 20, 30])
    }

    func testCreatorsAndClientsSeeTheOtherPerson() {
        let asClient = WidgetSnapshotBuilder.make(bookings: [booking()], userID: me, now: now)
        XCTAssertEqual(asClient.bookings.first?.counterpart, "with Dana Lens")
        let asCreator = WidgetSnapshotBuilder.make(bookings: [booking(creator: me, client: other)], userID: me, now: now)
        XCTAssertEqual(asCreator.bookings.first?.counterpart, "Client: Sam Client")
        let unnamed = WidgetSnapshotBuilder.make(bookings: [booking(creator: me, client: other, clientName: "  ")], userID: me, now: now)
        XCTAssertEqual(unnamed.bookings.first?.counterpart, "Client")
        let own = WidgetSnapshotBuilder.make(bookings: [booking(creator: me, client: me)], userID: me, now: now)
        XCTAssertEqual(own.bookings.first?.counterpart, "Test booking (you)")
    }

    func testTheWidgetCarriesTheTimesInTheShootsOwnZone() throws {
        let snapshot = WidgetSnapshotBuilder.make(bookings: [booking()], userID: me, now: now)
        let first = try XCTUnwrap(snapshot.bookings.first)
        XCTAssertEqual(first.timeZone.identifier, "America/Chicago")
        XCTAssertEqual(first.title, "Portrait session")
    }
}

final class WidgetStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-widget-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func sample() -> WidgetSnapshot {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return WidgetSnapshot(state: .signedIn, bookings: [
            WidgetBooking(id: UUID(), title: "Wedding", counterpart: "with Dana", startAt: start, endAt: start.addingTimeInterval(3600), timeZoneID: "America/Chicago"),
        ])
    }

    func testWhatTheAppWritesTheWidgetReads() throws {
        XCTAssertNil(WidgetStore.read(from: directory), "Nothing written yet")
        let snapshot = sample()
        try WidgetStore.write(snapshot, in: directory)
        XCTAssertEqual(WidgetStore.read(from: directory), snapshot)
        try WidgetStore.write(.signedOut, in: directory)
        XCTAssertEqual(WidgetStore.read(from: directory), .signedOut, "A newer snapshot replaces the older one")
    }

    func testAnUnreadableFileIsTreatedAsNothing() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent(WidgetStore.fileName))
        XCTAssertNil(WidgetStore.read(from: directory))
    }

    func testTheGroupComesFromTheBuildOrFallsBack() {
        XCTAssertTrue(WidgetStore.groupID.hasPrefix("group."))
        XCTAssertFalse(WidgetStore.groupID.hasPrefix("$("), "An unexpanded build setting is never used as the group")
    }
}

final class WidgetFormatTests: XCTestCase {
    private let chicago = TimeZone(identifier: "America/Chicago")!
    private let utc = TimeZone(identifier: "UTC")!

    func testDaysAreCountedInTheShootsZone() {
        // Friday 14:00 in Chicago. A shoot at 21:00 that evening is "today" in Chicago, but already Saturday in UTC.
        let now = TestClock.date(2027, 1, 22, 14, 0)
        let evening = TestClock.date(2027, 1, 22, 21, 0)
        XCTAssertEqual(WidgetFormat.day(of: evening, relativeTo: now, in: chicago), .today)
        XCTAssertEqual(WidgetFormat.day(of: evening, relativeTo: now, in: utc), .tomorrow)
    }

    func testTodayTomorrowAndLater() {
        let now = TestClock.date(2027, 1, 22, 23, 30)
        XCTAssertEqual(WidgetFormat.day(of: TestClock.date(2027, 1, 22, 23, 45), relativeTo: now, in: chicago), .today)
        XCTAssertEqual(WidgetFormat.day(of: TestClock.date(2027, 1, 23, 0, 15), relativeTo: now, in: chicago), .tomorrow, "Fifty minutes later, but another calendar day")
        XCTAssertEqual(WidgetFormat.day(of: TestClock.date(2027, 1, 24, 9, 0), relativeTo: now, in: chicago), .later)
        XCTAssertEqual(WidgetFormat.dayText(of: TestClock.date(2027, 1, 22, 23, 45), relativeTo: now, in: chicago), "Today")
        XCTAssertEqual(WidgetFormat.dayText(of: TestClock.date(2027, 1, 23, 9, 0), relativeTo: now, in: chicago), "Tomorrow")
    }

    func testAShootThatAlreadyStartedCountsAsToday() {
        let now = TestClock.date(2027, 1, 22, 11, 0)
        XCTAssertEqual(WidgetFormat.day(of: TestClock.date(2027, 1, 22, 9, 0), relativeTo: now, in: chicago), .today)
    }

    func testTimesAreShownInTheShootsZone() {
        let ten = TestClock.date(2027, 1, 22, 10, 0)
        XCTAssertTrue(WidgetFormat.timeText(ten, in: chicago).contains("10:00"), WidgetFormat.timeText(ten, in: chicago))
        XCTAssertNotEqual(WidgetFormat.timeText(ten, in: chicago), WidgetFormat.timeText(ten, in: utc))
        let range = WidgetFormat.timeRange(start: ten, end: ten.addingTimeInterval(5400), in: chicago)
        XCTAssertTrue(range.contains(" – "), range)
    }
}

final class WidgetRefreshTests: XCTestCase {
    private let chicago = "America/Chicago"

    private func booking(start: Date, minutes: Double = 60) -> WidgetBooking {
        WidgetBooking(id: UUID(), title: "Shoot", counterpart: "with Dana", startAt: start, endAt: start.addingTimeInterval(minutes * 60), timeZoneID: chicago)
    }

    func testTheWidgetRedrawsWhenABookingFinishesAndAtMidnight() {
        let now = TestClock.date(2027, 1, 22, 20, 0)
        let tomorrow = booking(start: TestClock.date(2027, 1, 23, 10, 0))
        let snapshot = WidgetSnapshot(state: .signedIn, bookings: [tomorrow])
        let dates = snapshot.refreshDates(from: now)
        XCTAssertEqual(dates, [now, TestClock.date(2027, 1, 23, 0, 0), tomorrow.endAt])
    }

    func testFinishedBookingsDropOffAndAreNotScheduled() {
        let now = TestClock.date(2027, 1, 22, 20, 0)
        let finished = booking(start: TestClock.date(2027, 1, 22, 9, 0))
        let snapshot = WidgetSnapshot(state: .signedIn, bookings: [finished])
        XCTAssertEqual(snapshot.refreshDates(from: now), [now])
        XCTAssertTrue(snapshot.upcoming(at: now).isEmpty)
    }

    func testEachMomentShowsWhatIsStillAhead() {
        let now = TestClock.date(2027, 1, 22, 8, 0)
        let first = booking(start: TestClock.date(2027, 1, 22, 10, 0))
        let second = booking(start: TestClock.date(2027, 1, 22, 15, 0))
        let snapshot = WidgetSnapshot(state: .signedIn, bookings: [second, first])
        XCTAssertEqual(snapshot.upcoming(at: now).map(\.id), [first.id, second.id], "Soonest first, whatever order they were written in")
        XCTAssertEqual(snapshot.upcoming(at: first.endAt).map(\.id), [second.id])
        XCTAssertTrue(snapshot.upcoming(at: second.endAt).isEmpty)
    }

    func testASignedOutSnapshotHasOnlyTheCurrentMoment() {
        let now = TestClock.date(2027, 1, 22, 8, 0)
        XCTAssertEqual(WidgetSnapshot.signedOut.refreshDates(from: now), [now])
    }
}

final class SystemWidgetPublisherTests: XCTestCase {
    private var directory: URL!
    private var reloads = 0

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("slate-publisher-\(UUID().uuidString)")
        reloads = 0
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func publisher(directory: URL?) -> SystemWidgetPublisher {
        SystemWidgetPublisher(directory: directory, reload: { [unowned self] in reloads += 1 })
    }

    private func snapshot(_ title: String) -> WidgetSnapshot {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return WidgetSnapshot(state: .signedIn, bookings: [
            WidgetBooking(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, title: title, counterpart: "with Dana", startAt: start, endAt: start.addingTimeInterval(3600), timeZoneID: "UTC"),
        ])
    }

    func testItWritesAndReloadsOnlyWhenSomethingChanged() {
        let publisher = publisher(directory: directory)
        publisher.publish(snapshot("Portrait"))
        XCTAssertEqual(reloads, 1)
        XCTAssertEqual(WidgetStore.read(from: directory), snapshot("Portrait"))

        publisher.publish(snapshot("Portrait"))
        XCTAssertEqual(reloads, 1, "The same picture again redraws nothing")
        publisher.publish(snapshot("Wedding"))
        XCTAssertEqual(reloads, 2)
        publisher.publish(.signedOut)
        XCTAssertEqual(reloads, 3)
        XCTAssertEqual(WidgetStore.read(from: directory), .signedOut)
    }

    func testAfterARestartItKnowsWhatTheWidgetAlreadyHas() throws {
        try WidgetStore.write(snapshot("Portrait"), in: directory)
        publisher(directory: directory).publish(snapshot("Portrait"))
        XCTAssertEqual(reloads, 0, "The file already says this")
    }

    func testWithoutAnAppGroupNothingHappens() {
        publisher(directory: nil).publish(snapshot("Portrait"))
        XCTAssertEqual(reloads, 0)
    }
}

// MARK: - What the app tells the widget

/// Remembers everything the app told the widget, so tests can look.
final class RecordingWidgetPublisher: WidgetPublisher {
    private(set) var snapshots: [WidgetSnapshot] = []
    var last: WidgetSnapshot? { snapshots.last }

    func publish(_ snapshot: WidgetSnapshot) { snapshots.append(snapshot) }
}

// MARK: - Home's "Needs attention"

final class AttentionListTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let me = UUID()
    private let other = UUID()

    private func booking(
        _ status: BookingStatus = .confirmed, creator: UUID? = nil, client: UUID? = nil, startsIn hours: Double = -5,
        deposit: Int = 50_000, hold: Date? = nil, shared: Bool = false, received: Bool = false, name: String = "Portrait session"
    ) -> Booking {
        Booking(
            id: UUID(), creatorID: creator ?? other, clientID: client ?? me, creatorName: "Dana Lens", clientName: "Sam Client",
            packageID: nil, packageName: name, addOns: [],
            startAt: now.addingTimeInterval(hours * 3600), endAt: now.addingTimeInterval(hours * 3600 + 3600),
            blockedUntil: now.addingTimeInterval(hours * 3600 + 5400), timeZoneID: "America/Chicago", currencyCode: "USD",
            totalCents: 200_000, depositCents: deposit, status: status, notes: "", createdAt: now.addingTimeInterval(-86_400 * 7),
            holdExpiresAt: hold,
            deliveredAt: shared ? now.addingTimeInterval(-60) : nil, deliveryURL: shared ? "https://files.example.com/x" : nil,
            receiptConfirmedAt: received ? now.addingTimeInterval(-30) : nil
        )
    }

    private func kinds(_ bookings: [Booking], as user: UUID? = nil) -> [AttentionItem.Kind] {
        AttentionList.make(bookings: bookings, userID: user ?? me, now: now).map(\.kind)
    }

    func testAClientIsAskedToPayAHeldDeposit() {
        XCTAssertEqual(kinds([booking(.held, startsIn: 100, hold: now.addingTimeInterval(600))]), [.payDeposit])
        XCTAssertEqual(kinds([booking(.held, startsIn: 100, hold: now.addingTimeInterval(-1))]), [], "A hold that ran out needs nothing")
    }

    func testAClientIsAskedToConfirmSharedFilesAndThenToPay() {
        XCTAssertEqual(kinds([booking(shared: true)]), [.confirmFiles])
        XCTAssertEqual(kinds([booking(shared: true, received: true)]), [.payBalance])
        XCTAssertEqual(kinds([booking(deposit: 200_000, shared: true, received: true)]), [], "Nothing owed")
        XCTAssertEqual(kinds([booking(.completed, shared: true, received: true)]), [])
    }

    func testACreatorIsAskedToShareFilesOnceTheShootIsOver() {
        let ours = booking(creator: me, client: other)
        XCTAssertEqual(kinds([ours]), [.shareFiles])
        XCTAssertEqual(kinds([booking(creator: me, client: other, shared: true)]), [], "Waiting on the client, nothing to do")
        XCTAssertEqual(kinds([booking(creator: me, client: other, startsIn: 3)]), [], "The shoot hasn't happened")
        XCTAssertEqual(kinds([booking(.cancelled, creator: me, client: other)]), [])
    }

    func testNothingForSomeoneElsesBookings() {
        XCTAssertEqual(kinds([booking(creator: other, client: other)]), [])
    }

    func testDepositsComeFirstThenByDate() {
        let late = booking(shared: true, name: "Late")
        var earlier = booking(shared: true, name: "Early")
        earlier.startAt = now.addingTimeInterval(-50 * 3600)
        earlier.endAt = earlier.startAt.addingTimeInterval(3600)
        let deposit = booking(.held, startsIn: 200, hold: now.addingTimeInterval(300), name: "Held")
        let items = AttentionList.make(bookings: [late, earlier, deposit], userID: me, now: now)
        XCTAssertEqual(items.map(\.kind), [.payDeposit, .confirmFiles, .confirmFiles])
        XCTAssertEqual(items.dropFirst().map(\.detail), ["Early from Dana Lens", "Late from Dana Lens"])
    }

    func testTestingYourOwnPackageGivesBothJobs() {
        let own = booking(creator: me, client: me)
        XCTAssertEqual(Set(kinds([own])), [.shareFiles])
        let shared = booking(creator: me, client: me, shared: true)
        XCTAssertEqual(kinds([shared]), [.confirmFiles])
    }

    func testWordingNamesTheOtherPerson() throws {
        let item = try XCTUnwrap(AttentionList.make(bookings: [booking(creator: me, client: other)], userID: me, now: now).first)
        XCTAssertEqual(item.title, "Share the final files")
        XCTAssertEqual(item.detail, "Portrait session for Sam Client")
        let pay = try XCTUnwrap(AttentionList.make(bookings: [booking(shared: true, received: true)], userID: me, now: now).first)
        XCTAssertEqual(pay.title, "Pay the balance")
        XCTAssertEqual(pay.detail, "$1,500 for Portrait session")
        XCTAssertEqual(Set(AttentionList.make(bookings: [booking(shared: true), booking(shared: true)], userID: me, now: now).map(\.id)).count, 2, "Every item has its own id")
    }
}
