import XCTest
@testable import Slate

/// What each role sees and can do from the app, on a company with the whole team: Dana the Owner, Marcus an Admin, Noor a
/// Manager, Theo and Jun Creators, Ben a Viewer.
@MainActor
final class TeamRolesFlowTests: TeamTestCase {
    private var model: AppModel!

    /// Signs the person in on a fresh app and opens the company.
    private func open(as name: String, in company: Company) async throws {
        model = AppModel(backend: backend)
        let clock = self.clock
        model.clock = { clock.now }
        await model.signIn(with: credential("apple-\(name.lowercased())"))
        XCTAssertNotNil(model.session, "Signing in failed: \(model.alert?.message ?? "no message")")
        await model.switchAccount(to: .company(company.org.id))
        XCTAssertEqual(model.activeAccount, .company(company.org.id), "The company didn't open for \(name)")
    }

    func testAViewerSeesEverythingAndChangesNothing() async throws {
        let company = try await makeCompany()
        _ = try await book(company, at: wednesday(10))
        _ = try await book(company, at: wednesday(10))

        try await open(as: "Ben", in: company)

        XCTAssertEqual(model.myRole, .viewer)
        XCTAssertEqual(model.visibleBookings.count, 2, "A viewer reads every booking")
        let booking = try XCTUnwrap(model.visibleBookings.first)
        XCTAssertFalse(model.canManage(booking))
        XCTAssertFalse(model.canAssign(booking))
        XCTAssertFalse(model.can(.servicesManage))
        XCTAssertFalse(model.can(.teamInvite))
        XCTAssertTrue(model.can(.calendarViewTeam))
        XCTAssertFalse(model.teamMembers.isEmpty, "The team is visible")
        XCTAssertTrue(model.teamInvites.isEmpty)
        XCTAssertTrue(model.assignmentQueue.isEmpty)
    }

    func testACreatorSeesAndRunsOnlyTheirOwnBookings() async throws {
        let company = try await makeCompany()
        _ = try await book(company, at: wednesday(10))
        _ = try await book(company, at: wednesday(10))

        try await open(as: "Theo", in: company)

        XCTAssertEqual(model.myRole, .creator)
        XCTAssertEqual(model.visibleBookings.count, 1, "The other booking is Jun's")
        let mine = try XCTUnwrap(model.visibleBookings.first)
        XCTAssertEqual(mine.assignedTo, company.theo)
        XCTAssertTrue(model.isMine(mine))
        XCTAssertTrue(model.canManage(mine))
        XCTAssertFalse(model.canAssign(mine))
        XCTAssertEqual(model.assigneeName(for: mine), "You")

        // The job is the company's, and it is also Theo's own.
        await model.switchAccount(to: .personal)
        XCTAssertEqual(model.visibleBookings.map(\.id), [mine.id])
        XCTAssertTrue(model.isMine(mine))
    }

    func testAManagerGivesAWaitingBookingToSomeone() async throws {
        let company = try await makeCompany(mode: .manual)
        let waiting = try await book(company, at: wednesday(10)).booking
        XCTAssertNil(waiting.assignedTo, "A manager hasn't chosen yet")

        try await open(as: "Noor", in: company)

        XCTAssertEqual(model.myRole, .manager)
        XCTAssertEqual(model.assignmentQueue.map(\.id), [waiting.id])
        XCTAssertEqual(model.unassignedCount, 1)
        let queued = try XCTUnwrap(model.assignmentQueue.first)
        XCTAssertTrue(model.canAssign(queued))

        let options = try await model.assignmentOptions(for: queued)
        XCTAssertEqual(Set(options.filter(\.isFree).map(\.displayName)), ["Theo", "Jun"], "Only the two who take bookings can be chosen")

        try await model.assign(queued, to: company.jun)

        XCTAssertTrue(model.assignmentQueue.isEmpty)
        let given = try XCTUnwrap(model.booking(withID: waiting.id))
        XCTAssertEqual(given.assignedTo, company.jun)
        XCTAssertEqual(model.assigneeName(for: given), "Jun")
    }

    func testACreatorCannotAssignOrInvite() async throws {
        let company = try await makeCompany(mode: .manual)
        _ = try await book(company, at: wednesday(10))
        try await open(as: "Theo", in: company)

        await expectError(.notAllowed) { try await model.createInvite(role: .viewer, email: nil) }
        await expectError(.notAllowed) { try await model.updateCompany(OrganizationUpdate(legalName: "Other Films LLC")) }
        XCTAssertTrue(model.assignmentQueue.isEmpty, "The queue is for people who can assign")
    }

    func testTheOwnerSeesTheSeatsAndTheActivity() async throws {
        let company = try await makeCompany()
        try await open(as: "Dana", in: company)

        XCTAssertEqual(model.myRole, .owner)
        XCTAssertTrue(model.can(.billingManage))
        XCTAssertTrue(model.can(.payoutsSplit))
        XCTAssertEqual(model.organization?.seats.used, 6)
        let overview = try await model.loadBilling()
        XCTAssertEqual(overview.seats.used, 6)
        let activity = try await model.loadActivity()
        XCTAssertFalse(activity.isEmpty)
        XCTAssertTrue(activity.contains { $0.action == "org.created" })
    }

    func testTheOfferedByListNarrowsWhoCanTakeAService() async throws {
        let company = try await makeCompany()
        try await open(as: "Dana", in: company)
        let service = try XCTUnwrap(model.packages.first)
        XCTAssertEqual(Set(model.offeredBy(service).map(\.displayName)), ["Theo", "Jun"], "Everyone who takes bookings, until it's narrowed")

        try await model.setPackageMembers([company.theo], for: service)

        XCTAssertEqual(model.offeredBy(service).map(\.displayName), ["Theo"])
        // And a client's booking can then go only to Theo.
        let first = try await book(company, at: wednesday(10)).booking
        XCTAssertEqual(first.assignedTo, company.theo)
        // Nobody else offers it, so the same time can't be booked twice.
        do {
            _ = try await book(company, at: wednesday(10))
            XCTFail("Only Theo offers it, and he is booked then")
        } catch {
            let slate = error as? SlateError
            XCTAssertTrue(slate == .slotTaken || slate == .slotUnavailable, "Unexpected error: \(error)")
        }
    }
}
