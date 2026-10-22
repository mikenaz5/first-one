import XCTest
@testable import Slate

/// The app's side of company accounts, end to end against the on-device backend: choosing and switching accounts,
/// what each account shows, joining by an invite link, and what a role can and can't do from the app.
@MainActor
final class TeamAppModelTests: XCTestCase {
    private var root: URL!
    private var clock: ManualClock!
    private var backend: LocalBackend!
    private var model: AppModel!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-team-app-\(UUID().uuidString)")
        clock = ManualClock(TestClock.date(2027, 1, 4, 8, 0))
        let clock = self.clock!
        backend = LocalBackend(
            root: root, clock: { clock.now },
            teamConfig: TeamConfig(seatMinimum: 3, seatMaximum: 6, inviteExpiryDays: 7, graceDays: 7)
        )
        model = AppModel(backend: backend)
        model.clock = { clock.now }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    // MARK: Helpers

    /// Maya signs in and finishes setting up her own profile.
    private func makeReady() async throws {
        await model.signInAsDemo()
        XCTAssertNotNil(model.session, "Signing in failed: \(model.alert?.message ?? "no message")")
        let draft = ProfileDraft()
        draft.displayName = "Maya Chen"
        // Not "maya": on-device mode keeps a few short handles as already taken, to show that state.
        draft.handle = "mayachen"
        draft.specialties = [.weddings]
        do {
            try await model.completeOnboarding(draft: draft, portfolio: [])
        } catch {
            XCTFail("Finishing onboarding failed: \(String(reflecting: error))")
            throw error
        }
        XCTAssertEqual(model.phase, .ready, "Load error: \(model.loadErrorMessage ?? "none")")
    }

    private func companyDraft(_ name: String = "Northlight Films", handle: String = "northlight") -> OrganizationDraft {
        OrganizationDraft(
            name: name, handle: handle, legalName: "\(name) LLC",
            legalAddress: "410 Congress Ave, Austin", bio: "Weddings and brand film", specialties: [.weddings]
        )
    }

    /// Dana owns a company on this device's backend and has an invite out for a role. Leaves Dana signed in.
    private func danasCompany(inviting role: OrgRole) async throws -> (org: Organization, invite: CreatedInvite, owner: UUID) {
        let session = try await backend.signInWithApple(
            AppleCredential(userID: "apple-dana", identityToken: "t", rawNonce: "n", fullName: nil, email: nil)
        )
        _ = try await backend.saveProfile(CreatorProfile(
            id: session.userID, handle: "dana", displayName: "Dana Lens", bio: "", specialties: [.weddings],
            location: nil, avatarURL: nil, createdAt: Date(), updatedAt: Date()
        ), avatarJPEG: nil)
        let org = try await backend.createOrganization(companyDraft(), by: session.userID)
        let invite = try await backend.createInvite(role: role, email: nil, organizationID: org.id, by: session.userID)
        return (org, invite, session.userID)
    }

    /// Maya opens an invite link and joins.
    private func join(_ invite: CreatedInvite, displayName: String? = nil) async throws {
        model.pendingInviteToken = invite.token
        await model.openPendingInviteIfNeeded()
        let offer = try XCTUnwrap(model.presentedInvite)
        try await model.acceptInvite(offer, displayName: displayName)
    }

    private func newPackage(_ name: String) -> ServicePackage {
        var package = model.makeNewPackage()
        package.name = name
        package.priceCents = 50_000
        package.durationMinutes = 60
        package.isPublished = false
        return package
    }

    // MARK: Starting and switching

    func testStartingACompanyOpensItAndMakesThePersonItsOwner() async throws {
        try await makeReady()
        let personalID = try XCTUnwrap(model.session?.userID)

        let company = try await model.createCompany(companyDraft(), location: nil, avatarJPEG: nil)

        XCTAssertEqual(model.activeAccount, .company(company.id))
        XCTAssertEqual(model.ownerID, company.id)
        XCTAssertEqual(model.organization?.myRole, .owner)
        XCTAssertEqual(model.profile?.kind, .company)
        XCTAssertEqual(model.profile?.displayName, "Northlight Films")
        XCTAssertTrue(model.can(.billingManage))
        XCTAssertEqual(model.accounts.companies.map(\.organizationID), [company.id])
        // The person is still themselves underneath.
        XCTAssertEqual(model.personalProfile?.id, personalID)
        XCTAssertEqual(model.personalProfile?.displayName, "Maya Chen")
    }

    func testSwitchingAccountsChangesWhatIsShownAndWhoOwnsIt() async throws {
        try await makeReady()
        let personalID = try XCTUnwrap(model.session?.userID)
        try await model.savePackage(newPackage("Portraits"))
        let company = try await model.createCompany(companyDraft(), location: nil, avatarJPEG: nil)
        XCTAssertTrue(model.packages.isEmpty, "A new company starts with no services of its own")
        try await model.savePackage(newPackage("Brand film"))
        XCTAssertEqual(model.packages.first?.creatorID, company.id)

        await model.switchAccount(to: .personal)
        XCTAssertEqual(model.activeAccount, .personal)
        XCTAssertEqual(model.ownerID, personalID)
        XCTAssertEqual(model.packages.map(\.name), ["Portraits"])
        XCTAssertNil(model.organization)
        XCTAssertEqual(model.profile?.displayName, "Maya Chen")

        await model.switchAccount(to: .company(company.id))
        XCTAssertEqual(model.packages.map(\.name), ["Brand film"])
        XCTAssertEqual(model.organization?.id, company.id)
        XCTAssertEqual(model.profile?.displayName, "Northlight Films")
    }

    func testSwitchingToACompanyThePersonIsNotOnDoesNothing() async throws {
        try await makeReady()
        await model.switchAccount(to: .company(UUID()))
        XCTAssertEqual(model.activeAccount, .personal)
    }

    func testTheAccountOnScreenIsRememberedOnRelaunch() async throws {
        try await makeReady()
        let company = try await model.createCompany(companyDraft(), location: nil, avatarJPEG: nil)

        let relaunched = AppModel(backend: backend)
        await relaunched.bootstrap()
        XCTAssertEqual(relaunched.phase, .ready)
        XCTAssertEqual(relaunched.activeAccount, .company(company.id))
        XCTAssertEqual(relaunched.organization?.myRole, .owner)

        await relaunched.switchAccount(to: .personal)
        let again = AppModel(backend: backend)
        await again.bootstrap()
        XCTAssertEqual(again.activeAccount, .personal)
    }

    // MARK: Upgrading and ending

    func testUpgradingMovesServicesToTheCompanyAndKeepsThePersonThemselves() async throws {
        try await makeReady()
        let personalID = try XCTUnwrap(model.session?.userID)
        try await model.savePackage(newPackage("Portraits"))

        let company = try await model.upgradeToCompany(companyDraft(), location: nil, avatarJPEG: nil)

        XCTAssertEqual(model.activeAccount, .company(company.id))
        XCTAssertEqual(model.packages.map(\.name), ["Portraits"])
        XCTAssertEqual(model.packages.first?.creatorID, company.id)
        XCTAssertEqual(model.organization?.myRole, .owner)
        XCTAssertEqual(model.personalProfile?.id, personalID)
        XCTAssertEqual(model.personalProfile?.displayName, "Maya Chen")

        await model.switchAccount(to: .personal)
        XCTAssertTrue(model.packages.isEmpty, "The services moved; they are not copied")
    }

    func testDowngradingGivesTheServicesBackAndClosesTheCompany() async throws {
        try await makeReady()
        let personalID = try XCTUnwrap(model.session?.userID)
        try await model.createCompany(companyDraft(), location: nil, avatarJPEG: nil)
        try await model.savePackage(newPackage("Brand film"))

        try await model.downgradeToIndividual()

        XCTAssertEqual(model.activeAccount, .personal)
        XCTAssertNil(model.organization)
        XCTAssertTrue(model.accounts.companies.isEmpty)
        XCTAssertEqual(model.packages.map(\.name), ["Brand film"])
        XCTAssertEqual(model.packages.first?.creatorID, personalID)
    }

    func testLeavingACompanyGoesBackToTheOwnAccount() async throws {
        let (org, invite, _) = try await danasCompany(inviting: .creator)
        try await makeReady()
        try await join(invite)
        XCTAssertEqual(model.activeAccount, .company(org.id))

        try await model.leaveCompany(org.id)

        XCTAssertEqual(model.activeAccount, .personal)
        XCTAssertNil(model.organization)
        XCTAssertTrue(model.accounts.companies.isEmpty)
        XCTAssertEqual(model.phase, .ready)
    }

    func testTheOnlyOwnerCannotLeave() async throws {
        try await makeReady()
        let company = try await model.createCompany(companyDraft(), location: nil, avatarJPEG: nil)
        do {
            try await model.leaveCompany(company.id)
            XCTFail("An owner with nobody to hand the company to can't just leave")
        } catch {
            XCTAssertEqual(error as? SlateError, .lastOwner)
        }
        XCTAssertEqual(model.activeAccount, .company(company.id))
    }

    // MARK: Invites

    func testAnInviteOpenedBeforeSettingUpIsOfferedFirstAndJoiningSkipsSetUp() async throws {
        let (org, invite, _) = try await danasCompany(inviting: .creator)
        await model.signInAsDemo()
        XCTAssertEqual(model.phase, .onboarding)

        model.pendingInviteToken = invite.token
        await model.openPendingInviteIfNeeded()
        let offer = try XCTUnwrap(model.presentedInvite)
        XCTAssertEqual(offer.preview.organizationName, "Northlight Films")
        XCTAssertEqual(offer.preview.role, .creator)
        XCTAssertFalse(offer.preview.hasProfile)

        try await model.acceptInvite(offer, displayName: "Maya Chen")

        XCTAssertNil(model.presentedInvite)
        XCTAssertEqual(model.phase, .ready, "Someone who only works for a company doesn't need a profile of their own first")
        XCTAssertEqual(model.activeAccount, .company(org.id))
        XCTAssertEqual(model.myRole, .creator)
        XCTAssertEqual(model.personalProfile?.displayName, "Maya Chen")
    }

    func testDecliningAnInviteLeavesEverythingAsItWas() async throws {
        let (_, invite, _) = try await danasCompany(inviting: .admin)
        try await makeReady()
        model.pendingInviteToken = invite.token
        await model.openPendingInviteIfNeeded()
        XCTAssertNotNil(model.presentedInvite)

        model.declineInvite()

        XCTAssertNil(model.presentedInvite)
        XCTAssertEqual(model.activeAccount, .personal)
        XCTAssertTrue(model.accounts.companies.isEmpty)
    }

    func testAnInviteThatIsNotValidIsReportedAndOffersNothing() async throws {
        try await makeReady()
        model.pendingInviteToken = "not-a-real-token"
        await model.openPendingInviteIfNeeded()
        XCTAssertNil(model.presentedInvite)
        XCTAssertNotNil(model.alert)
    }

    func testAnInviteToACompanyYouAreOnJustOpensIt() async throws {
        let (org, first, dana) = try await danasCompany(inviting: .creator)
        try await makeReady()
        try await join(first)
        await model.switchAccount(to: .personal)
        XCTAssertEqual(model.activeAccount, .personal)

        let second = try await backend.createInvite(role: .creator, email: nil, organizationID: org.id, by: dana)
        model.pendingInviteToken = second.token
        await model.openPendingInviteIfNeeded()

        XCTAssertNil(model.presentedInvite, "There's nothing to join; the person already works there")
        XCTAssertEqual(model.activeAccount, .company(org.id))
    }

    func testInviteAndBillingLinksAreRecognised() throws {
        XCTAssertEqual(AppLink(url: URL(string: "slate://join/abc123")!), .join(token: "abc123"))
        XCTAssertNil(AppLink(url: URL(string: "slate://join")!))
        XCTAssertEqual(AppLink(url: URL(string: "slate://billing/return")!), .billingReturn)
        XCTAssertEqual(AppLink(url: URL(string: "slate://billing/cancel")!), .billingReturn)
        let link = try XCTUnwrap(AppConfig.joinDeepLink(token: "tok_123-abc"))
        XCTAssertEqual(AppLink(url: link), .join(token: "tok_123-abc"))
    }

    // MARK: Roles from the app

    func testAViewerSeesTheTeamButCannotChangeIt() async throws {
        let (_, invite, _) = try await danasCompany(inviting: .viewer)
        try await makeReady()
        try await join(invite)

        XCTAssertEqual(model.myRole, .viewer)
        XCTAssertTrue(model.can(.teamView))
        XCTAssertFalse(model.can(.teamManage))
        XCTAssertFalse(model.can(.billingManage))
        XCTAssertFalse(model.teamMembers.isEmpty)
        XCTAssertTrue(model.teamInvites.isEmpty, "A viewer can't see invites")

        do {
            try await model.updateCompany(OrganizationUpdate(legalName: "Other Films LLC"))
            XCTFail("A viewer can't edit the company")
        } catch {
            XCTAssertEqual(error as? SlateError, .notAllowed)
        }
    }

    func testAnAdminManagesTheTeamButNotTheBilling() async throws {
        let (_, invite, _) = try await danasCompany(inviting: .admin)
        try await makeReady()
        try await join(invite)

        XCTAssertEqual(model.myRole, .admin)
        XCTAssertTrue(model.can(.teamManage))
        XCTAssertTrue(model.can(.servicesManage))
        XCTAssertFalse(model.can(.billingManage))
        XCTAssertFalse(model.can(.companyDelete))
    }

    func testChangingARoleFromTheAppShowsUpInTheList() async throws {
        try await makeReady()
        try await model.createCompany(companyDraft(), location: nil, avatarJPEG: nil)
        let created = try await model.createInvite(role: .creator, email: nil)
        XCTAssertEqual(model.teamInvites.count, 1)
        try await model.addPretendTeammate(accepting: created.invite, named: "Theo")
        XCTAssertTrue(model.teamInvites.isEmpty, "An accepted invite is no longer waiting")
        let theo = try XCTUnwrap(model.teamMembers.first { $0.displayName == "Theo" })
        XCTAssertEqual(theo.role, .creator)

        try await model.setRole(.manager, for: theo)

        XCTAssertEqual(model.member(withID: theo.userID)?.role, .manager)
        XCTAssertEqual(model.organization?.seats.used, 2)
    }

    func testRemovingSomeoneFromTheAppFreesTheirSeat() async throws {
        try await makeReady()
        try await model.createCompany(companyDraft(), location: nil, avatarJPEG: nil)
        let created = try await model.createInvite(role: .creator, email: nil)
        try await model.addPretendTeammate(accepting: created.invite, named: "Theo")
        let theo = try XCTUnwrap(model.teamMembers.first { $0.displayName == "Theo" })
        XCTAssertEqual(model.organization?.seats.used, 2)

        try await model.removeMember(theo)

        XCTAssertNil(model.member(withID: theo.userID))
        XCTAssertEqual(model.organization?.seats.used, 1)
    }

    // MARK: Bookings

    func testACompanyBookingShowsUnderTheCompanyAndNotUnderThePersonWhoLeadsIt() async throws {
        try await makeReady()
        let maya = try XCTUnwrap(model.session?.userID)
        let company = try await model.createCompany(companyDraft(), location: nil, avatarJPEG: nil)
        // Maya leads and takes no bookings herself; Theo does.
        try await model.updateMember(MemberUpdate(bookable: false), for: try XCTUnwrap(model.member(withID: maya)))
        let created = try await model.createInvite(role: .creator, email: nil)
        try await model.addPretendTeammate(accepting: created.invite, named: "Theo")
        let theo = try XCTUnwrap(model.teamMembers.first { $0.displayName == "Theo" })

        // Hours, a contract, a signer and a service.
        var hours = AvailabilitySettings.standard(timeZone: TestClock.timeZone)
        hours.bufferMinutes = 30
        try await model.saveAvailability(hours)
        let template = try await model.addStarterTemplate(.videography)
        try await model.saveCreatorSignature(ContractFixtures.creatorSignature(name: "Maya Chen"))
        try await model.designateSigner(maya, title: "Owner")
        XCTAssertTrue(model.hasCreatorSignature, "A named signer is what lets a company's contracts be signed")
        var package = model.makeNewPackage()
        package.name = "Brand film"
        package.category = .corporate
        package.priceCents = 200_000
        package.depositCents = 50_000
        package.durationMinutes = 60
        package.deliverables = ["A 2 minute film"]
        package.contractTemplateID = template.id
        package.isPublished = true
        try await model.savePackage(package)
        let saved = try XCTUnwrap(model.packages.first)

        // A client books the company.
        let start = TestClock.date(2027, 1, 6, 10, 0)
        _ = try await ContractFixtures.signedBooking(
            backend,
            BookingRequest(creatorID: company.id, packageID: saved.id, addOnIDs: [], startAt: start, notes: "", memberID: nil),
            clientID: UUID(), name: "Alex Rivera", pay: true
        )
        try await model.loadOwnerData()

        let booking = try XCTUnwrap(model.visibleBookings.first)
        XCTAssertEqual(model.visibleBookings.count, 1)
        XCTAssertEqual(booking.creatorID, company.id)
        XCTAssertEqual(booking.assignedTo, theo.userID, "With automatic assignment the booking goes to the person who takes them")
        XCTAssertTrue(model.isMine(booking))
        XCTAssertEqual(model.counterpartName(for: booking), "Alex Rivera")
        XCTAssertTrue(model.assignmentQueue.isEmpty)

        await model.switchAccount(to: .personal)
        XCTAssertTrue(model.visibleBookings.isEmpty, "It's the company's, and Theo's, not Maya's")
    }
}
