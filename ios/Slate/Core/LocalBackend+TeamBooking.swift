import Foundation

/// Who a company's bookings go to, and what the team calendars show, for the on-device backend. It follows the
/// assignment and calendar functions in `…_company_booking.sql`.
///
/// One rule underneath: nobody is in two places. A booking takes time from the person it is assigned to, whether it
/// came through their own page or their company's, so `member_slot_state` looks at every booking assigned to them.
extension LocalBackend {
    // MARK: - Who is on the provider side of a booking

    enum ProviderLevel {
        /// Reading it.
        case view
        /// Acting on it: cancel, deliver, message.
        case manage
    }

    /// The person who owns it can do both. In a company the Owner, Admins and Managers can manage any booking, Viewers
    /// can read any, and a Creator works on the bookings assigned to them. `public.provider_access` is the same.
    func providerAccess(_ userID: UUID, _ booking: Booking, _ level: ProviderLevel, in orgs: [StoredOrganization]? = nil) -> Bool {
        if booking.creatorID == userID { return true }
        let all = orgs ?? readOrganizations()
        guard let org = all.first(where: { $0.id == booking.creatorID }), let member = activeMember(org, userID) else { return false }
        func allowed(_ permission: OrgPermission) -> Bool {
            RoleRules.allows(permission, role: member.role, state: org.state)
        }
        let mine = booking.assignedTo == userID && allowed(.bookingsManageAssigned)
        switch level {
        case .manage: return allowed(.bookingsManage) || mine
        case .view: return allowed(.bookingsViewAll) || mine
        }
    }

    /// The client of the booking, or someone on the provider side who may read it.
    func isParty(_ userID: UUID, _ booking: Booking, _ level: ProviderLevel = .view, in orgs: [StoredOrganization]? = nil) -> Bool {
        booking.clientID == userID || providerAccess(userID, booking, level, in: orgs)
    }

    /// Whether a person is on the provider side, for deciding which half of a rule applies (a refund policy, a line in
    /// a conversation). In a test booking the same person is both, and then they are the provider.
    func isProviderSide(_ userID: UUID, _ booking: Booking) -> Bool {
        booking.creatorID == userID || (booking.clientID != userID && providerAccess(userID, booking, .view))
    }

    // MARK: - Free or taken

    enum SlotState {
        case ok
        /// Outside their hours, or over their calendar.
        case unavailable
        /// They already have a booking then.
        case taken
    }

    func readBusy(_ userID: UUID) -> [DateInterval] {
        read([DateInterval].self, from: busyURL(userID)) ?? []
    }

    /// Can this person take a booking of this length starting then? Mirrors `public.member_slot_state`: their hours
    /// (the company's, narrowed by their own), their own calendar, and every booking already assigned to them.
    func memberSlotState(
        _ userID: UUID, memberHours: [DayHours]?, settings: AvailabilitySettings,
        start: Date, end: Date, blockedUntil: Date, ignoring: UUID? = nil
    ) -> SlotState {
        let parts = settings.calendar.dateComponents([.weekday, .hour, .minute], from: start)
        let weekday = parts.weekday ?? 0
        let startMinute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        guard let company = settings.window(forWeekday: weekday) else { return .unavailable }
        var opens = company.startMinute
        var closes = company.endMinute
        if let memberHours {
            guard let own = memberHours.first(where: { $0.weekday == weekday })?.window else { return .unavailable }
            opens = max(opens, own.startMinute)
            closes = min(closes, own.endMinute)
        }
        let minutes = Int(end.timeIntervalSince(start) / 60)
        if startMinute < opens || startMinute + minutes > closes || (startMinute - opens) % max(1, settings.slotIntervalMinutes) != 0 {
            return .unavailable
        }

        let wanted = DateInterval(start: start, end: max(blockedUntil, start))
        let buffer = TimeInterval(settings.bufferMinutes) * 60
        for block in readBusy(userID) {
            let reach = DateInterval(start: block.start, end: block.end.addingTimeInterval(buffer))
            if IntervalMath.overlaps(reach, wanted) { return .unavailable }
        }
        let now = self.now
        for booking in readBookings() where booking.id != ignoring && booking.occupant == userID
            && booking.effectiveStatus(at: now).blocksTime && IntervalMath.overlaps(booking.blockedRange, wanted) {
            return .taken
        }
        return .ok
    }

    /// The people who could take a package: bookable members who can take bookings, narrowed to the package's chosen few.
    func eligibleMembers(_ org: StoredOrganization, packageID: UUID?) -> [StoredMember] {
        let offered = packageID.flatMap { org.packageMembers[$0.uuidString.lowercased()] } ?? []
        return activeMembers(org).filter { member in
            member.bookable && member.role != .viewer && (offered.isEmpty || offered.contains(member.userID))
        }
    }

    /// Open bookings from now on, which the planner uses to share the work out.
    func upcomingCount(for userID: UUID) -> Int {
        let now = self.now
        return readBookings().filter { $0.assignedTo == userID && $0.effectiveStatus(at: now).blocksTime && $0.endAt > now }.count
    }

    // MARK: - What a client's device needs to book a company

    /// The company's rules and, for each eligible person, their hours and busy time. With `includeBookings` false the
    /// busy time is only what is on their own calendars, which is how "taken" is told apart from "not offered".
    func makeTeamSchedule(
        org: StoredOrganization, package: ServicePackage, from: Date, to: Date, includeBookings: Bool = true
    ) throws -> TeamSchedule {
        guard let settings = read(AvailabilitySettings.self, from: availabilityURL(org.id)) else { throw SlateError.packageUnavailable }
        let window = DateInterval(start: from, end: max(to, from))
        let now = self.now
        let bookings = readBookings().filter { $0.effectiveStatus(at: now).blocksTime }
        let buffer = TimeInterval(settings.bufferMinutes) * 60

        var members: [MemberSchedule] = []
        let eligible = eligibleMembers(org, packageID: package.id).sorted {
            ($0.joinedAt, $0.userID.uuidString) < ($1.joinedAt, $1.userID.uuidString)
        }
        for member in eligible {
            var busy: [DateInterval] = []
            if includeBookings {
                busy += bookings.filter { $0.occupant == member.userID }.map(\.blockedRange)
            }
            busy += readBusy(member.userID).map { DateInterval(start: $0.start, end: $0.end.addingTimeInterval(buffer)) }
            members.append(MemberSchedule(
                userID: member.userID, displayName: personName(member.userID),
                weekly: TeamAvailability.effectiveHours(company: settings.weekly, member: member.weekly),
                busy: busy.filter { IntervalMath.overlaps($0, window) }
            ))
        }
        let waiting = includeBookings
            ? bookings.filter { $0.creatorID == org.id && $0.assignedTo == nil }.map(\.blockedRange).filter { IntervalMath.overlaps($0, window) }
            : []
        return TeamSchedule(settings: settings, assignmentMode: org.assignmentMode, members: members, unassigned: waiting)
    }

    func loadTeamSchedule(packageID: UUID, memberID: UUID?, from: Date, to: Date) async throws -> TeamSchedule {
        try expireLapsedHolds()
        for org in readOrganizations() where org.state == .active {
            guard let package = readPackages(org.id).first(where: { $0.id == packageID && $0.isPublished }) else { continue }
            let all = try makeTeamSchedule(org: org, package: package, from: from, to: min(to, from.addingTimeInterval(92 * 86_400)))
            guard let memberID else { return all }
            return TeamSchedule(
                settings: all.settings, assignmentMode: all.assignmentMode,
                members: all.members.filter { $0.userID == memberID }, unassigned: all.unassigned
            )
        }
        throw SlateError.packageUnavailable
    }

    // MARK: - Shared services

    func loadPackageMembers(packageID: UUID) async throws -> [UUID] {
        for org in readOrganizations() where readPackages(org.id).contains(where: { $0.id == packageID }) {
            return org.packageMembers[packageID.uuidString.lowercased()] ?? []
        }
        return []
    }

    func setPackageMembers(_ memberIDs: [UUID], packageID: UUID, by userID: UUID) async throws {
        guard let org = readOrganizations().first(where: { company in readPackages(company.id).contains { $0.id == packageID } }),
              let package = readPackages(org.id).first(where: { $0.id == packageID }),
              activeMember(org, userID) != nil
        else { throw SlateError.notFound }
        guard permits(org, userID, .servicesManage) else { throw SlateError.notAllowed }
        let people = Set(memberIDs)
        let allowed = Set(activeMembers(org).filter { $0.bookable && $0.role != .viewer }.map(\.userID))
        guard people.isSubset(of: allowed) else { throw SlateError.invalidAssignee }
        try mutateOrganization(org.id) { stored in
            let key = packageID.uuidString.lowercased()
            var unique: [UUID] = []
            for id in memberIDs where !unique.contains(id) { unique.append(id) }
            stored.packageMembers[key] = unique.isEmpty ? nil : unique
            let count = unique.count
            self.addActivity(&stored, actor: userID, "package.offered_by",
                             count == 0 ? "\(package.name) is offered by everyone"
                                        : "\(package.name) is offered by \(count) \(count == 1 ? "person" : "people")")
        }
    }

    // MARK: - Assigning

    func loadAssignmentQueue(organizationID: UUID, for userID: UUID) async throws -> [Booking] {
        let org = try memberOrganization(organizationID, userID)
        guard permits(org, userID, .bookingsAssign) else { throw SlateError.notAllowed }
        try expireLapsedHolds()
        let now = self.now
        return readBookings()
            .filter { $0.creatorID == organizationID && $0.assignedTo == nil && $0.effectiveStatus(at: now).blocksTime && $0.endAt > now }
            .sorted { ($0.startAt, $0.id.uuidString) < ($1.startAt, $1.id.uuidString) }
    }

    func loadAssignmentOptions(bookingID: UUID, for userID: UUID) async throws -> [AssignmentOption] {
        try expireLapsedHolds()
        guard let booking = readBookings().first(where: { $0.id == bookingID }), let org = try? memberOrganization(booking.creatorID, userID) else {
            throw SlateError.notFound
        }
        guard permits(org, userID, .bookingsAssign) else { throw SlateError.notAllowed }
        let settings = read(AvailabilitySettings.self, from: availabilityURL(org.id))
        var options: [AssignmentOption] = []
        for member in eligibleMembers(org, packageID: booking.packageID) {
            let state: SlotState
            if let settings {
                state = memberSlotState(
                    member.userID, memberHours: member.weekly, settings: settings,
                    start: booking.startAt, end: booking.endAt, blockedUntil: booking.blockedUntil, ignoring: booking.id
                )
            } else {
                state = .unavailable
            }
            let reason: String?
            switch state {
            case .ok: reason = nil
            case .taken: reason = "Already booked"
            case .unavailable: reason = "Not available"
            }
            options.append(AssignmentOption(userID: member.userID, displayName: personName(member.userID), isFree: state == .ok, reason: reason))
        }
        return options.sorted { lhs, rhs in
            if lhs.isFree != rhs.isFree { return lhs.isFree }
            if lhs.displayName.lowercased() != rhs.displayName.lowercased() { return lhs.displayName.lowercased() < rhs.displayName.lowercased() }
            return lhs.userID.uuidString < rhs.userID.uuidString
        }
    }

    func assignBooking(_ bookingID: UUID, to memberID: UUID, by userID: UUID) async throws -> Booking {
        try expireLapsedHolds()
        let now = stamp
        var bookings = readBookings()
        guard let index = bookings.firstIndex(where: { $0.id == bookingID }),
              let org = try? memberOrganization(bookings[index].creatorID, userID)
        else { throw SlateError.notFound }
        guard permits(org, userID, .bookingsAssign) else { throw SlateError.notAllowed }
        let booking = bookings[index]
        guard booking.status.blocksTime, booking.endAt > now else { throw SlateError.notAssignable }
        if booking.assignedTo == memberID { return booking }

        // The person must be one who can take it: offering the package, or (if the package is gone) any bookable member.
        let packageExists = booking.packageID.map { id in readPackages(org.id).contains { $0.id == id } } ?? false
        let candidates = packageExists ? eligibleMembers(org, packageID: booking.packageID)
                                       : activeMembers(org).filter { $0.bookable && $0.role != .viewer }
        guard let candidate = candidates.first(where: { $0.userID == memberID }) else { throw SlateError.invalidAssignee }

        if let settings = read(AvailabilitySettings.self, from: availabilityURL(org.id)) {
            let state = memberSlotState(
                memberID, memberHours: candidate.weekly, settings: settings,
                start: booking.startAt, end: booking.endAt, blockedUntil: booking.blockedUntil, ignoring: booking.id
            )
            guard state == .ok else { throw SlateError.slotTaken }
        }

        let previous = booking.assignedTo
        bookings[index].assignedTo = memberID
        bookings[index].assignedAt = now
        bookings[index].assigneeShareBps = org.splitEnabled ? candidate.shareBps : nil
        try write(bookings, to: bookingsURL)

        let package = booking.packageName
        let to = name(forMember: memberID)
        try mutateOrganization(org.id) { stored in
            if let previous {
                self.addActivity(&stored, actor: userID, "booking.reassigned",
                                 "Moved \(package) from \(self.name(forMember: previous)) to \(to)")
            } else {
                self.addActivity(&stored, actor: userID, "booking.assigned", "Assigned \(package) to \(to)")
            }
        }
        return bookings[index]
    }

    func name(forMember userID: UUID) -> String {
        let found = personName(userID)
        return found.isEmpty ? "a member" : found
    }

    // MARK: - The team calendar

    func loadTeamCalendar(
        organizationID: UUID, from: Date, to: Date, members: Set<UUID>, for userID: UUID
    ) async throws -> TeamCalendar {
        let org = try memberOrganization(organizationID, userID)
        guard permits(org, userID, .calendarViewTeam) else { throw SlateError.notAllowed }
        try expireLapsedHolds()
        let settings = read(AvailabilitySettings.self, from: availabilityURL(org.id))
        let window = DateInterval(start: from, end: min(max(to, from), from.addingTimeInterval(62 * 86_400)))
        let now = self.now
        let bookings = readBookings().filter { $0.effectiveStatus(at: now).blocksTime && IntervalMath.overlaps($0.blockedRange, window) }
        let orgs = readOrganizations()

        func entry(_ booking: Booking) -> CalendarBooking {
            let mayOpen = providerAccess(userID, booking, .view, in: orgs)
            return CalendarBooking(
                bookingID: mayOpen ? booking.id : nil, startAt: booking.startAt, endAt: booking.endAt,
                blockedUntil: booking.blockedUntil, status: booking.status,
                packageName: mayOpen ? booking.packageName : nil, clientName: mayOpen ? booking.clientName : nil,
                requestedMember: booking.requestedMember
            )
        }

        var rows: [MemberCalendar] = []
        for member in activeMembers(org) where member.role != .viewer && (members.isEmpty || members.contains(member.userID)) {
            let stored = read(StoredProfile.self, from: profileURL(member.userID))
            var busy = readBusy(member.userID).filter { IntervalMath.overlaps($0, window) }.map { BusyRange(range: $0, kind: .external) }
            busy += bookings.filter { $0.assignedTo == member.userID && $0.creatorID != org.id }
                .map { BusyRange(range: $0.blockedRange, kind: .personal) }
            let weekly = member.bookable && settings != nil
                ? TeamAvailability.effectiveHours(company: settings?.weekly ?? [], member: member.weekly)
                : []
            rows.append(MemberCalendar(
                userID: member.userID, displayName: stored?.displayName ?? "",
                avatarURL: stored?.avatarFile.map { userDirectory(member.userID).appendingPathComponent($0) },
                role: member.role, title: member.title, bookable: member.bookable, weekly: weekly,
                busy: busy.sorted { $0.range.start < $1.range.start },
                bookings: bookings.filter { $0.creatorID == org.id && $0.assignedTo == member.userID }
                    .sorted { $0.startAt < $1.startAt }.map(entry)
            ))
        }
        rows.sort { order($0.role, $0.displayName, $0.userID) < order($1.role, $1.displayName, $1.userID) }
        let waiting = bookings.filter { $0.creatorID == org.id && $0.assignedTo == nil }.sorted { $0.startAt < $1.startAt }.map(entry)
        return TeamCalendar(timeZoneID: settings?.timeZoneID ?? TimeZone.current.identifier, members: rows, unassigned: waiting)
    }

    private func order(_ role: OrgRole, _ name: String, _ id: UUID) -> String {
        let rank: Int
        switch role {
        case .owner: rank = 0
        case .admin: rank = 1
        case .manager: rank = 2
        case .creator, .viewer: rank = 3
        }
        return "\(rank)|\(name.lowercased())|\(id.uuidString.lowercased())"
    }
}
