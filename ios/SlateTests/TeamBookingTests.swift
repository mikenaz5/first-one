import XCTest
@testable import Slate

/// Booking a company: who gets the work, nobody in two places, contracts in the company's name, and what each role may
/// see and do with a booking. `company_rules.py` checks the same rules in Postgres.
final class TeamBookingTests: TeamTestCase {
    // MARK: Automatic assignment

    func testAutomaticAssignmentSharesTheWorkAndNeverDoubleBooksAPerson() async throws {
        let c = try await makeCompany()
        let first = try await book(c, at: wednesday(10))
        XCTAssertEqual(first.booking.creatorID, c.org.id, "The company owns it")
        XCTAssertEqual(first.booking.assignedTo, c.theo, "Both are free and idle; Theo joined first")
        XCTAssertFalse(first.booking.requestedMember)

        let second = try await book(c, at: wednesday(10))
        XCTAssertEqual(second.booking.assignedTo, c.jun, "Theo is busy then")
        await expectError(.slotTaken) { try await book(c, at: wednesday(10)) }
        await expectError(.slotTaken) { try await book(c, at: wednesday(11)) }

        let third = try await book(c, at: wednesday(14))
        XCTAssertEqual(third.booking.assignedTo, c.theo, "One booking each, so Theo again")
        let fourth = try await book(c, at: wednesday(16))
        XCTAssertEqual(fourth.booking.assignedTo, c.jun, "Theo has two, Jun has one")
    }

    func testAHeldBookingKeepsItsTimeAndAnExpiredOneFreesIt() async throws {
        let c = try await makeCompany()
        let held = try await book(c, at: wednesday(10), pay: false)
        XCTAssertEqual(held.booking.status, .held)
        XCTAssertEqual(held.booking.assignedTo, c.theo)
        let other = try await book(c, at: wednesday(10), pay: false)
        XCTAssertEqual(other.booking.assignedTo, c.jun)
        await expectError(.slotTaken) { try await book(c, at: wednesday(10), pay: false) }

        clock.advance(by: Double(PaymentRules.holdMinutes + 1) * 60)
        let again = try await book(c, at: wednesday(10))
        XCTAssertEqual(again.booking.assignedTo, c.theo, "The unpaid holds ran out")
    }

    func testCompaniesNeedASignerBeforeTheyCanBeBooked() async throws {
        let c = try await makeCompany(designateSigner: false)
        await expectError(.creatorNotReady) { try await book(c, at: wednesday(10)) }
    }

    func testAClosedCompanySellsNothing() async throws {
        let c = try await makeCompany()
        try await backend.closeOrganization(c.org.id, by: c.owner)
        await expectError(.packageUnavailable) { try await book(c, at: wednesday(10)) }
    }

    // MARK: Manual assignment

    func testManualCompaniesHoldABookingForAManager() async throws {
        let c = try await makeCompany(mode: .manual)
        let a = try await book(c, at: wednesday(10))
        XCTAssertNil(a.booking.assignedTo)
        XCTAssertTrue(a.booking.isWaitingForAssignment)
        let b = try await book(c, at: wednesday(10))
        XCTAssertNil(b.booking.assignedTo)
        // Two people are free and two bookings are waiting, so there is no room for a third.
        await expectError(.slotTaken) { try await book(c, at: wednesday(10)) }

        let queue = try await backend.loadAssignmentQueue(organizationID: c.org.id, for: c.manager)
        XCTAssertEqual(Set(queue.map(\.id)), [a.booking.id, b.booking.id])
        await expectError(.notAllowed) { try await backend.loadAssignmentQueue(organizationID: c.org.id, for: c.theo) }

        let options = try await backend.loadAssignmentOptions(bookingID: a.booking.id, for: c.manager)
        XCTAssertEqual(options.map(\.displayName), ["Jun", "Theo"], "Only people who can take bookings, free first")
        XCTAssertTrue(options.allSatisfy(\.isFree))

        let assigned = try await backend.assignBooking(a.booking.id, to: c.theo, by: c.manager)
        XCTAssertEqual(assigned.assignedTo, c.theo)
        XCTAssertEqual(assigned.assignedAt, clock.now.roundedDownToSecond)

        let after = try await backend.loadAssignmentOptions(bookingID: b.booking.id, for: c.manager)
        XCTAssertEqual(after.first?.displayName, "Jun", "Free people come first")
        let theo = try XCTUnwrap(after.first { $0.userID == c.theo })
        XCTAssertFalse(theo.isFree)
        XCTAssertEqual(theo.reason, "Already booked")

        await expectError(.slotTaken) { try await backend.assignBooking(b.booking.id, to: c.theo, by: c.manager) }
        await expectError(.invalidAssignee) { try await backend.assignBooking(b.booking.id, to: c.viewer, by: c.manager) }
        await expectError(.invalidAssignee) { try await backend.assignBooking(b.booking.id, to: UUID(), by: c.manager) }
        await expectError(.notAllowed) { try await backend.assignBooking(b.booking.id, to: c.jun, by: c.theo) }
        _ = try await backend.assignBooking(b.booking.id, to: c.jun, by: c.owner)
        let empty = try await backend.loadAssignmentQueue(organizationID: c.org.id, for: c.manager)
        XCTAssertTrue(empty.isEmpty)
    }

    func testABookingCanBeMovedToSomeoneElse() async throws {
        let c = try await makeCompany()
        let booked = try await book(c, at: wednesday(14))
        XCTAssertEqual(booked.booking.assignedTo, c.theo)
        let moved = try await backend.assignBooking(booked.booking.id, to: c.jun, by: c.manager)
        XCTAssertEqual(moved.assignedTo, c.jun)
        // Theo is free again then.
        let next = try await book(c, at: wednesday(14))
        XCTAssertEqual(next.booking.assignedTo, c.theo)
        let same = try await backend.assignBooking(booked.booking.id, to: c.jun, by: c.manager)
        XCTAssertEqual(same.assignedTo, c.jun, "Assigning to the same person changes nothing")

        let log = try await activity(c)
        XCTAssertTrue(log.contains { $0.action == "booking.reassigned" && $0.summary == "Moved Brand film from Theo to Jun" })
    }

    func testABookingThatIsOverOrCancelledCannotBeAssigned() async throws {
        let c = try await makeCompany(mode: .manual)
        let a = try await book(c, at: wednesday(10))
        _ = try await backend.cancelBooking(a.booking.id, by: c.manager)
        await expectError(.notAssignable) { try await backend.assignBooking(a.booking.id, to: c.theo, by: c.manager) }
        let queue = try await backend.loadAssignmentQueue(organizationID: c.org.id, for: c.manager)
        XCTAssertTrue(queue.isEmpty)
    }

    // MARK: Booking a person

    func testClientsCanBookAPersonByName() async throws {
        let c = try await makeCompany(mode: .manual)
        let named = try await book(c, at: wednesday(10), member: c.jun)
        XCTAssertEqual(named.booking.assignedTo, c.jun, "A named booking is assigned at once, whatever the mode")
        XCTAssertTrue(named.booking.requestedMember)
        await expectError(.slotTaken) { try await book(c, at: wednesday(10), member: c.jun) }
        await expectError(.memberUnavailable) { try await book(c, at: wednesday(10), member: c.viewer) }
        await expectError(.memberUnavailable) { try await book(c, at: wednesday(10), member: UUID()) }

        // Theo is still free then, and the queue doesn't stand in the way of booking him by name.
        let waiting = try await book(c, at: wednesday(10))
        XCTAssertNil(waiting.booking.assignedTo)
        let theo = try await book(c, at: wednesday(10), member: c.theo)
        XCTAssertEqual(theo.booking.assignedTo, c.theo)
    }

    // MARK: Hours and shared services

    func testAPersonsOwnHoursNarrowTheCompanys() async throws {
        let c = try await makeCompany()
        try await backend.actAs(c.jun)
        let afternoons = (2...6).map { DayHours(weekday: $0, window: TimeWindow(startMinute: 13 * 60, endMinute: 17 * 60)) }
        try await backend.saveMyHours(afternoons, organizationID: c.org.id, by: c.jun)
        let mine = try await backend.loadOrganization(c.org.id, for: c.jun)
        XCTAssertEqual(mine.myHours, afternoons)

        let morning = try await book(c, at: wednesday(10))
        XCTAssertEqual(morning.booking.assignedTo, c.theo, "Jun isn't working then")
        await expectError(.slotTaken) { try await book(c, at: wednesday(10)) }
        await expectError(.slotUnavailable) { try await book(c, at: wednesday(10), member: c.jun) }
        let afternoon = try await book(c, at: wednesday(14), member: c.jun)
        XCTAssertEqual(afternoon.booking.assignedTo, c.jun)

        // Clearing them goes back to the company's.
        try await backend.saveMyHours(nil, organizationID: c.org.id, by: c.jun)
        let early = try await book(c, at: wednesday(10), member: c.jun)
        XCTAssertEqual(early.booking.assignedTo, c.jun)
    }

    func testOwnHoursAreCheckedAndCannotWidenTheCompanys() async throws {
        let c = try await makeCompany()
        let backwards = [DayHours(weekday: 2, window: TimeWindow(startMinute: 700, endMinute: 600))]
        await expectError(.invalidInput) { try await backend.saveMyHours(backwards, organizationID: c.org.id, by: c.jun) }
        let twice = [
            DayHours(weekday: 2, window: TimeWindow(startMinute: 540, endMinute: 600)),
            DayHours(weekday: 2, window: TimeWindow(startMinute: 660, endMinute: 720)),
        ]
        await expectError(.invalidInput) { try await backend.saveMyHours(twice, organizationID: c.org.id, by: c.jun) }
        await expectError(.notAllowed) { try await backend.saveMyHours(nil, organizationID: c.org.id, by: c.viewer) }

        // A wider day than the company's is allowed to be saved, and means nothing outside the company's hours.
        let wide = (2...6).map { DayHours(weekday: $0, window: TimeWindow(startMinute: 6 * 60, endMinute: 22 * 60)) }
        try await backend.saveMyHours(wide, organizationID: c.org.id, by: c.jun)
        await expectError(.slotUnavailable) { try await book(c, at: wednesday(8), member: c.jun) }
        let ok = try await book(c, at: wednesday(9), member: c.jun)
        XCTAssertEqual(ok.booking.assignedTo, c.jun)
    }

    func testAServiceCanBeOfferedByChosenPeople() async throws {
        let c = try await makeCompany()
        await expectError(.notAllowed) { try await backend.setPackageMembers([c.theo], packageID: c.package.id, by: c.theo) }
        await expectError(.invalidAssignee) { try await backend.setPackageMembers([c.viewer], packageID: c.package.id, by: c.owner) }
        try await backend.setPackageMembers([c.theo, c.theo], packageID: c.package.id, by: c.admin)
        let offered = try await backend.loadPackageMembers(packageID: c.package.id)
        XCTAssertEqual(offered, [c.theo])

        let first = try await book(c, at: wednesday(10))
        XCTAssertEqual(first.booking.assignedTo, c.theo)
        await expectError(.slotTaken) { try await book(c, at: wednesday(10)) }
        await expectError(.memberUnavailable) { try await book(c, at: wednesday(14), member: c.jun) }

        try await backend.setPackageMembers([], packageID: c.package.id, by: c.owner)
        let everyone = try await backend.loadPackageMembers(packageID: c.package.id)
        XCTAssertTrue(everyone.isEmpty)
        let second = try await book(c, at: wednesday(10))
        XCTAssertEqual(second.booking.assignedTo, c.jun)
    }

    func testRemovingSomeoneTakesThemOffTheServicesAndReturnsTheirBookings() async throws {
        let c = try await makeCompany()
        try await backend.setPackageMembers([c.theo, c.jun], packageID: c.package.id, by: c.owner)
        let booked = try await book(c, at: wednesday(10))
        XCTAssertEqual(booked.booking.assignedTo, c.theo)

        try await backend.removeMember(memberID: c.theo, organizationID: c.org.id, by: c.owner)
        let offered = try await backend.loadPackageMembers(packageID: c.package.id)
        XCTAssertEqual(offered, [c.jun])
        let queue = try await backend.loadAssignmentQueue(organizationID: c.org.id, for: c.owner)
        XCTAssertEqual(queue.map(\.id), [booked.booking.id])
        let gone = try await backend.loadBookings(for: c.theo)
        XCTAssertTrue(gone.isEmpty, "They no longer see the company's bookings")
    }

    // MARK: Nobody in two places

    private func personalPage(for person: UUID) async throws -> ServicePackage {
        try await backend.actAs(person)
        try await backend.saveCreatorSignature(ContractFixtures.creatorSignature(name: "Theo Okafor"), for: person)
        let template = StarterTemplates.make(.videography, creatorID: person)
        _ = try await backend.saveContractTemplate(template)
        var settings = AvailabilitySettings.standard(timeZone: TestClock.timeZone)
        settings.bufferMinutes = 30
        _ = try await backend.saveAvailability(settings, for: person)
        let saved = try await backend.savePackage(ServicePackage(
            id: UUID(), creatorID: person, name: "Portrait session", summary: "", category: .portraits,
            priceCents: 30_000, currencyCode: "USD", durationMinutes: 60, deliverables: ["30 photos"],
            turnaroundDays: 7, depositCents: 10_000, addOns: [], isPublished: true, position: 0,
            createdAt: Date(), updatedAt: Date(), contractTemplateID: template.id
        ))
        return saved[0]
    }

    func testAPersonsOwnBookingsAndTheCompanysAreOneCalendar() async throws {
        let c = try await makeCompany()
        let personal = try await personalPage(for: c.theo)

        // A booking on Theo's own page at ten...
        let own = try await ContractFixtures.signedBooking(
            backend, BookingRequest(creatorID: c.theo, packageID: personal.id, addOnIDs: [], startAt: wednesday(10), notes: ""),
            name: "Sam Client"
        )
        XCTAssertEqual(own.booking.assignedTo, c.theo, "A person's own booking is theirs")
        // ...takes him out of the company's ten o'clock.
        let company = try await book(c, at: wednesday(10))
        XCTAssertEqual(company.booking.assignedTo, c.jun)
        await expectError(.slotTaken) { try await book(c, at: wednesday(10), member: c.theo) }

        // And the other way round.
        let afternoon = try await book(c, at: wednesday(14), member: c.theo)
        XCTAssertEqual(afternoon.booking.assignedTo, c.theo)
        await expectError(.slotTaken) {
            try await ContractFixtures.signedBooking(
                backend, BookingRequest(creatorID: c.theo, packageID: personal.id, addOnIDs: [], startAt: wednesday(14), notes: ""),
                name: "Sam Client"
            )
        }

        // The company's calendar shows Theo's own booking only as busy time.
        try await backend.actAs(c.owner)
        let calendar = try await backend.loadTeamCalendar(
            organizationID: c.org.id, from: TestClock.date(2027, 1, 6), to: TestClock.date(2027, 1, 7), members: [c.theo], for: c.owner
        )
        let row = try XCTUnwrap(calendar.members.first)
        XCTAssertTrue(row.busy.contains { $0.kind == .personal && $0.range.start == wednesday(10) })
        XCTAssertEqual(row.bookings.count, 1, "Only the company's booking is listed with details")
    }

    // MARK: Contracts

    func testTheContractIsInTheCompanysNameAndCountersignedByTheSigner() async throws {
        let c = try await makeCompany()
        let signed = try await book(c, at: wednesday(10))
        let contract = signed.contract
        XCTAssertEqual(contract.status, .executed)
        XCTAssertEqual(contract.creatorID, c.org.id)
        XCTAssertEqual(contract.providerLegalName, "Northlight Films LLC")
        XCTAssertEqual(contract.countersignerID, c.owner)
        XCTAssertEqual(contract.countersignerName, "Dana Lens")
        XCTAssertEqual(contract.countersignerTitle, "Owner")
        XCTAssertTrue(contract.sections.contains { $0.body.contains("Northlight Films LLC") }, "The text names the company")

        let provider = try XCTUnwrap(contract.signature(for: .creator))
        XCTAssertEqual(provider.userID, c.owner)
        XCTAssertEqual(provider.signedName, "Dana Lens")
        XCTAssertEqual(provider.onBehalfOf, "Northlight Films LLC")
        XCTAssertEqual(provider.signerTitle, "Owner")
        XCTAssertEqual(provider.method, .onFile)
        XCTAssertEqual(signed.booking.creatorName, "Northlight Films", "The booking carries the company's public name")
    }

    func testAContractKeepsTheSignerItWasMadeWith() async throws {
        let c = try await makeCompany()
        let before = try await book(c, at: wednesday(10))

        try await backend.actAs(c.admin)
        try await backend.saveCreatorSignature(ContractFixtures.creatorSignature(name: "Marcus Bell"), for: c.admin)
        _ = try await backend.designateSigner(userID: c.admin, title: "Producer", organizationID: c.org.id, by: c.owner)
        let after = try await book(c, at: wednesday(14))
        XCTAssertEqual(after.contract.countersignerName, "Marcus Bell")
        XCTAssertEqual(after.contract.countersignerTitle, "Producer")

        let unchanged = try await backend.loadContract(bookingID: before.booking.id, for: before.booking.clientID ?? UUID())
        XCTAssertEqual(unchanged?.countersignerName, "Dana Lens")
        XCTAssertEqual(unchanged?.providerLegalName, "Northlight Films LLC")
    }

    func testChoosingASigner() async throws {
        let c = try await makeCompany(designateSigner: false)
        await expectError(.signerRoleNotAllowed) { try await backend.designateSigner(userID: c.manager, title: "", organizationID: c.org.id, by: c.owner) }
        await expectError(.signerRoleNotAllowed) { try await backend.designateSigner(userID: c.theo, title: "", organizationID: c.org.id, by: c.owner) }
        await expectError(.signatureRequired) { try await backend.designateSigner(userID: c.admin, title: "", organizationID: c.org.id, by: c.owner) }
        await expectError(.notFound) { try await backend.designateSigner(userID: UUID(), title: "", organizationID: c.org.id, by: c.owner) }
        await expectError(.notAllowed) { try await backend.designateSigner(userID: c.owner, title: "", organizationID: c.org.id, by: c.manager) }

        try await backend.saveCreatorSignature(ContractFixtures.creatorSignature(name: "Dana Lens"), for: c.owner)
        await expectError(.invalidInput) {
            try await backend.designateSigner(userID: c.owner, title: String(repeating: "x", count: 81), organizationID: c.org.id, by: c.owner)
        }
        let org = try await backend.designateSigner(userID: c.owner, title: " Owner ", organizationID: c.org.id, by: c.owner)
        XCTAssertEqual(org.signerUserID, c.owner)
        XCTAssertEqual(org.signerTitle, "Owner")

        // Widening who may sign lets a Manager be named.
        try await backend.actAs(c.manager)
        try await backend.saveCreatorSignature(ContractFixtures.creatorSignature(name: "Noor Haddad"), for: c.manager)
        _ = try await backend.updateOrganization(c.org.id, with: OrganizationUpdate(signerRoles: [.owner, .admin, .manager]), by: c.owner)
        let named = try await backend.designateSigner(userID: c.manager, title: "Studio manager", organizationID: c.org.id, by: c.admin)
        XCTAssertEqual(named.signerUserID, c.manager)
    }

    func testAutoCountersigningStopsWhenTheSignerCanNoLongerSign() async throws {
        let c = try await makeCompany()
        _ = try await book(c, at: wednesday(10))
        // The Owner hands over, then leaves the signing roles by being demoted to a Creator.
        try await backend.transferOwnership(organizationID: c.org.id, to: c.admin, by: c.owner)
        try await backend.setMemberRole(.creator, memberID: c.owner, organizationID: c.org.id, by: c.admin)

        let org = try await backend.loadOrganization(c.org.id, for: c.admin)
        XCTAssertNil(org.signerUserID)
        await expectError(.creatorNotReady) { try await book(c, at: wednesday(14)) }
        let log = try await activity(c, as: c.admin)
        XCTAssertTrue(log.contains { $0.action == "signer.cleared" })
    }

    func testRemovingTheSignerStopsCountersigning() async throws {
        let c = try await makeCompany()
        try await backend.actAs(c.admin)
        try await backend.saveCreatorSignature(ContractFixtures.creatorSignature(name: "Marcus Bell"), for: c.admin)
        _ = try await backend.designateSigner(userID: c.admin, title: "Producer", organizationID: c.org.id, by: c.owner)
        try await backend.removeMember(memberID: c.admin, organizationID: c.org.id, by: c.owner)
        await expectError(.creatorNotReady) { try await book(c, at: wednesday(10)) }
    }

    // MARK: Who sees and does what

    func testEachRoleSeesTheBookingsItShould() async throws {
        let c = try await makeCompany()
        let signed = try await book(c, at: wednesday(10))
        let id = signed.booking.id

        for sees in [c.owner, c.admin, c.manager, c.viewer, c.theo] {
            let list = try await backend.loadBookings(for: sees)
            XCTAssertEqual(list.map(\.id), [id], "\(sees) should see it")
        }
        let jun = try await backend.loadBookings(for: c.jun)
        XCTAssertTrue(jun.isEmpty, "Another Creator sees only their own")

        for opens in [c.owner, c.manager, c.viewer, c.theo] {
            let contract = try await backend.loadContract(bookingID: id, for: opens)
            XCTAssertNotNil(contract)
            let payments = try await backend.loadPayments(for: opens)
            XCTAssertFalse(payments.isEmpty)
        }
        let hidden = try await backend.loadContract(bookingID: id, for: c.jun)
        XCTAssertNil(hidden)
        let noPayments = try await backend.loadPayments(for: c.jun)
        XCTAssertTrue(noPayments.isEmpty)
    }

    func testOnlyThoseWhoManageABookingCanCancelIt() async throws {
        let c = try await makeCompany()
        let a = try await book(c, at: wednesday(10))
        let b = try await book(c, at: wednesday(14))
        await expectError(.notCancellable) { try await backend.cancelBooking(a.booking.id, by: c.jun) }
        await expectError(.notCancellable) { try await backend.cancelBooking(a.booking.id, by: c.viewer) }
        await expectError(.notCancellable) { try await backend.cancelBooking(a.booking.id, by: UUID()) }

        let byManager = try await backend.cancelBooking(a.booking.id, by: c.manager)
        XCTAssertEqual(byManager.booking.cancelledByID, c.manager)
        XCTAssertEqual(byManager.refundCents, 50_000, "When the company cancels, the client gets everything back")

        // The person it is assigned to may cancel too.
        let assigned = try XCTUnwrap(b.booking.assignedTo)
        let byAssignee = try await backend.cancelBooking(b.booking.id, by: assigned)
        XCTAssertEqual(byAssignee.booking.status, .cancelled)

        let log = try await activity(c)
        XCTAssertTrue(log.contains { $0.action == "booking.cancelled" && $0.summary == "Cancelled Brand film for Alex Rivera" })
    }

    func testMessagesAreForThePeopleWhoManageTheBooking() async throws {
        let c = try await makeCompany()
        let signed = try await book(c, at: wednesday(10))
        let id = signed.booking.id
        let assignee = try XCTUnwrap(signed.booking.assignedTo)
        let other = assignee == c.theo ? c.jun : c.theo

        let sent = try await backend.sendMessage("On my way", bookingID: id, clientMessageID: UUID(), from: assignee)
        XCTAssertEqual(sent.body, "On my way")
        _ = try await backend.sendMessage("Noted", bookingID: id, clientMessageID: UUID(), from: c.manager)
        await expectError(.bookingNotFound) { try await backend.sendMessage("Hi", bookingID: id, clientMessageID: UUID(), from: other) }
        await expectError(.bookingNotFound) { try await backend.sendMessage("Hi", bookingID: id, clientMessageID: UUID(), from: c.viewer) }

        let viewerReads = try await backend.loadMessages(bookingID: id, since: nil, for: c.viewer)
        XCTAssertFalse(viewerReads.isEmpty, "A Viewer can read")
        let otherReads = try await backend.loadMessages(bookingID: id, since: nil, for: other)
        XCTAssertTrue(otherReads.isEmpty)
        let conversations = try await backend.loadConversations(for: c.manager)
        XCTAssertEqual(conversations.map(\.bookingID), [id])
    }

    func testTheAssignedPersonDeliversTheFiles() async throws {
        let c = try await makeCompany()
        let client = UUID()
        let signed = try await book(c, at: wednesday(10), client: client)
        let id = signed.booking.id
        let assignee = try XCTUnwrap(signed.booking.assignedTo)
        let other = assignee == c.theo ? c.jun : c.theo
        clock.set(wednesday(11))

        await expectError(.bookingNotFound) { try await backend.shareDelivery(bookingID: id, link: "https://example.com/files", note: "", by: other) }
        await expectError(.bookingNotFound) { try await backend.shareDelivery(bookingID: id, link: "https://example.com/files", note: "", by: c.viewer) }
        let shared = try await backend.shareDelivery(bookingID: id, link: "https://example.com/files", note: "", by: assignee)
        XCTAssertNotNil(shared.deliveredAt)
        let confirmed = try await backend.confirmReceipt(bookingID: id, by: client)
        XCTAssertNotNil(confirmed.receiptConfirmedAt)

        let log = try await activity(c)
        XCTAssertTrue(log.contains { $0.action == "booking.delivered" })
        XCTAssertTrue(log.contains { $0.action == "booking.created" && $0.summary.hasPrefix("New booking: Brand film for Alex Rivera, with ") })
        XCTAssertTrue(log.contains { $0.action == "contract.executed" && $0.summary.hasSuffix("countersigned by Dana Lens (Owner)") })
    }

    func testAManagerCanDeliverAnyBooking() async throws {
        let c = try await makeCompany()
        let client = UUID()
        let signed = try await book(c, at: wednesday(10), client: client)
        clock.set(wednesday(11))
        let shared = try await backend.shareDelivery(bookingID: signed.booking.id, link: "https://example.com/files", note: "", by: c.manager)
        XCTAssertNotNil(shared.deliveredAt)
    }

    // MARK: What clients see

    func testTheCompanysPageListsItsServicesAndThePeopleToBook() async throws {
        let c = try await makeCompany()
        try await backend.updateMember(MemberUpdate(title: "Lead videographer"), memberID: c.theo, organizationID: c.org.id, by: c.owner)
        try await backend.updateMember(MemberUpdate(listed: false), memberID: c.jun, organizationID: c.org.id, by: c.owner)

        let loaded = try await backend.loadPublicPage(handle: "northlight")
        let page = try XCTUnwrap(loaded)
        XCTAssertEqual(page.profile.kind, .company)
        XCTAssertEqual(page.profile.displayName, "Northlight Films")
        XCTAssertEqual(page.packages.map(\.name), ["Brand film"])
        XCTAssertEqual(page.team.map(\.displayName), ["Theo"], "Only listed people who take bookings")
        XCTAssertEqual(page.team.first?.title, "Lead videographer")

        let personal = try await backend.loadPublicPage(handle: "theo")
        let person = try XCTUnwrap(personal)
        XCTAssertEqual(person.profile.kind, .person)
        XCTAssertTrue(person.team.isEmpty)
    }

    func testAClientSeesEveryonesFreeTimeAsOne() async throws {
        let c = try await makeCompany()
        let from = TestClock.date(2027, 1, 4)
        let to = TestClock.date(2027, 1, 11)
        let day = CalendarDay(year: 2027, month: 1, day: 6)

        let open = try await backend.loadTeamSchedule(packageID: c.package.id, memberID: nil, from: from, to: to)
        XCTAssertEqual(open.members.map(\.displayName), ["Theo", "Jun"])
        XCTAssertEqual(open.assignmentMode, .auto)
        let morning = AvailabilityEngine.slots(on: day, durationMinutes: 60, schedule: open.asSchedule, now: clock.now)
        XCTAssertEqual(TestClock.hours(morning).first, 9)

        _ = try await book(c, at: wednesday(10))
        _ = try await book(c, at: wednesday(10))
        let busy = try await backend.loadTeamSchedule(packageID: c.package.id, memberID: nil, from: from, to: to)
        let slots = AvailabilityEngine.slots(on: day, durationMinutes: 60, schedule: busy.asSchedule, now: clock.now)
        XCTAssertEqual(TestClock.hours(slots).first, 11.5, "Both are busy until 11:30, buffer included")

        let justJun = try await backend.loadTeamSchedule(packageID: c.package.id, memberID: c.jun, from: from, to: to)
        XCTAssertEqual(justJun.members.map(\.displayName), ["Jun"])
        await expectError(.packageUnavailable) { try await backend.loadTeamSchedule(packageID: UUID(), memberID: nil, from: from, to: to) }
    }

    // MARK: The team calendar

    func testTheTeamCalendarShowsEveryoneAndHidesWhatARoleMayNotOpen() async throws {
        let c = try await makeCompany()
        _ = try await book(c, at: wednesday(10))
        let second = try await book(c, at: wednesday(10))
        XCTAssertEqual(second.booking.assignedTo, c.jun)
        let from = TestClock.date(2027, 1, 6)
        let to = TestClock.date(2027, 1, 7)

        let owner = try await backend.loadTeamCalendar(organizationID: c.org.id, from: from, to: to, members: [], for: c.owner)
        XCTAssertEqual(owner.members.map(\.displayName), ["Dana", "Marcus", "Noor", "Jun", "Theo"], "A Viewer takes no bookings, so has no row")
        XCTAssertEqual(owner.timeZoneID, TestClock.timeZone.identifier)
        let theo = try XCTUnwrap(owner.members.first { $0.userID == c.theo })
        XCTAssertEqual(theo.bookings.map(\.packageName), ["Brand film"])
        XCTAssertEqual(theo.bookings.first?.clientName, "Alex Rivera")
        XCTAssertNotNil(theo.bookings.first?.bookingID)
        XCTAssertEqual(theo.weekly.count, 5, "Monday to Friday")
        let dana = try XCTUnwrap(owner.members.first { $0.userID == c.owner })
        XCTAssertTrue(dana.weekly.isEmpty, "Someone who takes no bookings has no hours to show")

        // A Creator sees that someone else is busy, not with what.
        let asJun = try await backend.loadTeamCalendar(organizationID: c.org.id, from: from, to: to, members: [], for: c.jun)
        let theoForJun = try XCTUnwrap(asJun.members.first { $0.userID == c.theo })
        XCTAssertEqual(theoForJun.bookings.count, 1)
        XCTAssertNil(theoForJun.bookings.first?.bookingID)
        XCTAssertNil(theoForJun.bookings.first?.packageName)
        XCTAssertNil(theoForJun.bookings.first?.clientName)
        let junForJun = try XCTUnwrap(asJun.members.first { $0.userID == c.jun })
        XCTAssertNotNil(junForJun.bookings.first?.clientName, "Their own is open to them")

        // A Viewer can read everything.
        let asViewer = try await backend.loadTeamCalendar(organizationID: c.org.id, from: from, to: to, members: [], for: c.viewer)
        XCTAssertEqual(asViewer.members.first { $0.userID == c.theo }?.bookings.first?.clientName, "Alex Rivera")

        // Filters keep the rest in order.
        let onlyTheo = try await backend.loadTeamCalendar(organizationID: c.org.id, from: from, to: to, members: [c.theo], for: c.owner)
        XCTAssertEqual(onlyTheo.members.map(\.displayName), ["Theo"])

        let stranger = try await person("Zoe")
        await expectError(.notFound) { try await backend.loadTeamCalendar(organizationID: c.org.id, from: from, to: to, members: [], for: stranger) }
    }

    func testTheCalendarShowsBookingsWaitingAndOutsideBusyTime() async throws {
        let c = try await makeCompany(mode: .manual)
        _ = try await book(c, at: wednesday(10))
        try await backend.replaceBusyBlocks([DateInterval(start: wednesday(12), end: wednesday(13))], for: c.theo)
        let calendar = try await backend.loadTeamCalendar(
            organizationID: c.org.id, from: TestClock.date(2027, 1, 6), to: TestClock.date(2027, 1, 7), members: [], for: c.manager
        )
        XCTAssertEqual(calendar.unassigned.count, 1)
        XCTAssertEqual(calendar.unassigned.first?.startAt, wednesday(10))
        let theo = try XCTUnwrap(calendar.members.first { $0.userID == c.theo })
        XCTAssertEqual(theo.busy.map(\.kind), [.external])
        XCTAssertEqual(theo.busy.first?.range, DateInterval(start: wednesday(12), end: wednesday(13)))
    }

    // MARK: Upgrading and going back

    private func solo() async throws -> (id: UUID, package: ServicePackage) {
        let mara = try await person("Mara")
        let template = try await ContractFixtures.equip(backend, creatorID: mara, kind: .videography)
        var settings = AvailabilitySettings.standard(timeZone: TestClock.timeZone)
        settings.bufferMinutes = 30
        _ = try await backend.saveAvailability(settings, for: mara)
        let saved = try await backend.savePackage(ServicePackage(
            id: UUID(), creatorID: mara, name: "Brand film", summary: "", category: .corporate,
            priceCents: 200_000, currencyCode: "USD", durationMinutes: 60, deliverables: ["A film"],
            turnaroundDays: 14, depositCents: 50_000, addOns: [], isPublished: true, position: 0,
            createdAt: Date(), updatedAt: Date(), contractTemplateID: template.id
        ))
        return (mara, saved[0])
    }

    func testUpgradingMovesServicesAndLeavesSignedWorkWhereItIs() async throws {
        let (mara, package) = try await solo()
        let earlier = try await ContractFixtures.signedBooking(
            backend, BookingRequest(creatorID: mara, packageID: package.id, addOnIDs: [], startAt: wednesday(10), notes: ""), name: "Sam Client"
        )

        let draft = OrganizationDraft(name: "Mara Studio", handle: "mara-studio", legalName: "Mara Studio LLC")
        let org = try await backend.upgradeToCompany(draft, by: mara)
        XCTAssertEqual(org.myRole, .owner)
        XCTAssertEqual(org.specialties, [.weddings], "The company starts with their specialties")

        let moved = try await backend.loadPackages(for: org.id)
        XCTAssertEqual(moved.map(\.name), ["Brand film"])
        XCTAssertEqual(moved.first?.creatorID, org.id)
        let left = try await backend.loadPackages(for: mara)
        XCTAssertTrue(left.isEmpty)
        let templates = try await backend.loadContractTemplates(for: org.id)
        XCTAssertEqual(templates.count, 1)
        XCTAssertEqual(templates.first?.creatorID, org.id)
        let hours = try await backend.loadAvailability(for: org.id)
        XCTAssertNotNil(hours, "The company starts with their hours")
        let kept = try await backend.loadAvailability(for: mara)
        XCTAssertNotNil(kept)

        // The booking and its contract stay in the person's name.
        let bookings = try await backend.loadBookings(for: mara)
        XCTAssertEqual(bookings.map(\.id), [earlier.booking.id])
        XCTAssertEqual(bookings.first?.creatorID, mara)
        let contract = try await backend.loadContract(bookingID: earlier.booking.id, for: mara)
        XCTAssertEqual(contract?.creatorID, mara)
        XCTAssertNil(contract?.providerLegalName)

        let profile = try await backend.loadProfile(for: mara)
        XCTAssertEqual(profile?.kind, .person)
        let log = try await backend.loadActivity(organizationID: org.id, limit: 10, before: nil, for: mara)
        XCTAssertTrue(log.contains { $0.summary == "Upgraded from an individual account: moved 1 service and 1 contract template" })

        // The company can sell once someone is named to sign, and the new owner is its only bookable person.
        _ = try await backend.designateSigner(userID: mara, title: "Owner", organizationID: org.id, by: mara)
        let companyBooking = try await ContractFixtures.signedBooking(
            backend, BookingRequest(creatorID: org.id, packageID: package.id, addOnIDs: [], startAt: wednesday(14), notes: ""), name: "Alex Rivera"
        )
        XCTAssertEqual(companyBooking.booking.assignedTo, mara)
        XCTAssertEqual(companyBooking.contract.providerLegalName, "Mara Studio LLC")
    }

    func testUpgradingNeedsAProfileAndNoBookingMidHold() async throws {
        let session = try await backend.signInWithApple(credential("apple-nobody"))
        let draft = OrganizationDraft(name: "No Profile Co", handle: "no-profile", legalName: "No Profile Co LLC")
        await expectError(.profileRequired) { try await backend.upgradeToCompany(draft, by: session.userID) }

        let (mara, package) = try await solo()
        let held = try await ContractFixtures.signedBooking(
            backend, BookingRequest(creatorID: mara, packageID: package.id, addOnIDs: [], startAt: wednesday(10), notes: ""),
            name: "Sam Client", pay: false
        )
        XCTAssertEqual(held.booking.status, .held)
        let marasDraft = OrganizationDraft(name: "Mara Studio", handle: "mara-studio", legalName: "Mara Studio LLC")
        await expectError(.bookingsInHold) { try await backend.upgradeToCompany(marasDraft, by: mara) }
        _ = try await ContractFixtures.payDeposit(backend, held)
        _ = try await backend.upgradeToCompany(marasDraft, by: mara)
    }

    func testGoingBackToAnIndividualAccount() async throws {
        let (mara, package) = try await solo()
        let org = try await backend.upgradeToCompany(OrganizationDraft(name: "Mara Studio", handle: "mara-studio", legalName: "Mara Studio LLC"), by: mara)
        _ = try await backend.designateSigner(userID: mara, title: "", organizationID: org.id, by: mara)
        let booked = try await ContractFixtures.signedBooking(
            backend, BookingRequest(creatorID: org.id, packageID: package.id, addOnIDs: [], startAt: wednesday(10), notes: ""), name: "Alex Rivera"
        )
        await expectError(.hasUpcomingBookings) { try await backend.downgradeToIndividual(organizationID: org.id, by: mara) }

        // With a teammate, the Owner can't go back until they are alone.
        let teammate = try await backend.createInvite(role: .creator, email: nil, organizationID: org.id, by: mara)
        _ = try await backend.completeSimulatedJoin(inviteID: teammate.invite.id, displayName: "Theo Okafor")
        _ = try await backend.cancelBooking(booked.booking.id, by: mara)
        await expectError(.teamNotEmpty) { try await backend.downgradeToIndividual(organizationID: org.id, by: mara) }

        let members = try await backend.loadMembers(organizationID: org.id, for: mara)
        let theo = try XCTUnwrap(members.first { $0.role == .creator })
        try await backend.removeMember(memberID: theo.userID, organizationID: org.id, by: mara)
        try await backend.downgradeToIndividual(organizationID: org.id, by: mara)

        let back = try await backend.loadPackages(for: mara)
        XCTAssertEqual(back.map(\.name), ["Brand film"])
        XCTAssertEqual(back.first?.creatorID, mara)
        let accounts = try await backend.loadAccounts(for: mara)
        XCTAssertTrue(accounts.companies.isEmpty)
        XCTAssertTrue(accounts.hasPersonalProfile)
    }

    // MARK: On a device with one person

    func testATeammateCanBeSimulatedWhenThereIsNoSecondPhone() async throws {
        let owner = try await person("Dana")
        let org = try await backend.createOrganization(OrganizationDraft(name: "Small Co", handle: "small-co", legalName: "Small Co LLC"), by: owner)
        let invite = try await backend.createInvite(role: .creator, email: nil, organizationID: org.id, by: owner)
        let teammate = try await backend.completeSimulatedJoin(inviteID: invite.invite.id, displayName: "Theo Okafor")

        let members = try await backend.loadMembers(organizationID: org.id, for: owner)
        XCTAssertEqual(members.first { $0.userID == teammate }?.displayName, "Theo Okafor")
        XCTAssertEqual(members.first { $0.userID == teammate }?.handle, "theo-okafor")
        let accounts = try await backend.loadAccounts(for: teammate)
        XCTAssertEqual(accounts.companies.first?.role, .creator)
        await expectError(.inviteInvalid) { try await backend.completeSimulatedJoin(inviteID: invite.invite.id, displayName: "Again") }

        try await backend.actAs(teammate)
        let session = await backend.restoreSession()
        XCTAssertEqual(session?.userID, teammate)
    }
}

private extension Date {
    /// Stored dates are whole seconds.
    var roundedDownToSecond: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}
