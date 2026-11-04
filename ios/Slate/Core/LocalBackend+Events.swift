import Foundation

/// Team events for the on-device backend. It follows `…_team_events.sql` rule for rule.
///
/// An event is for the whole team or for people named. Owners, Admins, Managers and Creators add them; the person who made
/// one changes or removes it, and Owners, Admins and Managers change or remove anyone's. Everyone on the team sees them.
/// While one that blocks bookings lasts, the people it is for can't be booked (see `memberSlotState`, `makeTeamSchedule` and
/// `loadTeamCalendar` in `LocalBackend+TeamBooking.swift`, which count them as busy time).
extension LocalBackend {
    // MARK: - Storage

    private var eventsURL: URL { root.appendingPathComponent("team_events.json") }

    func readTeamEvents() -> [TeamEvent] {
        read([TeamEvent].self, from: eventsURL) ?? []
    }

    /// An event as the person asking sees it: only people still in the team, and whether they can change it.
    private func present(_ event: TeamEvent, for userID: UUID, in org: StoredOrganization) -> TeamEvent {
        var shown = event
        let active = Set(activeMembers(org).map(\.userID))
        shown.memberIDs = event.everyone ? [] : event.memberIDs.filter { active.contains($0) }.sorted { $0.uuidString < $1.uuidString }
        shown.createdByName = personName(event.createdBy)
        shown.canEdit = mayChange(event, userID, in: org)
        shown.organizationName = personName(org.id)
        return shown
    }

    /// The author (while they can still add events) or the people who run the calendar.
    private func mayChange(_ event: TeamEvent, _ userID: UUID, in org: StoredOrganization) -> Bool {
        (event.createdBy == userID && permits(org, userID, .eventsAdd)) || permits(org, userID, .eventsManageAll)
    }

    // MARK: - Reading

    func loadTeamEvents(organizationID: UUID, from: Date, to: Date, for userID: UUID) async throws -> [TeamEvent] {
        let org = try memberOrganization(organizationID, userID)
        guard permits(org, userID, .calendarViewTeam) else { throw SlateError.notAllowed }
        let window = DateInterval(start: from, end: min(max(to, from), from.addingTimeInterval(62 * 86_400)))
        return readTeamEvents()
            .filter { $0.organizationID == org.id && IntervalMath.overlaps($0.interval, window) }
            .sorted { ($0.startsAt, $0.id.uuidString) < ($1.startsAt, $1.id.uuidString) }
            .map { present($0, for: userID, in: org) }
    }

    func loadMyTeamEvents(from: Date, to: Date, for userID: UUID) async throws -> [TeamEvent] {
        let window = DateInterval(start: from, end: min(max(to, from), from.addingTimeInterval(400 * 86_400)))
        var found: [TeamEvent] = []
        for org in readOrganizations() where activeMember(org, userID) != nil && permits(org, userID, .calendarViewTeam) {
            found += readTeamEvents()
                .filter { $0.organizationID == org.id && $0.isFor(userID) && IntervalMath.overlaps($0.interval, window) }
                .map { present($0, for: userID, in: org) }
        }
        return found.sorted { ($0.startsAt, $0.id.uuidString) < ($1.startsAt, $1.id.uuidString) }
    }

    // MARK: - Writing

    func saveTeamEvent(_ draft: TeamEventDraft, organizationID: UUID, by userID: UUID) async throws -> TeamEvent {
        let org = try memberOrganization(organizationID, userID)
        guard permits(org, userID, .eventsAdd) else { throw SlateError.notAllowed }

        var events = readTeamEvents()
        var index: Int?
        if let id = draft.id {
            guard let found = events.firstIndex(where: { $0.id == id && $0.organizationID == org.id }) else { throw SlateError.notFound }
            guard mayChange(events[found], userID, in: org) else { throw SlateError.notAllowed }
            index = found
        }

        if let problem = EventRules.problem(
            title: draft.title, notes: draft.notes, location: draft.location, startsAt: draft.startsAt, endsAt: draft.endsAt,
            everyone: draft.everyone, people: draft.memberIDs.count
        ) {
            throw problem.error
        }
        if !draft.everyone, draft.memberIDs.contains(where: { activeMember(org, $0) == nil }) { throw SlateError.invalidAttendee }

        let now = stamp
        if index == nil {
            let upcoming = events.filter { $0.organizationID == org.id && $0.endsAt > now }.count
            if upcoming >= EventRules.maxUpcoming { throw SlateError.tooManyEvents }
        }

        var event = index.map { events[$0] } ?? TeamEvent(
            id: UUID(), organizationID: org.id, title: "", notes: "", location: "", startsAt: draft.startsAt, endsAt: draft.endsAt,
            allDay: false, everyone: true, blocksBookings: true, memberIDs: [], createdBy: userID, createdByName: "", canEdit: true
        )
        event.title = EventRules.cleanLine(draft.title)
        event.notes = EventRules.cleanNotes(draft.notes)
        event.location = EventRules.cleanLine(draft.location)
        event.startsAt = draft.startsAt
        event.endsAt = draft.endsAt
        event.allDay = draft.allDay
        event.everyone = draft.everyone
        event.blocksBookings = draft.blocksBookings
        event.memberIDs = draft.everyone ? [] : draft.memberIDs.sorted { $0.uuidString < $1.uuidString }

        if let index { events[index] = event } else { events.append(event) }
        try write(events, to: eventsURL)
        let title = event.title
        let created = index == nil
        try mutateOrganization(org.id) { stored in
            addActivity(&stored, actor: userID, created ? "event.created" : "event.updated",
                        created ? "Added the event \"\(title)\"" : "Changed the event \"\(title)\"")
        }
        return present(event, for: userID, in: try memberOrganization(org.id, userID))
    }

    func deleteTeamEvent(_ eventID: UUID, by userID: UUID) async throws {
        var events = readTeamEvents()
        guard let index = events.firstIndex(where: { $0.id == eventID }), let org = try? memberOrganization(events[index].organizationID, userID) else {
            throw SlateError.notFound
        }
        guard permits(org, userID, .eventsAdd), mayChange(events[index], userID, in: org) else { throw SlateError.notAllowed }
        let title = events[index].title
        events.remove(at: index)
        try write(events, to: eventsURL)
        try mutateOrganization(org.id) { stored in
            addActivity(&stored, actor: userID, "event.deleted", "Removed the event \"\(title)\"")
        }
    }

    // MARK: - Calendar links

    /// A calendar link is an address on a server, and an on-device account has none.
    func calendarLink(for userID: UUID) async throws -> CalendarLink? { nil }

    func resetCalendarLink(for userID: UUID) async throws -> CalendarLink? { nil }
}
