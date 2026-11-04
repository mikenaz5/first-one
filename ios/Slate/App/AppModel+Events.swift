import Foundation

extension AppModel {
    // MARK: - Who can do what

    /// Whether the person can add events to the team calendar of the company on screen. Owners, Admins, Managers and
    /// Creators can; Viewers can only look.
    var canAddEvents: Bool { isCompanyActive && can(.eventsAdd) }

    // MARK: - Events

    /// The company on screen's events in a window of at most 62 days.
    func loadTeamEvents(from: Date, to: Date) async throws -> [TeamEvent] {
        let (company, me) = try activeCompanyForEvents()
        return try await backend.loadTeamEvents(organizationID: company, from: from, to: to, for: me)
    }

    /// Adds an event to the company on screen, or changes the one in `draft`. The phone's own calendar follows, if the
    /// person asked for that.
    @discardableResult
    func saveTeamEvent(_ draft: TeamEventDraft) async throws -> TeamEvent {
        let (company, me) = try activeCompanyForEvents()
        let saved = try await backend.saveTeamEvent(draft, organizationID: company, by: me)
        await syncTeamEvents()
        return saved
    }

    func deleteTeamEvent(_ event: TeamEvent) async throws {
        let (_, me) = try activeCompanyForEvents()
        try await backend.deleteTeamEvent(event.id, by: me)
        await syncTeamEvents()
    }

    private func activeCompanyForEvents() throws -> (UUID, UUID) {
        guard let session else { throw SlateError.notSignedIn }
        guard let id = activeAccount.companyID else { throw SlateError.notFound }
        return (id, session.userID)
    }

    // MARK: - Calendar links

    /// The private address other calendar apps read, or nil when this account has no server to serve one.
    func calendarLink() async throws -> CalendarLink? {
        guard let session else { throw SlateError.notSignedIn }
        return try await backend.calendarLink(for: session.userID)
    }

    /// A new address; the old one stops working at once.
    func resetCalendarLink() async throws -> CalendarLink? {
        guard let session else { throw SlateError.notSignedIn }
        return try await backend.resetCalendarLink(for: session.userID)
    }
}
