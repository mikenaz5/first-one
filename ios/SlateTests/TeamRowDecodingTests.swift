import XCTest
@testable import Slate

/// The Supabase backend against what the team functions really return. `Fixtures/team_rows.json` is written by
/// `supabase/tests/dump_team_rows.py` from a real Postgres: a renamed column or a changed shape fails here, not on a phone.
/// This checks the shapes and the mapping, not the network (nothing here talks to a server).
final class TeamRowDecodingTests: XCTestCase {
    private var rows: [String: Any] = [:]
    private let backend = SupabaseBackend(url: URL(string: "https://example.supabase.co")!, anonKey: "test")

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "team_rows", withExtension: "json"), "team_rows.json is missing from the test bundle")
        rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// Postgres writes microseconds; Foundation's ISO 8601 parser is only promised milliseconds, so trim them like a
    /// careful client would.
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let trimmed = text.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: trimmed) { return date }
            if let date = ISO8601DateFormatter().date(from: trimmed) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a date: \(text)"))
        }
        return decoder
    }

    private func load<T: Decodable>(_ key: String, _ type: T.Type = T.self) throws -> T {
        let value = try XCTUnwrap(rows[key], "\(key) is missing from team_rows.json")
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return try decoder().decode(type, from: data)
    }

    private struct Signed: Decodable {
        var booking: SupabaseBackend.BookingRow
        var contract: SupabaseBackend.ContractRow
    }

    // MARK: Settings

    func testTheDatabaseAndTheAppAgreeOnTheDefaultNumbers() throws {
        let row: SupabaseBackend.TeamConfigRow = try load("team_config")
        let standard = TeamConfig.standard
        XCTAssertEqual(row.seatMinimum, standard.seatMinimum)
        XCTAssertEqual(row.seatMaximum, standard.seatMaximum)
        XCTAssertEqual(row.inviteExpiryDays, standard.inviteExpiryDays)
        XCTAssertEqual(row.graceDays, standard.graceDays)
    }

    func testAccounts() throws {
        let before: SupabaseBackend.AccountsRow = try load("my_accounts_before")
        XCTAssertTrue(before.personal.hasProfile)
        XCTAssertTrue(before.companies.isEmpty)

        let after: SupabaseBackend.AccountsRow = try load("my_accounts_after")
        XCTAssertEqual(after.companies.count, 1)
        XCTAssertEqual(after.companies.first?.name, "Acme Films")
        XCTAssertEqual(after.companies.first?.role, "creator")
        XCTAssertEqual(after.companies.first?.state, "active")
        XCTAssertEqual(after.companies.first.flatMap { UUID(uuidString: $0.organizationId) }, try organizationID())
    }

    private func organizationID() throws -> UUID {
        let row: SupabaseBackend.OverviewRow = try load("org_create")
        return try XCTUnwrap(UUID(uuidString: row.organizationId))
    }

    // MARK: The company

    func testACompanyAsItsOwnerSeesIt() throws {
        let row: SupabaseBackend.OverviewRow = try load("org_create")
        let org = try backend.makeOrganization(row)
        XCTAssertEqual(org.name, "Acme Films")
        XCTAssertEqual(org.handle, "acme-films")
        XCTAssertEqual(org.legalName, "Acme Films LLC")
        XCTAssertEqual(org.legalAddress, "1 Main St")
        XCTAssertEqual(org.bio, "Weddings and film")
        XCTAssertEqual(org.specialties, [.weddings, .corporate])
        XCTAssertEqual(org.assignmentMode, .auto)
        XCTAssertEqual(org.signerRoles, [.owner, .admin])
        XCTAssertNil(org.signerUserID)
        XCTAssertEqual(org.state, .active)
        XCTAssertEqual(org.myRole, .owner)
        XCTAssertEqual(org.seats.used, 1)
        XCTAssertEqual(org.seats.pending, 0)
        XCTAssertEqual(org.seats.billed, TeamConfig.standard.seatMinimum)
        XCTAssertEqual(org.seats.minimum, TeamConfig.standard.seatMinimum)
        XCTAssertEqual(org.seats.maximum, TeamConfig.standard.seatMaximum)
        XCTAssertFalse(org.plan.required, "Billing was off when this was recorded")
        XCTAssertTrue(org.plan.isOK)
        XCTAssertTrue(org.can(.companyDelete))
    }

    func testTheSameCompanyAsACreatorSeesLess() throws {
        let org = try backend.makeOrganization(try load("org_overview_creator"))
        XCTAssertEqual(org.myRole, .creator)
        XCTAssertTrue(org.can(.calendarManageOwn))
        XCTAssertFalse(org.can(.companyDelete))
        XCTAssertFalse(org.can(.teamInvite))
        XCTAssertEqual(org.seats.used, 6, "Everyone can see how many people there are")
    }

    func testAPersonsOwnHoursAndTheSigner() throws {
        let narrowed = try backend.makeOrganization(try load("org_overview_with_hours"))
        XCTAssertEqual(narrowed.myHours?.count, 5)
        XCTAssertEqual(narrowed.myHours?.first?.window, TimeWindow(startMinute: 600, endMinute: 840))

        let withSigner = try backend.makeOrganization(try load("org_overview_with_signer"))
        XCTAssertNotNil(withSigner.signerUserID)
        XCTAssertEqual(withSigner.signerTitle, "Director")
        XCTAssertTrue(withSigner.hasSigner)
    }

    func testThePlanTheCompanyIsOn() throws {
        let unpaid = try backend.makeOrganization(try load("org_overview_unpaid"))
        XCTAssertTrue(unpaid.plan.required)
        XCTAssertEqual(unpaid.plan.status, .none)
        XCTAssertFalse(unpaid.plan.isOK)
        XCTAssertNotNil(unpaid.plan.banner)

        let paid = try backend.makeOrganization(try load("org_overview_paid"))
        XCTAssertEqual(paid.plan.status, .active)
        XCTAssertTrue(paid.plan.isOK)
        XCTAssertNil(paid.plan.banner)
        XCTAssertNotNil(paid.plan.periodEnd)
    }

    func testBilling() throws {
        let none: SupabaseBackend.BillingRow = try load("billing_overview_none")
        XCTAssertTrue(none.required)
        XCTAssertEqual(none.status, "none")
        XCTAssertEqual(none.seats.used, 6)
        XCTAssertEqual(none.seats.billed, TeamConfig.standard.seatMinimum, "Billed for the floor, not for six")
        let plan = PlanSummary.make(required: none.required, status: PlanStatus(rawValue: none.status) ?? .none, graceUntil: none.graceUntil,
                                    cancelAtPeriodEnd: none.cancelAtPeriodEnd ?? false, periodEnd: none.currentPeriodEnd)
        XCTAssertFalse(plan.isOK)

        let active: SupabaseBackend.BillingRow = try load("billing_overview_active")
        XCTAssertEqual(active.status, "active")
        XCTAssertEqual(active.seatsBilledByStripe, 6)
        XCTAssertNotNil(active.currentPeriodEnd)
        XCTAssertEqual(PlanStatus(rawValue: active.status), .active)

        let preview: SupabaseBackend.SeatPlanRow = try load("billing_preview")
        let expected = SeatPlan.make(used: 6, delta: 1, config: .standard)
        XCTAssertEqual(preview.used, expected.used)
        XCTAssertEqual(preview.usedAfter, expected.usedAfter)
        XCTAssertEqual(preview.billedNow, expected.billedNow)
        XCTAssertEqual(preview.billedAfter, expected.billedAfter)
        XCTAssertEqual(preview.allowed, expected.allowed)
        XCTAssertEqual(SeatPlan.Change(rawValue: preview.change), expected.change)
    }

    // MARK: People and invites

    func testTheTeamList() throws {
        let owner: [SupabaseBackend.MemberRow] = try load("member_list_owner")
        let members = try owner.map(backend.makeMember)
        XCTAssertEqual(members.map(\.role), [.owner, .admin, .manager, .creator, .creator, .viewer])
        XCTAssertEqual(members.first?.displayName, "Olivia Ng")
        XCTAssertEqual(members[1].displayName, "Dee Okafor")
        XCTAssertEqual(members.filter(\.bookable).count, 2, "Only the two shooters take bookings")
        XCTAssertTrue(members.allSatisfy { $0.handle != nil }, "Everyone has a profile of their own")
        XCTAssertTrue(members.allSatisfy { $0.avatarURL == nil })
        XCTAssertEqual(Set(members.map(\.userID)).count, 6)

        let admin: [SupabaseBackend.MemberRow] = try load("member_list_admin")
        XCTAssertEqual(admin.count, 6)
    }

    func testAnInviteThatWasJustMade() throws {
        let row: SupabaseBackend.CreatedInviteRow = try load("invite_create")
        let created = try backend.makeCreatedInvite(row)
        XCTAssertEqual(created.invite.role, .admin)
        XCTAssertEqual(created.invite.email, "dee@example.com")
        XCTAssertEqual(created.invite.status, .pending)
        XCTAssertEqual(created.invite.expiresAt.timeIntervalSince(created.invite.createdAt), 7 * 86_400, accuracy: 1)
        XCTAssertEqual(created.link?.absoluteString, "slate://join/\(created.token)")
        XCTAssertFalse(created.token.isEmpty)

        let resent = try backend.makeCreatedInvite(try load("invite_resend"))
        XCTAssertEqual(resent.invite.role, .creator)
        XCTAssertEqual(resent.invite.email, "new.hire@example.com")
    }

    func testTheOpenInvites() throws {
        let list: [SupabaseBackend.InviteRow] = try load("invite_list")
        let invites = try list.map(backend.makeInvite)
        XCTAssertEqual(invites.count, 2, "The one that was resent is gone; the expired one is still listed")
        XCTAssertEqual(Set(invites.map(\.status)), [.pending, .expired])
        XCTAssertEqual(invites.first { $0.status == .pending }?.role, .creator)
        XCTAssertEqual(invites.first { $0.status == .expired }?.role, .viewer)
        XCTAssertTrue(invites.allSatisfy { $0.invitedByName == "Olivia Ng" })
    }

    func testWhatSomeoneSeesBeforeJoining() throws {
        let row: SupabaseBackend.PreviewInviteRow = try load("invite_preview")
        XCTAssertEqual(row.organizationName, "Acme Films")
        XCTAssertEqual(row.role, "admin")
        XCTAssertEqual(row.invitedByName, "Olivia Ng")
        XCTAssertFalse(row.alreadyMember)
        XCTAssertFalse(row.hasProfile, "Dee had no profile of her own before accepting")
        XCTAssertEqual(UUID(uuidString: row.organizationId), try organizationID())

        let joined = try backend.makeOrganization(try load("accept_invite"))
        XCTAssertEqual(joined.myRole, .admin)
        XCTAssertEqual(joined.id, try organizationID())
    }

    func testThePeopleAClientCanBook() throws {
        let list: [SupabaseBackend.PublicMemberRow] = try load("org_public_team")
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(Set(list.map(\.displayName)), ["Cal R", "Kim T"])
        XCTAssertTrue(list.allSatisfy { $0.handle != nil })
    }

    func testWhoOffersAService() throws {
        let list: [SupabaseBackend.PackageMemberRow] = try load("package_members")
        XCTAssertEqual(list.count, 2)
        XCTAssertTrue(list.allSatisfy { UUID(uuidString: $0.userId) != nil })
    }

    // MARK: Bookings

    func testBookingsCarryTheirAssignment() throws {
        let list: [SupabaseBackend.BookingRow] = try load("bookings_select")
        let bookings = try list.map(backend.makeBooking)
        XCTAssertEqual(bookings.count, 3)
        let company = try organizationID()
        XCTAssertTrue(bookings.allSatisfy { $0.creatorID == company })
        XCTAssertTrue(bookings.allSatisfy { $0.creatorName == "Acme Films" })
        XCTAssertEqual(bookings.filter(\.requestedMember).count, 1, "One was booked by name")
        XCTAssertEqual(bookings.filter { $0.assignedTo == nil }.count, 1, "One waits for a manager")
        XCTAssertTrue(bookings.filter { $0.assignedTo != nil }.allSatisfy { $0.assignedAt != nil })
        XCTAssertTrue(bookings.filter(\.isWaitingForAssignment).count == 1)
        XCTAssertTrue(bookings.allSatisfy { $0.assigneeShareBps == nil }, "The split ledger was off")
    }

    func testAssigningAndTheQueue() throws {
        let queue: [SupabaseBackend.BookingRow] = try load("assignment_queue")
        XCTAssertEqual(queue.count, 1)
        XCTAssertNil(queue.first?.assignedTo)

        let options: [SupabaseBackend.OptionRow] = try load("assignment_options")
        XCTAssertEqual(Set(options.map(\.displayName)), ["Cal R", "Kim T"])
        let byName = Dictionary(uniqueKeysWithValues: options.map { ($0.displayName, $0) })
        XCTAssertEqual(byName["Cal R"]?.free, true)
        XCTAssertEqual(byName["Kim T"]?.free, false, "The database says who can't take it, and why")
        XCTAssertEqual(byName["Kim T"]?.reason, "Not available")

        let assigned = try backend.makeBooking(try load("assign_booking"))
        XCTAssertNotNil(assigned.assignedTo)
        XCTAssertNotNil(assigned.assignedAt)
        XCTAssertEqual(assigned.id, try backend.makeBooking(try XCTUnwrap(queue.first)).id)
    }

    func testABookingAndItsCompanyContract() throws {
        let signed: Signed = try load("create_booking")
        let booking = try backend.makeBooking(signed.booking)
        XCTAssertNotNil(booking.assignedTo)
        XCTAssertFalse(booking.requestedMember)

        let contract = try backend.makeContract(signed.contract)
        XCTAssertEqual(contract.status, .executed)
        XCTAssertEqual(contract.creatorID, booking.creatorID)
        XCTAssertEqual(contract.providerLegalName, "Acme Films LLC")
        XCTAssertEqual(contract.countersignerName, "Dee Okafor")
        XCTAssertEqual(contract.countersignerTitle, "Director")
        XCTAssertNotNil(contract.countersignerID)
        let provider = try XCTUnwrap(contract.signature(for: .creator))
        XCTAssertEqual(provider.onBehalfOf, "Acme Films LLC")
        XCTAssertEqual(provider.signerTitle, "Director")
        XCTAssertEqual(provider.userID, contract.countersignerID)
        XCTAssertEqual(provider.method, .onFile)
        XCTAssertNil(contract.signature(for: .client)?.onBehalfOf)

        let named = try backend.makeBooking(try load("create_booking_named", Signed.self).booking)
        XCTAssertTrue(named.requestedMember)
        let waiting = try backend.makeBooking(try load("create_booking_waiting", Signed.self).booking)
        XCTAssertNil(waiting.assignedTo)
    }

    // MARK: What clients and the team see

    func testWhatAClientSeesWhenChoosingATime() throws {
        let before = backend.makeTeamSchedule(try load("team_availability"))
        XCTAssertEqual(before.assignmentMode, .auto)
        XCTAssertEqual(before.settings.timeZoneID, "America/Chicago")
        XCTAssertEqual(Set(before.members.map(\.displayName)), ["Cal R", "Kim T"])
        XCTAssertTrue(before.members.allSatisfy { $0.weekly.count == 5 && $0.busy.isEmpty })
        XCTAssertEqual(before.settings.bufferMinutes, 30)

        // Cal's and Kim's bookings are in `bookings_select`; the first is at ten, the named one at twelve.
        let bookings = try (load("bookings_select", [SupabaseBackend.BookingRow].self)).map(backend.makeBooking).sorted { $0.startAt < $1.startAt }
        let day = CalendarDay(bookings[0].startAt, calendar: before.settings.calendar)
        let now = bookings[0].startAt.addingTimeInterval(-5 * 86_400)
        let free = AvailabilityEngine.slots(on: day, durationMinutes: 60, schedule: before.asSchedule, now: now)
        XCTAssertEqual(free.first.map { Calendar.current.dateComponents(in: before.settings.timeZone, from: $0.start).hour }, 9)

        // Kim alone works ten to two, and was booked at twelve (busy until 1:30 with the buffer): only the first hour is left.
        let kim = backend.makeTeamSchedule(try load("team_availability_one"))
        XCTAssertEqual(kim.members.map(\.displayName), ["Kim T"])
        XCTAssertEqual(kim.members.first?.busy.count, 1)
        let hours = TestClock.hours(AvailabilityEngine.slots(on: day, durationMinutes: 60, schedule: kim.asSchedule, now: now))
        XCTAssertEqual(hours, [10, 10.5])
    }

    func testTheTeamCalendar() throws {
        let owner = try backend.makeTeamCalendar(try load("team_calendar_owner"))
        XCTAssertEqual(owner.timeZoneID, "America/Chicago")
        XCTAssertEqual(owner.members.count, 5, "A Viewer takes no bookings, so has no row")
        XCTAssertFalse(owner.members.contains { $0.role == .viewer })
        let cal = try XCTUnwrap(owner.members.first { $0.displayName == "Cal R" })
        let kim = try XCTUnwrap(owner.members.first { $0.displayName == "Kim T" })
        XCTAssertEqual(cal.bookings.count, 2)
        XCTAssertEqual(kim.bookings.count, 1)
        XCTAssertEqual(cal.weekly.count, 5)
        XCTAssertTrue(owner.members.first { $0.role == .owner }?.weekly.isEmpty == true, "Someone who takes no bookings has no hours")
        XCTAssertTrue(cal.bookings.allSatisfy { $0.clientName == "Alex Client" && $0.packageName == "Wedding film" && !$0.isHidden })
        XCTAssertTrue(owner.unassigned.isEmpty, "The waiting booking was assigned")

        // A Creator sees that Kim is busy, not with what.
        let asCal = try backend.makeTeamCalendar(try load("team_calendar_creator"))
        let kimForCal = try XCTUnwrap(asCal.members.first { $0.displayName == "Kim T" })
        XCTAssertEqual(kimForCal.bookings.count, 1)
        XCTAssertTrue(kimForCal.bookings.allSatisfy(\.isHidden))
        XCTAssertTrue(kimForCal.bookings.allSatisfy { $0.clientName == nil && $0.packageName == nil })
        let calForCal = try XCTUnwrap(asCal.members.first { $0.displayName == "Cal R" })
        XCTAssertTrue(calForCal.bookings.allSatisfy { !$0.isHidden })
    }

    func testTheActivityLog() throws {
        let list: [SupabaseBackend.ActivityRow] = try load("activity_list")
        XCTAssertGreaterThan(list.count, 20)
        let actions = Set(list.map(\.action))
        for expected in ["org.created", "member.joined", "invite.created", "signer.designated", "booking.created", "booking.assigned", "contract.executed"] {
            XCTAssertTrue(actions.contains(expected), expected)
        }
        XCTAssertEqual(list.map(\.createdAt), list.map(\.createdAt).sorted(by: >), "Newest first")
        XCTAssertTrue(list.allSatisfy { UUID(uuidString: $0.id) != nil })
        XCTAssertTrue(list.contains { $0.actorName == "Olivia Ng" })
    }

    // MARK: Errors

    func testEveryTokenTheTeamFunctionsRaiseBecomesATypedError() {
        let expected: [(String, SlateError)] = [
            ("not_allowed", .notAllowed), ("invite_invalid", .inviteInvalid), ("already_member", .alreadyMember),
            ("seat_limit", .seatLimit), ("plan_inactive", .planInactive), ("last_owner", .lastOwner),
            ("invalid_role", .invalidRole), ("has_upcoming_bookings", .hasUpcomingBookings), ("team_not_empty", .teamNotEmpty),
            ("bookings_in_hold", .bookingsInHold), ("signature_required", .signatureRequired),
            ("signer_role_not_allowed", .signerRoleNotAllowed), ("invalid_assignee", .invalidAssignee),
            ("not_assignable", .notAssignable), ("member_unavailable", .memberUnavailable), ("profile_required", .profileRequired),
            ("handle_taken", .handleTaken), ("invalid_input", .invalidInput), ("not_found", .notFound),
        ]
        struct Raised: Error, CustomStringConvertible { var description: String }
        for (token, error) in expected {
            XCTAssertEqual(SupabaseBackend.mapTeamError(Raised(description: "PostgrestError: \(token)")) as? SlateError, error, token)
        }
        // Tokens that belong to bookings still map, and a slot lost while assigning is a taken slot.
        XCTAssertEqual(SupabaseBackend.mapTeamError(Raised(description: "slot_taken")) as? SlateError, .slotTaken)
        XCTAssertEqual(SupabaseBackend.mapTeamError(Raised(description: "creator_not_ready")) as? SlateError, .creatorNotReady)
        XCTAssertNil(SupabaseBackend.mapTeamToken("something else"))
    }

    func testEveryErrorTheDatabaseRaisesForTeamsIsKnownToTheApp() throws {
        // Reads the migrations: any token a team function can raise must be one the app maps.
        let migrations = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("supabase/migrations")
        guard let files = try? FileManager.default.contentsOfDirectory(at: migrations, includingPropertiesForKeys: nil) else {
            throw XCTSkip("The migrations are not next to the tests (this runs from a checkout)")
        }
        var tokens = Set<String>()
        let pattern = try NSRegularExpression(pattern: "raise exception '([a-z_]+)'")
        for file in files where ["organizations", "company_booking", "seat_billing"].contains(where: { file.lastPathComponent.contains($0) }) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { tokens.insert(String(text[range])) }
            }
        }
        // Only Stripe's webhook (the service role) can reach this one; no person ever sees it.
        tokens.subtract(["invalid_status"])
        XCTAssertGreaterThan(tokens.count, 20)
        struct Raised: Error, CustomStringConvertible { var description: String }
        let unmapped = tokens.sorted().filter { token in
            let error = SupabaseBackend.mapTeamError(Raised(description: token))
            if case SlateError.backend = error { return true }
            return !(error is SlateError)
        }
        XCTAssertEqual(unmapped, [], "These tokens would reach a person as an unexplained error")
    }
}
