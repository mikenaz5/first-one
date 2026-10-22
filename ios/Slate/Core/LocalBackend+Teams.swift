import Foundation

/// Companies for the on-device backend: the company, its people, invites and activity log.
///
/// It follows `…_organizations.sql` and `…_company_booking.sql` rule for rule (the same checks in the same order, with
/// the same errors), so the whole of company accounts can be tried with no server, and the same tests describe both.
/// One difference that can't be avoided: there is one signed-in person on a device, so a teammate accepting an invite
/// is simulated (`completeSimulatedJoin`), the way a payment is.
///
/// Who is acting. Most methods are told who is calling. The few that aren't (saving a service, a contract template,
/// the hours, the company profile) act for the person signed in on this device, which `authorizeOwner` looks up. Only a
/// company's are checked: on a device only one person uses, a person's own need no check.
extension LocalBackend {
    // MARK: - Stored shapes

    struct StoredMember: Codable, Equatable {
        var userID: UUID
        var role: OrgRole
        var title: String
        var listed: Bool
        var bookable: Bool
        var shareBps: Int
        var joinedAt: Date
        var removedAt: Date?
        /// Their own hours, narrowing the company's. Nil means the company's.
        var weekly: [DayHours]?
    }

    struct StoredInvite: Codable, Equatable {
        enum State: String, Codable {
            case pending, accepted, revoked
        }

        var id: UUID
        var role: OrgRole
        var email: String?
        var tokenHash: String
        var invitedBy: UUID
        var createdAt: Date
        var expiresAt: Date
        var state: State
    }

    struct StoredOrganization: Codable, Equatable {
        var id: UUID
        var legalName: String
        var legalAddress: String
        var assignmentMode: AssignmentMode
        var signerRoles: [OrgRole]
        var signerUserID: UUID?
        var signerTitle: String
        var splitEnabled: Bool
        var state: OrgState
        var createdBy: UUID
        var createdAt: Date
        var members: [StoredMember]
        var invites: [StoredInvite]
        /// Oldest first.
        var activity: [ActivityEntry]
        /// Package id (lowercase) to the people who offer it. A package with no entry is offered by everyone.
        var packageMembers: [String: [UUID]]
    }

    // MARK: - Reading and writing

    var organizationsURL: URL { root.appendingPathComponent("organizations.json") }

    func readOrganizations() -> [StoredOrganization] {
        read([StoredOrganization].self, from: organizationsURL) ?? []
    }

    func readOrganization(_ id: UUID) -> StoredOrganization? {
        readOrganizations().first { $0.id == id }
    }

    /// Reads one company, lets `body` change it, and saves it. If `body` throws, nothing is saved.
    @discardableResult
    func mutateOrganization<T>(_ id: UUID, _ body: (inout StoredOrganization) throws -> T) throws -> T {
        var all = readOrganizations()
        guard let index = all.firstIndex(where: { $0.id == id }) else { throw SlateError.notFound }
        let result = try body(&all[index])
        try write(all, to: organizationsURL)
        return result
    }

    /// Stored dates are whole seconds, so use whole seconds: what this returns then equals what is read back later.
    var stamp: Date {
        Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
    }

    func currentUserID() -> UUID? {
        read(AuthSession.self, from: sessionURL)?.userID
    }

    /// On-device only: from now on the person using this device is this one, as if they had signed in. A team has several
    /// people and a device has one, so this is how a teammate's view is tried, and how tests are anyone they need.
    func actAs(_ userID: UUID) throws {
        let previous = read(AuthSession.self, from: sessionURL)
        let keep = previous?.userID == userID
        try write(AuthSession(
            userID: userID, appleUserID: keep ? previous?.appleUserID : nil, email: keep ? previous?.email : nil,
            fullName: keep ? previous?.fullName : nil
        ), to: sessionURL)
    }

    func personName(_ userID: UUID?) -> String {
        guard let userID, let stored = read(StoredProfile.self, from: profileURL(userID)) else { return "" }
        return stored.displayName
    }

    func activeMember(_ org: StoredOrganization, _ userID: UUID) -> StoredMember? {
        org.members.first { $0.userID == userID && $0.removedAt == nil }
    }

    func activeMembers(_ org: StoredOrganization) -> [StoredMember] {
        org.members.filter { $0.removedAt == nil }
    }

    func permits(_ org: StoredOrganization, _ userID: UUID, _ permission: OrgPermission) -> Bool {
        guard let member = activeMember(org, userID) else { return false }
        return RoleRules.allows(permission, role: member.role, state: org.state)
    }

    /// Whether a company's services, templates, hours and profile may be changed by the person signed in on this device.
    func authorizeOwner(_ ownerID: UUID, _ permission: OrgPermission) throws {
        guard let org = readOrganization(ownerID) else { return }
        guard let actor = currentUserID() else { throw SlateError.notSignedIn }
        guard permits(org, actor, permission) else { throw SlateError.notAllowed }
    }

    /// A company the caller belongs to, or `notFound`: like the database, a stranger can't tell it exists.
    func memberOrganization(_ id: UUID, _ userID: UUID) throws -> StoredOrganization {
        guard let org = readOrganization(id), activeMember(org, userID) != nil else { throw SlateError.notFound }
        return org
    }

    /// Adds a line to the activity log.
    func addActivity(_ org: inout StoredOrganization, actor: UUID?, _ action: String, _ summary: String) {
        org.activity.append(ActivityEntry(
            id: UUID(), actorID: actor, actorName: personName(actor), action: action, summary: summary, createdAt: stamp
        ))
    }

    /// Owners first, then by name: how every list of people is ordered.
    private func order(_ role: OrgRole, _ name: String, _ id: UUID) -> String {
        "\(roleRank(role))|\(name.lowercased())|\(id.uuidString.lowercased())"
    }

    private func roleRank(_ role: OrgRole) -> Int {
        switch role {
        case .owner: 0
        case .admin: 1
        case .manager: 2
        case .creator: 3
        case .viewer: 4
        }
    }

    private func name(of userID: UUID, fallback: String) -> String {
        let found = personName(userID)
        return found.isEmpty ? fallback : found
    }

    // MARK: - Making the public shapes

    func seatCounts(_ org: StoredOrganization) -> SeatCounts {
        let used = activeMembers(org).count
        let pending = org.invites.filter { $0.state == .pending && $0.expiresAt > now }.count
        return SeatCounts(used: used, pending: pending, billed: max(teamConfig.seatMinimum, used),
                          minimum: teamConfig.seatMinimum, maximum: teamConfig.seatMaximum)
    }

    func makeOrganization(_ org: StoredOrganization, for userID: UUID) throws -> Organization {
        guard let me = activeMember(org, userID), let stored = read(StoredProfile.self, from: profileURL(org.id)) else {
            throw SlateError.notFound
        }
        let profile = makeProfile(stored, userID: org.id)
        return Organization(
            id: org.id, name: profile.displayName, handle: profile.handle, avatarURL: profile.avatarURL, bio: profile.bio,
            locationName: profile.location?.name, specialties: profile.specialties,
            legalName: org.legalName, legalAddress: org.legalAddress, assignmentMode: org.assignmentMode,
            signerRoles: org.signerRoles, signerUserID: org.signerUserID, signerTitle: org.signerTitle,
            splitEnabled: org.splitEnabled, state: org.state, myRole: me.role, myTitle: me.title, myHours: me.weekly,
            seats: seatCounts(org), plan: .notRequired
        )
    }

    func makeMember(_ member: StoredMember, in org: StoredOrganization, showMoney: Bool) -> TeamMember {
        let stored = read(StoredProfile.self, from: profileURL(member.userID))
        return TeamMember(
            userID: member.userID, role: member.role, title: member.title, listed: member.listed, bookable: member.bookable,
            shareBps: showMoney ? member.shareBps : 0, joinedAt: member.joinedAt, displayName: stored?.displayName ?? "",
            handle: stored?.handle,
            avatarURL: stored?.avatarFile.map { userDirectory(member.userID).appendingPathComponent($0) },
            isSigner: org.signerUserID == member.userID
        )
    }

    /// The people clients may book from a company's page.
    func publicTeam(_ org: StoredOrganization) -> [PublicTeamMember] {
        let listed = activeMembers(org).filter { $0.listed && $0.bookable }
        let ordered = listed.sorted { order($0.role, personName($0.userID), $0.userID) < order($1.role, personName($1.userID), $1.userID) }
        return ordered
            .compactMap { member in
                guard let stored = read(StoredProfile.self, from: profileURL(member.userID)) else { return nil }
                return PublicTeamMember(
                    userID: member.userID, displayName: stored.displayName, handle: stored.handle,
                    avatarURL: stored.avatarFile.map { userDirectory(member.userID).appendingPathComponent($0) },
                    bio: stored.bio, specialties: stored.specialties, title: member.title
                )
            }
    }

    // MARK: - Accounts

    func loadTeamConfig() async throws -> TeamConfig { teamConfig }

    func loadAccounts(for userID: UUID) async throws -> AccountList {
        let mine = read(StoredProfile.self, from: profileURL(userID))
        let hasPersonal = mine != nil && (mine?.kind ?? .person) == .person
        var companies: [CompanyAccount] = []
        for org in readOrganizations() where org.state != .closed {
            guard let member = activeMember(org, userID), let stored = read(StoredProfile.self, from: profileURL(org.id)) else { continue }
            let profile = makeProfile(stored, userID: org.id)
            companies.append(CompanyAccount(
                organizationID: org.id, name: profile.displayName, handle: profile.handle, avatarURL: profile.avatarURL,
                role: member.role, title: member.title, state: org.state
            ))
        }
        return AccountList(hasPersonalProfile: hasPersonal, companies: companies)
    }

    // MARK: - Starting a company

    /// A person's own profile is what shows beside their name on a team. Make a minimal one if they have none.
    func ensurePersonProfile(_ userID: UUID, displayName: String?) throws {
        if read(StoredProfile.self, from: profileURL(userID)) != nil { return }
        let session = read(AuthSession.self, from: sessionURL)
        let supplied = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fallback = session?.userID == userID ? (session?.fullName ?? "") : ""
        let name = !supplied.isEmpty ? supplied : (!fallback.isEmpty ? fallback : "Member")

        var base = String(HandleRules.normalize(name).prefix(24))
        if HandleRules.validate(base) != nil { base = "member" }
        var handle = base
        var attempt = 1
        while HandleRules.validate(handle) != nil || isHandleTaken(handle, excluding: userID) {
            attempt += 1
            handle = "\(base)-\(attempt)"
        }
        let created = stamp
        try fileManager.createDirectory(at: userDirectory(userID), withIntermediateDirectories: true)
        try write(StoredProfile(
            id: userID, handle: handle, displayName: String(name.prefix(80)), bio: "", specialties: [], location: nil,
            avatarFile: nil, createdAt: created, updatedAt: created, kind: nil
        ), to: profileURL(userID))
    }

    private func validate(_ draft: OrganizationDraft) throws {
        if draft.problem != nil { throw SlateError.invalidInput }
    }

    private func makeNewOrganization(
        _ draft: OrganizationDraft, owner: UUID, bio: String, specialties: [Specialty], location: CreatorLocation?
    ) throws -> StoredOrganization {
        let handle = draft.handle.lowercased()
        let id = UUID()
        guard !isHandleTaken(handle, excluding: id) else { throw SlateError.handleTaken }

        let created = stamp
        let displayName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        try fileManager.createDirectory(at: userDirectory(id), withIntermediateDirectories: true)
        try write(StoredProfile(
            id: id, handle: handle, displayName: displayName, bio: bio, specialties: specialties, location: location,
            avatarFile: nil, createdAt: created, updatedAt: created, kind: .company
        ), to: profileURL(id))

        var org = StoredOrganization(
            id: id, legalName: draft.legalName.trimmingCharacters(in: .whitespacesAndNewlines),
            legalAddress: draft.legalAddress.trimmingCharacters(in: .whitespacesAndNewlines),
            assignmentMode: .auto, signerRoles: [.owner, .admin], signerUserID: nil, signerTitle: "", splitEnabled: false,
            state: .active, createdBy: owner, createdAt: created,
            members: [StoredMember(userID: owner, role: .owner, title: "", listed: true, bookable: true, shareBps: 0,
                                   joinedAt: created, removedAt: nil, weekly: nil)],
            invites: [], activity: [], packageMembers: [:]
        )
        addActivity(&org, actor: owner, "org.created", "Created \(displayName)")
        var all = readOrganizations()
        all.append(org)
        try write(all, to: organizationsURL)
        return org
    }

    func createOrganization(_ draft: OrganizationDraft, by userID: UUID) async throws -> Organization {
        try validate(draft)
        try ensurePersonProfile(userID, displayName: draft.ownerDisplayName)
        let org = try makeNewOrganization(draft, owner: userID, bio: draft.bio, specialties: draft.specialties, location: nil)
        return try makeOrganization(org, for: userID)
    }

    func upgradeToCompany(_ draft: OrganizationDraft, by userID: UUID) async throws -> Organization {
        try validate(draft)
        guard let me = read(StoredProfile.self, from: profileURL(userID)), (me.kind ?? .person) == .person else {
            throw SlateError.profileRequired
        }
        // A client paying a deposit must never find a booking half moved.
        try expireLapsedHolds()
        let now = self.now
        if readBookings().contains(where: { $0.creatorID == userID && $0.status == .held && ($0.holdExpiresAt ?? .distantPast) > now }) {
            throw SlateError.bookingsInHold
        }

        let org = try makeNewOrganization(draft, owner: userID, bio: me.bio, specialties: me.specialties, location: me.location)

        // The company starts with the person's own hours and rules.
        if let hours = read(AvailabilitySettings.self, from: availabilityURL(userID)) {
            try write(hours, to: availabilityURL(org.id))
        }
        // Services and contract templates move. Bookings and signed contracts stay where they are.
        var packages = readPackages(userID)
        for index in packages.indices { packages[index].creatorID = org.id }
        var templates = readTemplates(userID)
        for index in templates.indices { templates[index].creatorID = org.id }
        try write(packages, to: packagesURL(org.id))
        try write(templates, to: templatesURL(org.id))
        try? fileManager.removeItem(at: packagesURL(userID))
        try? fileManager.removeItem(at: templatesURL(userID))

        let services = packages.count
        let contracts = templates.count
        try mutateOrganization(org.id) { stored in
            self.addActivity(&stored, actor: userID, "org.upgraded",
                             "Upgraded from an individual account: moved \(services) \(services == 1 ? "service" : "services") and \(contracts) contract \(contracts == 1 ? "template" : "templates")")
        }
        return try makeOrganization(try memberOrganization(org.id, userID), for: userID)
    }

    func downgradeToIndividual(organizationID: UUID, by userID: UUID) async throws {
        let org = try memberOrganization(organizationID, userID)
        guard permits(org, userID, .companyDelete) else { throw SlateError.notAllowed }
        guard activeMembers(org).count == 1 else { throw SlateError.teamNotEmpty }
        try expireLapsedHolds()
        let now = self.now
        if readBookings().contains(where: { $0.creatorID == org.id && $0.status.blocksTime && $0.endAt > now }) {
            throw SlateError.hasUpcomingBookings
        }
        var packages = readPackages(org.id)
        for index in packages.indices { packages[index].creatorID = userID }
        var templates = readTemplates(org.id)
        for index in templates.indices { templates[index].creatorID = userID }
        try fileManager.createDirectory(at: userDirectory(userID), withIntermediateDirectories: true)
        try write(packages, to: packagesURL(userID))
        try write(templates, to: templatesURL(userID))
        try? fileManager.removeItem(at: packagesURL(org.id))
        try? fileManager.removeItem(at: templatesURL(org.id))
        try mutateOrganization(org.id) { stored in
            stored.packageMembers = [:]
            self.addActivity(&stored, actor: userID, "org.downgraded", "Went back to an individual account")
        }
        try closeRecord(org.id, by: userID)
    }

    // MARK: - The company's settings

    func loadOrganization(_ id: UUID, for userID: UUID) async throws -> Organization {
        try makeOrganization(try memberOrganization(id, userID), for: userID)
    }

    func updateOrganization(_ id: UUID, with update: OrganizationUpdate, by userID: UUID) async throws -> Organization {
        let org = try memberOrganization(id, userID)
        guard permits(org, userID, .companyEdit) else { throw SlateError.notAllowed }
        // Widening who may sign for the company is the Owner's call.
        if let roles = update.signerRoles, Set(roles) != Set(org.signerRoles), activeMember(org, userID)?.role != .owner {
            throw SlateError.notAllowed
        }
        if let legal = update.legalName, !legal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !TeamRules.legalNameLength.contains(legal.trimmingCharacters(in: .whitespacesAndNewlines).count) {
            throw SlateError.invalidInput
        }
        if let address = update.legalAddress, address.trimmingCharacters(in: .whitespacesAndNewlines).count > TeamRules.legalAddressLimit {
            throw SlateError.invalidInput
        }
        if let roles = update.signerRoles, roles.contains(.viewer) { throw SlateError.invalidInput }

        try mutateOrganization(id) { stored in
            var changed: [String] = []
            if let legal = update.legalName?.trimmingCharacters(in: .whitespacesAndNewlines), !legal.isEmpty, legal != stored.legalName {
                stored.legalName = legal
                changed.append("legal name")
            }
            if let address = update.legalAddress?.trimmingCharacters(in: .whitespacesAndNewlines), address != stored.legalAddress {
                stored.legalAddress = address
                changed.append("legal address")
            }
            if let mode = update.assignmentMode, mode != stored.assignmentMode {
                stored.assignmentMode = mode
                changed.append("assignment: \(mode.rawValue)")
            }
            if let roles = update.signerRoles, Set(roles) != Set(stored.signerRoles) {
                stored.signerRoles = OrgRole.allCases.filter { roles.contains($0) }
                changed.append("signer roles")
            }
            if !changed.isEmpty {
                self.addActivity(&stored, actor: userID, "org.updated", "Changed company settings (\(changed.joined(separator: ", ")))")
            }
            self.revalidateSigner(&stored)
        }
        return try makeOrganization(try memberOrganization(id, userID), for: userID)
    }

    func setSplitEnabled(_ enabled: Bool, organizationID: UUID, by userID: UUID) async throws -> Organization {
        let org = try memberOrganization(organizationID, userID)
        guard permits(org, userID, .payoutsSplit) else { throw SlateError.notAllowed }
        try mutateOrganization(organizationID) { stored in
            guard stored.splitEnabled != enabled else { return }
            stored.splitEnabled = enabled
            self.addActivity(&stored, actor: userID, "org.split_changed",
                     enabled ? "Turned on the member split ledger" : "Turned off the member split ledger")
        }
        return try makeOrganization(try memberOrganization(organizationID, userID), for: userID)
    }

    /// If the person named to sign is no longer on the team, or their role no longer allows it, signing stops.
    func revalidateSigner(_ org: inout StoredOrganization) {
        guard let signer = org.signerUserID else { return }
        if let member = activeMember(org, signer), org.signerRoles.contains(member.role) { return }
        let who = name(of: signer, fallback: "the designated signer")
        org.signerUserID = nil
        org.signerTitle = ""
        addActivity(&org, actor: nil, "signer.cleared", "Auto-countersign stopped: \(who) can no longer sign for the company")
    }

    func designateSigner(userID: UUID, title: String, organizationID: UUID, by actorID: UUID) async throws -> Organization {
        let org = try memberOrganization(organizationID, actorID)
        guard permits(org, actorID, .signerDesignate) else { throw SlateError.notAllowed }
        guard let member = activeMember(org, userID) else { throw SlateError.notFound }
        guard org.signerRoles.contains(member.role) else { throw SlateError.signerRoleNotAllowed }
        guard let signature = read(CreatorSignature.self, from: signatureURL(userID)), SignatureRules.isValid(signature) else {
            throw SlateError.signatureRequired
        }
        guard title.count <= TeamRules.titleLimit else { throw SlateError.invalidInput }
        try mutateOrganization(organizationID) { stored in
            stored.signerUserID = userID
            stored.signerTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            self.addActivity(&stored, actor: actorID, "signer.designated",
                     "Named \(self.name(of: userID, fallback: "a member")) as the signer for company contracts")
        }
        return try makeOrganization(try memberOrganization(organizationID, actorID), for: actorID)
    }

    func transferOwnership(organizationID: UUID, to userID: UUID, by actorID: UUID) async throws {
        let org = try memberOrganization(organizationID, actorID)
        guard activeMember(org, actorID)?.role == .owner else { throw SlateError.notAllowed }
        guard userID != actorID, activeMember(org, userID) != nil else { throw SlateError.invalidInput }
        try mutateOrganization(organizationID) { stored in
            for index in stored.members.indices where stored.members[index].removedAt == nil {
                if stored.members[index].userID == actorID { stored.members[index].role = .admin }
                if stored.members[index].userID == userID {
                    stored.members[index].role = .owner
                    stored.members[index].bookable = true
                }
            }
            self.addActivity(&stored, actor: actorID, "org.ownership_transferred",
                     "Transferred ownership to \(self.name(of: userID, fallback: "a member"))")
            self.revalidateSigner(&stored)
        }
    }

    func closeOrganization(_ id: UUID, by userID: UUID) async throws {
        let org = try memberOrganization(id, userID)
        guard permits(org, userID, .companyDelete) else { throw SlateError.notAllowed }
        try expireLapsedHolds()
        let now = self.now
        if readBookings().contains(where: { $0.creatorID == id && $0.status.blocksTime && $0.endAt > now }) {
            throw SlateError.hasUpcomingBookings
        }
        try closeRecord(id, by: userID)
    }

    /// Closes a company: its signed contracts are kept because they name it, and everything else is let go.
    func closeRecord(_ id: UUID, by userID: UUID) throws {
        let stamp = self.stamp
        try mutateOrganization(id) { stored in
            self.addActivity(&stored, actor: userID, "org.closed", "Closed the company")
            for index in stored.members.indices where stored.members[index].removedAt == nil {
                stored.members[index].removedAt = stamp
            }
            for index in stored.invites.indices where stored.invites[index].state == .pending {
                stored.invites[index].state = .revoked
            }
            stored.state = .closed
            stored.signerUserID = nil
            stored.signerTitle = ""
        }
        // Services stop being sold, and the handle is free for someone else.
        var packages = readPackages(id)
        for index in packages.indices { packages[index].isPublished = false }
        if !packages.isEmpty { try write(packages, to: packagesURL(id)) }
        if var profile = read(StoredProfile.self, from: profileURL(id)) {
            profile.handle = "closed-" + String(id.uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8))
            try write(profile, to: profileURL(id))
        }
    }

    // MARK: - Members

    func loadMembers(organizationID: UUID, for userID: UUID) async throws -> [TeamMember] {
        let org = try memberOrganization(organizationID, userID)
        let showMoney = permits(org, userID, .payoutsSplit)
        let members = activeMembers(org).map { makeMember($0, in: org, showMoney: showMoney) }
        return members.sorted { order($0.role, $0.displayName, $0.userID) < order($1.role, $1.displayName, $1.userID) }
    }

    func setMemberRole(_ role: OrgRole, memberID: UUID, organizationID: UUID, by userID: UUID) async throws {
        let org = try memberOrganization(organizationID, userID)
        guard let actorRole = activeMember(org, userID)?.role, let current = activeMember(org, memberID)?.role else {
            throw SlateError.notFound
        }
        guard permits(org, userID, .teamManage) else { throw SlateError.notAllowed }
        guard role != .owner else { throw SlateError.invalidRole }
        guard memberID != userID, RoleRules.canAssign(actor: actorRole, current: current, new: role) else { throw SlateError.notAllowed }
        guard current != role else { return }
        try mutateOrganization(organizationID) { stored in
            guard let index = stored.members.firstIndex(where: { $0.userID == memberID && $0.removedAt == nil }) else { return }
            stored.members[index].role = role
            if role == .viewer {
                stored.members[index].bookable = false
            } else if current == .viewer {
                stored.members[index].bookable = true
            }
            self.addActivity(&stored, actor: userID, "member.role_changed",
                     "Changed \(self.name(of: memberID, fallback: "a member")) from \(current.rawValue) to \(role.rawValue)")
            self.revalidateSigner(&stored)
        }
    }

    func updateMember(_ update: MemberUpdate, memberID: UUID, organizationID: UUID, by userID: UUID) async throws {
        let org = try memberOrganization(organizationID, userID)
        guard let actorRole = activeMember(org, userID)?.role, let current = activeMember(org, memberID)?.role else {
            throw SlateError.notFound
        }
        guard permits(org, userID, .teamManage) else { throw SlateError.notAllowed }
        // You may edit yourself or anyone you could manage.
        if memberID != userID, !RoleRules.canManage(actor: actorRole, target: current) { throw SlateError.notAllowed }
        if update.bookable == true, current == .viewer { throw SlateError.invalidInput }
        if let title = update.title, title.trimmingCharacters(in: .whitespacesAndNewlines).count > TeamRules.titleLimit {
            throw SlateError.invalidInput
        }
        try mutateOrganization(organizationID) { stored in
            guard let index = stored.members.firstIndex(where: { $0.userID == memberID && $0.removedAt == nil }) else { return }
            if let title = update.title { stored.members[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let listed = update.listed { stored.members[index].listed = listed }
            if let bookable = update.bookable { stored.members[index].bookable = bookable }
            self.addActivity(&stored, actor: userID, "member.updated", "Updated \(self.name(of: memberID, fallback: "a member"))'s team profile")
        }
    }

    func setMemberShare(bps: Int, memberID: UUID, organizationID: UUID, by userID: UUID) async throws {
        let org = try memberOrganization(organizationID, userID)
        guard activeMember(org, memberID) != nil else { throw SlateError.notFound }
        guard permits(org, userID, .payoutsSplit) else { throw SlateError.notAllowed }
        guard TeamRules.isValidShare(bps) else { throw SlateError.invalidInput }
        try mutateOrganization(organizationID) { stored in
            guard let index = stored.members.firstIndex(where: { $0.userID == memberID && $0.removedAt == nil }) else { return }
            stored.members[index].shareBps = bps
            self.addActivity(&stored, actor: userID, "member.share_changed",
                     "Set \(self.name(of: memberID, fallback: "a member"))'s share to \(TeamRules.shareText(bps))")
        }
    }

    func removeMember(memberID: UUID, organizationID: UUID, by userID: UUID) async throws {
        let org = try memberOrganization(organizationID, userID)
        guard let actorRole = activeMember(org, userID)?.role, let current = activeMember(org, memberID)?.role else {
            throw SlateError.notFound
        }
        guard permits(org, userID, .teamManage) else { throw SlateError.notAllowed }
        if current == .owner { throw SlateError.lastOwner }
        guard memberID != userID, RoleRules.canManage(actor: actorRole, target: current) else { throw SlateError.notAllowed }
        try endMembership(organizationID, memberID, action: "member.removed", by: userID)
    }

    func leaveOrganization(_ id: UUID, by userID: UUID) async throws {
        let org = try memberOrganization(id, userID)
        if activeMember(org, userID)?.role == .owner { throw SlateError.lastOwner }
        try endMembership(id, userID, action: "member.left", by: userID)
    }

    /// Ends a membership. Their upcoming bookings go back to the queue and they stop offering any service.
    func endMembership(_ orgID: UUID, _ memberID: UUID, action: String, by actorID: UUID) throws {
        let stamp = self.stamp
        let now = self.now
        var bookings = readBookings()
        var returned = 0
        for index in bookings.indices where bookings[index].creatorID == orgID && bookings[index].assignedTo == memberID
            && bookings[index].status.blocksTime && bookings[index].endAt > now {
            bookings[index].assignedTo = nil
            bookings[index].assignedAt = nil
            bookings[index].assigneeShareBps = nil
            returned += 1
        }
        if returned > 0 { try write(bookings, to: bookingsURL) }
        try mutateOrganization(orgID) { stored in
            guard let index = stored.members.firstIndex(where: { $0.userID == memberID && $0.removedAt == nil }) else { return }
            stored.members[index].removedAt = stamp
            for key in Array(stored.packageMembers.keys) {
                stored.packageMembers[key] = (stored.packageMembers[key] ?? []).filter { $0 != memberID }
                if stored.packageMembers[key]?.isEmpty == true { stored.packageMembers[key] = nil }
            }
            let who = self.name(of: memberID, fallback: action == "member.left" ? "A member" : "a member")
            var line = action == "member.left" ? "\(who) left the team" : "Removed \(who) from the team"
            if returned > 0 { line += "; \(returned) \(returned == 1 ? "booking" : "bookings") returned to the assignment queue" }
            self.addActivity(&stored, actor: actorID, action, line)
            self.revalidateSigner(&stored)
        }
    }

    /// Used when an account is deleted: leave every company.
    func endAllMemberships(of userID: UUID) throws {
        for org in readOrganizations() where activeMember(org, userID) != nil {
            try endMembership(org.id, userID, action: "member.left", by: userID)
        }
    }

    func saveMyHours(_ hours: [DayHours]?, organizationID: UUID, by userID: UUID) async throws {
        let org = try memberOrganization(organizationID, userID)
        guard permits(org, userID, .calendarManageOwn) else { throw SlateError.notAllowed }
        if let hours {
            let valid = hours.count <= 7
                && hours.allSatisfy { (1...7).contains($0.weekday) && $0.window.isValid }
                && Set(hours.map(\.weekday)).count == hours.count
            guard valid else { throw SlateError.invalidInput }
        }
        try mutateOrganization(organizationID) { stored in
            guard let index = stored.members.firstIndex(where: { $0.userID == userID && $0.removedAt == nil }) else { return }
            stored.members[index].weekly = hours
        }
    }

    // MARK: - Invites

    func loadInvites(organizationID: UUID, for userID: UUID) async throws -> [OrgInvite] {
        let org = try memberOrganization(organizationID, userID)
        guard permits(org, userID, .teamInvite) else { throw SlateError.notAllowed }
        let now = self.now
        return org.invites
            .filter { $0.state == .pending }
            .sorted { $0.createdAt > $1.createdAt }
            .map { invite in
                OrgInvite(
                    id: invite.id, role: invite.role, email: invite.email, status: invite.expiresAt <= now ? .expired : .pending,
                    createdAt: invite.createdAt, expiresAt: invite.expiresAt,
                    invitedByName: personName(invite.invitedBy).isEmpty ? nil : personName(invite.invitedBy)
                )
            }
    }

    func createInvite(role: OrgRole, email: String?, organizationID: UUID, by userID: UUID) async throws -> CreatedInvite {
        let org = try memberOrganization(organizationID, userID)
        guard let actorRole = activeMember(org, userID)?.role else { throw SlateError.notFound }
        guard permits(org, userID, .teamInvite) else { throw SlateError.notAllowed }
        guard role != .owner else { throw SlateError.invalidRole }
        guard RoleRules.canAssign(actor: actorRole, current: .viewer, new: role) else { throw SlateError.notAllowed }
        let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanEmail = TeamRules.cleanInviteEmail(trimmed)
        if !trimmed.isEmpty, cleanEmail == nil { throw SlateError.invalidInput }
        guard org.state == .active else { throw SlateError.planInactive }
        let seats = seatCounts(org)
        guard seats.used + seats.pending < seats.maximum else { throw SlateError.seatLimit }

        let token = Self.newInviteToken()
        let created = stamp
        let invite = StoredInvite(
            id: UUID(), role: role, email: cleanEmail, tokenHash: Hashing.sha256Hex(token), invitedBy: userID,
            createdAt: created, expiresAt: created.addingTimeInterval(Double(teamConfig.inviteExpiryDays) * 86_400), state: .pending
        )
        try mutateOrganization(organizationID) { stored in
            stored.invites.append(invite)
            self.addActivity(&stored, actor: userID, "invite.created", "Invited \(cleanEmail ?? "someone") as \(role.rawValue)")
        }
        return CreatedInvite(
            invite: OrgInvite(id: invite.id, role: role, email: cleanEmail, status: .pending, createdAt: created,
                              expiresAt: invite.expiresAt, invitedByName: nil),
            token: token
        )
    }

    /// Two UUIDs' worth of randomness, as lowercase letters and digits.
    static func newInviteToken() -> String {
        (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    }

    func revokeInvite(_ id: UUID, organizationID: UUID, by userID: UUID) async throws {
        let org = try memberOrganization(organizationID, userID)
        guard let invite = org.invites.first(where: { $0.id == id }), let actorRole = activeMember(org, userID)?.role else {
            throw SlateError.notFound
        }
        guard permits(org, userID, .teamInvite) else { throw SlateError.notAllowed }
        // An Admin can't cancel an invite that would have made an Admin.
        guard RoleRules.canAssign(actor: actorRole, current: .viewer, new: invite.role) else { throw SlateError.notAllowed }
        guard invite.state == .pending else { throw SlateError.inviteInvalid }
        try mutateOrganization(organizationID) { stored in
            guard let index = stored.invites.firstIndex(where: { $0.id == id }) else { return }
            stored.invites[index].state = .revoked
            self.addActivity(&stored, actor: userID, "invite.revoked", "Cancelled the invite for \(invite.email ?? "someone")")
        }
    }

    func resendInvite(_ id: UUID, organizationID: UUID, by userID: UUID) async throws -> CreatedInvite {
        let org = try memberOrganization(organizationID, userID)
        guard let invite = org.invites.first(where: { $0.id == id }) else { throw SlateError.notFound }
        try await revokeInvite(id, organizationID: organizationID, by: userID)
        return try await createInvite(role: invite.role, email: invite.email, organizationID: organizationID, by: userID)
    }

    /// The pending, unexpired invite for a token in a company that can take people, or `inviteInvalid`.
    private func openInvite(token: String) throws -> (org: StoredOrganization, invite: StoredInvite) {
        let hash = Hashing.sha256Hex(token)
        let now = self.now
        for org in readOrganizations() {
            if let invite = org.invites.first(where: { $0.tokenHash == hash }) {
                guard invite.state == .pending, invite.expiresAt > now, org.state == .active else { throw SlateError.inviteInvalid }
                return (org, invite)
            }
        }
        throw SlateError.inviteInvalid
    }

    func previewInvite(token: String, for userID: UUID) async throws -> InvitePreview {
        let (org, invite) = try openInvite(token: token)
        let profile = read(StoredProfile.self, from: profileURL(org.id))
        let mine = read(StoredProfile.self, from: profileURL(userID))
        return InvitePreview(
            organizationID: org.id, organizationName: profile?.displayName ?? "", role: invite.role,
            invitedByName: personName(invite.invitedBy).isEmpty ? nil : personName(invite.invitedBy), expiresAt: invite.expiresAt,
            alreadyMember: activeMember(org, userID) != nil, hasProfile: mine != nil && (mine?.kind ?? .person) == .person
        )
    }

    func acceptInvite(token: String, displayName: String?, by userID: UUID) async throws -> Organization {
        let (org, invite) = try openInvite(token: token)
        if activeMember(org, userID) != nil { throw SlateError.alreadyMember }
        try ensurePersonProfile(userID, displayName: displayName)
        try join(org.id, invite: invite.id, userID: userID)
        return try makeOrganization(try memberOrganization(org.id, userID), for: userID)
    }

    private func join(_ orgID: UUID, invite inviteID: UUID, userID: UUID) throws {
        let stamp = self.stamp
        try mutateOrganization(orgID) { stored in
            guard let inviteIndex = stored.invites.firstIndex(where: { $0.id == inviteID }) else { throw SlateError.inviteInvalid }
            let role = stored.invites[inviteIndex].role
            stored.members.append(StoredMember(
                userID: userID, role: role, title: "", listed: true, bookable: role != .viewer, shareBps: 0,
                joinedAt: stamp, removedAt: nil, weekly: nil
            ))
            stored.invites[inviteIndex].state = .accepted
            self.addActivity(&stored, actor: userID, "member.joined", "\(self.name(of: userID, fallback: "Someone")) joined as \(role.rawValue)")
        }
    }

    func completeSimulatedJoin(inviteID: UUID, displayName: String) async throws -> UUID {
        guard let org = readOrganizations().first(where: { company in company.invites.contains { $0.id == inviteID } }),
              let invite = org.invites.first(where: { $0.id == inviteID }),
              invite.state == .pending, invite.expiresAt > now, org.state == .active
        else { throw SlateError.inviteInvalid }

        let userID = UUID()
        var accounts = read([String: UUID].self, from: accountsURL) ?? [:]
        accounts["simulated:\(userID.uuidString.lowercased())"] = userID
        try write(accounts, to: accountsURL)
        try ensurePersonProfile(userID, displayName: displayName)
        try join(org.id, invite: inviteID, userID: userID)
        return userID
    }

    // MARK: - What happens to a company's work

    /// Adds a line to a company's log. A person's own work has no log, so this does nothing for them.
    func recordForCompany(_ ownerID: UUID, actor: UUID?, _ action: String, _ summary: String) {
        guard readOrganization(ownerID) != nil else { return }
        try? mutateOrganization(ownerID) { stored in
            self.addActivity(&stored, actor: actor, action, summary)
        }
    }

    func recordBookingCreated(_ booking: Booking) {
        guard readOrganization(booking.creatorID) != nil else { return }
        let client = booking.clientName.isEmpty ? "a client" : booking.clientName
        let who = booking.assignedTo.map { "with \(name(forMember: $0))" } ?? "waiting for someone to take it"
        recordForCompany(booking.creatorID, actor: booking.clientID, "booking.created",
                         "New booking: \(booking.packageName) for \(client), \(who)")
    }

    func recordBookingEvent(_ booking: Booking, _ action: String, _ verb: String, actor: UUID?) {
        let client = booking.clientName.isEmpty ? "a client" : booking.clientName
        recordForCompany(booking.creatorID, actor: actor, action, "\(verb) \(booking.packageName) for \(client)")
    }

    func recordContractExecuted(_ contract: Contract, booking: Booking?) {
        let client = (booking?.clientName).flatMap { $0.isEmpty ? nil : $0 } ?? "a client"
        var line = "Contract signed for \(booking?.packageName ?? "a booking") (\(client))"
        if let signer = contract.countersignerName {
            let title = contract.countersignerTitle ?? ""
            line += ", countersigned by \(signer)" + (title.isEmpty ? "" : " (\(title))")
        }
        recordForCompany(contract.creatorID, actor: nil, "contract.executed", line)
    }

    func recordPackageChange(from old: ServicePackage?, to new: ServicePackage) {
        guard readOrganization(new.creatorID) != nil else { return }
        let actor = currentUserID()
        func money(_ cents: Int, _ code: String) -> String { ContractFormat.money(cents: cents, code: code) }
        guard let old else {
            recordForCompany(new.creatorID, actor: actor, "package.created", "Added the service \(new.name) at \(money(new.priceCents, new.currencyCode))")
            return
        }
        if new.priceCents != old.priceCents {
            recordForCompany(new.creatorID, actor: actor, "package.price_changed",
                             "Changed the price of \(new.name) from \(money(old.priceCents, old.currencyCode)) to \(money(new.priceCents, new.currencyCode))")
        }
        if new.depositCents != old.depositCents {
            recordForCompany(new.creatorID, actor: actor, "package.deposit_changed",
                             "Changed the deposit of \(new.name) from \(money(old.depositCents, old.currencyCode)) to \(money(new.depositCents, new.currencyCode))")
        }
        if new.isPublished != old.isPublished {
            recordForCompany(new.creatorID, actor: actor, "package.visibility_changed", (new.isPublished ? "Published " : "Hid ") + new.name)
        }
        if new.name != old.name {
            recordForCompany(new.creatorID, actor: actor, "package.renamed", "Renamed the service \(old.name) to \(new.name)")
        }
        if new.contractTemplateID != old.contractTemplateID {
            recordForCompany(new.creatorID, actor: actor, "package.contract_changed", "Changed the contract for \(new.name)")
        }
    }

    // MARK: - Activity and billing

    func loadActivity(organizationID: UUID, limit: Int, before: Date?, for userID: UUID) async throws -> [ActivityEntry] {
        guard let org = readOrganization(organizationID), permits(org, userID, .activityView) else { throw SlateError.notAllowed }
        var entries = Array(org.activity.reversed())
        if let before { entries = entries.filter { $0.createdAt < before } }
        return Array(entries.prefix(max(1, min(limit, 200))))
    }

    func loadBilling(organizationID: UUID, for userID: UUID) async throws -> BillingOverview {
        let org = try memberOrganization(organizationID, userID)
        guard permits(org, userID, .billingManage) else { throw SlateError.notAllowed }
        return BillingOverview(plan: .notRequired, seats: seatCounts(org), seatsBilledByStripe: 0, trialEnd: nil, state: org.state)
    }

    func previewSeatChange(delta: Int, organizationID: UUID, for userID: UUID) async throws -> SeatPlan {
        let org = try memberOrganization(organizationID, userID)
        guard permits(org, userID, .teamManage) || permits(org, userID, .billingManage) else { throw SlateError.notAllowed }
        return SeatPlan.make(used: activeMembers(org).count, delta: delta, config: teamConfig)
    }

    /// Plans are Stripe's. On a device with no server there is nothing to open.
    func beginBilling(_ action: BillingAction, organizationID: UUID, by userID: UUID) async throws -> URL {
        throw SlateError.billingUnavailable
    }
}
