import XCTest
@testable import Slate

/// Starting a company, its people, roles, invites and seats, against the on-device backend. The Postgres harnesses
/// `team_rules.py` and `company_rules.py` check the same rules in the database.
final class TeamBackendTests: TeamTestCase {
    // MARK: Starting a company

    func testStartingACompanyMakesYouItsOwnerAndGivesItAProfile() async throws {
        let c = try await makeCompany()
        XCTAssertEqual(c.org.myRole, .owner)
        XCTAssertEqual(c.org.legalName, "Northlight Films LLC")
        XCTAssertEqual(c.org.assignmentMode, .auto)
        XCTAssertEqual(c.org.state, .active)
        XCTAssertEqual(c.org.seats.minimum, 3)
        XCTAssertEqual(c.org.seats.maximum, 6)
        XCTAssertFalse(c.org.plan.required, "On a device there is no plan to pay for")

        let profile = try await backend.loadProfile(for: c.org.id)
        XCTAssertEqual(profile?.kind, .company)
        XCTAssertEqual(profile?.displayName, "Northlight Films")
        let mine = try await backend.loadProfile(for: c.owner)
        XCTAssertEqual(mine?.kind, .person, "The Owner keeps a profile of their own")
    }

    func testTheAccountSwitcherListsEveryCompanyAPersonBelongsTo() async throws {
        let c = try await makeCompany()
        let owner = try await backend.loadAccounts(for: c.owner)
        XCTAssertTrue(owner.hasPersonalProfile)
        XCTAssertEqual(owner.companies.map(\.name), ["Northlight Films"])
        XCTAssertEqual(owner.companies.first?.role, .owner)

        let theo = try await backend.loadAccounts(for: c.theo)
        XCTAssertEqual(theo.companies.first?.role, .creator)

        let stranger = try await person("Zoe")
        let none = try await backend.loadAccounts(for: stranger)
        XCTAssertTrue(none.companies.isEmpty)
    }

    func testACompanyNeedsValidNamesAndAFreeHandle() async throws {
        let owner = try await person("Dana")
        let draft = OrganizationDraft(name: "Northlight Films", handle: "northlight", legalName: "Northlight Films LLC")
        var bad = draft
        bad.legalName = "X"
        await expectError(.invalidInput) { try await backend.createOrganization(bad, by: owner) }
        bad = draft
        bad.handle = "no"
        await expectError(.invalidInput) { try await backend.createOrganization(bad, by: owner) }

        _ = try await backend.createOrganization(draft, by: owner)
        await expectError(.handleTaken) { try await backend.createOrganization(draft, by: owner) }
        var asPerson = draft
        asPerson.handle = "dana"
        await expectError(.handleTaken) { try await backend.createOrganization(asPerson, by: owner) }
    }

    func testAnOwnerWithNoProfileGetsAMinimalOne() async throws {
        let session = try await backend.signInWithApple(credential("apple-newcomer"))
        let org = try await backend.createOrganization(OrganizationDraft(
            name: "Fresh Co", handle: "fresh-co", legalName: "Fresh Co Ltd", ownerDisplayName: "Nell Newcomer"
        ), by: session.userID)
        XCTAssertEqual(org.myRole, .owner)
        let profile = try await backend.loadProfile(for: session.userID)
        XCTAssertEqual(profile?.displayName, "Nell Newcomer")
        XCTAssertEqual(profile?.handle, "nell-newcomer")
    }

    func testStrangersCannotSeeACompanyExists() async throws {
        let c = try await makeCompany()
        let stranger = try await person("Zoe")
        await expectError(.notFound) { try await backend.loadOrganization(c.org.id, for: stranger) }
        await expectError(.notFound) { try await backend.loadMembers(organizationID: c.org.id, for: stranger) }
        await expectError(.notAllowed) { try await backend.loadActivity(organizationID: c.org.id, limit: 10, before: nil, for: stranger) }
    }

    // MARK: Roles

    func testWhoCanInviteWhom() async throws {
        let c = try await makeCompany()
        await expectError(.invalidRole) { try await backend.createInvite(role: .owner, email: nil, organizationID: c.org.id, by: c.owner) }
        // An Admin invites everyone below Admin, not other Admins.
        await expectError(.notAllowed) { try await backend.createInvite(role: .admin, email: nil, organizationID: c.org.id, by: c.admin) }
        // Seats are 6 of 6 now, so make room first.
        try await backend.removeMember(memberID: c.jun, organizationID: c.org.id, by: c.owner)
        _ = try await backend.createInvite(role: .creator, email: nil, organizationID: c.org.id, by: c.admin)
        // Managers, Creators and Viewers can't invite at all.
        for other in [c.manager, c.theo, c.viewer] {
            await expectError(.notAllowed) { try await backend.createInvite(role: .viewer, email: nil, organizationID: c.org.id, by: other) }
        }
    }

    func testWhoCanChangeWhoseRole() async throws {
        let c = try await makeCompany()
        // The Owner can't change themselves, and nobody can make an Owner by changing a role.
        await expectError(.notAllowed) { try await backend.setMemberRole(.admin, memberID: c.owner, organizationID: c.org.id, by: c.owner) }
        await expectError(.invalidRole) { try await backend.setMemberRole(.owner, memberID: c.theo, organizationID: c.org.id, by: c.owner) }
        // An Admin can't touch another Admin, or make one.
        await expectError(.notAllowed) { try await backend.setMemberRole(.viewer, memberID: c.admin, organizationID: c.org.id, by: c.admin) }
        await expectError(.notAllowed) { try await backend.setMemberRole(.admin, memberID: c.theo, organizationID: c.org.id, by: c.admin) }
        try await backend.setMemberRole(.viewer, memberID: c.theo, organizationID: c.org.id, by: c.admin)
        // A Manager can't change anyone.
        await expectError(.notAllowed) { try await backend.setMemberRole(.viewer, memberID: c.jun, organizationID: c.org.id, by: c.manager) }

        let members = try await backend.loadMembers(organizationID: c.org.id, for: c.owner)
        let theo = try XCTUnwrap(members.first { $0.userID == c.theo })
        XCTAssertEqual(theo.role, .viewer)
        XCTAssertFalse(theo.bookable, "A Viewer can't take bookings")
        try await backend.setMemberRole(.creator, memberID: c.theo, organizationID: c.org.id, by: c.owner)
        let back = try await backend.loadMembers(organizationID: c.org.id, for: c.owner)
        XCTAssertTrue(try XCTUnwrap(back.first { $0.userID == c.theo }).bookable, "Becoming a Creator again makes them bookable")
    }

    func testRemovingAndLeaving() async throws {
        let c = try await makeCompany()
        await expectError(.notAllowed) { try await backend.removeMember(memberID: c.jun, organizationID: c.org.id, by: c.manager) }
        await expectError(.notAllowed) { try await backend.removeMember(memberID: c.admin, organizationID: c.org.id, by: c.admin) }
        await expectError(.lastOwner) { try await backend.removeMember(memberID: c.owner, organizationID: c.org.id, by: c.admin) }
        await expectError(.lastOwner) { try await backend.leaveOrganization(c.org.id, by: c.owner) }

        try await backend.removeMember(memberID: c.jun, organizationID: c.org.id, by: c.admin)
        try await backend.leaveOrganization(c.org.id, by: c.theo)
        let members = try await backend.loadMembers(organizationID: c.org.id, for: c.owner)
        XCTAssertEqual(Set(members.map(\.userID)), [c.owner, c.admin, c.manager, c.viewer])
        let gone = try await backend.loadAccounts(for: c.jun)
        XCTAssertTrue(gone.companies.isEmpty)
        await expectError(.notFound) { try await backend.loadOrganization(c.org.id, for: c.jun) }
    }

    func testTransferringOwnership() async throws {
        let c = try await makeCompany()
        await expectError(.notAllowed) { try await backend.transferOwnership(organizationID: c.org.id, to: c.admin, by: c.admin) }
        await expectError(.invalidInput) { try await backend.transferOwnership(organizationID: c.org.id, to: c.owner, by: c.owner) }
        await expectError(.invalidInput) { try await backend.transferOwnership(organizationID: c.org.id, to: UUID(), by: c.owner) }
        try await backend.transferOwnership(organizationID: c.org.id, to: c.admin, by: c.owner)

        let members = try await backend.loadMembers(organizationID: c.org.id, for: c.admin)
        XCTAssertEqual(members.first { $0.userID == c.admin }?.role, .owner)
        XCTAssertEqual(members.first { $0.userID == c.owner }?.role, .admin)
        XCTAssertEqual(members.filter { $0.role == .owner }.count, 1)
        // Dana is an Admin now, still allowed to sign, so the signer stays.
        XCTAssertTrue(try XCTUnwrap(members.first { $0.userID == c.owner }).isSigner)
    }

    func testOnlyTheOwnerSeesWhatMembersAreShared() async throws {
        let c = try await makeCompany(split: true)
        try await backend.setMemberShare(bps: 3000, memberID: c.theo, organizationID: c.org.id, by: c.owner)
        await expectError(.notAllowed) { try await backend.setMemberShare(bps: 3000, memberID: c.theo, organizationID: c.org.id, by: c.admin) }
        await expectError(.invalidInput) { try await backend.setMemberShare(bps: 10_001, memberID: c.theo, organizationID: c.org.id, by: c.owner) }

        let seenByOwner = try await backend.loadMembers(organizationID: c.org.id, for: c.owner)
        XCTAssertEqual(seenByOwner.first { $0.userID == c.theo }?.shareBps, 3000)
        let seenByAdmin = try await backend.loadMembers(organizationID: c.org.id, for: c.admin)
        XCTAssertEqual(seenByAdmin.first { $0.userID == c.theo }?.shareBps, 0, "An Admin doesn't see anyone's share")
    }

    func testTeamProfilesAreEditedByWhoCanManageTheTeam() async throws {
        let c = try await makeCompany()
        try await backend.updateMember(MemberUpdate(title: "Lead videographer", listed: true), memberID: c.theo, organizationID: c.org.id, by: c.admin)
        await expectError(.notAllowed) { try await backend.updateMember(MemberUpdate(title: "Boss"), memberID: c.theo, organizationID: c.org.id, by: c.manager) }
        await expectError(.invalidInput) { try await backend.updateMember(MemberUpdate(bookable: true), memberID: c.viewer, organizationID: c.org.id, by: c.owner) }
        await expectError(.invalidInput) {
            try await backend.updateMember(MemberUpdate(title: String(repeating: "x", count: 81)), memberID: c.theo, organizationID: c.org.id, by: c.owner)
        }
        let members = try await backend.loadMembers(organizationID: c.org.id, for: c.owner)
        XCTAssertEqual(members.first { $0.userID == c.theo }?.subtitle, "Lead videographer")
    }

    func testMembersListOwnersFirst() async throws {
        let c = try await makeCompany()
        let members = try await backend.loadMembers(organizationID: c.org.id, for: c.viewer)
        XCTAssertEqual(members.map(\.role), [.owner, .admin, .manager, .creator, .creator, .viewer])
        XCTAssertEqual(members.map(\.displayName), ["Dana", "Marcus", "Noor", "Jun", "Theo", "Ben"])
    }

    // MARK: Settings

    func testCompanySettingsAreForOwnersAndAdmins() async throws {
        let c = try await makeCompany()
        await expectError(.notAllowed) { try await backend.updateOrganization(c.org.id, with: OrganizationUpdate(legalName: "Other LLC"), by: c.manager) }
        let renamed = try await backend.updateOrganization(c.org.id, with: OrganizationUpdate(legalName: "Northlight Films Inc."), by: c.admin)
        XCTAssertEqual(renamed.legalName, "Northlight Films Inc.")
        // Widening who may sign is the Owner's call.
        await expectError(.notAllowed) {
            try await backend.updateOrganization(c.org.id, with: OrganizationUpdate(signerRoles: [.owner, .admin, .manager]), by: c.admin)
        }
        let widened = try await backend.updateOrganization(c.org.id, with: OrganizationUpdate(signerRoles: [.owner, .admin, .manager]), by: c.owner)
        XCTAssertEqual(widened.signerRoles, [.owner, .admin, .manager])
        await expectError(.invalidInput) { try await backend.updateOrganization(c.org.id, with: OrganizationUpdate(legalName: "X" + String(repeating: "y", count: 130)), by: c.owner) }
    }

    func testThePayoutSplitIsTheOwnersAlone() async throws {
        let c = try await makeCompany()
        await expectError(.notAllowed) { try await backend.setSplitEnabled(true, organizationID: c.org.id, by: c.admin) }
        let on = try await backend.setSplitEnabled(true, organizationID: c.org.id, by: c.owner)
        XCTAssertTrue(on.splitEnabled)
    }

    func testBillingIsTheOwnersAndNotAvailableOnADevice() async throws {
        let c = try await makeCompany()
        await expectError(.notAllowed) { try await backend.loadBilling(organizationID: c.org.id, for: c.admin) }
        let overview = try await backend.loadBilling(organizationID: c.org.id, for: c.owner)
        XCTAssertEqual(overview.seats.used, 6)
        XCTAssertEqual(overview.seats.billed, 6)
        await expectError(.billingUnavailable) { try await backend.beginBilling(.checkout, organizationID: c.org.id, by: c.owner) }

        // Admins and Owners can ask what a change would do to the bill; Creators can't.
        let plan = try await backend.previewSeatChange(delta: 1, organizationID: c.org.id, for: c.admin)
        XCTAssertFalse(plan.allowed, "6 is the most this team can have")
        let fewer = try await backend.previewSeatChange(delta: -1, organizationID: c.org.id, for: c.owner)
        XCTAssertEqual(fewer.billedAfter, 5)
        await expectError(.notAllowed) { try await backend.previewSeatChange(delta: 1, organizationID: c.org.id, for: c.theo) }
    }

    // MARK: Invites and seats

    func testAnInviteIsSingleUseAndShownOnce() async throws {
        let owner = try await person("Dana")
        let org = try await backend.createOrganization(OrganizationDraft(name: "Small Co", handle: "small-co", legalName: "Small Co LLC"), by: owner)
        let invite = try await backend.createInvite(role: .creator, email: " Theo@Example.com ", organizationID: org.id, by: owner)
        XCTAssertEqual(invite.invite.email, "theo@example.com")
        XCTAssertEqual(invite.link?.absoluteString, "slate://join/\(invite.token)")
        XCTAssertGreaterThanOrEqual(invite.token.count, 48)

        let listed = try await backend.loadInvites(organizationID: org.id, for: owner)
        XCTAssertEqual(listed.map(\.id), [invite.invite.id])
        XCTAssertEqual(listed.first?.invitedByName, "Dana")

        let theo = try await person("Theo")
        let preview = try await backend.previewInvite(token: invite.token, for: theo)
        XCTAssertEqual(preview.organizationName, "Small Co")
        XCTAssertEqual(preview.role, .creator)
        XCTAssertEqual(preview.invitedByName, "Dana")
        XCTAssertFalse(preview.alreadyMember)
        XCTAssertTrue(preview.hasProfile)

        let joined = try await backend.acceptInvite(token: invite.token, displayName: nil, by: theo)
        XCTAssertEqual(joined.myRole, .creator)
        let remaining = try await backend.loadInvites(organizationID: org.id, for: owner)
        XCTAssertTrue(remaining.isEmpty)

        // The same link can't be used again, by anyone.
        await expectError(.inviteInvalid) { try await backend.acceptInvite(token: invite.token, displayName: nil, by: theo) }
        let other = try await person("Zoe")
        await expectError(.inviteInvalid) { try await backend.acceptInvite(token: invite.token, displayName: nil, by: other) }
        // The label is never matched against who accepts.
        XCTAssertEqual(joined.seats.used, 2)
    }

    func testBadTokensAllLookTheSame() async throws {
        let owner = try await person("Dana")
        await expectError(.inviteInvalid) { try await backend.previewInvite(token: "nonsense", for: owner) }
        await expectError(.inviteInvalid) { try await backend.acceptInvite(token: "", displayName: nil, by: owner) }
    }

    func testAnInviteLapsesAfterTheExpiryDays() async throws {
        let owner = try await person("Dana")
        let org = try await backend.createOrganization(OrganizationDraft(name: "Small Co", handle: "small-co", legalName: "Small Co LLC"), by: owner)
        let invite = try await backend.createInvite(role: .viewer, email: nil, organizationID: org.id, by: owner)
        XCTAssertEqual(invite.invite.expiresAt.timeIntervalSince(invite.invite.createdAt), 7 * 86_400)

        clock.advance(by: 8 * 86_400)
        let listed = try await backend.loadInvites(organizationID: org.id, for: owner)
        XCTAssertEqual(listed.first?.status, .expired)
        let guest = try await person("Zoe")
        await expectError(.inviteInvalid) { try await backend.previewInvite(token: invite.token, for: guest) }
        let seats = try await backend.loadOrganization(org.id, for: owner).seats
        XCTAssertEqual(seats.pending, 0, "An expired invite no longer holds a seat")
    }

    func testAMemberOpeningAnInviteIsToldTheyAreAlreadyIn() async throws {
        let c = try await makeCompany()
        try await backend.removeMember(memberID: c.viewer, organizationID: c.org.id, by: c.owner)
        let invite = try await backend.createInvite(role: .viewer, email: nil, organizationID: c.org.id, by: c.owner)
        let preview = try await backend.previewInvite(token: invite.token, for: c.theo)
        XCTAssertTrue(preview.alreadyMember)
        await expectError(.alreadyMember) { try await backend.acceptInvite(token: invite.token, displayName: nil, by: c.theo) }
    }

    func testOpenInvitesCountTowardTheMaximum() async throws {
        let c = try await makeCompany()
        // 6 people, the most there can be.
        await expectError(.seatLimit) { try await backend.createInvite(role: .viewer, email: nil, organizationID: c.org.id, by: c.owner) }

        try await backend.removeMember(memberID: c.viewer, organizationID: c.org.id, by: c.owner)
        let open = try await backend.createInvite(role: .viewer, email: nil, organizationID: c.org.id, by: c.owner)
        await expectError(.seatLimit) { try await backend.createInvite(role: .viewer, email: nil, organizationID: c.org.id, by: c.owner) }
        var seats = try await backend.loadOrganization(c.org.id, for: c.owner).seats
        XCTAssertEqual(seats.used, 5)
        XCTAssertEqual(seats.pending, 1)
        XCTAssertEqual(seats.remaining, 0)

        try await backend.revokeInvite(open.invite.id, organizationID: c.org.id, by: c.owner)
        seats = try await backend.loadOrganization(c.org.id, for: c.owner).seats
        XCTAssertEqual(seats.remaining, 1)
        await expectError(.inviteInvalid) { try await backend.revokeInvite(open.invite.id, organizationID: c.org.id, by: c.owner) }
    }

    func testBilledSeatsNeverFallBelowTheFloor() async throws {
        let owner = try await person("Dana")
        let org = try await backend.createOrganization(OrganizationDraft(name: "Small Co", handle: "small-co", legalName: "Small Co LLC"), by: owner)
        XCTAssertEqual(org.seats.used, 1)
        XCTAssertEqual(org.seats.billed, 3)
        let plan = try await backend.previewSeatChange(delta: 1, organizationID: org.id, for: owner)
        XCTAssertEqual(plan.change, .none)
        XCTAssertEqual(plan.billedAfter, 3)
    }

    func testResendingReplacesALostLink() async throws {
        let owner = try await person("Dana")
        let org = try await backend.createOrganization(OrganizationDraft(name: "Small Co", handle: "small-co", legalName: "Small Co LLC"), by: owner)
        let first = try await backend.createInvite(role: .manager, email: "noor@example.com", organizationID: org.id, by: owner)
        let second = try await backend.resendInvite(first.invite.id, organizationID: org.id, by: owner)
        XCTAssertNotEqual(first.token, second.token)
        XCTAssertEqual(second.invite.role, .manager)
        XCTAssertEqual(second.invite.email, "noor@example.com")
        let guest = try await person("Noor")
        await expectError(.inviteInvalid) { try await backend.previewInvite(token: first.token, for: guest) }
        _ = try await backend.previewInvite(token: second.token, for: guest)
        let listed = try await backend.loadInvites(organizationID: org.id, for: owner)
        XCTAssertEqual(listed.map(\.id), [second.invite.id])
    }

    func testInviteEmailsAreChecked() async throws {
        let owner = try await person("Dana")
        let org = try await backend.createOrganization(OrganizationDraft(name: "Small Co", handle: "small-co", legalName: "Small Co LLC"), by: owner)
        await expectError(.invalidInput) { try await backend.createInvite(role: .viewer, email: "not an email", organizationID: org.id, by: owner) }
        _ = try await backend.createInvite(role: .viewer, email: "", organizationID: org.id, by: owner)
        _ = try await backend.createInvite(role: .viewer, email: nil, organizationID: org.id, by: owner)
    }

    func testAnAdminCannotCancelAnAdminInvite() async throws {
        let owner = try await person("Dana")
        let org = try await backend.createOrganization(OrganizationDraft(name: "Small Co", handle: "small-co", legalName: "Small Co LLC"), by: owner)
        let adminInvite = try await backend.createInvite(role: .admin, email: nil, organizationID: org.id, by: owner)
        let marcus = try await person("Marcus")
        _ = try await backend.acceptInvite(token: adminInvite.token, displayName: nil, by: marcus)
        let pending = try await backend.createInvite(role: .admin, email: nil, organizationID: org.id, by: owner)
        await expectError(.notAllowed) { try await backend.revokeInvite(pending.invite.id, organizationID: org.id, by: marcus) }
    }

    // MARK: Activity

    func testTheActivityLogRecordsWhoChangedWhat() async throws {
        let c = try await makeCompany()
        try await backend.setMemberRole(.viewer, memberID: c.jun, organizationID: c.org.id, by: c.admin)
        var price = c.package
        price.priceCents = 240_000
        try await backend.actAs(c.admin)
        _ = try await backend.savePackage(price)

        let log = try await activity(c)
        XCTAssertEqual(log.first?.action, "package.price_changed", "Newest first")
        XCTAssertEqual(log.first?.summary, "Changed the price of Brand film from $2,000 to $2,400")
        XCTAssertEqual(log.first?.actorName, "Marcus")
        XCTAssertTrue(log.contains { $0.action == "member.role_changed" && $0.summary == "Changed Jun from creator to viewer" })
        XCTAssertTrue(log.contains { $0.action == "member.joined" && $0.summary == "Theo joined as creator" })
        XCTAssertTrue(log.contains { $0.action == "invite.created" })
        XCTAssertTrue(log.contains { $0.action == "signer.designated" })
        XCTAssertEqual(log.last?.action, "org.created")
    }

    func testOnlyOwnersAndAdminsReadTheLog() async throws {
        let c = try await makeCompany()
        for allowed in [c.owner, c.admin] {
            let log = try await activity(c, as: allowed)
            XCTAssertFalse(log.isEmpty)
        }
        for denied in [c.manager, c.theo, c.viewer] {
            await expectError(.notAllowed) { try await activity(c, as: denied) }
        }
    }

    func testTheLogPagesBackwardsInTime() async throws {
        let c = try await makeCompany()
        let all = try await activity(c)
        XCTAssertGreaterThan(all.count, 6)
        let page = try await backend.loadActivity(organizationID: c.org.id, limit: 3, before: nil, for: c.owner)
        XCTAssertEqual(page.map(\.id), Array(all.prefix(3)).map(\.id))
        let older = try await backend.loadActivity(organizationID: c.org.id, limit: 200, before: page.last?.createdAt, for: c.owner)
        XCTAssertTrue(older.allSatisfy { $0.createdAt < (page.last?.createdAt ?? .distantPast) })
    }

    func testRemovingSomeoneIsLoggedWithTheirBookingsReturned() async throws {
        let c = try await makeCompany()
        let booked = try await book(c, at: wednesday(10))
        let who = try XCTUnwrap(booked.booking.assignedTo)
        try await backend.removeMember(memberID: who, organizationID: c.org.id, by: c.owner)
        let log = try await activity(c)
        XCTAssertTrue(log.contains { $0.action == "member.removed" && $0.summary.hasSuffix("1 booking returned to the assignment queue") })
    }

    // MARK: Leaving the company

    func testDeletingYourAccountNeedsYouToHandTheCompanyOver() async throws {
        let c = try await makeCompany()
        try await backend.actAs(c.owner)
        await expectError(.lastOwner) { try await backend.deleteAccount() }
        try await backend.transferOwnership(organizationID: c.org.id, to: c.admin, by: c.owner)
        try await backend.deleteAccount()
        let members = try await backend.loadMembers(organizationID: c.org.id, for: c.admin)
        XCTAssertFalse(members.contains { $0.userID == c.owner }, "Deleting an account leaves its companies")
    }

    func testClosingACompanyKeepsItsContractsAndFreesItsHandle() async throws {
        let c = try await makeCompany()
        await expectError(.notAllowed) { try await backend.closeOrganization(c.org.id, by: c.admin) }
        try await backend.closeOrganization(c.org.id, by: c.owner)

        let accounts = try await backend.loadAccounts(for: c.owner)
        XCTAssertTrue(accounts.companies.isEmpty)
        let page = try await backend.loadPublicPage(handle: "northlight")
        XCTAssertNil(page, "A closed company has no page")
        // The handle can be used again.
        let next = try await backend.createOrganization(OrganizationDraft(name: "Northlight 2", handle: "northlight", legalName: "Northlight Two LLC"), by: c.owner)
        XCTAssertEqual(next.handle, "northlight")
    }

    func testACompanyWithBookingsComingUpCannotBeClosed() async throws {
        let c = try await makeCompany()
        _ = try await book(c, at: wednesday(10))
        await expectError(.hasUpcomingBookings) { try await backend.closeOrganization(c.org.id, by: c.owner) }
    }
}
