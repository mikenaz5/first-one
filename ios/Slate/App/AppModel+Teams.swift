import Foundation

/// A company invite the person is looking at, waiting for them to join or say no.
struct InviteOffer: Identifiable, Equatable {
    var token: String
    var preview: InvitePreview

    var id: String { token }
}

/// Everything about acting for a company: which account is showing, what the person's role allows, and the team
/// actions. The backend checks every one of them against the role; the app only hides what a role can't use.
extension AppModel {
    // MARK: - Who is acting

    /// Whose services, hours, contract templates, portfolio and payment account are on screen: the person's own, or
    /// the company's when one is showing. Bookings, payments and messages always belong to the person.
    var ownerID: UUID? {
        switch activeAccount {
        case .personal: session?.userID
        case .company(let id): id
        }
    }

    var isCompanyActive: Bool { organization != nil }

    /// The person's role in the company on screen, if one is.
    var myRole: OrgRole? { organization?.myRole }

    /// Whether the active account lets the person do this. A person's own account is theirs, so it allows everything.
    func can(_ permission: OrgPermission) -> Bool {
        guard let organization else { return true }
        return organization.can(permission)
    }

    /// True when the company on screen has no active plan, so what needs one is switched off for now.
    var isPlanLapsed: Bool {
        guard let organization else { return false }
        return organization.state == .lapsed
    }

    private var companyIDs: Set<UUID> { Set(accounts.companies.map(\.organizationID)) }

    /// Whether a booking is on the providing side for this person: theirs, assigned to them, or a company's they work for.
    func isProviderSide(_ booking: Booking) -> Bool {
        guard let me = session?.userID else { return false }
        return booking.isProviderFor(me) || companyIDs.contains(booking.creatorID)
    }

    /// The bookings that belong on screen for the active account. A company shows its own (as much as the role lets
    /// the person see); the person's own account shows what they booked and the work that is theirs, including jobs a
    /// company has given them.
    var visibleBookings: [Booking] {
        guard let me = session?.userID else { return [] }
        switch activeAccount {
        case .company(let id):
            return bookings.filter { $0.creatorID == id }
        case .personal:
            return bookings.filter { $0.clientID == me || $0.isProviderFor(me) }
        }
    }

    /// Bookings waiting for someone to be put on them, for the badge on the company's home.
    var unassignedCount: Int { assignmentQueue.count }

    /// Who a company booking is with, for its row. Nil outside a company or while it waits for someone.
    func assigneeName(for booking: Booking) -> String? {
        guard let assignee = booking.assignedTo, booking.creatorID != assignee else { return nil }
        if assignee == session?.userID { return "You" }
        return member(withID: assignee)?.displayName ?? "A teammate"
    }

    /// Whether the person may choose who takes this booking: their role in the company it belongs to allows it.
    func canAssign(_ booking: Booking) -> Bool {
        guard let company = accounts.companies.first(where: { $0.organizationID == booking.creatorID }) else { return false }
        return company.state == .active && company.role.allows(.bookingsAssign)
    }

    /// Whether the person may cancel, deliver and otherwise run this booking: it is theirs, or their role in the company
    /// it belongs to lets them (everything for a Manager and up; their own bookings for a Creator).
    func canManage(_ booking: Booking) -> Bool {
        guard let me = session?.userID else { return false }
        if booking.clientID == me || booking.creatorID == me { return true }
        guard let company = accounts.companies.first(where: { $0.organizationID == booking.creatorID }) else {
            return booking.assignedTo == me
        }
        if company.role.allows(.bookingsManage) { return true }
        return booking.assignedTo == me && company.role.allows(.bookingsManageAssigned)
    }

    /// The company's people as a client would see them, for previewing its page.
    var publicTeam: [PublicTeamMember] {
        teamMembers
            .filter { $0.listed && $0.bookable }
            .map {
                PublicTeamMember(
                    userID: $0.userID, displayName: $0.displayName, handle: $0.handle, avatarURL: $0.avatarURL,
                    bio: "", specialties: [], title: $0.title
                )
            }
    }

    // MARK: - Switching accounts

    /// Moves to the person's own account or one of their companies, the way Apple's apps switch accounts.
    func switchAccount(to target: ActiveAccount) async {
        guard let session, target != activeAccount else { return }
        switch target {
        case .personal:
            guard personalProfile != nil else { return }
        case .company(let id):
            guard companyIDs.contains(id) else { return }
        }
        let previous = activeAccount
        activeAccount = target
        clearActiveAccountData()
        do {
            try await loadOwnerData()
        } catch {
            activeAccount = previous
            clearActiveAccountData()
            try? await loadOwnerData()
            show(error, title: "Couldn't switch accounts")
            return
        }
        remember(activeAccount, for: session.userID)
        bookingsPath = []
        bookingsChanged()
    }

    private func remember(_ account: ActiveAccount, for userID: UUID) {
        UserDefaults.standard.set(account.storageValue, forKey: AppConfig.activeAccountKey(for: userID))
    }

    /// Empties what belongs to one account, so another's never shows while it loads.
    private func clearActiveAccountData() {
        portfolio = []
        packages = []
        availability = nil
        contractTemplates = []
        paymentAccount = nil
        organization = nil
        teamMembers = []
        teamInvites = []
        assignmentQueue = []
        packageMembers = [:]
    }

    /// Makes a company the account on screen and loads it. Used after starting, upgrading to or joining one.
    private func enter(_ company: Organization, location: CreatorLocation?, avatarJPEG: Data?) async throws {
        guard let session else { throw SlateError.notSignedIn }
        personalProfile = (try? await backend.loadProfile(for: session.userID)) ?? personalProfile
        accounts = (try? await backend.loadAccounts(for: session.userID)) ?? accounts
        activeAccount = .company(company.id)
        remember(activeAccount, for: session.userID)
        clearActiveAccountData()
        try await loadOwnerData()
        if location != nil || avatarJPEG != nil, var page = profile {
            if let location { page.location = location }
            // The company exists whether or not this works, and the page can be edited from its profile.
            if let saved = try? await backend.saveProfile(page, avatarJPEG: avatarJPEG) { profile = saved }
        }
        bookingsPath = []
        bookingsChanged()
        updatePhase()
    }

    /// Goes back to the person's own account after leaving, closing or downgrading the company on screen.
    private func returnToPersonal() async throws {
        guard let session else { throw SlateError.notSignedIn }
        personalProfile = (try? await backend.loadProfile(for: session.userID)) ?? personalProfile
        accounts = (try? await backend.loadAccounts(for: session.userID)) ?? accounts
        activeAccount = .personal
        remember(activeAccount, for: session.userID)
        clearActiveAccountData()
        try await loadOwnerData()
        bookingsPath = []
        bookingsChanged()
        updatePhase()
    }

    /// After leaving or closing a company: if it was the one on screen, go back to being yourself.
    private func afterLeaving(_ companyID: UUID) async throws {
        if activeAccount.companyID == companyID {
            try await returnToPersonal()
        } else if let session {
            accounts = (try? await backend.loadAccounts(for: session.userID)) ?? accounts
        }
    }

    // MARK: - Starting, upgrading and ending a company

    /// Starts a company from nothing and opens it.
    @discardableResult
    func createCompany(_ draft: OrganizationDraft, location: CreatorLocation?, avatarJPEG: Data?) async throws -> Organization {
        guard let session else { throw SlateError.notSignedIn }
        let company = try await backend.createOrganization(withOwnerName(draft), by: session.userID)
        try await enter(company, location: location, avatarJPEG: avatarJPEG)
        return company
    }

    /// Turns the person's individual account into a company. Services and contract templates move with it; bookings and
    /// signed contracts stay where they are.
    @discardableResult
    func upgradeToCompany(_ draft: OrganizationDraft, location: CreatorLocation?, avatarJPEG: Data?) async throws -> Organization {
        guard let session else { throw SlateError.notSignedIn }
        let company = try await backend.upgradeToCompany(withOwnerName(draft), by: session.userID)
        try await enter(company, location: location, avatarJPEG: avatarJPEG)
        return company
    }

    private func withOwnerName(_ draft: OrganizationDraft) -> OrganizationDraft {
        var named = draft
        if named.ownerDisplayName == nil {
            let name = personalProfile?.displayName ?? session?.fullName ?? ""
            named.ownerDisplayName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name
        }
        return named
    }

    /// The other way: the Owner, alone with nothing coming up, goes back to an individual account.
    func downgradeToIndividual() async throws {
        let (company, me) = try activeCompanyAndUser()
        try await backend.downgradeToIndividual(organizationID: company, by: me)
        try await returnToPersonal()
    }

    func closeCompany() async throws {
        let (company, me) = try activeCompanyAndUser()
        try await backend.closeOrganization(company, by: me)
        try await afterLeaving(company)
    }

    func leaveCompany(_ id: UUID) async throws {
        guard let session else { throw SlateError.notSignedIn }
        try await backend.leaveOrganization(id, by: session.userID)
        try await afterLeaving(id)
    }

    // MARK: - The company's settings

    @discardableResult
    func updateCompany(_ update: OrganizationUpdate) async throws -> Organization {
        let (company, me) = try activeCompanyAndUser()
        let saved = try await backend.updateOrganization(company, with: update, by: me)
        organization = saved
        await loadTeam()
        return saved
    }

    @discardableResult
    func setSplit(enabled: Bool) async throws -> Organization {
        let (company, me) = try activeCompanyAndUser()
        let saved = try await backend.setSplitEnabled(enabled, organizationID: company, by: me)
        organization = saved
        await loadTeam()
        return saved
    }

    /// Names who countersigns the company's contracts. They need a saved signature of their own.
    @discardableResult
    func designateSigner(_ userID: UUID, title: String) async throws -> Organization {
        let (company, me) = try activeCompanyAndUser()
        let saved = try await backend.designateSigner(userID: userID, title: title, organizationID: company, by: me)
        organization = saved
        await loadTeam()
        return saved
    }

    func transferOwnership(to member: TeamMember) async throws {
        let (company, me) = try activeCompanyAndUser()
        try await backend.transferOwnership(organizationID: company, to: member.userID, by: me)
        await reloadCompany()
    }

    // MARK: - People

    func setRole(_ role: OrgRole, for member: TeamMember) async throws {
        let (company, me) = try activeCompanyAndUser()
        try await backend.setMemberRole(role, memberID: member.userID, organizationID: company, by: me)
        await reloadCompany()
    }

    func updateMember(_ update: MemberUpdate, for member: TeamMember) async throws {
        let (company, me) = try activeCompanyAndUser()
        try await backend.updateMember(update, memberID: member.userID, organizationID: company, by: me)
        await reloadCompany()
    }

    func setShare(bps: Int, for member: TeamMember) async throws {
        let (company, me) = try activeCompanyAndUser()
        try await backend.setMemberShare(bps: bps, memberID: member.userID, organizationID: company, by: me)
        await reloadCompany()
    }

    /// Takes someone off the team. Their upcoming bookings go back to the queue.
    func removeMember(_ member: TeamMember) async throws {
        let (company, me) = try activeCompanyAndUser()
        try await backend.removeMember(memberID: member.userID, organizationID: company, by: me)
        await reloadCompany()
        bookings = (try? await backend.loadBookings(for: me)) ?? bookings
        bookingsChanged()
    }

    /// The person's own hours at the company (nil: the company's). They can only narrow the company's.
    func saveMyHours(_ hours: [DayHours]?) async throws {
        let (company, me) = try activeCompanyAndUser()
        try await backend.saveMyHours(hours, organizationID: company, by: me)
        await reloadCompany()
    }

    // MARK: - Invites

    func createInvite(role: OrgRole, email: String?) async throws -> CreatedInvite {
        let (company, me) = try activeCompanyAndUser()
        let created = try await backend.createInvite(role: role, email: email, organizationID: company, by: me)
        await reloadCompany()
        return created
    }

    func revokeInvite(_ invite: OrgInvite) async throws {
        let (company, me) = try activeCompanyAndUser()
        try await backend.revokeInvite(invite.id, organizationID: company, by: me)
        await reloadCompany()
    }

    /// A lost link is replaced, not recovered: the old one stops working and a new one is made.
    func resendInvite(_ invite: OrgInvite) async throws -> CreatedInvite {
        let (company, me) = try activeCompanyAndUser()
        let created = try await backend.resendInvite(invite.id, organizationID: company, by: me)
        await reloadCompany()
        return created
    }

    /// True on a device with no server, where a teammate can be added without a second phone.
    var canAddPretendTeammate: Bool { backend is LocalBackend }

    /// On-device only: a teammate accepting an invite, so a team can be tried alone.
    func addPretendTeammate(accepting invite: OrgInvite, named name: String) async throws {
        _ = try await backend.completeSimulatedJoin(inviteID: invite.id, displayName: name)
        await reloadCompany()
    }

    /// Opens an invite link once the person is signed in.
    func openPendingInviteIfNeeded() async {
        guard let session, phase == .ready || phase == .onboarding, let token = pendingInviteToken else { return }
        pendingInviteToken = nil
        do {
            let preview = try await backend.previewInvite(token: token, for: session.userID)
            if preview.alreadyMember {
                await switchAccount(to: .company(preview.organizationID))
            } else {
                presentedInvite = InviteOffer(token: token, preview: preview)
            }
        } catch {
            show(error, title: "Couldn't open that invite")
        }
    }

    /// Joins the company the invite is for, and opens it. Someone with no profile yet gives a name to go by.
    func acceptInvite(_ offer: InviteOffer, displayName: String?) async throws {
        guard let session else { throw SlateError.notSignedIn }
        let company = try await backend.acceptInvite(token: offer.token, displayName: displayName, by: session.userID)
        presentedInvite = nil
        try await enter(company, location: nil, avatarJPEG: nil)
    }

    func declineInvite() { presentedInvite = nil }

    // MARK: - Loading the company

    /// Loads what the role lets the person see. Each part that a role can't see stays empty rather than failing.
    func loadTeam() async {
        guard let session, let company = organization else { return }
        let me = session.userID
        teamMembers = (try? await backend.loadMembers(organizationID: company.id, for: me)) ?? []
        teamInvites = company.can(.teamInvite)
            ? ((try? await backend.loadInvites(organizationID: company.id, for: me)) ?? []) : []
        assignmentQueue = company.can(.bookingsAssign)
            ? ((try? await backend.loadAssignmentQueue(organizationID: company.id, for: me)) ?? []) : []
        var offered: [UUID: [UUID]] = [:]
        for package in packages {
            offered[package.id] = (try? await backend.loadPackageMembers(packageID: package.id)) ?? []
        }
        packageMembers = offered
    }

    /// Reads the company, its people and the person's own bookings again, after something changed.
    func reloadCompany() async {
        guard let session, let id = activeAccount.companyID else { return }
        do {
            organization = try await backend.loadOrganization(id, for: session.userID)
        } catch SlateError.notFound {
            // Removed from it, or it was closed.
            try? await returnToPersonal()
            return
        } catch {
            // Keep what is on screen; the next refresh will try again.
        }
        accounts = (try? await backend.loadAccounts(for: session.userID)) ?? accounts
        await loadTeam()
    }

    private func activeCompanyAndUser() throws -> (UUID, UUID) {
        guard let session else { throw SlateError.notSignedIn }
        guard let id = activeAccount.companyID else { throw SlateError.notFound }
        return (id, session.userID)
    }

    /// The person on the team with this id, if the role lets the person see the team.
    func member(withID id: UUID?) -> TeamMember? {
        guard let id else { return nil }
        return teamMembers.first { $0.userID == id }
    }

    /// Who takes bookings for a service: the people chosen for it, or everyone who takes bookings.
    func offeredBy(_ package: ServicePackage) -> [TeamMember] {
        let chosen = packageMembers[package.id] ?? []
        let bookable = teamMembers.filter { $0.bookable && $0.role.canTakeBookings }
        return chosen.isEmpty ? bookable : bookable.filter { chosen.contains($0.userID) }
    }

    func setPackageMembers(_ ids: [UUID], for package: ServicePackage) async throws {
        let (_, me) = try activeCompanyAndUser()
        try await backend.setPackageMembers(ids, packageID: package.id, by: me)
        packageMembers[package.id] = ids
    }

    // MARK: - Assigning bookings

    func assignmentOptions(for booking: Booking) async throws -> [AssignmentOption] {
        guard let session else { throw SlateError.notSignedIn }
        return try await backend.loadAssignmentOptions(bookingID: booking.id, for: session.userID)
    }

    /// Gives a booking to a person (or moves it to someone else).
    func assign(_ booking: Booking, to member: UUID) async throws {
        guard let session else { throw SlateError.notSignedIn }
        let updated = try await backend.assignBooking(booking.id, to: member, by: session.userID)
        if let index = bookings.firstIndex(where: { $0.id == updated.id }) {
            bookings[index] = updated
        } else {
            bookings.append(updated)
        }
        assignmentQueue.removeAll { $0.id == updated.id }
        bookingsChanged()
    }

    // MARK: - Calendar, activity and billing

    func loadTeamCalendar(from: Date, to: Date, members: Set<UUID> = []) async throws -> TeamCalendar {
        let (company, me) = try activeCompanyAndUser()
        return try await backend.loadTeamCalendar(organizationID: company, from: from, to: to, members: members, for: me)
    }

    func loadActivity(before: Date? = nil, limit: Int = 50) async throws -> [ActivityEntry] {
        let (company, me) = try activeCompanyAndUser()
        return try await backend.loadActivity(organizationID: company, limit: limit, before: before, for: me)
    }

    func loadBilling() async throws -> BillingOverview {
        let (company, me) = try activeCompanyAndUser()
        return try await backend.loadBilling(organizationID: company, for: me)
    }

    /// What adding (`delta` > 0) or removing people does to the bill, for the sheet that asks first.
    func previewSeatChange(delta: Int) async throws -> SeatPlan {
        let (company, me) = try activeCompanyAndUser()
        return try await backend.previewSeatChange(delta: delta, organizationID: company, for: me)
    }

    /// A Stripe-hosted page to start the plan or manage it, to open in a web authentication session.
    func beginBilling(_ action: BillingAction) async throws -> URL {
        let (company, me) = try activeCompanyAndUser()
        return try await backend.beginBilling(action, organizationID: company, by: me)
    }

    /// Back from Stripe's billing pages: see where the plan stands now.
    func billingReturned() async {
        await reloadCompany()
    }

    /// Opens a link to join a company (`slate://join/<token>`).
    func openInviteLink(token: String) {
        pendingInviteToken = token
        Task { await openPendingInviteIfNeeded() }
    }
}
