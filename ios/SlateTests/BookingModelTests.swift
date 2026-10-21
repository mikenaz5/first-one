import XCTest
@testable import Slate

/// The booking sheet's behaviour: what is preselected, what happens when add-ons change the
/// length of the shoot, and how it recovers when someone else takes the time first.
@MainActor
final class BookingModelTests: XCTestCase {
    private var root: URL!
    private var backend: LocalBackend!
    private var model: AppModel!
    private var creator: CreatorProfile!
    private var package: ServicePackage!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-booking-\(UUID().uuidString)")
        backend = LocalBackend(root: root)
        model = AppModel(backend: backend)
        try await makeCreator()
        await model.signInAsDemo() // The person who will be booking.
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private func makeCreator(withAvailability: Bool = true) async throws {
        let session = try await backend.signInWithApple(
            AppleCredential(userID: "creator-apple", identityToken: "t", rawNonce: "n", fullName: nil, email: nil)
        )
        creator = try await backend.saveProfile(CreatorProfile(
            id: session.userID, handle: "maya-chen", displayName: "Maya Chen", bio: "", specialties: [.portraits],
            location: nil, avatarURL: nil, createdAt: Date(), updatedAt: Date()
        ), avatarJPEG: nil)
        if withAvailability {
            var settings = AvailabilitySettings.standard(timeZone: TestClock.timeZone)
            settings.bufferMinutes = 30
            _ = try await backend.saveAvailability(settings, for: session.userID)
        }
        let saved = try await backend.savePackage(ServicePackage(
            id: UUID(), creatorID: session.userID, name: "Half day", summary: "", category: nil,
            priceCents: 200_000, currencyCode: "USD", durationMinutes: 120, deliverables: [], turnaroundDays: 14,
            depositCents: 50_000,
            addOns: [AddOn(kind: .extraTime, name: "Extra hour", priceCents: 15_000, extraMinutes: 60)],
            isPublished: true, position: 0, createdAt: Date(), updatedAt: Date()
        ))
        package = saved[0]
    }

    private func loaded() async -> BookingModel {
        let booking = BookingModel(creator: creator, package: package)
        await booking.load(using: model)
        return booking
    }

    func testTheEarliestOpeningIsPreselected() async {
        let booking = await loaded()
        XCTAssertEqual(booking.phase, .ready)
        XCTAssertNotNil(booking.selectedSlot)
        XCTAssertEqual(booking.selectedSlot, booking.days.first?.slots.first)
        XCTAssertEqual(booking.selectedDay, booking.days.first?.day)
    }

    func testSoonestChipsAreOnePerDayAndInOrder() async {
        let booking = await loaded()
        XCTAssertFalse(booking.soonest.isEmpty)
        XCTAssertLessThanOrEqual(booking.soonest.count, 4)
        let days = booking.soonest.map { CalendarDay($0.start, calendar: TestClock.calendar) }
        XCTAssertEqual(Set(days).count, days.count)
        XCTAssertEqual(days, days.sorted())
    }

    func testChoosingADayJumpsToItsFirstTime() async {
        let booking = await loaded()
        let target = booking.days[2]
        booking.selectDay(target.day)
        XCTAssertEqual(booking.selectedSlot, target.slots.first)
        XCTAssertEqual(booking.selectedDay, target.day)
    }

    func testAnExtraHourLengthensTheBookingAndKeepsTheSelectedStart() async {
        let booking = await loaded()
        // The second open day is always a full day, so its first start (9:00) leaves room for the extra hour.
        // (The first open day can be partial, depending on what time the suite happens to run.)
        booking.select(booking.days[1].slots.first!)
        let startBefore = booking.selectedSlot!.start
        let endBefore = booking.selectedSlot!.end
        XCTAssertEqual(booking.summary.durationMinutes, 120)

        booking.toggle(package.addOns[0])
        XCTAssertEqual(booking.summary.durationMinutes, 180)
        XCTAssertEqual(booking.selectedSlot?.start, startBefore, "Still the same start time")
        XCTAssertEqual(booking.selectedSlot?.end, endBefore.addingTimeInterval(3600))
        XCTAssertEqual(booking.summary.totalCents, 215_000)
        XCTAssertNil(booking.notice)

        booking.toggle(package.addOns[0])
        XCTAssertEqual(booking.summary.durationMinutes, 120)
        XCTAssertEqual(booking.summary.totalCents, 200_000)
    }

    func testAnAddOnThatNoLongerFitsMovesTheSelectionAndSaysSo() async {
        let booking = await loaded()
        // The last start of a 2 hour shoot is 15:00 (ends 17:00). With an extra hour it would end at 18:00.
        let lastOfDay = booking.days[0].slots.last!
        booking.select(lastOfDay)
        XCTAssertEqual(CalendarDay(lastOfDay.start, calendar: TestClock.calendar), booking.days[0].day)

        booking.toggle(package.addOns[0])
        XCTAssertNotEqual(booking.selectedSlot?.start, lastOfDay.start)
        XCTAssertNotNil(booking.selectedSlot, "Falls forward to the next opening instead of leaving nothing selected")
        XCTAssertNotNil(booking.notice)
    }

    func testBookingSucceedsAndIsRecorded() async {
        let booking = await loaded()
        let chosen = booking.selectedSlot!
        let ok = await booking.submit(using: model)
        XCTAssertTrue(ok)
        XCTAssertEqual(booking.confirmed?.startAt, chosen.start)
        XCTAssertEqual(booking.confirmed?.totalCents, 200_000)
        XCTAssertEqual(model.bookings.map(\.id), [booking.confirmed!.id])
    }

    func testWhenSomeoneElseTakesTheTimeTheScreenRecovers() async throws {
        let booking = await loaded()
        let contested = booking.selectedSlot!

        // Another client books the very slot this screen is showing.
        _ = try await backend.createBooking(
            BookingRequest(creatorID: creator.id, packageID: package.id, addOnIDs: [], startAt: contested.start, notes: ""),
            clientID: UUID(), clientName: "Someone else"
        )

        let ok = await booking.submit(using: model)
        XCTAssertFalse(ok)
        XCTAssertNil(booking.confirmed)
        XCTAssertEqual(booking.notice, SlateError.slotTaken.errorDescription)
        XCTAssertNotNil(booking.selectedSlot, "A fresh opening is preselected")
        XCTAssertNotEqual(booking.selectedSlot?.start, contested.start)
        XCTAssertGreaterThan(booking.selectedSlot!.start, contested.start)
        XCTAssertEqual(booking.phase, .ready, "No flash back to a loading state")
        XCTAssertFalse(booking.days.flatMap(\.slots).contains { $0.start == contested.start })
    }

    func testACreatorWithNoHoursShowsAnEmptyState() async throws {
        let other = try await backend.signInWithApple(
            AppleCredential(userID: "second-creator", identityToken: "t", rawNonce: "n", fullName: nil, email: nil)
        )
        let profile = try await backend.saveProfile(CreatorProfile(
            id: other.userID, handle: "no-hours", displayName: "No Hours", bio: "", specialties: [.events],
            location: nil, avatarURL: nil, createdAt: Date(), updatedAt: Date()
        ), avatarJPEG: nil)
        let booking = BookingModel(creator: profile, package: package)
        await booking.load(using: model)
        XCTAssertEqual(booking.phase, .noAvailability)
        XCTAssertNil(booking.selectedSlot)
        let ok = await booking.submit(using: model)
        XCTAssertFalse(ok, "Nothing to book")
    }

    func testBookingYourOwnPackageIsAllowedOnDeviceSoTheFlowCanBeTried() {
        XCTAssertTrue(backend.allowsSelfBooking)
        XCTAssertTrue(model.canBook(creatorID: model.session!.userID))
        XCTAssertTrue(model.canBook(creatorID: UUID()))
    }

    func testCancellingFromTheAppFreesTheSlot() async {
        let booking = await loaded()
        let slot = booking.selectedSlot!
        await booking.submit(using: model)
        let made = booking.confirmed!

        await model.cancel(made)
        XCTAssertEqual(model.bookings.first { $0.id == made.id }?.status, .cancelled)

        let again = await loaded()
        XCTAssertTrue(again.days.flatMap(\.slots).contains { $0.start == slot.start }, "The time is offered again")
    }
}
