import Foundation
import Supabase

/// Team events and calendar links on Supabase.
///
/// Who may add, change or see an event, and what an event does to a person's bookable time, is decided in the database
/// (`…_team_events.sql`: `team_event_save`, `team_event_delete`, `team_events_list`, `my_team_events`, and the three
/// functions that count events as busy time). The calendar link is a secret kept in `calendar_feeds`; the `calendar-feed`
/// Edge Function turns it into the calendar file other apps read.
extension SupabaseBackend {
    // MARK: - Rows

    /// `team_event_json`, and `my_team_events` (which adds the company's name).
    struct TeamEventRow: Decodable {
        var id: String
        var organizationId: String
        var title: String
        var notes: String
        var location: String
        var startsAt: Date
        var endsAt: Date
        var allDay: Bool
        var everyone: Bool
        var blocksBookings: Bool
        var memberIds: [String]
        var createdBy: String?
        var createdByName: String
        var canEdit: Bool
        var organizationName: String?

        enum CodingKeys: String, CodingKey {
            case id, title, notes, location, everyone
            case organizationId = "organization_id"
            case startsAt = "starts_at"
            case endsAt = "ends_at"
            case allDay = "all_day"
            case blocksBookings = "blocks_bookings"
            case memberIds = "member_ids"
            case createdBy = "created_by"
            case createdByName = "created_by_name"
            case canEdit = "can_edit"
            case organizationName = "organization_name"
        }

        /// Nil for a row with ids this version can't read.
        var event: TeamEvent? {
            guard let id = UUID(uuidString: id), let organization = UUID(uuidString: organizationId) else { return nil }
            return TeamEvent(
                id: id, organizationID: organization, title: title, notes: notes, location: location, startsAt: startsAt,
                endsAt: endsAt, allDay: allDay, everyone: everyone, blocksBookings: blocksBookings,
                memberIDs: memberIds.compactMap(UUID.init(uuidString:)), createdBy: createdBy.flatMap(UUID.init(uuidString:)),
                createdByName: createdByName, canEdit: canEdit, organizationName: organizationName ?? ""
            )
        }
    }

    // MARK: - Parameters

    private struct EventListParams: Encodable {
        var pOrg: String
        var pFrom: Date
        var pTo: Date

        enum CodingKeys: String, CodingKey {
            case pOrg = "p_org"
            case pFrom = "p_from"
            case pTo = "p_to"
        }
    }

    private struct MyEventsParams: Encodable {
        var pFrom: Date
        var pTo: Date

        enum CodingKeys: String, CodingKey {
            case pFrom = "p_from"
            case pTo = "p_to"
        }
    }

    /// `p_event_id` has no default in SQL, so a new event sends it as an explicit null rather than leaving it out.
    private struct SaveEventParams: Encodable {
        var pOrg: String
        var pEventId: String?
        var pTitle: String
        var pNotes: String
        var pLocation: String
        var pStartsAt: Date
        var pEndsAt: Date
        var pAllDay: Bool
        var pEveryone: Bool
        var pMemberIds: [String]
        var pBlocks: Bool

        enum CodingKeys: String, CodingKey {
            case pOrg = "p_org"
            case pEventId = "p_event_id"
            case pTitle = "p_title"
            case pNotes = "p_notes"
            case pLocation = "p_location"
            case pStartsAt = "p_starts_at"
            case pEndsAt = "p_ends_at"
            case pAllDay = "p_all_day"
            case pEveryone = "p_everyone"
            case pMemberIds = "p_member_ids"
            case pBlocks = "p_blocks"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(pOrg, forKey: .pOrg)
            try container.encode(pEventId, forKey: .pEventId)
            try container.encode(pTitle, forKey: .pTitle)
            try container.encode(pNotes, forKey: .pNotes)
            try container.encode(pLocation, forKey: .pLocation)
            try container.encode(pStartsAt, forKey: .pStartsAt)
            try container.encode(pEndsAt, forKey: .pEndsAt)
            try container.encode(pAllDay, forKey: .pAllDay)
            try container.encode(pEveryone, forKey: .pEveryone)
            try container.encode(pMemberIds, forKey: .pMemberIds)
            try container.encode(pBlocks, forKey: .pBlocks)
        }
    }

    private struct DeleteEventParams: Encodable {
        var pEventId: String

        enum CodingKeys: String, CodingKey { case pEventId = "p_event_id" }
    }

    // MARK: - Events

    func loadTeamEvents(organizationID: UUID, from: Date, to: Date, for userID: UUID) async throws -> [TeamEvent] {
        let rows: [TeamEventRow] = try await call("team_events_list", EventListParams(pOrg: Self.key(organizationID), pFrom: from, pTo: max(to, from)))
        return rows.compactMap(\.event)
    }

    func loadMyTeamEvents(from: Date, to: Date, for userID: UUID) async throws -> [TeamEvent] {
        let rows: [TeamEventRow] = try await call("my_team_events", MyEventsParams(pFrom: from, pTo: max(to, from)))
        return rows.compactMap(\.event)
    }

    func saveTeamEvent(_ draft: TeamEventDraft, organizationID: UUID, by userID: UUID) async throws -> TeamEvent {
        // What is sent is tidied the way the database tidies it, so a title that is cut to fit shows as it will be kept.
        let row: TeamEventRow = try await call("team_event_save", SaveEventParams(
            pOrg: Self.key(organizationID), pEventId: draft.id.map(Self.key),
            pTitle: EventRules.cleanLine(draft.title), pNotes: EventRules.cleanNotes(draft.notes),
            pLocation: EventRules.cleanLine(draft.location), pStartsAt: draft.startsAt, pEndsAt: draft.endsAt,
            pAllDay: draft.allDay, pEveryone: draft.everyone,
            pMemberIds: draft.everyone ? [] : draft.memberIDs.map(Self.key).sorted(), pBlocks: draft.blocksBookings
        ))
        guard let event = row.event else { throw SlateError.backend("The event came back in a form this version can't read.") }
        return event
    }

    func deleteTeamEvent(_ eventID: UUID, by userID: UUID) async throws {
        do {
            try await client.rpc("team_event_delete", params: DeleteEventParams(pEventId: Self.key(eventID))).execute()
        } catch {
            throw Self.mapTeamError(error)
        }
    }

    // MARK: - Calendar links

    func calendarLink(for userID: UUID) async throws -> CalendarLink? {
        do {
            let token: String = try await client.rpc("calendar_feed_token").execute().value
            return CalendarLink.make(projectURL: projectURL, token: token)
        } catch {
            throw Self.mapTeamError(error)
        }
    }

    func resetCalendarLink(for userID: UUID) async throws -> CalendarLink? {
        do {
            let token: String = try await client.rpc("calendar_feed_reset").execute().value
            return CalendarLink.make(projectURL: projectURL, token: token)
        } catch {
            throw Self.mapTeamError(error)
        }
    }

    private func call<Params: Encodable, Value: Decodable>(_ function: String, _ params: Params) async throws -> Value {
        do {
            return try await client.rpc(function, params: params).execute().value
        } catch {
            throw Self.mapTeamError(error)
        }
    }
}
