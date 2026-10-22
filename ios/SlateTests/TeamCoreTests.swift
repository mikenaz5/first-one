import XCTest
@testable import Slate

/// The rules the database and the app must agree on, from the shared fixtures `team_permissions.json` and
/// `seat_rules.json`. The same files are read by `supabase/tests/team_rules.py`.
final class SharedTeamRulesTests: XCTestCase {
    private struct Permissions: Decodable {
        struct Assign: Decodable {
            var actor: String
            var current: String
            var new: String
            var allowed: Bool
        }

        struct Manage: Decodable {
            var actor: String
            var target: String
            var allowed: Bool
        }

        var roles: [String]
        var permissions: [String: [String]]
        var assign: [Assign]
        var manage: [Manage]
        var readOnlyWhenLapsed: [String]
    }

    private struct Seats: Decodable {
        struct Case: Decodable {
            var min: Int
            var max: Int
            var used: Int
            var delta: Int
            var usedAfter: Int
            var billedNow: Int
            var billedAfter: Int
            var allowed: Bool
            var change: String
        }

        var cases: [Case]
    }

    private func load<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "json"),
            "\(name).json is missing from the test bundle"
        )
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    func testTheRolesAreTheOnesTheDatabaseKnows() throws {
        let fixture = try load(Permissions.self, "team_permissions")
        XCTAssertEqual(OrgRole.allCases.map(\.rawValue), fixture.roles)
    }

    func testEveryPermissionIsHeldByTheSameRolesAsInTheDatabase() throws {
        let fixture = try load(Permissions.self, "team_permissions")
        XCTAssertEqual(Set(OrgPermission.allCases.map(\.rawValue)), Set(fixture.permissions.keys))
        for permission in OrgPermission.allCases {
            let expected = Set(try XCTUnwrap(fixture.permissions[permission.rawValue]))
            XCTAssertEqual(Set(permission.roles.map(\.rawValue)), expected, permission.rawValue)
            for role in OrgRole.allCases {
                XCTAssertEqual(role.allows(permission), expected.contains(role.rawValue), "\(role) \(permission)")
            }
        }
    }

    func testWhoMayGiveWhomWhichRoleMatchesTheDatabaseOnEveryCombination() throws {
        let fixture = try load(Permissions.self, "team_permissions")
        XCTAssertEqual(fixture.assign.count, 125)
        for example in fixture.assign {
            let actor = try XCTUnwrap(OrgRole(rawValue: example.actor))
            let current = try XCTUnwrap(OrgRole(rawValue: example.current))
            let new = try XCTUnwrap(OrgRole(rawValue: example.new))
            XCTAssertEqual(RoleRules.canAssign(actor: actor, current: current, new: new), example.allowed,
                           "\(example.actor) changing \(example.current) to \(example.new)")
        }
    }

    func testWhoMayManageWhomMatchesTheDatabaseOnEveryCombination() throws {
        let fixture = try load(Permissions.self, "team_permissions")
        XCTAssertEqual(fixture.manage.count, 25)
        for example in fixture.manage {
            let actor = try XCTUnwrap(OrgRole(rawValue: example.actor))
            let target = try XCTUnwrap(OrgRole(rawValue: example.target))
            XCTAssertEqual(RoleRules.canManage(actor: actor, target: target), example.allowed, "\(example.actor) on \(example.target)")
        }
    }

    func testALapsedCompanyKeepsOnlyReadingAndBilling() throws {
        let fixture = try load(Permissions.self, "team_permissions")
        XCTAssertEqual(Set(RoleRules.allowedWhenLapsed.map(\.rawValue)), Set(fixture.readOnlyWhenLapsed))
        for role in OrgRole.allCases {
            for permission in OrgPermission.allCases {
                let expected = role.allows(permission) && fixture.readOnlyWhenLapsed.contains(permission.rawValue)
                XCTAssertEqual(RoleRules.allows(permission, role: role, state: .lapsed), expected, "\(role) \(permission)")
                XCTAssertEqual(RoleRules.allows(permission, role: role, state: .active), role.allows(permission))
                XCTAssertFalse(RoleRules.allows(permission, role: role, state: .closed))
            }
        }
    }

    func testSeatPlansMatchTheDatabaseOnEverySharedCase() throws {
        let fixture = try load(Seats.self, "seat_rules")
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 90)
        for example in fixture.cases {
            let config = TeamConfig(seatMinimum: example.min, seatMaximum: example.max, inviteExpiryDays: 7, graceDays: 7)
            let plan = SeatPlan.make(used: example.used, delta: example.delta, config: config)
            let label = "min \(example.min) max \(example.max) used \(example.used) delta \(example.delta)"
            XCTAssertEqual(plan.usedAfter, example.usedAfter, label)
            XCTAssertEqual(plan.billedNow, example.billedNow, label)
            XCTAssertEqual(plan.billedAfter, example.billedAfter, label)
            XCTAssertEqual(plan.allowed, example.allowed, label)
            XCTAssertEqual(plan.change.rawValue, example.change, label)
        }
    }
}

final class TeamRulesTests: XCTestCase {
    func testTheOwnerCanInviteEveryRoleButOwnerAndAnAdminCannotMakeAdmins() {
        XCTAssertEqual(RoleRules.invitableRoles(by: .owner), [.admin, .manager, .creator, .viewer])
        XCTAssertEqual(RoleRules.invitableRoles(by: .admin), [.manager, .creator, .viewer])
        XCTAssertEqual(RoleRules.invitableRoles(by: .manager), [])
        XCTAssertEqual(RoleRules.invitableRoles(by: .creator), [])
        XCTAssertEqual(RoleRules.invitableRoles(by: .viewer), [])
    }

    func testChangingARoleOffersOnlyWhatTheActorMayGive() {
        XCTAssertEqual(RoleRules.assignableRoles(by: .owner, to: .creator), [.admin, .manager, .creator, .viewer])
        XCTAssertEqual(RoleRules.assignableRoles(by: .owner, to: .owner), [])
        XCTAssertEqual(RoleRules.assignableRoles(by: .admin, to: .admin), [])
        XCTAssertEqual(RoleRules.assignableRoles(by: .admin, to: .viewer), [.manager, .creator, .viewer])
    }

    func testOnlyViewersCannotTakeBookings() {
        XCTAssertEqual(OrgRole.allCases.filter(\.canTakeBookings), [.owner, .admin, .manager, .creator])
    }

    func testAnInviteEmailIsTidiedAndChecked() {
        XCTAssertEqual(TeamRules.cleanInviteEmail("  Sam@Example.COM "), "sam@example.com")
        XCTAssertNil(TeamRules.cleanInviteEmail(""))
        XCTAssertNil(TeamRules.cleanInviteEmail("sam"))
        XCTAssertNil(TeamRules.cleanInviteEmail("@example.com"))
        XCTAssertNil(TeamRules.cleanInviteEmail("sam@"))
        XCTAssertNil(TeamRules.cleanInviteEmail("a@b@c.com"))
        XCTAssertNil(TeamRules.cleanInviteEmail("sam smith@example.com"))
    }

    func testSharesAreWholeBasisPointsFromNothingToAll() {
        XCTAssertTrue(TeamRules.isValidShare(0))
        XCTAssertTrue(TeamRules.isValidShare(10_000))
        XCTAssertFalse(TeamRules.isValidShare(-1))
        XCTAssertFalse(TeamRules.isValidShare(10_001))
        XCTAssertEqual(TeamRules.shareText(3000), "30%")
        XCTAssertEqual(TeamRules.shareText(1250), "12.5%")
    }

    func testTheSeatSentenceSaysWhenTheBillChanges() {
        let config = TeamConfig.standard
        XCTAssertTrue(SeatPlan.make(used: 3, delta: 1, config: config).billingSentence(periodEnd: nil).contains("at least 10"))
        XCTAssertTrue(SeatPlan.make(used: 10, delta: 1, config: config).billingSentence(periodEnd: nil).contains("charged now"))
        XCTAssertTrue(SeatPlan.make(used: 11, delta: -1, config: config).billingSentence(periodEnd: nil).contains("next invoice"))
    }

    func testTheActiveAccountSurvivesBeingStoredAsText() {
        let id = UUID()
        XCTAssertEqual(ActiveAccount(storageValue: ActiveAccount.company(id).storageValue), .company(id))
        XCTAssertEqual(ActiveAccount(storageValue: ActiveAccount.personal.storageValue), .personal)
        XCTAssertEqual(ActiveAccount(storageValue: nil), .personal)
        XCTAssertEqual(ActiveAccount(storageValue: "not an id"), .personal)
        XCTAssertEqual(ActiveAccount.company(id).companyID, id)
        XCTAssertNil(ActiveAccount.personal.companyID)
    }

    func testACompanyNeedsANameAHandleAndALegalName() {
        var draft = OrganizationDraft(name: "Northlight Films", handle: "northlight", legalName: "Northlight Films LLC")
        XCTAssertNil(draft.problem)
        draft.name = "  "
        XCTAssertEqual(draft.problem, .name)
        draft.name = "Northlight Films"
        draft.handle = "ab"
        XCTAssertEqual(draft.problem, .handle(.tooShort))
        draft.handle = "northlight"
        draft.legalName = "N"
        XCTAssertEqual(draft.problem, .legalName)
    }

    func testTheInviteLinkOpensTheApp() {
        XCTAssertEqual(AppConfig.joinDeepLink(token: "abc-123_x")?.absoluteString, "slate://join/abc-123_x")
    }

    func testAnOldBookingAndAnOldProfileStillLoad() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let booking = """
        {"id":"\(UUID().uuidString)","creatorID":"\(UUID().uuidString)","clientName":"Sam","creatorName":"Maya","packageName":"Portrait",
         "addOns":[],"startAt":"2027-01-05T15:00:00Z","endAt":"2027-01-05T16:00:00Z","blockedUntil":"2027-01-05T16:30:00Z",
         "timeZoneID":"America/Chicago","currencyCode":"USD","totalCents":50000,"depositCents":10000,"status":"confirmed",
         "notes":"","createdAt":"2027-01-01T12:00:00Z"}
        """
        let decoded = try decoder.decode(Booking.self, from: Data(booking.utf8))
        XCTAssertNil(decoded.assignedTo)
        XCTAssertFalse(decoded.requestedMember)
        XCTAssertNil(decoded.assigneeShareBps)

        let profile = """
        {"id":"\(UUID().uuidString)","handle":"maya","displayName":"Maya","bio":"","specialties":["weddings"],
         "createdAt":"2027-01-01T12:00:00Z","updatedAt":"2027-01-01T12:00:00Z"}
        """
        XCTAssertEqual(try decoder.decode(CreatorProfile.self, from: Data(profile.utf8)).kind, .person)
    }
}

final class TeamAvailabilityTests: XCTestCase {
    // 2027-01-04 is a Monday; the tests look at the Tuesday.
    private let now = TestClock.date(2027, 1, 4, 8, 0)
    private let tuesday = CalendarDay(year: 2027, month: 1, day: 5)

    private func settings(buffer: Int = 0) -> AvailabilitySettings {
        var settings = AvailabilitySettings.standard(timeZone: TestClock.timeZone)
        settings.minNoticeHours = 0
        settings.bufferMinutes = buffer
        settings.slotIntervalMinutes = 30
        return settings
    }

    private func hours(from start: Int, to end: Int) -> [DayHours] {
        (2...6).map { DayHours(weekday: $0, window: TimeWindow(startMinute: start * 60, endMinute: end * 60)) }
    }

    private func member(_ name: String, hours: [DayHours], busy: [DateInterval] = []) -> MemberSchedule {
        MemberSchedule(userID: UUID(), displayName: name, weekly: hours, busy: busy)
    }

    private func range(_ from: Int, _ to: Int) -> DateInterval {
        DateInterval(start: TestClock.date(2027, 1, 5, from), end: TestClock.date(2027, 1, 5, to))
    }

    private func team(_ members: [MemberSchedule], mode: AssignmentMode = .auto, unassigned: [DateInterval] = [], buffer: Int = 0) -> TeamSchedule {
        TeamSchedule(settings: settings(buffer: buffer), assignmentMode: mode, members: members, unassigned: unassigned)
    }

    private func offered(_ team: TeamSchedule, minutes: Int = 60) -> [Double] {
        TestClock.hours(TeamAvailability.slots(on: tuesday, durationMinutes: minutes, team: team, now: now))
    }

    func testATimeIsOfferedWhenAnyoneIsFree() {
        let a = member("A", hours: hours(from: 9, to: 17), busy: [range(9, 11)])
        let b = member("B", hours: hours(from: 10, to: 14))
        let result = offered(team([a, b]))
        XCTAssertEqual(result.first, 10, "B is free at 10 though A is busy until 11")
        XCTAssertFalse(result.contains(9), "A is busy and B is not in yet")
        XCTAssertEqual(result.last, 16, "only A works until five")
        XCTAssertTrue(result.contains(14.5), "after B leaves, A is still free")
    }

    func testNoOneFreeMeansNoSlot() {
        let a = member("A", hours: hours(from: 9, to: 17), busy: [range(12, 14)])
        let b = member("B", hours: hours(from: 9, to: 17), busy: [range(12, 14)])
        let result = offered(team([a, b]))
        XCTAssertFalse(result.contains(12))
        XCTAssertFalse(result.contains(13))
        XCTAssertTrue(result.contains(11))
        XCTAssertTrue(result.contains(14))
    }

    func testTheBufferInTheBusyRangesIsRespected() {
        // A booking 10-11 with a 30 minute buffer is stored as 10:00 to 11:30.
        let busy = DateInterval(start: TestClock.date(2027, 1, 5, 10), end: TestClock.date(2027, 1, 5, 11, 30))
        let a = member("A", hours: hours(from: 9, to: 17), busy: [busy])
        let result = offered(team([a], buffer: 30))
        XCTAssertFalse(result.contains(11), "11:00 is inside the buffer")
        XCTAssertTrue(result.contains(11.5))
        XCTAssertFalse(result.contains(9), "a booking at 9 would need its buffer to end before 10")
    }

    func testAManualCompanyOffersATimeOnlyWhileThereAreMoreFreePeopleThanWaitingBookings() {
        let a = member("A", hours: hours(from: 9, to: 17))
        let b = member("B", hours: hours(from: 9, to: 17))
        let one = [range(10, 11)]
        let two = [range(10, 11), range(10, 12)]
        XCTAssertTrue(offered(team([a, b], mode: .manual, unassigned: one)).contains(10))
        XCTAssertFalse(offered(team([a, b], mode: .manual, unassigned: two)).contains(10))
        XCTAssertTrue(offered(team([a, b], mode: .manual, unassigned: two)).contains(12), "after they end, there is room again")
        XCTAssertTrue(offered(team([a, b], mode: .auto, unassigned: two)).contains(10), "automatic companies hand them out at once")
    }

    func testChoosingAPersonIgnoresTheQueueAndShowsOnlyTheirTime() {
        let a = member("A", hours: hours(from: 9, to: 17), busy: [range(9, 12)])
        let b = member("B", hours: hours(from: 9, to: 17))
        let everyone = team([a, b], mode: .manual, unassigned: [range(13, 14), range(13, 14)])
        XCTAssertFalse(offered(everyone).contains(13))
        let justA = everyone.filtered(to: a.userID)
        XCTAssertEqual(offered(justA).first, 12)
        XCTAssertTrue(offered(justA).contains(13))
        XCTAssertFalse(offered(justA).contains(10))
        XCTAssertTrue(offered(everyone.filtered(to: b.userID)).contains(10))
        XCTAssertTrue(offered(everyone.filtered(to: UUID())).isEmpty)
    }

    func testWhoIsFreeAtAnExactTime() {
        let a = member("A", hours: hours(from: 9, to: 17), busy: [range(10, 11)])
        let b = member("B", hours: hours(from: 9, to: 17))
        let schedule = team([a, b])
        let ten = TestClock.date(2027, 1, 5, 10)
        let eleven = TestClock.date(2027, 1, 5, 11)
        XCTAssertEqual(TeamAvailability.freeMembers(start: ten, durationMinutes: 60, team: schedule, now: now).map(\.displayName), ["B"])
        XCTAssertEqual(TeamAvailability.freeMembers(start: eleven, durationMinutes: 60, team: schedule, now: now).map(\.displayName), ["A", "B"])
    }

    func testTheBookingScreensEngineUnderstandsATeam() {
        let a = member("A", hours: hours(from: 9, to: 17))
        let schedule = team([a]).asSchedule
        XCTAssertTrue(AvailabilityEngine.isAvailable(start: TestClock.date(2027, 1, 5, 9), durationMinutes: 60, schedule: schedule, now: now))
        XCTAssertFalse(AvailabilityEngine.isAvailable(start: TestClock.date(2027, 1, 5, 17), durationMinutes: 60, schedule: schedule, now: now))
        XCTAssertFalse(AvailabilityEngine.availableDays(durationMinutes: 60, schedule: schedule, now: now, limit: 3).isEmpty)
    }

    func testTheCompanysRulesApplyToEveryone() {
        var rules = settings()
        rules.minNoticeHours = 48
        let a = member("A", hours: hours(from: 9, to: 17))
        let strict = TeamSchedule(settings: rules, assignmentMode: .auto, members: [a], unassigned: [])
        XCTAssertTrue(TeamAvailability.slots(on: tuesday, durationMinutes: 60, team: strict, now: now).isEmpty, "Tuesday is under 48 hours away")
        let wednesday = tuesday.adding(days: 1, in: TestClock.calendar)
        XCTAssertFalse(TeamAvailability.slots(on: wednesday, durationMinutes: 60, team: strict, now: now).isEmpty)
    }
}

final class AssignmentPlannerTests: XCTestCase {
    private func candidate(_ id: String, joined: TimeInterval, upcoming: Int, free: Bool = true) -> AssignmentPlanner.Candidate {
        AssignmentPlanner.Candidate(userID: UUID(uuidString: id)!, joinedAt: Date(timeIntervalSince1970: joined), upcoming: upcoming, isFree: free)
    }

    func testTheLeastBusyFreePersonGetsIt() {
        let result = AssignmentPlanner.choose(from: [
            candidate("00000000-0000-0000-0000-000000000001", joined: 1, upcoming: 3),
            candidate("00000000-0000-0000-0000-000000000002", joined: 2, upcoming: 1),
            candidate("00000000-0000-0000-0000-000000000003", joined: 3, upcoming: 0, free: false),
        ])
        XCTAssertEqual(result, UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
    }

    func testATieGoesToWhoeverJoinedFirstThenTheLowestId() {
        let early = candidate("00000000-0000-0000-0000-00000000000b", joined: 1, upcoming: 2)
        let late = candidate("00000000-0000-0000-0000-00000000000a", joined: 5, upcoming: 2)
        XCTAssertEqual(AssignmentPlanner.choose(from: [late, early]), early.userID)
        let sameDay = candidate("00000000-0000-0000-0000-00000000000a", joined: 1, upcoming: 2)
        XCTAssertEqual(AssignmentPlanner.choose(from: [early, sameDay]), sameDay.userID)
    }

    func testNobodyFreeMeansNobody() {
        XCTAssertNil(AssignmentPlanner.choose(from: [candidate("00000000-0000-0000-0000-000000000001", joined: 1, upcoming: 0, free: false)]))
        XCTAssertNil(AssignmentPlanner.choose(from: []))
    }
}
