import Foundation
import Supabase

/// Companies on Supabase. Every rule (who may do what, seats, assignment, no double booking) lives in the SQL functions
/// in `…_organizations.sql`, `…_company_booking.sql` and `…_seat_billing.sql`; this file calls them and turns their
/// error tokens into `SlateError`. Billing pages come from the `billing-session` Edge Function.
///
/// Not yet run against a live project. The row shapes below are the JSON those functions return, checked against real
/// Postgres output in `TeamRowDecodingTests`.
extension SupabaseBackend {
    // MARK: - Rows

    struct SeatsRow: Decodable {
        var used: Int
        var pending: Int
        var billed: Int
        var minimum: Int
        var maximum: Int
    }

    struct PlanRow: Decodable {
        var required: Bool
        var status: String
        var ok: Bool?
        var graceUntil: Date?
        var cancelAtPeriodEnd: Bool?
        var periodEnd: Date?

        enum CodingKeys: String, CodingKey {
            case required, status, ok
            case graceUntil = "grace_until"
            case cancelAtPeriodEnd = "cancel_at_period_end"
            case periodEnd = "period_end"
        }
    }

    /// `org_overview`.
    struct OverviewRow: Decodable {
        var organizationId: String
        var name: String
        var handle: String
        var avatarPath: String?
        var bio: String?
        var locationName: String?
        var specialties: [String]?
        var legalName: String
        var legalAddress: String
        var assignmentMode: String
        var signerRoles: [String]
        var signerUserId: String?
        var signerTitle: String?
        var splitEnabled: Bool
        var state: String
        var myRole: String
        var myTitle: String?
        var myHours: [DayHours]?
        var seats: SeatsRow
        var plan: PlanRow?

        enum CodingKeys: String, CodingKey {
            case name, handle, bio, specialties, state, seats, plan
            case organizationId = "organization_id"
            case avatarPath = "avatar_path"
            case locationName = "location_name"
            case legalName = "legal_name"
            case legalAddress = "legal_address"
            case assignmentMode = "assignment_mode"
            case signerRoles = "signer_roles"
            case signerUserId = "signer_user_id"
            case signerTitle = "signer_title"
            case splitEnabled = "split_enabled"
            case myRole = "my_role"
            case myTitle = "my_title"
            case myHours = "my_hours"
        }
    }

    struct AccountsRow: Decodable {
        struct Personal: Decodable {
            var hasProfile: Bool

            enum CodingKeys: String, CodingKey { case hasProfile = "has_profile" }
        }

        struct Company: Decodable {
            var organizationId: String
            var name: String
            var handle: String
            var avatarPath: String?
            var role: String
            var title: String?
            var state: String

            enum CodingKeys: String, CodingKey {
                case name, handle, role, title, state
                case organizationId = "organization_id"
                case avatarPath = "avatar_path"
            }
        }

        var personal: Personal
        var companies: [Company]
    }

    struct MemberRow: Decodable {
        var userId: String
        var role: String
        var title: String?
        var listed: Bool
        var bookable: Bool
        var shareBps: Int
        var joinedAt: Date
        var displayName: String
        var handle: String?
        var avatarPath: String?
        /// Null for everyone who is not the signer, as the database writes it.
        var isSigner: Bool?

        enum CodingKeys: String, CodingKey {
            case role, title, listed, bookable, handle
            case userId = "user_id"
            case shareBps = "share_bps"
            case joinedAt = "joined_at"
            case displayName = "display_name"
            case avatarPath = "avatar_path"
            case isSigner = "is_signer"
        }
    }

    struct PublicMemberRow: Decodable {
        var userId: String
        var displayName: String
        var handle: String?
        var avatarPath: String?
        var bio: String?
        var specialties: [String]?
        var title: String?

        enum CodingKeys: String, CodingKey {
            case handle, bio, specialties, title
            case userId = "user_id"
            case displayName = "display_name"
            case avatarPath = "avatar_path"
        }
    }

    struct InviteRow: Decodable {
        var id: String
        var role: String
        var email: String?
        var status: String
        var createdAt: Date
        var expiresAt: Date
        var invitedByName: String?

        enum CodingKeys: String, CodingKey {
            case id, role, email, status
            case createdAt = "created_at"
            case expiresAt = "expires_at"
            case invitedByName = "invited_by_name"
        }
    }

    /// `invite_create` and `invite_resend`: the invite, and the token that is shown once.
    struct CreatedInviteRow: Decodable {
        struct Invite: Decodable {
            var id: String
            var role: String
            var email: String?
            var expiresAt: Date
            var createdAt: Date

            enum CodingKeys: String, CodingKey {
                case id, role, email
                case expiresAt = "expires_at"
                case createdAt = "created_at"
            }
        }

        var invite: Invite
        var token: String
    }

    struct PreviewInviteRow: Decodable {
        var organizationId: String
        var organizationName: String?
        var role: String
        var invitedByName: String?
        var expiresAt: Date
        var alreadyMember: Bool
        var hasProfile: Bool

        enum CodingKeys: String, CodingKey {
            case role
            case organizationId = "organization_id"
            case organizationName = "organization_name"
            case invitedByName = "invited_by_name"
            case expiresAt = "expires_at"
            case alreadyMember = "already_member"
            case hasProfile = "has_profile"
        }
    }

    struct ActivityRow: Decodable {
        var id: String
        var actorId: String?
        var actorName: String?
        var action: String
        var summary: String
        var createdAt: Date

        enum CodingKeys: String, CodingKey {
            case id, action, summary
            case actorId = "actor_id"
            case actorName = "actor_name"
            case createdAt = "created_at"
        }
    }

    struct BillingRow: Decodable {
        var required: Bool
        var status: String
        var seats: SeatsRow
        var seatsBilledByStripe: Int?
        var currentPeriodEnd: Date?
        var trialEnd: Date?
        var cancelAtPeriodEnd: Bool?
        var graceUntil: Date?
        var state: String

        enum CodingKeys: String, CodingKey {
            case required, status, seats, state
            case seatsBilledByStripe = "seats_billed_by_stripe"
            case currentPeriodEnd = "current_period_end"
            case trialEnd = "trial_end"
            case cancelAtPeriodEnd = "cancel_at_period_end"
            case graceUntil = "grace_until"
        }
    }

    struct SeatPlanRow: Decodable {
        var used: Int
        var usedAfter: Int
        var billedNow: Int
        var billedAfter: Int
        var allowed: Bool
        var change: String

        enum CodingKeys: String, CodingKey {
            case used, allowed, change
            case usedAfter = "used_after"
            case billedNow = "billed_now"
            case billedAfter = "billed_after"
        }
    }

    struct TeamConfigRow: Decodable {
        var seatMinimum: Int
        var seatMaximum: Int
        var inviteExpiryDays: Int
        var graceDays: Int

        enum CodingKeys: String, CodingKey {
            case seatMinimum = "seat_minimum"
            case seatMaximum = "seat_maximum"
            case inviteExpiryDays = "invite_expiry_days"
            case graceDays = "grace_days"
        }
    }

    struct OptionRow: Decodable {
        var userId: String
        var displayName: String
        var free: Bool
        var reason: String?

        enum CodingKeys: String, CodingKey {
            case free, reason
            case userId = "user_id"
            case displayName = "display_name"
        }
    }

    struct BusyRow: Decodable {
        var startsAt: Date
        var endsAt: Date
        var kind: String?

        enum CodingKeys: String, CodingKey {
            case kind
            case startsAt = "starts_at"
            case endsAt = "ends_at"
        }
    }

    struct CalendarBookingRow: Decodable {
        var id: String?
        var startAt: Date
        var endAt: Date
        var blockedUntil: Date
        var status: String
        var packageName: String?
        var clientName: String?
        var requestedMember: Bool?

        enum CodingKeys: String, CodingKey {
            case id, status
            case startAt = "start_at"
            case endAt = "end_at"
            case blockedUntil = "blocked_until"
            case packageName = "package_name"
            case clientName = "client_name"
            case requestedMember = "requested_member"
        }
    }

    struct CalendarMemberRow: Decodable {
        var userId: String
        var displayName: String
        var avatarPath: String?
        var role: String
        var title: String?
        var bookable: Bool
        var weekly: [DayHours]
        var busy: [BusyRow]
        var bookings: [CalendarBookingRow]

        enum CodingKeys: String, CodingKey {
            case role, title, bookable, weekly, busy, bookings
            case userId = "user_id"
            case displayName = "display_name"
            case avatarPath = "avatar_path"
        }
    }

    /// `team_calendar`.
    struct TeamCalendarRow: Decodable {
        var timeZone: String?
        var members: [CalendarMemberRow]
        var unassigned: [CalendarBookingRow]

        enum CodingKeys: String, CodingKey {
            case members, unassigned
            case timeZone = "time_zone"
        }
    }

    struct TeamMemberScheduleRow: Decodable {
        var userId: String
        var displayName: String
        var weekly: [DayHours]
        var busy: [BusyRow]

        enum CodingKeys: String, CodingKey {
            case weekly, busy
            case userId = "user_id"
            case displayName = "display_name"
        }
    }

    /// `team_availability`: the company's availability row, and each eligible person's hours and busy time.
    struct TeamAvailabilityRow: Decodable {
        struct Settings: Decodable {
            var timeZone: String
            var weekly: [DayHours]
            var blackouts: [BlackoutRange]
            var minNoticeHours: Int
            var maxAdvanceDays: Int
            var bufferMinutes: Int
            var slotIntervalMinutes: Int

            enum CodingKeys: String, CodingKey {
                case weekly, blackouts
                case timeZone = "time_zone"
                case minNoticeHours = "min_notice_hours"
                case maxAdvanceDays = "max_advance_days"
                case bufferMinutes = "buffer_minutes"
                case slotIntervalMinutes = "slot_interval_minutes"
            }
        }

        var settings: Settings
        var assignmentMode: String
        var members: [TeamMemberScheduleRow]
        var unassigned: [BusyRow]

        enum CodingKeys: String, CodingKey {
            case settings, members, unassigned
            case assignmentMode = "assignment_mode"
        }
    }

    struct PackageMemberRow: Decodable {
        var userId: String

        enum CodingKeys: String, CodingKey { case userId = "user_id" }
    }

    private struct BillingSessionReply: Decodable {
        var url: String
    }

    // MARK: - Parameters

    private struct NoParams: Encodable {}

    private struct OrgParams: Encodable {
        var pOrg: String
        enum CodingKeys: String, CodingKey { case pOrg = "p_org" }
    }

    private struct OrgUserParams: Encodable {
        var pOrg: String
        var pUser: String
        enum CodingKeys: String, CodingKey {
            case pOrg = "p_org"
            case pUser = "p_user"
        }
    }

    private struct CreateOrgParams: Encodable {
        var pHandle: String
        var pDisplayName: String
        var pLegalName: String
        var pLegalAddress: String
        var pBio: String
        var pSpecialties: [String]
        var pOwnerDisplayName: String?

        enum CodingKeys: String, CodingKey {
            case pHandle = "p_handle"
            case pDisplayName = "p_display_name"
            case pLegalName = "p_legal_name"
            case pLegalAddress = "p_legal_address"
            case pBio = "p_bio"
            case pSpecialties = "p_specialties"
            case pOwnerDisplayName = "p_owner_display_name"
        }
    }

    private struct UpgradeParams: Encodable {
        var pHandle: String
        var pDisplayName: String
        var pLegalName: String
        var pLegalAddress: String

        enum CodingKeys: String, CodingKey {
            case pHandle = "p_handle"
            case pDisplayName = "p_display_name"
            case pLegalName = "p_legal_name"
            case pLegalAddress = "p_legal_address"
        }
    }

    private struct UpdateOrgParams: Encodable {
        var pOrg: String
        var pLegalName: String?
        var pLegalAddress: String?
        var pAssignmentMode: String?
        var pSignerRoles: [String]?

        enum CodingKeys: String, CodingKey {
            case pOrg = "p_org"
            case pLegalName = "p_legal_name"
            case pLegalAddress = "p_legal_address"
            case pAssignmentMode = "p_assignment_mode"
            case pSignerRoles = "p_signer_roles"
        }
    }

    private struct SplitParams: Encodable {
        var pOrg: String
        var pEnabled: Bool
        enum CodingKeys: String, CodingKey {
            case pOrg = "p_org"
            case pEnabled = "p_enabled"
        }
    }

    private struct SignerParams: Encodable {
        var pOrg: String
        var pUser: String
        var pTitle: String
        enum CodingKeys: String, CodingKey {
            case pOrg = "p_org"
            case pUser = "p_user"
            case pTitle = "p_title"
        }
    }

    private struct TransferParams: Encodable {
        var pOrg: String
        var pToUser: String
        enum CodingKeys: String, CodingKey {
            case pOrg = "p_org"
            case pToUser = "p_to_user"
        }
    }

    private struct RoleParams: Encodable {
        var pOrg: String
        var pUser: String
        var pRole: String
        enum CodingKeys: String, CodingKey {
            case pOrg = "p_org"
            case pUser = "p_user"
            case pRole = "p_role"
        }
    }

    private struct MemberUpdateParams: Encodable {
        var pOrg: String
        var pUser: String
        var pTitle: String?
        var pListed: Bool?
        var pBookable: Bool?
        enum CodingKeys: String, CodingKey {
            case pOrg = "p_org"
            case pUser = "p_user"
            case pTitle = "p_title"
            case pListed = "p_listed"
            case pBookable = "p_bookable"
        }
    }

    private struct ShareParams: Encodable {
        var pOrg: String
        var pUser: String
        var pShareBps: Int
        enum CodingKeys: String, CodingKey {
            case pOrg = "p_org"
            case pUser = "p_user"
            case pShareBps = "p_share_bps"
        }
    }

    /// `member_set_hours` takes the hours or an explicit null, and a missing key is not the same as null.
    private struct HoursParams: Encodable {
        var pOrg: String
        var pWeekly: [DayHours]?

        enum CodingKeys: String, CodingKey {
            case pOrg = "p_org"
            case pWeekly = "p_weekly"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(pOrg, forKey: .pOrg)
            if let pWeekly {
                try container.encode(pWeekly, forKey: .pWeekly)
            } else {
                try container.encodeNil(forKey: .pWeekly)
            }
        }
    }

    private struct InviteCreateParams: Encodable {
        var pOrg: String
        var pRole: String
        var pEmail: String?
        enum CodingKeys: String, CodingKey {
            case pOrg = "p_org"
            case pRole = "p_role"
            case pEmail = "p_email"
        }
    }

    private struct InviteIDParams: Encodable {
        var pInviteId: String
        enum CodingKeys: String, CodingKey { case pInviteId = "p_invite_id" }
    }

    private struct TokenParams: Encodable {
        var pToken: String
        enum CodingKeys: String, CodingKey { case pToken = "p_token" }
    }

    private struct AcceptParams: Encodable {
        var pToken: String
        var pDisplayName: String?
        enum CodingKeys: String, CodingKey {
            case pToken = "p_token"
            case pDisplayName = "p_display_name"
        }
    }

    private struct ActivityParams: Encodable {
        var pOrg: String
        var pLimit: Int
        var pBefore: Date?
        enum CodingKeys: String, CodingKey {
            case pOrg = "p_org"
            case pLimit = "p_limit"
            case pBefore = "p_before"
        }
    }

    private struct DeltaParams: Encodable {
        var pOrg: String
        var pDelta: Int
        enum CodingKeys: String, CodingKey {
            case pOrg = "p_org"
            case pDelta = "p_delta"
        }
    }

    private struct BookingIDParams: Encodable {
        var pBookingId: String
        enum CodingKeys: String, CodingKey { case pBookingId = "p_booking_id" }
    }

    private struct AssignParams: Encodable {
        var pBookingId: String
        var pUserId: String
        enum CodingKeys: String, CodingKey {
            case pBookingId = "p_booking_id"
            case pUserId = "p_user_id"
        }
    }

    private struct CalendarParams: Encodable {
        var pOrg: String
        var pFrom: Date
        var pTo: Date
        var pMemberIds: [String]?
        enum CodingKeys: String, CodingKey {
            case pOrg = "p_org"
            case pFrom = "p_from"
            case pTo = "p_to"
            case pMemberIds = "p_member_ids"
        }
    }

    private struct TeamAvailabilityParams: Encodable {
        var pPackageId: String
        var pMemberId: String?
        var pFrom: Date
        var pTo: Date
        enum CodingKeys: String, CodingKey {
            case pPackageId = "p_package_id"
            case pMemberId = "p_member_id"
            case pFrom = "p_from"
            case pTo = "p_to"
        }
    }

    private struct PackageMembersParams: Encodable {
        var pPackageId: String
        var pUserIds: [String]
        enum CodingKeys: String, CodingKey {
            case pPackageId = "p_package_id"
            case pUserIds = "p_user_ids"
        }
    }

    private struct BillingSessionBody: Encodable {
        var organizationId: String
        var action: String
        enum CodingKeys: String, CodingKey {
            case organizationId = "organization_id"
            case action
        }
    }

    // MARK: - Errors

    /// The SQL functions raise plain tokens such as `last_owner`; turn them into typed errors. Team tokens come first
    /// because a few (`not_found`) also exist for bookings.
    static func mapTeamError(_ error: Error) -> Error {
        if error is SlateError { return error }
        if let mapped = mapTeamToken("\(error)") { return mapped }
        return mapBookingError(error)
    }

    /// The error a token in `text` stands for, if it names one.
    static func mapTeamToken(_ text: String) -> SlateError? {
        let known: [(token: String, error: SlateError)] = [
            ("not_allowed", .notAllowed),
            ("42501", .notAllowed),
            ("invite_invalid", .inviteInvalid),
            ("already_member", .alreadyMember),
            ("seat_limit", .seatLimit),
            ("plan_inactive", .planInactive),
            ("last_owner", .lastOwner),
            ("invalid_role", .invalidRole),
            ("has_upcoming_bookings", .hasUpcomingBookings),
            ("team_not_empty", .teamNotEmpty),
            ("bookings_in_hold", .bookingsInHold),
            ("signature_required", .signatureRequired),
            ("signer_role_not_allowed", .signerRoleNotAllowed),
            ("invalid_assignee", .invalidAssignee),
            ("not_assignable", .notAssignable),
            ("member_unavailable", .memberUnavailable),
            ("profile_required", .profileRequired),
            ("handle_taken", .handleTaken),
            ("invalid_input", .invalidInput),
            ("billing_not_configured", .billingUnavailable),
        ]
        // The longest token first: `signer_role_not_allowed` contains `not_allowed`.
        for entry in known.sorted(by: { $0.token.count > $1.token.count }) where text.contains(entry.token) { return entry.error }
        if text.contains("not_found") { return SlateError.notFound }
        return nil
    }

    private func rpcValue<Params: Encodable, Value: Decodable>(_ function: String, _ params: Params) async throws -> Value {
        do {
            return try await client.rpc(function, params: params).execute().value
        } catch {
            throw Self.mapTeamError(error)
        }
    }

    private func rpcDone<Params: Encodable>(_ function: String, _ params: Params) async throws {
        do {
            try await client.rpc(function, params: params).execute()
        } catch {
            throw Self.mapTeamError(error)
        }
    }

    // MARK: - Mapping

    func makeOrganization(_ row: OverviewRow) throws -> Organization {
        guard let id = UUID(uuidString: row.organizationId) else { throw SlateError.backend("Malformed company id.") }
        let plan = row.plan.map { plan in
            PlanSummary.make(
                required: plan.required, status: PlanStatus(rawValue: plan.status) ?? .none, graceUntil: plan.graceUntil,
                cancelAtPeriodEnd: plan.cancelAtPeriodEnd ?? false, periodEnd: plan.periodEnd
            )
        } ?? PlanSummary.notRequired
        return Organization(
            id: id, name: row.name, handle: row.handle,
            avatarURL: try row.avatarPath.map { try publicURL(bucket: "avatars", path: $0) },
            bio: row.bio ?? "", locationName: row.locationName, specialties: (row.specialties ?? []).compactMap(Specialty.init(rawValue:)),
            legalName: row.legalName, legalAddress: row.legalAddress,
            assignmentMode: AssignmentMode(rawValue: row.assignmentMode) ?? .auto,
            signerRoles: row.signerRoles.compactMap(OrgRole.init(rawValue:)),
            signerUserID: row.signerUserId.flatMap(UUID.init(uuidString:)),
            signerTitle: row.signerTitle ?? "", splitEnabled: row.splitEnabled,
            state: OrgState(rawValue: row.state) ?? .active, myRole: OrgRole(rawValue: row.myRole) ?? .viewer,
            myTitle: row.myTitle ?? "", myHours: row.myHours,
            seats: SeatCounts(used: row.seats.used, pending: row.seats.pending, billed: row.seats.billed,
                              minimum: row.seats.minimum, maximum: row.seats.maximum),
            plan: plan
        )
    }

    func makeMember(_ row: MemberRow) throws -> TeamMember {
        guard let id = UUID(uuidString: row.userId) else { throw SlateError.backend("Malformed member id.") }
        return TeamMember(
            userID: id, role: OrgRole(rawValue: row.role) ?? .viewer, title: row.title ?? "", listed: row.listed,
            bookable: row.bookable, shareBps: row.shareBps, joinedAt: row.joinedAt, displayName: row.displayName,
            handle: row.handle, avatarURL: try row.avatarPath.map { try publicURL(bucket: "avatars", path: $0) },
            isSigner: row.isSigner ?? false
        )
    }

    func makeInvite(_ row: InviteRow) throws -> OrgInvite {
        guard let id = UUID(uuidString: row.id) else { throw SlateError.backend("Malformed invite id.") }
        return OrgInvite(
            id: id, role: OrgRole(rawValue: row.role) ?? .viewer, email: row.email,
            status: row.status == "expired" ? .expired : .pending, createdAt: row.createdAt, expiresAt: row.expiresAt,
            invitedByName: row.invitedByName.flatMap { $0.isEmpty ? nil : $0 }
        )
    }

    func makeCreatedInvite(_ row: CreatedInviteRow) throws -> CreatedInvite {
        guard let id = UUID(uuidString: row.invite.id) else { throw SlateError.backend("Malformed invite id.") }
        return CreatedInvite(
            invite: OrgInvite(id: id, role: OrgRole(rawValue: row.invite.role) ?? .viewer, email: row.invite.email, status: .pending,
                              createdAt: row.invite.createdAt, expiresAt: row.invite.expiresAt, invitedByName: nil),
            token: row.token
        )
    }

    func makeCalendarBooking(_ row: CalendarBookingRow) -> CalendarBooking {
        CalendarBooking(
            bookingID: row.id.flatMap(UUID.init(uuidString:)), startAt: row.startAt, endAt: row.endAt,
            blockedUntil: row.blockedUntil, status: BookingStatus(rawValue: row.status) ?? .confirmed,
            packageName: row.packageName, clientName: row.clientName, requestedMember: row.requestedMember ?? false
        )
    }

    func makeTeamCalendar(_ row: TeamCalendarRow) throws -> TeamCalendar {
        var members: [MemberCalendar] = []
        for member in row.members {
            guard let id = UUID(uuidString: member.userId) else { continue }
            members.append(MemberCalendar(
                userID: id, displayName: member.displayName,
                avatarURL: try member.avatarPath.map { try publicURL(bucket: "avatars", path: $0) },
                role: OrgRole(rawValue: member.role) ?? .viewer, title: member.title ?? "", bookable: member.bookable,
                weekly: member.weekly,
                busy: member.busy.filter { $0.endsAt > $0.startsAt }.map {
                    BusyRange(range: DateInterval(start: $0.startsAt, end: $0.endsAt), kind: BusyRange.Kind(rawValue: $0.kind ?? "") ?? .external)
                },
                bookings: member.bookings.map(makeCalendarBooking)
            ))
        }
        return TeamCalendar(
            timeZoneID: row.timeZone ?? TimeZone.current.identifier, members: members, unassigned: row.unassigned.map(makeCalendarBooking)
        )
    }

    func makeTeamSchedule(_ row: TeamAvailabilityRow) -> TeamSchedule {
        let settings = AvailabilitySettings(
            timeZoneID: row.settings.timeZone, weekly: row.settings.weekly, blackouts: row.settings.blackouts,
            minNoticeHours: row.settings.minNoticeHours, maxAdvanceDays: row.settings.maxAdvanceDays,
            bufferMinutes: row.settings.bufferMinutes, slotIntervalMinutes: row.settings.slotIntervalMinutes
        )
        func ranges(_ rows: [BusyRow]) -> [DateInterval] {
            rows.filter { $0.endsAt > $0.startsAt }.map { DateInterval(start: $0.startsAt, end: $0.endsAt) }
        }
        return TeamSchedule(
            settings: settings, assignmentMode: AssignmentMode(rawValue: row.assignmentMode) ?? .auto,
            members: row.members.compactMap { member in
                UUID(uuidString: member.userId).map {
                    MemberSchedule(userID: $0, displayName: member.displayName, weekly: member.weekly, busy: ranges(member.busy))
                }
            },
            unassigned: ranges(row.unassigned)
        )
    }

    // MARK: - Accounts

    func loadTeamConfig() async throws -> TeamConfig {
        let row: TeamConfigRow = try await rpcValue("team_config", NoParams())
        return TeamConfig(seatMinimum: row.seatMinimum, seatMaximum: row.seatMaximum, inviteExpiryDays: row.inviteExpiryDays, graceDays: row.graceDays)
    }

    func loadAccounts(for userID: UUID) async throws -> AccountList {
        let row: AccountsRow = try await rpcValue("my_accounts", NoParams())
        let companies = try row.companies.compactMap { company -> CompanyAccount? in
            guard let id = UUID(uuidString: company.organizationId) else { return nil }
            return CompanyAccount(
                organizationID: id, name: company.name, handle: company.handle,
                avatarURL: try company.avatarPath.map { try publicURL(bucket: "avatars", path: $0) },
                role: OrgRole(rawValue: company.role) ?? .viewer, title: company.title ?? "",
                state: OrgState(rawValue: company.state) ?? .active
            )
        }
        return AccountList(hasPersonalProfile: row.personal.hasProfile, companies: companies)
    }

    // MARK: - Starting a company

    func createOrganization(_ draft: OrganizationDraft, by userID: UUID) async throws -> Organization {
        if draft.problem != nil { throw SlateError.invalidInput }
        let row: OverviewRow = try await rpcValue("org_create", CreateOrgParams(
            pHandle: draft.handle, pDisplayName: draft.name, pLegalName: draft.legalName, pLegalAddress: draft.legalAddress,
            pBio: draft.bio, pSpecialties: draft.specialties.map(\.rawValue), pOwnerDisplayName: draft.ownerDisplayName
        ))
        return try makeOrganization(row)
    }

    func upgradeToCompany(_ draft: OrganizationDraft, by userID: UUID) async throws -> Organization {
        if draft.problem != nil { throw SlateError.invalidInput }
        let row: OverviewRow = try await rpcValue("org_upgrade", UpgradeParams(
            pHandle: draft.handle, pDisplayName: draft.name, pLegalName: draft.legalName, pLegalAddress: draft.legalAddress
        ))
        return try makeOrganization(row)
    }

    func downgradeToIndividual(organizationID: UUID, by userID: UUID) async throws {
        try await rpcDone("org_downgrade", OrgParams(pOrg: Self.key(organizationID)))
    }

    func loadOrganization(_ id: UUID, for userID: UUID) async throws -> Organization {
        try makeOrganization(try await rpcValue("org_overview", OrgParams(pOrg: Self.key(id))))
    }

    func updateOrganization(_ id: UUID, with update: OrganizationUpdate, by userID: UUID) async throws -> Organization {
        let row: OverviewRow = try await rpcValue("org_update", UpdateOrgParams(
            pOrg: Self.key(id), pLegalName: update.legalName, pLegalAddress: update.legalAddress,
            pAssignmentMode: update.assignmentMode?.rawValue, pSignerRoles: update.signerRoles?.map(\.rawValue)
        ))
        return try makeOrganization(row)
    }

    func setSplitEnabled(_ enabled: Bool, organizationID: UUID, by userID: UUID) async throws -> Organization {
        try makeOrganization(try await rpcValue("org_set_split", SplitParams(pOrg: Self.key(organizationID), pEnabled: enabled)))
    }

    func designateSigner(userID: UUID, title: String, organizationID: UUID, by actorID: UUID) async throws -> Organization {
        try makeOrganization(try await rpcValue("org_designate_signer", SignerParams(
            pOrg: Self.key(organizationID), pUser: Self.key(userID), pTitle: title
        )))
    }

    func transferOwnership(organizationID: UUID, to userID: UUID, by actorID: UUID) async throws {
        try await rpcDone("org_transfer_ownership", TransferParams(pOrg: Self.key(organizationID), pToUser: Self.key(userID)))
    }

    func closeOrganization(_ id: UUID, by userID: UUID) async throws {
        try await rpcDone("org_close", OrgParams(pOrg: Self.key(id)))
    }

    // MARK: - Members

    func loadMembers(organizationID: UUID, for userID: UUID) async throws -> [TeamMember] {
        let rows: [MemberRow] = try await rpcValue("member_list", OrgParams(pOrg: Self.key(organizationID)))
        return try rows.map(makeMember)
    }

    func setMemberRole(_ role: OrgRole, memberID: UUID, organizationID: UUID, by userID: UUID) async throws {
        try await rpcDone("member_set_role", RoleParams(pOrg: Self.key(organizationID), pUser: Self.key(memberID), pRole: role.rawValue))
    }

    func updateMember(_ update: MemberUpdate, memberID: UUID, organizationID: UUID, by userID: UUID) async throws {
        try await rpcDone("member_update", MemberUpdateParams(
            pOrg: Self.key(organizationID), pUser: Self.key(memberID),
            pTitle: update.title, pListed: update.listed, pBookable: update.bookable
        ))
    }

    func setMemberShare(bps: Int, memberID: UUID, organizationID: UUID, by userID: UUID) async throws {
        try await rpcDone("member_set_share", ShareParams(pOrg: Self.key(organizationID), pUser: Self.key(memberID), pShareBps: bps))
    }

    func removeMember(memberID: UUID, organizationID: UUID, by userID: UUID) async throws {
        try await rpcDone("member_remove", OrgUserParams(pOrg: Self.key(organizationID), pUser: Self.key(memberID)))
    }

    func leaveOrganization(_ id: UUID, by userID: UUID) async throws {
        try await rpcDone("member_leave", OrgParams(pOrg: Self.key(id)))
    }

    func saveMyHours(_ hours: [DayHours]?, organizationID: UUID, by userID: UUID) async throws {
        try await rpcDone("member_set_hours", HoursParams(pOrg: Self.key(organizationID), pWeekly: hours))
    }

    // MARK: - Invites

    func loadInvites(organizationID: UUID, for userID: UUID) async throws -> [OrgInvite] {
        let rows: [InviteRow] = try await rpcValue("invite_list", OrgParams(pOrg: Self.key(organizationID)))
        return try rows.map(makeInvite)
    }

    func createInvite(role: OrgRole, email: String?, organizationID: UUID, by userID: UUID) async throws -> CreatedInvite {
        let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let clean = TeamRules.cleanInviteEmail(trimmed)
        if !trimmed.isEmpty, clean == nil { throw SlateError.invalidInput }
        let row: CreatedInviteRow = try await rpcValue("invite_create", InviteCreateParams(
            pOrg: Self.key(organizationID), pRole: role.rawValue, pEmail: clean
        ))
        return try makeCreatedInvite(row)
    }

    func revokeInvite(_ id: UUID, organizationID: UUID, by userID: UUID) async throws {
        try await rpcDone("invite_revoke", InviteIDParams(pInviteId: Self.key(id)))
    }

    func resendInvite(_ id: UUID, organizationID: UUID, by userID: UUID) async throws -> CreatedInvite {
        let row: CreatedInviteRow = try await rpcValue("invite_resend", InviteIDParams(pInviteId: Self.key(id)))
        return try makeCreatedInvite(row)
    }

    func previewInvite(token: String, for userID: UUID) async throws -> InvitePreview {
        let row: PreviewInviteRow = try await rpcValue("invite_preview", TokenParams(pToken: token))
        guard let id = UUID(uuidString: row.organizationId) else { throw SlateError.inviteInvalid }
        return InvitePreview(
            organizationID: id, organizationName: row.organizationName ?? "", role: OrgRole(rawValue: row.role) ?? .viewer,
            invitedByName: row.invitedByName.flatMap { $0.isEmpty ? nil : $0 }, expiresAt: row.expiresAt,
            alreadyMember: row.alreadyMember, hasProfile: row.hasProfile
        )
    }

    func acceptInvite(token: String, displayName: String?, by userID: UUID) async throws -> Organization {
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let row: OverviewRow = try await rpcValue("accept_invite", AcceptParams(pToken: token, pDisplayName: (name?.isEmpty ?? true) ? nil : name))
        return try makeOrganization(row)
    }

    /// Real people accept their own invites on their own phones.
    func completeSimulatedJoin(inviteID: UUID, displayName: String) async throws -> UUID {
        throw SlateError.backend("Pretend teammates only exist when the app runs on this device alone.")
    }

    // MARK: - Activity and billing

    func loadActivity(organizationID: UUID, limit: Int, before: Date?, for userID: UUID) async throws -> [ActivityEntry] {
        let rows: [ActivityRow] = try await rpcValue("activity_list", ActivityParams(
            pOrg: Self.key(organizationID), pLimit: max(1, min(limit, 200)), pBefore: before
        ))
        return rows.compactMap { row in
            guard let id = UUID(uuidString: row.id) else { return nil }
            return ActivityEntry(
                id: id, actorID: row.actorId.flatMap(UUID.init(uuidString:)), actorName: row.actorName ?? "",
                action: row.action, summary: row.summary, createdAt: row.createdAt
            )
        }
    }

    func loadBilling(organizationID: UUID, for userID: UUID) async throws -> BillingOverview {
        let row: BillingRow = try await rpcValue("billing_overview", OrgParams(pOrg: Self.key(organizationID)))
        let plan = PlanSummary.make(
            required: row.required, status: PlanStatus(rawValue: row.status) ?? .none, graceUntil: row.graceUntil,
            cancelAtPeriodEnd: row.cancelAtPeriodEnd ?? false, periodEnd: row.currentPeriodEnd
        )
        return BillingOverview(
            plan: plan,
            seats: SeatCounts(used: row.seats.used, pending: row.seats.pending, billed: row.seats.billed,
                              minimum: row.seats.minimum, maximum: row.seats.maximum),
            seatsBilledByStripe: row.seatsBilledByStripe ?? 0, trialEnd: row.trialEnd, state: OrgState(rawValue: row.state) ?? .active
        )
    }

    func previewSeatChange(delta: Int, organizationID: UUID, for userID: UUID) async throws -> SeatPlan {
        let row: SeatPlanRow = try await rpcValue("billing_preview", DeltaParams(pOrg: Self.key(organizationID), pDelta: delta))
        return SeatPlan(
            used: row.used, usedAfter: row.usedAfter, billedNow: row.billedNow, billedAfter: row.billedAfter,
            allowed: row.allowed, change: SeatPlan.Change(rawValue: row.change) ?? .none
        )
    }

    func beginBilling(_ action: BillingAction, organizationID: UUID, by userID: UUID) async throws -> URL {
        do {
            let reply: BillingSessionReply = try await client.functions.invoke(
                "billing-session",
                options: FunctionInvokeOptions(body: BillingSessionBody(organizationId: Self.key(organizationID), action: action.rawValue))
            )
            guard let url = URL(string: reply.url), url.scheme == "https" else { throw SlateError.billingUnavailable }
            return url
        } catch let error as FunctionsError {
            if case .httpError(_, let data) = error, let text = String(data: data, encoding: .utf8) {
                throw Self.mapTeamToken(text) ?? SlateError.billingUnavailable
            }
            throw SlateError.billingUnavailable
        }
    }

    // MARK: - Assigning bookings

    func loadAssignmentQueue(organizationID: UUID, for userID: UUID) async throws -> [Booking] {
        let rows: [BookingRow] = try await rpcValue("assignment_queue", OrgParams(pOrg: Self.key(organizationID)))
        return try rows.map(makeBooking)
    }

    func loadAssignmentOptions(bookingID: UUID, for userID: UUID) async throws -> [AssignmentOption] {
        let rows: [OptionRow] = try await rpcValue("assignment_options", BookingIDParams(pBookingId: Self.key(bookingID)))
        return rows.compactMap { row in
            UUID(uuidString: row.userId).map {
                AssignmentOption(userID: $0, displayName: row.displayName, isFree: row.free, reason: row.reason)
            }
        }
    }

    func assignBooking(_ bookingID: UUID, to memberID: UUID, by userID: UUID) async throws -> Booking {
        let row: BookingRow = try await rpcValue("assign_booking", AssignParams(pBookingId: Self.key(bookingID), pUserId: Self.key(memberID)))
        return try makeBooking(row)
    }

    // MARK: - Calendar and shared services

    func loadTeamCalendar(organizationID: UUID, from: Date, to: Date, members: Set<UUID>, for userID: UUID) async throws -> TeamCalendar {
        let row: TeamCalendarRow = try await rpcValue("team_calendar", CalendarParams(
            pOrg: Self.key(organizationID), pFrom: from, pTo: max(to, from),
            pMemberIds: members.isEmpty ? nil : members.map(Self.key)
        ))
        return try makeTeamCalendar(row)
    }

    func loadTeamSchedule(packageID: UUID, memberID: UUID?, from: Date, to: Date) async throws -> TeamSchedule {
        let row: TeamAvailabilityRow = try await rpcValue("team_availability", TeamAvailabilityParams(
            pPackageId: Self.key(packageID), pMemberId: memberID.map(Self.key), pFrom: from, pTo: max(to, from)
        ))
        return makeTeamSchedule(row)
    }

    func loadPackageMembers(packageID: UUID) async throws -> [UUID] {
        let rows: [PackageMemberRow] = try await client
            .from("package_members")
            .select("user_id")
            .eq("package_id", value: Self.key(packageID))
            .execute()
            .value
        return rows.compactMap { UUID(uuidString: $0.userId) }
    }

    func setPackageMembers(_ memberIDs: [UUID], packageID: UUID, by userID: UUID) async throws {
        try await rpcDone("package_set_members", PackageMembersParams(pPackageId: Self.key(packageID), pUserIds: memberIDs.map(Self.key)))
    }

    /// The people a client may book from a company's page.
    func loadPublicTeam(organizationID: UUID) async throws -> [PublicTeamMember] {
        let rows: [PublicMemberRow] = try await rpcValue("org_public_team", OrgParams(pOrg: Self.key(organizationID)))
        return try rows.compactMap { row in
            guard let id = UUID(uuidString: row.userId) else { return nil }
            return PublicTeamMember(
                userID: id, displayName: row.displayName, handle: row.handle,
                avatarURL: try row.avatarPath.map { try publicURL(bucket: "avatars", path: $0) },
                bio: row.bio ?? "", specialties: (row.specialties ?? []).compactMap(Specialty.init(rawValue:)), title: row.title ?? ""
            )
        }
    }
}
