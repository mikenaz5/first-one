import XCTest
@testable import Slate

// MARK: - Rules

final class CreatorSearchRulesTests: XCTestCase {
    private func profile(_ handle: String, _ name: String, _ specialties: [Specialty] = []) -> CreatorProfile {
        CreatorProfile(
            id: UUID(), handle: handle, displayName: name, bio: "", specialties: specialties,
            location: nil, avatarURL: nil, createdAt: Date(), updatedAt: Date()
        )
    }

    func testASearchNeedsTwoToSixtyCharactersAndSpacingDoesntCount() {
        XCTAssertNil(CreatorSearchRules.clean(""))
        XCTAssertNil(CreatorSearchRules.clean("m"))
        XCTAssertNil(CreatorSearchRules.clean("  m  "))
        XCTAssertEqual(CreatorSearchRules.clean("ma"), "ma")
        XCTAssertEqual(CreatorSearchRules.clean("  maya   chen  "), "maya chen")
        XCTAssertNotNil(CreatorSearchRules.clean(String(repeating: "x", count: 60)))
        XCTAssertNil(CreatorSearchRules.clean(String(repeating: "x", count: 61)))
    }

    func testLinksAreToldApartFromWords() {
        XCTAssertTrue(CreatorSearchRules.looksLikeLink("slate://book/maya"))
        XCTAssertTrue(CreatorSearchRules.looksLikeLink("https://slate.example/maya"))
        XCTAssertTrue(CreatorSearchRules.looksLikeLink("  Slate.Example/maya"))
        XCTAssertFalse(CreatorSearchRules.looksLikeLink("maya"))
        XCTAssertFalse(CreatorSearchRules.looksLikeLink("real estate"))
        XCTAssertFalse(CreatorSearchRules.looksLikeLink("weddings in austin"))
    }

    func testANameALinkNameOrASpecialtyMatches() {
        let maya = profile("mayachen", "Maya Chen", [.weddings, .portraits])
        let films = profile("northlight", "Northlight Films", [.commercial, .realEstate])
        XCTAssertTrue(CreatorSearchRules.matches(maya, query: "chen"))
        XCTAssertTrue(CreatorSearchRules.matches(maya, query: "MAYA CHEN"))
        XCTAssertTrue(CreatorSearchRules.matches(maya, query: "mayachen"))
        XCTAssertTrue(CreatorSearchRules.matches(maya, query: "wedding"))
        XCTAssertFalse(CreatorSearchRules.matches(maya, query: "real estate"))
        XCTAssertTrue(CreatorSearchRules.matches(films, query: "real estate"))
        XCTAssertTrue(CreatorSearchRules.matches(films, query: "REALESTATE"))
        XCTAssertFalse(CreatorSearchRules.matches(films, query: "m"), "Too short to search for")
    }

    func testWildcardCharactersAreJustCharacters() {
        let maya = profile("mayachen", "Maya Chen", [.weddings])
        let fifty = profile("percent_50", "Fifty% Studio", [.food])
        for query in ["%%", "%a", "m_ya", "\\", "a\\"] { XCTAssertFalse(CreatorSearchRules.matches(maya, query: query), query) }
        XCTAssertTrue(CreatorSearchRules.matches(fifty, query: "fifty%"))
        XCTAssertTrue(CreatorSearchRules.matches(fifty, query: "percent_50"))
    }

    func testAnExactLinkNameComesFirstThenNamesThatStartWithIt() {
        let found = CreatorSearchRules.order([
            profile("maya-films", "Northlight Films"),
            profile("mayachen", "Maya Chen"),
            profile("maya", "Zed Quill"),
        ], query: "maya")
        XCTAssertEqual(found.map(\.handle), ["maya", "mayachen", "maya-films"])
    }

    func testTheLimitIsKeptBetweenOneAndThirty() {
        XCTAssertEqual(CreatorSearchRules.clamped(limit: 0), 1)
        XCTAssertEqual(CreatorSearchRules.clamped(limit: -4), 1)
        XCTAssertEqual(CreatorSearchRules.clamped(limit: 20), 20)
        XCTAssertEqual(CreatorSearchRules.clamped(limit: 500), 30)
    }
}

// MARK: - The on-device backend

final class ClientSearchBackendTests: XCTestCase {
    private var root: URL!
    private var backend: LocalBackend!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-search-\(UUID().uuidString)")
        backend = LocalBackend(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    @discardableResult
    private func creator(_ handle: String, _ name: String, _ specialties: [Specialty] = [], published: Bool = true, packages: Int = 1) async throws -> UUID {
        let session = try await backend.signInWithApple(
            AppleCredential(userID: "apple-\(handle)", identityToken: "t", rawNonce: "n", fullName: nil, email: nil)
        )
        _ = try await backend.saveProfile(CreatorProfile(
            id: session.userID, handle: handle, displayName: name, bio: "", specialties: specialties,
            location: nil, avatarURL: nil, createdAt: Date(), updatedAt: Date()
        ), avatarJPEG: nil)
        guard packages > 0 else { return session.userID }
        let template = try await ContractFixtures.equip(backend, creatorID: session.userID, signature: ContractFixtures.creatorSignature(name: name))
        for index in 0..<packages {
            _ = try await backend.savePackage(ServicePackage(
                id: UUID(), creatorID: session.userID, name: "Package \(index + 1)", summary: "", category: nil,
                priceCents: 100_000, currencyCode: "USD", durationMinutes: 60, deliverables: [], turnaroundDays: 7,
                depositCents: 0, addOns: [], isPublished: published, position: index, createdAt: Date(), updatedAt: Date(),
                contractTemplateID: template.id, cancellationPolicy: .flexible, usageRights: .commercial
            ))
        }
        return session.userID
    }

    private func handles(_ query: String, limit: Int = 20) async throws -> [String] {
        try await backend.searchCreators(query, limit: limit).map(\.handle)
    }

    func testCreatorsAreFoundByNameLinkNameAndSpecialty() async throws {
        try await creator("mayachen", "Maya Chen", [.weddings, .portraits])
        try await creator("northlight", "Northlight Films", [.commercial, .realEstate])
        try await creator("dana-lens", "Dana Lens", [.portraits])

        var found = try await handles("chen")
        XCTAssertEqual(found, ["mayachen"])
        found = try await handles("  MAYA   chen ")
        XCTAssertEqual(found, ["mayachen"])
        found = try await handles("dana-lens")
        XCTAssertEqual(found, ["dana-lens"])
        found = try await handles("real estate")
        XCTAssertEqual(found, ["northlight"])
        found = try await handles("portrait")
        XCTAssertEqual(Set(found), ["mayachen", "dana-lens"])
    }

    func testOnlyCreatorsAClientCouldBookAreFound() async throws {
        try await creator("visible", "Dana Visible", [.weddings])
        try await creator("draft-only", "Dana Draft", [.weddings], published: false)
        try await creator("no-packages", "Dana Nothing", [.weddings], packages: 0)
        let found = try await handles("dana")
        XCTAssertEqual(found, ["visible"])
        let byTopic = try await handles("wedding")
        XCTAssertEqual(byTopic, ["visible"])
    }

    func testTooShortOrOddSearchesFindNothing() async throws {
        try await creator("mayachen", "Maya Chen", [.weddings])
        for query in ["", "   ", "m", "%%", "%a", "m_ya", "x'; drop table packages; --", String(repeating: "x", count: 61)] {
            let found = try await handles(query)
            XCTAssertTrue(found.isEmpty, "\"\(query)\" should find nothing, found \(found)")
        }
    }

    func testAnExactLinkNameBeatsNamesThatMerelyContainIt() async throws {
        try await creator("mayachen", "Maya Chen", [.weddings])
        try await creator("maya-films", "Northlight Films", [.commercial])
        try await creator("maya", "Zed Quill", [.music])
        let found = try await handles("maya")
        XCTAssertEqual(found, ["maya", "mayachen", "maya-films"])
    }

    func testTheLimitIsRespected() async throws {
        for index in 0..<8 { try await creator("bulk-\(index)", "Bulk Creator \(index)", [.food]) }
        let few = try await handles("bulk", limit: 3)
        XCTAssertEqual(few.count, 3)
        let none = try await handles("bulk", limit: 0)
        XCTAssertEqual(none.count, 1, "At least one")
        let all = try await handles("bulk", limit: 500)
        XCTAssertEqual(all.count, 8)
        XCTAssertEqual(all, (0..<8).map { "bulk-\($0)" }, "In a steady order")
    }
}

// MARK: - A client's own money and paperwork

final class ClientActivityTests: XCTestCase {
    private let me = UUID()

    private func payment(_ kind: PaymentKind, _ cents: Int, _ status: PaymentRecordStatus = .succeeded, at: Date = TestClock.date(2027, 1, 10, 9, 0)) -> Payment {
        Payment(
            id: UUID(), bookingID: UUID(), kind: kind, amountCents: cents, currencyCode: "USD", status: status,
            createdAt: at, paidAt: status == .succeeded ? at : nil
        )
    }

    private func booking(_ status: BookingStatus, day: Int, client: UUID? = nil) -> Booking {
        let start = TestClock.date(2027, 2, day, 10, 0)
        return Booking(
            id: UUID(), creatorID: UUID(), clientID: client ?? me, creatorName: "Dana Lens", clientName: "Sam",
            packageID: nil, packageName: "Portrait session", addOns: [],
            startAt: start, endAt: start.addingTimeInterval(3600), blockedUntil: start.addingTimeInterval(5400),
            timeZoneID: "America/Chicago", currencyCode: "USD", totalCents: 100_000, depositCents: 25_000, status: status,
            notes: "", createdAt: start.addingTimeInterval(-86_400 * 7)
        )
    }

    func testWhatWasPaidLessWhatCameBack() {
        let net = ClientActivity.netPaidCents([
            payment(.deposit, 25_000), payment(.balance, 75_000), payment(.refund, 30_000),
        ])
        XCTAssertEqual(net, 70_000)
    }

    func testOnlyPaymentsThatWentThroughCount() {
        let net = ClientActivity.netPaidCents([
            payment(.deposit, 25_000), payment(.balance, 75_000, .pending), payment(.balance, 75_000, .failed),
            payment(.refund, 10_000, .pending), payment(.deposit, 5_000, .canceled),
        ])
        XCTAssertEqual(net, 25_000)
        XCTAssertEqual(ClientActivity.netPaidCents([]), 0)
    }

    func testPaymentsAreListedNewestFirst() {
        let old = payment(.deposit, 1, at: TestClock.date(2027, 1, 1, 9, 0))
        let mid = payment(.balance, 2, at: TestClock.date(2027, 1, 5, 9, 0))
        let new = payment(.refund, 3, at: TestClock.date(2027, 1, 9, 9, 0))
        XCTAssertEqual(ClientActivity.history([mid, old, new]).map(\.amountCents), [3, 2, 1])
    }

    func testOnlyConfirmedAndCompletedBookingsHaveContractsThatCount() {
        let kept = [booking(.confirmed, day: 10), booking(.completed, day: 20)]
        let dropped = [booking(.held, day: 11), booking(.cancelled, day: 12), booking(.expired, day: 13), booking(.confirmed, day: 14, client: UUID())]
        let list = ClientActivity.contractedBookings(kept + dropped, clientID: me)
        XCTAssertEqual(list.map(\.id), [kept[1].id, kept[0].id], "Newest shoot first, and only mine")
    }
}
