import XCTest
@testable import Slate

/// Packages, availability and bookings against the on-device backend.
final class SchedulingBackendTests: XCTestCase {
    private var root: URL!
    private var backend: LocalBackend!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-sched-\(UUID().uuidString)")
        backend = LocalBackend(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: Helpers

    private let cal = TestClock.calendar

    /// A weekday at least three days from now, so the 24 hour notice rule never interferes.
    private func openDay(minDaysAhead: Int = 3) -> CalendarDay {
        var day = CalendarDay(Date(), calendar: cal).adding(days: minDaysAhead, in: cal)
        while !(2...6).contains(day.weekday(in: cal)) { day = day.adding(days: 1, in: cal) }
        return day
    }

    private func at(_ day: CalendarDay, _ hour: Int, _ minute: Int = 0) -> Date {
        day.date(atMinute: hour * 60 + minute, in: cal)!
    }

    private func credential(_ id: String) -> AppleCredential {
        AppleCredential(userID: id, identityToken: "t", rawNonce: "n", fullName: nil, email: nil)
    }

    /// Each creator's contract, so every package built for them can be sold.
    private var contracts: [UUID: UUID] = [:]

    private func package(for creatorID: UUID, name: String = "Portrait session", duration: Int = 60, published: Bool = true) -> ServicePackage {
        ServicePackage(
            id: UUID(), creatorID: creatorID, name: name, summary: "", category: .portraits,
            priceCents: 200_000, currencyCode: "USD", durationMinutes: duration,
            deliverables: ["30 edited photos"], turnaroundDays: 7, depositCents: 50_000,
            addOns: [
                AddOn(kind: .extraTime, name: "Extra hour", priceCents: 15_000, extraMinutes: 60),
                AddOn(kind: .drone, name: "Drone", priceCents: 25_000),
            ],
            isPublished: published, position: 0, createdAt: Date(), updatedAt: Date(),
            contractTemplateID: contracts[creatorID]
        )
    }

    struct Creator {
        var id: UUID
        var package: ServicePackage
    }

    private func makeCreator(
        handle: String = "maya-chen", buffer: Int = 30, duration: Int = 60, withAvailability: Bool = true
    ) async throws -> Creator {
        let session = try await backend.signInWithApple(credential("apple-\(handle)"))
        _ = try await backend.saveProfile(CreatorProfile(
            id: session.userID, handle: handle, displayName: "Maya Chen", bio: "", specialties: [.portraits],
            location: nil, avatarURL: nil, createdAt: Date(), updatedAt: Date()
        ), avatarJPEG: nil)

        if withAvailability {
            var settings = AvailabilitySettings.standard(timeZone: TestClock.timeZone)
            settings.bufferMinutes = buffer
            _ = try await backend.saveAvailability(settings, for: session.userID)
        }
        contracts[session.userID] = try await ContractFixtures.equip(backend, creatorID: session.userID).id
        let saved = try await backend.savePackage(package(for: session.userID, duration: duration))
        return Creator(id: session.userID, package: saved[0])
    }

    private func request(_ creator: Creator, at start: Date, addOns: [UUID] = []) -> BookingRequest {
        BookingRequest(creatorID: creator.id, packageID: creator.package.id, addOnIDs: addOns, startAt: start, notes: "")
    }

    /// Reads the contract and signs it, as a client would.
    private func book(_ creator: Creator, at start: Date, addOns: [UUID] = [], client: UUID = UUID()) async throws -> Booking {
        try await ContractFixtures.signedBooking(
            backend, request(creator, at: start, addOns: addOns), clientID: client, name: "Client"
        ).booking
    }

    private func expectError<T>(_ expected: SlateError, file: StaticString = #filePath, line: UInt = #line, _ work: () async throws -> T) async {
        do {
            _ = try await work()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SlateError, expected, file: file, line: line)
        }
    }

    // MARK: Packages

    func testSavedPackagesKeepTheirOrderAndPositions() async throws {
        let creator = try await makeCreator()
        _ = try await backend.savePackage(package(for: creator.id, name: "Second"))
        let list = try await backend.savePackage(package(for: creator.id, name: "Third"))
        XCTAssertEqual(list.map(\.name), ["Portrait session", "Second", "Third"])
        XCTAssertEqual(list.map(\.position), [0, 1, 2])
    }

    func testEditingAPackageKeepsItsPlaceAndCreationDate() async throws {
        let creator = try await makeCreator()
        _ = try await backend.savePackage(package(for: creator.id, name: "Second"))
        var edited = creator.package
        edited.priceCents = 250_000
        edited.createdAt = Date(timeIntervalSince1970: 0) // The backend must ignore this.
        let list = try await backend.savePackage(edited)
        XCTAssertEqual(list.map(\.name), ["Portrait session", "Second"])
        XCTAssertEqual(list[0].priceCents, 250_000)
        XCTAssertEqual(list[0].createdAt, creator.package.createdAt)
    }

    func testInvalidPackagesAreRejected() async throws {
        let creator = try await makeCreator()
        var bad = package(for: creator.id)
        bad.priceCents = 0
        await expectError(.invalidPackage) { try await backend.savePackage(bad) }
        var tooLong = package(for: creator.id)
        tooLong.durationMinutes = 7
        await expectError(.invalidPackage) { try await backend.savePackage(tooLong) }
    }

    func testDeletingRepacksPositions() async throws {
        let creator = try await makeCreator()
        let second = try await backend.savePackage(package(for: creator.id, name: "Second"))
        _ = try await backend.savePackage(package(for: creator.id, name: "Third"))
        let list = try await backend.deletePackage(second[1].id, for: creator.id)
        XCTAssertEqual(list.map(\.name), ["Portrait session", "Third"])
        XCTAssertEqual(list.map(\.position), [0, 1])
    }

    // MARK: Availability

    func testAvailabilityRoundTripsAndValidates() async throws {
        let creator = try await makeCreator(withAvailability: false)
        let before = try await backend.loadAvailability(for: creator.id)
        XCTAssertNil(before, "Nothing is assumed until the creator sets it")

        var settings = AvailabilitySettings.standard(timeZone: TestClock.timeZone)
        settings.blackouts = [BlackoutRange(start: openDay(), end: openDay(minDaysAhead: 5), reason: "Trip")]
        _ = try await backend.saveAvailability(settings, for: creator.id)
        let after = try await backend.loadAvailability(for: creator.id)
        XCTAssertEqual(after, settings)

        settings.slotIntervalMinutes = 7
        await expectError(.invalidAvailability) { try await backend.saveAvailability(settings, for: creator.id) }
    }

    func testCreatorWithoutHoursOffersNothing() async throws {
        let creator = try await makeCreator(withAvailability: false)
        let schedule = try await backend.loadSchedule(for: creator.id, from: Date(), to: Date().addingTimeInterval(86_400 * 30))
        XCTAssertFalse(schedule.settings.hasOpenDay)
        await expectError(.slotUnavailable) { try await book(creator, at: at(openDay(), 10)) }
    }

    // MARK: Public page

    func testPublicPageShowsOnlyPublishedPackages() async throws {
        let creator = try await makeCreator()
        _ = try await backend.savePackage(package(for: creator.id, name: "Draft", published: false))
        let page = try await backend.loadPublicPage(handle: "maya-chen")
        XCTAssertEqual(page?.packages.map(\.name), ["Portrait session"])
        let own = try await backend.loadPackages(for: creator.id)
        XCTAssertEqual(own.count, 2, "The creator still sees their drafts")
    }

    func testUnknownHandlesAndIncompleteProfilesHaveNoPage() async throws {
        _ = try await makeCreator()
        let missing = try await backend.loadPublicPage(handle: "nobody")
        XCTAssertNil(missing)

        let other = try await backend.signInWithApple(credential("apple-incomplete"))
        _ = try await backend.saveProfile(CreatorProfile(
            id: other.userID, handle: "half-done", displayName: "Half", bio: "", specialties: [],
            location: nil, avatarURL: nil, createdAt: Date(), updatedAt: Date()
        ), avatarJPEG: nil)
        let incomplete = try await backend.loadPublicPage(handle: "half-done")
        XCTAssertNil(incomplete)
    }

    // MARK: Booking basics

    func testPriceAndDurationComeFromThePackageNotTheClient() async throws {
        let creator = try await makeCreator(buffer: 30)
        let extra = creator.package.addOns[0].id, drone = creator.package.addOns[1].id
        let day = openDay()
        let booking = try await book(creator, at: at(day, 10), addOns: [extra, drone])

        XCTAssertEqual(booking.totalCents, 200_000 + 15_000 + 25_000)
        XCTAssertEqual(booking.depositCents, 50_000)
        XCTAssertEqual(booking.status, .confirmed)
        XCTAssertEqual(booking.endAt.timeIntervalSince(booking.startAt), 7200, "60 min + the 60 min extra-hour add-on")
        XCTAssertEqual(booking.blockedUntil.timeIntervalSince(booking.endAt), 1800, "30 min buffer")
        XCTAssertEqual(booking.packageName, "Portrait session")
        XCTAssertEqual(booking.creatorName, "Maya Chen")
        XCTAssertEqual(booking.addOns.map(\.name).sorted(), ["Drone", "Extra hour"])
        XCTAssertEqual(booking.timeZoneID, "America/Chicago")
    }

    func testBothPartiesSeeTheBookingAndStrangersDoNot() async throws {
        let creator = try await makeCreator()
        let client = UUID()
        let booking = try await book(creator, at: at(openDay(), 10), client: client)
        let forCreator = try await backend.loadBookings(for: creator.id)
        let forClient = try await backend.loadBookings(for: client)
        let forStranger = try await backend.loadBookings(for: UUID())
        XCTAssertEqual(forCreator.map(\.id), [booking.id])
        XCTAssertEqual(forClient.map(\.id), [booking.id])
        XCTAssertTrue(forStranger.isEmpty)
    }

    func testHiddenPackagesAndUnknownAddOnsCannotBeBooked() async throws {
        let creator = try await makeCreator()
        let draft = try await backend.savePackage(package(for: creator.id, name: "Draft", published: false))
        let hidden = draft.first { $0.name == "Draft" }!
        let day = openDay()
        await expectError(.packageUnavailable) {
            try await ContractFixtures.signedBooking(
                backend,
                BookingRequest(creatorID: creator.id, packageID: hidden.id, addOnIDs: [], startAt: at(day, 10), notes: "")
            )
        }
        await expectError(.packageUnavailable) { try await book(creator, at: at(day, 10), addOns: [UUID()]) }
    }

    // MARK: No double booking

    func testSameSlotCannotBeBookedTwice() async throws {
        let creator = try await makeCreator()
        let day = openDay()
        _ = try await book(creator, at: at(day, 10))
        await expectError(.slotTaken) { try await book(creator, at: at(day, 10)) }
    }

    func testOverlapsAndTheBufferAreRefusedButBackToBackAfterTheBufferIsAllowed() async throws {
        let creator = try await makeCreator(buffer: 30)
        let day = openDay()
        _ = try await book(creator, at: at(day, 10)) // Occupies 10:00-11:00 plus buffer to 11:30.

        await expectError(.slotTaken) { try await book(creator, at: at(day, 10, 30)) }
        await expectError(.slotTaken) { try await book(creator, at: at(day, 11)) }
        await expectError(.slotTaken) { try await book(creator, at: at(day, 9)) }   // would run into 10:00
        await expectError(.slotUnavailable) { try await book(creator, at: at(day, 8, 30)) } // before opening, not "taken"
        let backToBack = try await book(creator, at: at(day, 11, 30))             // starts exactly as the buffer ends
        XCTAssertEqual(backToBack.status, .confirmed)
    }

    func testDifferentDaysAreIndependent() async throws {
        let creator = try await makeCreator()
        let day = openDay()
        _ = try await book(creator, at: at(day, 10))
        _ = try await book(creator, at: at(day.adding(days: 7, in: cal), 10))
    }

    func testTwoCreatorsDoNotBlockEachOther() async throws {
        let maya = try await makeCreator(handle: "maya-chen")
        let dan = try await makeCreator(handle: "dan-lee")
        let day = openDay()
        _ = try await book(maya, at: at(day, 10))
        _ = try await book(dan, at: at(day, 10))
    }

    func testManyClientsRacingForOneSlotProduceExactlyOneBooking() async throws {
        let creator = try await makeCreator()
        let day = openDay()
        let backend = self.backend!
        // Half ask for 10:00 and half for 10:30. Those overlap, so there can still only be one winner.
        let outcomes = await withTaskGroup(of: Result<Booking, Error>.self) { group in
            for index in 0..<24 {
                let start = self.at(day, 10, index.isMultiple(of: 2) ? 0 : 30)
                let request = self.request(creator, at: start)
                group.addTask {
                    do {
                        let signed = try await ContractFixtures.signedBooking(backend, request, name: "Client \(index)")
                        return .success(signed.booking)
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var all: [Result<Booking, Error>] = []
            for await outcome in group { all.append(outcome) }
            return all
        }

        let wins = outcomes.compactMap { try? $0.get() }
        let losses = outcomes.compactMap { outcome -> SlateError? in
            if case .failure(let error) = outcome { return error as? SlateError }
            return nil
        }
        XCTAssertEqual(wins.count, 1)
        XCTAssertEqual(losses.count, 23)
        XCTAssertTrue(losses.allSatisfy { $0 == .slotTaken }, "\(losses)")
        let stored = try await backend.loadBookings(for: creator.id)
        XCTAssertEqual(stored.count, 1)
    }

    func testCancellingFreesTheTimeForSomeoneElse() async throws {
        let creator = try await makeCreator()
        let client = UUID()
        let day = openDay()
        let first = try await book(creator, at: at(day, 10), client: client)
        await expectError(.slotTaken) { try await book(creator, at: at(day, 10)) }

        let cancelled = try await backend.cancelBooking(first.id, by: client)
        XCTAssertEqual(cancelled.booking.status, .cancelled)
        let second = try await book(creator, at: at(day, 10))
        XCTAssertEqual(second.status, .confirmed)
    }

    func testOnlyThePartiesCanCancelAndOnlyOnce() async throws {
        let creator = try await makeCreator()
        let client = UUID()
        let booking = try await book(creator, at: at(openDay(), 10), client: client)

        await expectError(.notCancellable) { try await backend.cancelBooking(booking.id, by: UUID()) }
        _ = try await backend.cancelBooking(booking.id, by: creator.id)
        await expectError(.notCancellable) { try await backend.cancelBooking(booking.id, by: client) }
    }

    // MARK: Availability rules at booking time

    func testBookingsOutsideOpeningRulesAreRefused() async throws {
        let creator = try await makeCreator()
        let day = openDay()
        await expectError(.slotUnavailable) { try await book(creator, at: at(day, 7)) }          // before opening
        await expectError(.slotUnavailable) { try await book(creator, at: at(day, 16, 30)) }     // runs past closing
        await expectError(.slotUnavailable) { try await book(creator, at: at(day, 10, 15)) }     // off the grid
        let weekend = day.adding(days: (7 - day.weekday(in: cal)), in: cal) // the Saturday after
        await expectError(.slotUnavailable) { try await book(creator, at: at(weekend, 10)) }
        let yesterday = CalendarDay(Date(), calendar: cal).adding(days: -1, in: cal)
        await expectError(.slotUnavailable) { try await book(creator, at: at(yesterday, 10)) }
        _ = try await book(creator, at: at(day, 16)) // ends exactly at closing
    }

    func testAnExtraHourAddOnCannotPushPastClosing() async throws {
        let creator = try await makeCreator()
        let day = openDay()
        let extra = creator.package.addOns[0].id
        await expectError(.slotUnavailable) { try await book(creator, at: at(day, 16), addOns: [extra]) }
        _ = try await book(creator, at: at(day, 15), addOns: [extra]) // 15:00 + 2 hours = 17:00
    }

    func testBlackoutDatesAreRefused() async throws {
        let creator = try await makeCreator()
        let day = openDay()
        var settings = AvailabilitySettings.standard(timeZone: TestClock.timeZone)
        settings.blackouts = [BlackoutRange(start: day, end: day)]
        _ = try await backend.saveAvailability(settings, for: creator.id)
        await expectError(.slotUnavailable) { try await book(creator, at: at(day, 10)) }
        _ = try await book(creator, at: at(day.adding(days: 7, in: cal), 10))
    }

    func testMinimumNoticeIsEnforced() async throws {
        let creator = try await makeCreator()
        var settings = AvailabilitySettings.standard(timeZone: TestClock.timeZone)
        settings.minNoticeHours = 168 // A week
        _ = try await backend.saveAvailability(settings, for: creator.id)
        await expectError(.slotUnavailable) { try await book(creator, at: at(openDay(minDaysAhead: 3), 10)) }
        _ = try await book(creator, at: at(openDay(minDaysAhead: 9), 10))
    }

    func testImportedCalendarBusyTimeBlocksBookings() async throws {
        let creator = try await makeCreator(buffer: 30)
        let day = openDay()
        try await backend.replaceBusyBlocks([DateInterval(start: at(day, 10), end: at(day, 11))], for: creator.id)

        await expectError(.slotUnavailable) { try await book(creator, at: at(day, 10)) }
        await expectError(.slotUnavailable) { try await book(creator, at: at(day, 11)) } // inside the buffer after the event
        _ = try await book(creator, at: at(day, 11, 30))

        try await backend.replaceBusyBlocks([], for: creator.id)
        _ = try await book(creator, at: at(day, 10)) // freed
    }

    // MARK: What clients can see

    func testScheduleExposesBlockedRangesButNoDetails() async throws {
        let creator = try await makeCreator(buffer: 30)
        let day = openDay()
        let booking = try await book(creator, at: at(day, 10))
        var schedule = try await backend.loadSchedule(for: creator.id, from: at(day, 0), to: at(day, 23))
        XCTAssertEqual(schedule.bookedRanges, [booking.blockedRange])
        XCTAssertTrue(schedule.externalBusy.isEmpty)

        _ = try await backend.cancelBooking(booking.id, by: creator.id)
        schedule = try await backend.loadSchedule(for: creator.id, from: at(day, 0), to: at(day, 23))
        XCTAssertTrue(schedule.bookedRanges.isEmpty, "Cancelled bookings no longer block time")
    }

    func testEngineAndBackendAgreeOnWhatIsBookable() async throws {
        let creator = try await makeCreator(buffer: 30)
        let day = openDay()
        _ = try await book(creator, at: at(day, 10))

        let schedule = try await backend.loadSchedule(for: creator.id, from: Date(), to: Date().addingTimeInterval(86_400 * 30))
        let offered = AvailabilityEngine.slots(on: day, durationMinutes: 60, schedule: schedule, now: Date())
        XCTAssertFalse(offered.isEmpty)
        // Times the screen offers must be accepted. (Only the first and last, which can't touch each
        // other: booking one changes what the next would see.)
        for slot in [offered.first!, offered.last!] {
            let ok = try await book(creator, at: slot.start)
            XCTAssertEqual(ok.startAt, slot.start)
        }
        // ...and a time it doesn't offer must be refused.
        await expectError(.slotTaken) { try await book(creator, at: at(day, 10)) }
    }
}
