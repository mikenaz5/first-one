import XCTest
@testable import Slate

/// A company with a team, on the on-device backend, for the tests that need one.
///
/// The clock is Monday 2027-01-04 at 08:00 in Chicago and moves only when a test moves it. People join a minute apart,
/// so "who joined first" is settled. Seats are 3 to 6 so limits are quick to reach. The company is open Monday to Friday,
/// 9 to 5, with a 30 minute buffer, and sells one one-hour package.
class TeamTestCase: XCTestCase {
    let clock = ManualClock(TestClock.date(2027, 1, 4, 8, 0))
    let config = TeamConfig(seatMinimum: 3, seatMaximum: 6, inviteExpiryDays: 7, graceDays: 7)
    var root: URL!
    var backend: LocalBackend!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-team-\(UUID().uuidString)")
        let clock = self.clock
        backend = LocalBackend(root: root, clock: { clock.now }, teamConfig: config)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: People

    func credential(_ id: String) -> AppleCredential {
        AppleCredential(userID: id, identityToken: "t", rawNonce: "n", fullName: nil, email: nil)
    }

    /// Signs a person in (making them the one using the device) with a profile of their own.
    func person(_ name: String) async throws -> UUID {
        let session = try await backend.signInWithApple(credential("apple-\(name.lowercased())"))
        _ = try await backend.saveProfile(CreatorProfile(
            id: session.userID, handle: name.lowercased(), displayName: name, bio: "", specialties: [.weddings],
            location: nil, avatarURL: nil, createdAt: Date(), updatedAt: Date()
        ), avatarJPEG: nil)
        return session.userID
    }

    /// Invites someone into a role and has them accept, then goes back to being `owner`.
    @discardableResult
    func join(_ role: OrgRole, _ name: String, org: UUID, by owner: UUID) async throws -> UUID {
        let invite = try await backend.createInvite(role: role, email: nil, organizationID: org, by: owner)
        let id = try await person(name)
        _ = try await backend.acceptInvite(token: invite.token, displayName: nil, by: id)
        clock.advance(by: 60)
        try await backend.actAs(owner)
        return id
    }

    struct Company {
        var org: Organization
        var owner: UUID
        var admin: UUID
        var manager: UUID
        var theo: UUID
        var jun: UUID
        var viewer: UUID
        var package: ServicePackage
        var template: ContractTemplate
    }

    /// Dana owns Northlight Films. Marcus is an Admin, Noor a Manager, Theo and Jun Creators, Ben a Viewer. Only Theo and
    /// Jun take bookings. Dana is the signer.
    func makeCompany(mode: AssignmentMode = .auto, split: Bool = false, designateSigner: Bool = true) async throws -> Company {
        let owner = try await person("Dana")
        var org = try await backend.createOrganization(OrganizationDraft(
            name: "Northlight Films", handle: "northlight", legalName: "Northlight Films LLC",
            legalAddress: "410 Congress Ave, Austin", bio: "Weddings and brand film", specialties: [.weddings]
        ), by: owner)
        clock.advance(by: 60)

        let admin = try await join(.admin, "Marcus", org: org.id, by: owner)
        let manager = try await join(.manager, "Noor", org: org.id, by: owner)
        let theo = try await join(.creator, "Theo", org: org.id, by: owner)
        let jun = try await join(.creator, "Jun", org: org.id, by: owner)
        let viewer = try await join(.viewer, "Ben", org: org.id, by: owner)
        for lead in [owner, admin, manager] {
            try await backend.updateMember(MemberUpdate(bookable: false), memberID: lead, organizationID: org.id, by: owner)
        }

        if designateSigner {
            try await backend.saveCreatorSignature(ContractFixtures.creatorSignature(name: "Dana Lens"), for: owner)
            org = try await backend.designateSigner(userID: owner, title: "Owner", organizationID: org.id, by: owner)
        }
        if mode != .auto || split {
            org = try await backend.updateOrganization(org.id, with: OrganizationUpdate(assignmentMode: mode), by: owner)
        }
        if split { org = try await backend.setSplitEnabled(true, organizationID: org.id, by: owner) }

        var settings = AvailabilitySettings.standard(timeZone: TestClock.timeZone)
        settings.bufferMinutes = 30
        _ = try await backend.saveAvailability(settings, for: org.id)
        let template = StarterTemplates.make(.videography, creatorID: org.id)
        _ = try await backend.saveContractTemplate(template)
        let saved = try await backend.savePackage(ServicePackage(
            id: UUID(), creatorID: org.id, name: "Brand film", summary: "", category: .corporate,
            priceCents: 200_000, currencyCode: "USD", durationMinutes: 60, deliverables: ["A 2 minute film"],
            turnaroundDays: 14, depositCents: 50_000, addOns: [], isPublished: true, position: 0,
            createdAt: Date(), updatedAt: Date(), contractTemplateID: template.id
        ))
        return Company(
            org: org, owner: owner, admin: admin, manager: manager, theo: theo, jun: jun, viewer: viewer,
            package: saved[0], template: template
        )
    }

    // MARK: Time

    /// The Wednesday after the clock's Monday, at this hour. More than 24 hours away, so the notice rule is met.
    func wednesday(_ hour: Int, _ minute: Int = 0) -> Date {
        TestClock.date(2027, 1, 6, hour, minute)
    }

    func request(_ company: Company, at start: Date, member: UUID? = nil) -> BookingRequest {
        BookingRequest(creatorID: company.org.id, packageID: company.package.id, addOnIDs: [], startAt: start, notes: "", memberID: member)
    }

    /// A client books and signs (and pays the deposit, so the booking is confirmed).
    func book(_ company: Company, at start: Date, member: UUID? = nil, client: UUID = UUID(), pay: Bool = true) async throws -> SignedBooking {
        try await ContractFixtures.signedBooking(
            backend, request(company, at: start, member: member), clientID: client, name: "Alex Rivera", pay: pay
        )
    }

    func expectError<T>(_ expected: SlateError, file: StaticString = #filePath, line: UInt = #line, _ work: () async throws -> T) async {
        do {
            _ = try await work()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SlateError, expected, file: file, line: line)
        }
    }

    func activity(_ company: Company, as userID: UUID? = nil) async throws -> [ActivityEntry] {
        try await backend.loadActivity(organizationID: company.org.id, limit: 200, before: nil, for: userID ?? company.owner)
    }
}
