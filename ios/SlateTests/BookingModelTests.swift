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
    private var template: ContractTemplate!

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
            id: session.userID, handle: "dana-lens", displayName: "Dana Lens", bio: "", specialties: [.portraits],
            location: nil, avatarURL: nil, createdAt: Date(), updatedAt: Date()
        ), avatarJPEG: nil)
        if withAvailability {
            var settings = AvailabilitySettings.standard(timeZone: TestClock.timeZone)
            settings.bufferMinutes = 30
            _ = try await backend.saveAvailability(settings, for: session.userID)
        }
        template = try await ContractFixtures.equip(backend, creatorID: session.userID)
        let saved = try await backend.savePackage(ServicePackage(
            id: UUID(), creatorID: session.userID, name: "Half day", summary: "", category: nil,
            priceCents: 200_000, currencyCode: "USD", durationMinutes: 120, deliverables: [], turnaroundDays: 14,
            depositCents: 50_000,
            addOns: [AddOn(kind: .extraTime, name: "Extra hour", priceCents: 15_000, extraMinutes: 60)],
            isPublished: true, position: 0, createdAt: Date(), updatedAt: Date(),
            contractTemplateID: template.id
        ))
        package = saved[0]
    }

    private func loaded() async -> BookingModel {
        let booking = BookingModel(creator: creator, package: package, signerName: "Sam Client")
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

        let contract = booking.signedContract
        XCTAssertEqual(contract?.status, .executed)
        XCTAssertEqual(contract?.bookingID, booking.confirmed?.id)
        XCTAssertEqual(contract?.signature(for: .client)?.signedName, "Sam Client")
        XCTAssertEqual(contract?.signature(for: .creator)?.method, .onFile)
        XCTAssertEqual(contract?.documentHash, booking.contractPreview?.documentHash, "They signed what they were shown")
    }

    func testTheContractIsFilledInForTheChosenTimeAndAddOns() async {
        let booking = await loaded()
        booking.toggle(package.addOns[0])
        XCTAssertNil(booking.contractPreview, "Changing a choice clears the contract that was shown")
        await booking.loadContract(using: model)

        let text = booking.contractPreview?.contract.text ?? ""
        XCTAssertEqual(booking.contractPhase, .ready)
        XCTAssertNotEqual(model.clientDisplayName, "Client", "The demo person has a name")
        XCTAssertTrue(text.contains(model.clientDisplayName), "The client, from their account")
        XCTAssertTrue(text.contains("Dana Lens"), "The creator")
        XCTAssertTrue(text.contains("Half day"))
        XCTAssertTrue(text.contains("$2,150"), "Package plus the extra hour")
        XCTAssertTrue(text.contains("Extra hour"))
        XCTAssertFalse(text.contains("{{"), "Every placeholder was filled in")
    }

    func testChangingAChoiceAfterReadingMeansReadingAgain() async {
        let booking = await loaded()
        await booking.loadContract(using: model)
        let first = booking.contractPreview?.documentHash
        XCTAssertNotNil(first)

        booking.select(booking.days[1].slots.first!)
        XCTAssertNil(booking.contractPreview)
        XCTAssertEqual(booking.contractPhase, .idle)
        XCTAssertNotNil(booking.signBlocker)

        await booking.loadContract(using: model)
        XCTAssertNotEqual(booking.contractPreview?.documentHash, first, "A different day is a different contract")
        XCTAssertNil(booking.signBlocker)
    }

    func testSigningNeedsANameAndInkIfDrawing() async {
        let booking = await loaded()
        await booking.loadContract(using: model)
        XCTAssertNil(booking.signBlocker)

        booking.capture.fullName = "S"
        XCTAssertEqual(booking.signBlocker, "Add your full name to sign.")
        let refused = await booking.submit(using: model)
        XCTAssertFalse(refused)
        XCTAssertNil(booking.confirmed)

        booking.capture.fullName = "Sam Client"
        booking.capture.method = .drawn
        XCTAssertEqual(booking.signBlocker, "Draw your signature to continue.")
        booking.capture.method = .typed
        XCTAssertNil(booking.signBlocker)
    }

    func testIfTheWordingChangesAfterReadingTheyAreShownTheNewVersionAndNothingIsBooked() async throws {
        let booking = await loaded()
        await booking.loadContract(using: model)
        let shown = booking.contractPreview!.documentHash

        // The creator edits the contract while the client is reading it.
        var edited = template!
        edited.clauses.append(ContractClause(title: "Parking", body: "The Client arranges parking. Cancellation: {{cancellation_policy}}"))
        _ = try await backend.saveContractTemplate(edited)

        let ok = await booking.submit(using: model)
        XCTAssertFalse(ok)
        XCTAssertNil(booking.confirmed)
        XCTAssertEqual(booking.notice, SlateError.contractChanged.errorDescription)
        XCTAssertNotEqual(booking.contractPreview?.documentHash, shown, "The new wording is on screen to read")
        XCTAssertTrue(booking.contractPreview?.contract.text.contains("Parking") == true)
        let stored = try await backend.loadBookings(for: creator.id)
        XCTAssertTrue(stored.isEmpty)

        let again = await booking.submit(using: model)
        XCTAssertTrue(again, "Signing the version they were shown now works")
    }

    func testWhenSomeoneElseTakesTheTimeTheScreenRecovers() async throws {
        let booking = await loaded()
        let contested = booking.selectedSlot!

        // Another client books the very slot this screen is showing.
        _ = try await ContractFixtures.signedBooking(
            backend,
            BookingRequest(creatorID: creator.id, packageID: package.id, addOnIDs: [], startAt: contested.start, notes: ""),
            name: "Someone Else"
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
