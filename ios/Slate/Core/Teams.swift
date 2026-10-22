import Foundation

// MARK: - Account kind

/// Whether a profile is a person or a company. A person's profile id is their user id; a company's is its
/// organization id. Everything that has an owner (services, bookings, contracts, payment accounts) points at one.
enum ProfileKind: String, Codable, Hashable {
    case person, company
}

// MARK: - Roles and permissions

/// What a person is in a company. SPEC section 4.2.
enum OrgRole: String, Codable, CaseIterable, Identifiable, Hashable {
    case owner, admin, manager, creator, viewer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .owner: "Owner"
        case .admin: "Admin"
        case .manager: "Manager"
        case .creator: "Creator"
        case .viewer: "Viewer"
        }
    }

    /// One line on what the role is for, shown where a role is chosen.
    var summary: String {
        switch self {
        case .owner: "Billing, deleting the company, and everything else."
        case .admin: "Manages the team, services, prices and contract templates."
        case .manager: "Assigns and manages bookings, and sees reports."
        case .creator: "Manages their own calendar and the bookings assigned to them."
        case .viewer: "Can look, not change."
        }
    }

    /// SF Symbol shown beside the role.
    var symbol: String {
        switch self {
        case .owner: "crown.fill"
        case .admin: "person.badge.key.fill"
        case .manager: "list.clipboard.fill"
        case .creator: "camera.fill"
        case .viewer: "eye.fill"
        }
    }

    /// Whether a booking can be assigned to someone in this role. A Viewer can't take bookings.
    var canTakeBookings: Bool { self != .viewer }

    func allows(_ permission: OrgPermission) -> Bool { permission.roles.contains(self) }
}

/// Everything a role can be allowed to do. The table is SPEC section 4.3; `SlateTests/Fixtures/team_permissions.json`
/// holds the same table and both this file and the database's `org_role_allows` are tested against it.
enum OrgPermission: String, CaseIterable, Codable, Hashable {
    case companyDelete = "company.delete"
    case billingManage = "billing.manage"
    case paymentsConnect = "payments.connect"
    case payoutsSplit = "payouts.split"
    case companyEdit = "company.edit"
    case teamInvite = "team.invite"
    case teamManage = "team.manage"
    case servicesManage = "services.manage"
    case templatesManage = "templates.manage"
    case signerDesignate = "signer.designate"
    case activityView = "activity.view"
    case bookingsAssign = "bookings.assign"
    case bookingsManage = "bookings.manage"
    case bookingsViewAll = "bookings.view_all"
    case reportsView = "reports.view"
    case bookingsManageAssigned = "bookings.manage_assigned"
    case calendarManageOwn = "calendar.manage_own"
    case calendarViewTeam = "calendar.view_team"
    case teamView = "team.view"

    var roles: Set<OrgRole> {
        switch self {
        case .companyDelete, .billingManage, .paymentsConnect, .payoutsSplit:
            [.owner]
        case .companyEdit, .teamInvite, .teamManage, .servicesManage, .templatesManage, .signerDesignate, .activityView:
            [.owner, .admin]
        case .bookingsAssign, .bookingsManage:
            [.owner, .admin, .manager]
        case .bookingsViewAll, .reportsView:
            [.owner, .admin, .manager, .viewer]
        case .bookingsManageAssigned, .calendarManageOwn:
            [.owner, .admin, .manager, .creator]
        case .calendarViewTeam, .teamView:
            [.owner, .admin, .manager, .creator, .viewer]
        }
    }
}

/// Whether a company is open for business.
enum OrgState: String, Codable, Hashable {
    /// Working normally.
    case active
    /// The plan lapsed: everyone can read, only billing and closing work.
    case lapsed
    /// Deleted. Kept only because signed contracts name it.
    case closed
}

enum RoleRules {
    /// Who may give someone a role. The Owner works on anyone but themselves (not an Owner, and not into one: ownership
    /// is transferred). An Admin works only on Managers, Creators and Viewers. Callers also refuse changing yourself.
    static func canAssign(actor: OrgRole, current: OrgRole, new: OrgRole) -> Bool {
        switch actor {
        case .owner: current != .owner && new != .owner
        case .admin: current.isBelowAdmin && new.isBelowAdmin
        case .manager, .creator, .viewer: false
        }
    }

    /// Can this role remove, or edit the team profile of, someone in the other role?
    static func canManage(actor: OrgRole, target: OrgRole) -> Bool {
        switch actor {
        case .owner: target != .owner
        case .admin: target.isBelowAdmin
        case .manager, .creator, .viewer: false
        }
    }

    /// The roles an invite from this role can offer.
    static func invitableRoles(by actor: OrgRole) -> [OrgRole] {
        OrgRole.allCases.filter { $0 != .owner && canAssign(actor: actor, current: .viewer, new: $0) }
    }

    /// The roles this role may change someone to, when the person is currently `current`.
    static func assignableRoles(by actor: OrgRole, to current: OrgRole) -> [OrgRole] {
        OrgRole.allCases.filter { canAssign(actor: actor, current: current, new: $0) }
    }

    /// What still works when a company's plan has lapsed: reading, the Owner's billing, and closing.
    static let allowedWhenLapsed: Set<OrgPermission> = [
        .bookingsViewAll, .reportsView, .calendarViewTeam, .teamView, .activityView, .billingManage, .companyDelete,
    ]

    /// Does someone in this role hold the permission in a company in this state?
    static func allows(_ permission: OrgPermission, role: OrgRole, state: OrgState) -> Bool {
        guard role.allows(permission) else { return false }
        switch state {
        case .active: return true
        case .lapsed: return allowedWhenLapsed.contains(permission)
        case .closed: return false
        }
    }
}

private extension OrgRole {
    var isBelowAdmin: Bool { self == .manager || self == .creator || self == .viewer }
}

// MARK: - Settings

/// How new bookings reach a company's people.
enum AssignmentMode: String, Codable, CaseIterable, Identifiable, Hashable {
    /// The free, eligible person with the fewest upcoming bookings gets it.
    case auto
    /// It waits for a Manager to choose.
    case manual

    var id: String { rawValue }

    var title: String { self == .auto ? "Automatically" : "A manager assigns them" }

    var detail: String {
        switch self {
        case .auto: "A new booking goes to the free team member with the fewest upcoming bookings."
        case .manual: "New bookings wait in a queue until a manager picks who takes them."
        }
    }
}

/// The numbers that are meant to change without touching rules code. The database holds the real values
/// (`app_settings`); the app asks for them, and uses these until it has.
struct TeamConfig: Codable, Equatable, Hashable {
    /// Billing floor: a company is billed for at least this many seats.
    var seatMinimum: Int
    /// The most people a company can have, counting open invites.
    var seatMaximum: Int
    var inviteExpiryDays: Int
    /// How long a company keeps working after a payment fails.
    var graceDays: Int

    static let standard = TeamConfig(seatMinimum: 10, seatMaximum: 250, inviteExpiryDays: 7, graceDays: 7)
}

// MARK: - Seats

/// What adding or removing people does to the seats billed. `SlateTests/Fixtures/seat_rules.json` is checked against
/// this and the database's `seat_plan`.
struct SeatPlan: Equatable, Hashable {
    enum Change: String, Codable, Hashable {
        case increase, decrease, none
    }

    var used: Int
    var usedAfter: Int
    var billedNow: Int
    var billedAfter: Int
    /// False if the change would take the team past the maximum.
    var allowed: Bool
    var change: Change

    static func make(used: Int, delta: Int, config: TeamConfig = .standard) -> SeatPlan {
        let before = max(used, 0)
        let after = max(used + delta, 0)
        let billedNow = max(config.seatMinimum, before)
        let billedAfter = max(config.seatMinimum, after)
        return SeatPlan(
            used: before,
            usedAfter: after,
            billedNow: billedNow,
            billedAfter: billedAfter,
            allowed: used + delta <= config.seatMaximum,
            change: billedAfter > billedNow ? .increase : (billedAfter < billedNow ? .decrease : .none)
        )
    }

    /// Plain words for what happens to the bill, for the sheet that asks before someone adds or removes a person.
    func billingSentence(periodEnd: Date?) -> String {
        switch change {
        case .none:
            return "Your bill doesn't change: you're billed for at least \(billedNow) seats."
        case .increase:
            return "Seats billed go from \(billedNow) to \(billedAfter). The extra is charged now, for the rest of this period."
        case .decrease:
            let when = periodEnd.map { "from your next invoice on \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "from your next invoice"
            return "Seats billed go from \(billedNow) to \(billedAfter), \(when). Nothing is refunded for the rest of this period."
        }
    }
}

// MARK: - Plan

enum PlanStatus: String, Codable, Hashable {
    case none, trialing, active
    case pastDue = "past_due"
    case canceled

    var title: String {
        switch self {
        case .none: "No plan yet"
        case .trialing: "Free trial"
        case .active: "Active"
        case .pastDue: "Payment failed"
        case .canceled: "Cancelled"
        }
    }
}

struct SeatCounts: Codable, Equatable, Hashable {
    /// Active members.
    var used: Int
    /// Open invites. Not billed until accepted, but counted toward the maximum.
    var pending: Int
    /// Seats billed: at least the floor.
    var billed: Int
    var minimum: Int
    var maximum: Int

    /// How many more people fit, counting open invites.
    var remaining: Int { max(0, maximum - used - pending) }
}

struct PlanSummary: Codable, Equatable, Hashable {
    /// False in a project with no billing set up, where every company can work.
    var required: Bool
    var status: PlanStatus
    /// Whether the company may take members and bookings right now.
    var isOK: Bool
    var graceUntil: Date?
    var cancelAtPeriodEnd: Bool
    var periodEnd: Date?

    static let unsubscribed = PlanSummary(required: true, status: .none, isOK: false, graceUntil: nil, cancelAtPeriodEnd: false, periodEnd: nil)
    static let notRequired = PlanSummary(required: false, status: .none, isOK: true, graceUntil: nil, cancelAtPeriodEnd: false, periodEnd: nil)

    /// What the people running the company should be told, if anything.
    var banner: String? {
        guard required else { return nil }
        switch status {
        case .none: return "Choose a plan to invite your team and take bookings."
        case .pastDue:
            if let graceUntil { return "A payment failed. Update your card by \(graceUntil.formatted(date: .abbreviated, time: .omitted)) to keep working." }
            return "A payment failed. Update your card to keep working."
        case .canceled: return "The plan ended. Choose a plan to take bookings again."
        case .trialing, .active:
            if cancelAtPeriodEnd, let periodEnd { return "The plan ends on \(periodEnd.formatted(date: .abbreviated, time: .omitted))." }
            return nil
        }
    }
}

// MARK: - The company

/// A company as one of its members sees it.
struct Organization: Identifiable, Codable, Equatable, Hashable {
    /// The organization id, which is also its public profile id.
    var id: UUID
    var name: String
    var handle: String
    var avatarURL: URL?
    var bio: String
    var locationName: String?
    var specialties: [Specialty]
    /// The name that appears on contracts.
    var legalName: String
    var legalAddress: String
    var assignmentMode: AssignmentMode
    /// Roles that may be named to countersign contracts.
    var signerRoles: [OrgRole]
    var signerUserID: UUID?
    var signerTitle: String
    var splitEnabled: Bool
    var state: OrgState
    var myRole: OrgRole
    var myTitle: String
    /// The person's own hours at this company, narrowing the company's. Nil means the company's hours.
    var myHours: [DayHours]?
    var seats: SeatCounts
    var plan: PlanSummary

    func can(_ permission: OrgPermission) -> Bool {
        RoleRules.allows(permission, role: myRole, state: state)
    }

    /// Clients can't book a company without someone to countersign its contracts.
    var hasSigner: Bool { signerUserID != nil }
}

/// A person on a team.
struct TeamMember: Identifiable, Codable, Equatable, Hashable {
    var userID: UUID
    var role: OrgRole
    var title: String
    /// Shown on the company page.
    var listed: Bool
    /// Can be assigned bookings, and booked directly.
    var bookable: Bool
    /// Their share of each booking assigned to them, in basis points. Only the Owner sees it.
    var shareBps: Int
    var joinedAt: Date
    var displayName: String
    var handle: String?
    var avatarURL: URL?
    var isSigner: Bool

    var id: UUID { userID }

    /// "Lead videographer" if they have a title, otherwise their role.
    var subtitle: String { title.isEmpty ? role.title : title }
}

/// An invite that hasn't been accepted.
struct OrgInvite: Identifiable, Codable, Equatable, Hashable {
    enum Status: String, Codable, Hashable {
        case pending, expired
    }

    var id: UUID
    var role: OrgRole
    var email: String?
    var status: Status
    var createdAt: Date
    var expiresAt: Date
    var invitedByName: String?
}

/// A new invite, with the link that is shown once. The token is never stored; only its hash is.
struct CreatedInvite: Equatable {
    var invite: OrgInvite
    var token: String

    /// `slate://join/<token>`: opens the app. (A web address for people without it comes with the web page.)
    var link: URL? { AppConfig.joinDeepLink(token: token) }
}

/// What the person who opened an invite link sees before joining.
struct InvitePreview: Equatable {
    var organizationID: UUID
    var organizationName: String
    var role: OrgRole
    var invitedByName: String?
    var expiresAt: Date
    var alreadyMember: Bool
    var hasProfile: Bool
}

/// One line of the activity log: who changed what.
struct ActivityEntry: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var actorID: UUID?
    var actorName: String
    /// A dotted key such as `package.price_changed`, for choosing a symbol.
    var action: String
    var summary: String
    var createdAt: Date

    var symbol: String {
        let family = action.split(separator: ".").first.map(String.init) ?? ""
        switch family {
        case "booking": return "calendar"
        case "contract": return "doc.text.fill"
        case "package", "template": return "tag.fill"
        case "member", "invite": return "person.2.fill"
        case "plan": return "creditcard.fill"
        case "signer": return "signature"
        default: return "building.2.fill"
        }
    }
}

// MARK: - Accounts

/// One company a person works for, as listed in the account switcher.
struct CompanyAccount: Identifiable, Codable, Equatable, Hashable {
    var organizationID: UUID
    var name: String
    var handle: String
    var avatarURL: URL?
    var role: OrgRole
    var title: String
    var state: OrgState

    var id: UUID { organizationID }
}

/// Every account a signed-in person can act as.
struct AccountList: Equatable {
    var hasPersonalProfile: Bool
    var companies: [CompanyAccount]

    static let empty = AccountList(hasPersonalProfile: false, companies: [])
}

/// Which account the app is showing. Personal is the person's own; a company is one they work for.
enum ActiveAccount: Hashable, Codable {
    case personal
    case company(UUID)

    var companyID: UUID? {
        if case .company(let id) = self { return id }
        return nil
    }

    private static let personalKey = "personal"

    /// Stored per device, so the app opens on the account that was last used.
    var storageValue: String {
        switch self {
        case .personal: Self.personalKey
        case .company(let id): id.uuidString.lowercased()
        }
    }

    init(storageValue: String?) {
        if let storageValue, let id = UUID(uuidString: storageValue) {
            self = .company(id)
        } else {
            self = .personal
        }
    }
}

// MARK: - Rules for inputs

enum TeamRules {
    static let titleLimit = 80
    static let legalNameLength = 2...120
    static let legalAddressLimit = 300
    static let companyNameLength = 1...80

    /// A label for an invite. It is never matched against who accepts it (Hide My Email hides the real address).
    static func cleanInviteEmail(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= 254, let at = trimmed.firstIndex(of: "@"), at != trimmed.startIndex,
              trimmed.index(after: at) != trimmed.endIndex, trimmed.filter({ $0 == "@" }).count == 1,
              !trimmed.contains(" ")
        else { return nil }
        return trimmed
    }

    /// Whether a share of a booking is a valid number of basis points.
    static func isValidShare(_ bps: Int) -> Bool { (0...10_000).contains(bps) }

    /// "30%" for 3000 basis points; "12.5%" for 1250.
    static func shareText(_ bps: Int) -> String {
        let percent = Double(bps) / 100
        return percent.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(percent))%" : String(format: "%.1f%%", percent)
    }
}

// MARK: - Inputs

/// What it takes to start a company.
struct OrganizationDraft: Equatable {
    /// The public name on the company page.
    var name: String
    var handle: String
    /// The name on contracts.
    var legalName: String
    var legalAddress: String = ""
    var bio: String = ""
    var specialties: [Specialty] = []
    var locationName: String? = nil
    /// The Owner's own display name, if they have no profile of their own yet.
    var ownerDisplayName: String? = nil

    var problem: Problem? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TeamRules.companyNameLength.contains(trimmedName.count) else { return .name }
        if let issue = HandleRules.validate(handle) { return .handle(issue) }
        guard TeamRules.legalNameLength.contains(legalName.trimmingCharacters(in: .whitespacesAndNewlines).count) else { return .legalName }
        guard legalAddress.count <= TeamRules.legalAddressLimit else { return .legalAddress }
        return nil
    }

    enum Problem: Equatable {
        case name
        case handle(HandleRules.Problem)
        case legalName
        case legalAddress
    }
}

/// Changes to company settings. Nil leaves a setting alone.
struct OrganizationUpdate: Equatable {
    var legalName: String? = nil
    var legalAddress: String? = nil
    var assignmentMode: AssignmentMode? = nil
    var signerRoles: [OrgRole]? = nil
}

/// Changes to a person's team profile. Nil leaves a setting alone.
struct MemberUpdate: Equatable {
    var title: String? = nil
    var listed: Bool? = nil
    var bookable: Bool? = nil
}

// MARK: - Public

/// A person on a company's page. Clients can book them directly.
struct PublicTeamMember: Identifiable, Codable, Equatable, Hashable {
    var userID: UUID
    var displayName: String
    var handle: String?
    var avatarURL: URL?
    var bio: String
    var specialties: [Specialty]
    var title: String

    var id: UUID { userID }
}

// MARK: - Assigning

/// One person a booking could go to, and whether they are free at its time.
struct AssignmentOption: Identifiable, Equatable, Hashable {
    var userID: UUID
    var displayName: String
    var isFree: Bool
    /// Why not, in a few words ("Already booked").
    var reason: String?

    var id: UUID { userID }
}

/// Picks who takes a booking. The database and `LocalBackend` follow it the same way.
enum AssignmentPlanner {
    struct Candidate: Equatable {
        var userID: UUID
        var joinedAt: Date
        /// Open bookings from now on.
        var upcoming: Int
        var isFree: Bool
    }

    /// The free person with the fewest upcoming bookings; a tie goes to whoever joined first, then to the lowest id,
    /// so two devices looking at the same team always agree.
    static func choose(from candidates: [Candidate]) -> UUID? {
        candidates
            .filter(\.isFree)
            .sorted { lhs, rhs in
                if lhs.upcoming != rhs.upcoming { return lhs.upcoming < rhs.upcoming }
                if lhs.joinedAt != rhs.joinedAt { return lhs.joinedAt < rhs.joinedAt }
                return lhs.userID.uuidString.lowercased() < rhs.userID.uuidString.lowercased()
            }
            .first?.userID
    }
}

// MARK: - Team calendar

/// A booking as the team calendar shows it. Who it is for and what it is appear only to people allowed to open it.
struct CalendarBooking: Identifiable, Equatable, Hashable {
    /// Nil when the viewer may not open this booking.
    var bookingID: UUID?
    var startAt: Date
    var endAt: Date
    var blockedUntil: Date
    var status: BookingStatus
    var packageName: String?
    var clientName: String?
    var requestedMember: Bool

    var id: String { "\(bookingID?.uuidString ?? "hidden")-\(startAt.timeIntervalSince1970)" }
    var isHidden: Bool { bookingID == nil }
}

/// Time a person is busy that isn't one of the company's bookings.
struct BusyRange: Equatable, Hashable {
    enum Kind: String, Codable, Hashable {
        /// From their own calendar.
        case external
        /// A booking they have as an individual.
        case personal
    }

    var range: DateInterval
    var kind: Kind
}

/// One person's row in the team calendar.
struct MemberCalendar: Identifiable, Equatable, Hashable {
    var userID: UUID
    var displayName: String
    var avatarURL: URL?
    var role: OrgRole
    var title: String
    var bookable: Bool
    /// The hours they can take bookings: the company's, narrowed by their own.
    var weekly: [DayHours]
    var busy: [BusyRange]
    var bookings: [CalendarBooking]

    var id: UUID { userID }
}

struct TeamCalendar: Equatable {
    var timeZoneID: String
    var members: [MemberCalendar]
    /// Bookings no one has been given yet.
    var unassigned: [CalendarBooking]

    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .current }

    static let empty = TeamCalendar(timeZoneID: TimeZone.current.identifier, members: [], unassigned: [])

    /// Only these people, in the same order.
    func filtered(to ids: Set<UUID>) -> TeamCalendar {
        guard !ids.isEmpty else { return self }
        var copy = self
        copy.members = members.filter { ids.contains($0.userID) }
        return copy
    }
}

// MARK: - Billing

enum BillingAction: String, Codable, Hashable {
    /// Start the seat plan.
    case checkout
    /// Change the card, read invoices, cancel.
    case portal
}

/// What the Owner sees under Billing.
struct BillingOverview: Equatable {
    var plan: PlanSummary
    var seats: SeatCounts
    var seatsBilledByStripe: Int
    var trialEnd: Date?
    var state: OrgState
}
