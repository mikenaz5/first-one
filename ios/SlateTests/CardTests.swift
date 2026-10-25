import XCTest
@testable import Slate

// MARK: - The shared fixture

/// `Fixtures/card_rules.json`, which `supabase/tests/card_rules.py` reads too: the limits, the version of the agreement
/// wording and every expiry case, so the phone and the database can't disagree about when a card has expired.
private struct CardFixture: Decodable {
    struct Expiry: Decodable {
        var month: Int
        var year: Int
        var at: String
        var expired: Bool
    }

    var maxCards: Int
    var consentVersion: Int
    var expiry: [Expiry]

    static func load() throws -> CardFixture {
        let url = try XCTUnwrap(
            Bundle(for: CardRulesTests.self).url(forResource: "card_rules", withExtension: "json"),
            "card_rules.json is missing from the test bundle"
        )
        return try JSONDecoder().decode(CardFixture.self, from: Data(contentsOf: url))
    }
}

// MARK: - Rules

final class CardRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000) // 15 Jan 2027

    private func card(_ brand: CardBrand = .visa, _ last4: String = "4242", month: Int = 8, year: Int = 2028, added: TimeInterval = 0) -> SavedCard {
        SavedCard(id: UUID(), brand: brand, last4: last4, expMonth: month, expYear: year, addedAt: now.addingTimeInterval(added))
    }

    func testTheLimitAndTheAgreementVersionAreTheDatabasesOwn() throws {
        let fixture = try CardFixture.load()
        XCTAssertEqual(CardRules.maxCards, fixture.maxCards)
        XCTAssertEqual(CardRules.consentVersion, fixture.consentVersion)
        XCTAssertEqual(CardConsent.version, fixture.consentVersion)
    }

    func testTheAppAndTheDatabaseAgreeOnEveryExpiry() throws {
        let fixture = try CardFixture.load()
        XCTAssertGreaterThanOrEqual(fixture.expiry.count, 8)
        let parser = ISO8601DateFormatter()
        for item in fixture.expiry {
            let date = try XCTUnwrap(parser.date(from: item.at), item.at)
            XCTAssertEqual(CardRules.isExpired(month: item.month, year: item.year, at: date), item.expired, "\(item.month)/\(item.year) at \(item.at)")
        }
    }

    func testBrandsAreStripesWordsInPlainEnglish() {
        XCTAssertEqual(CardBrand(stripe: "visa"), .visa)
        XCTAssertEqual(CardBrand(stripe: "Mastercard"), .mastercard)
        XCTAssertEqual(CardBrand(stripe: "amex"), .amex)
        XCTAssertEqual(CardBrand(stripe: "diners"), .diners)
        XCTAssertEqual(CardBrand(stripe: "diners_club"), .diners)
        XCTAssertEqual(CardBrand(stripe: "cartes_bancaires"), .other)
        XCTAssertEqual(CardBrand(stripe: nil), .other)
        XCTAssertEqual(CardBrand.amex.title, "American Express")
        XCTAssertEqual(CardBrand.other.title, "Card")
        XCTAssertEqual(Set(CardBrand.allCases.map(\.title)).count, CardBrand.allCases.count, "No two brands read the same")
    }

    func testACardIsDescribedWithoutAnythingSecret() {
        let visa = card(.visa, "4242", month: 8, year: 2028)
        XCTAssertEqual(visa.title, "Visa ending 4242")
        XCTAssertEqual(visa.expiryText, "08/28")
        XCTAssertEqual(visa.detail(at: now), "Expires 08/28")
        let later = now.addingTimeInterval(86_400 * 365 * 2)
        XCTAssertEqual(visa.detail(at: later), "Expired 08/28")
        XCTAssertTrue(visa.accessibilitySummary(at: now).hasPrefix("Visa ending 4242, expires"))
        XCTAssertTrue(visa.accessibilitySummary(at: now).hasSuffix("2028"))
        XCTAssertTrue(visa.accessibilitySummary(at: later).contains("expired"))
    }

    func testTwoDigitYearsKeepTheirLeadingZero() {
        XCTAssertEqual(card(month: 1, year: 2101).expiryText, "01/01")
        XCTAssertEqual(card(month: 12, year: 2030).expiryText, "12/30")
    }

    func testOnlyFiveCardsFit() {
        XCTAssertTrue(CardRules.canAddAnother(to: 0))
        XCTAssertTrue(CardRules.canAddAnother(to: CardRules.maxCards - 1))
        XCTAssertFalse(CardRules.canAddAnother(to: CardRules.maxCards))
    }

    func testCardsAreShownUsableFirstThenNewest() {
        let old = card(.visa, "0001", year: 2030, added: -1000)
        let new = card(.mastercard, "0002", year: 2030, added: 0)
        let expired = card(.amex, "0003", month: 1, year: 2020, added: 500)
        XCTAssertEqual(CardRules.ordered([old, expired, new], at: now).map(\.last4), ["0002", "0001", "0003"])
    }

    // MARK: Who could be allowed

    private func booking(_ creator: UUID, _ name: String, client: UUID, status: BookingStatus = .confirmed, startsIn days: Double = 5, hold: Date? = nil) -> Booking {
        let start = now.addingTimeInterval(days * 86_400)
        return Booking(
            id: UUID(), creatorID: creator, clientID: client, creatorName: name, clientName: "Sam Client",
            packageID: nil, packageName: "Portrait session", addOns: [],
            startAt: start, endAt: start.addingTimeInterval(3600), blockedUntil: start.addingTimeInterval(5400),
            timeZoneID: "America/Chicago", currencyCode: "USD", totalCents: 200_000, depositCents: 50_000,
            status: status, notes: "", createdAt: now, holdExpiresAt: hold
        )
    }

    private func permission(_ creator: UUID) -> CardPermission {
        CardPermission(
            creatorID: creator, creatorName: "Allowed", handle: nil, cardID: UUID(), brand: .visa, last4: "4242",
            expMonth: 8, expYear: 2030, allowedAt: now
        )
    }

    func testOnlyCreatorsTheClientHasBookedCanBeAllowed() {
        let me = UUID(), dana = UUID(), maya = UUID(), lee = UUID()
        let bookings = [
            booking(dana, "Dana Lens", client: me, startsIn: 3),
            booking(dana, "Dana Lens", client: me, startsIn: 9),
            booking(maya, "Maya Chen", client: me, status: .completed, startsIn: -30),
            booking(lee, "Lee Park", client: UUID()), // someone else's booking
        ]
        let found = CardRules.candidates(bookings: bookings, permissions: [], userID: me, at: now)
        XCTAssertEqual(found.map(\.name), ["Dana Lens", "Maya Chen"], "One row for each creator, the most recent booking first")
        XCTAssertEqual(found.first?.lastBookingAt, bookings[1].startAt)
    }

    func testCancelledAndExpiredBookingsDoNotCountButAHeldOneDoes() {
        let me = UUID(), a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let bookings = [
            booking(a, "Cancelled", client: me, status: .cancelled),
            booking(b, "Expired", client: me, status: .expired),
            booking(c, "Held", client: me, status: .held, hold: now.addingTimeInterval(600)),
            booking(d, "Lapsed hold", client: me, status: .held, hold: now.addingTimeInterval(-60)),
        ]
        XCTAssertEqual(CardRules.candidates(bookings: bookings, permissions: [], userID: me, at: now).map(\.name), ["Held"])
    }

    func testAnAlreadyAllowedCreatorAndYourselfAreLeftOut() {
        let me = UUID(), dana = UUID()
        let bookings = [booking(dana, "Dana Lens", client: me), booking(me, "My own studio", client: me)]
        XCTAssertTrue(CardRules.candidates(bookings: bookings, permissions: [permission(dana)], userID: me, at: now).isEmpty)
    }

    // MARK: What a booking offers

    func testWhatTheCreatorIsOfferedFollowsTheBookingsMoney() {
        let allowed = CardAccess(allowed: true, brand: .visa, last4: nil, expired: false)
        let phases: [(PaymentSummary.Phase, CardRules.ChargeState)] = [
            (.depositDue, .waiting), (.depositFailed, .waiting), (.depositPaid, .waiting), (.noDepositRequired, .waiting),
            (.awaitingConfirmation, .waiting), (.balanceDue, .ready),
            (.holdExpired, .hidden), (.paidInFull, .hidden), (.cancelledUnpaid, .hidden), (.refundPending, .hidden),
            (.refunded, .hidden), (.refundFailed, .hidden), (.noRefund, .hidden),
        ]
        for (phase, expected) in phases {
            XCTAssertEqual(CardRules.chargeState(access: allowed, phase: phase), expected, "\(phase)")
        }
    }

    func testNothingIsOfferedWithoutAPermission() {
        for phase in [PaymentSummary.Phase.depositPaid, .balanceDue, .awaitingConfirmation] {
            XCTAssertEqual(CardRules.chargeState(access: .none, phase: phase), .hidden, "\(phase)")
        }
    }

    func testAnExpiredCardIsSaidSoUnlessThereIsNothingLeftToPay() {
        let expired = CardAccess(allowed: true, brand: .visa, last4: nil, expired: true)
        XCTAssertEqual(CardRules.chargeState(access: expired, phase: .balanceDue), .expired)
        XCTAssertEqual(CardRules.chargeState(access: expired, phase: .depositPaid), .expired)
        XCTAssertEqual(CardRules.chargeState(access: expired, phase: .paidInFull), .hidden)
    }

    func testTheClientIsOfferedToAllowOnlyWhileABalanceIsStillToCome() {
        XCTAssertTrue(CardRules.shouldOfferToAllow(access: .none, phase: .depositPaid, hasUsableCard: true))
        XCTAssertTrue(CardRules.shouldOfferToAllow(access: .none, phase: .balanceDue, hasUsableCard: true))
        XCTAssertFalse(CardRules.shouldOfferToAllow(access: .none, phase: .depositPaid, hasUsableCard: false), "They need a card first")
        XCTAssertFalse(CardRules.shouldOfferToAllow(access: .none, phase: .paidInFull, hasUsableCard: true))
        XCTAssertFalse(CardRules.shouldOfferToAllow(access: .none, phase: .refunded, hasUsableCard: true))
        XCTAssertFalse(CardRules.shouldOfferToAllow(
            access: CardAccess(allowed: true, brand: .visa, last4: "4242", expired: false), phase: .depositPaid, hasUsableCard: true
        ), "Already allowed")
    }

    func testWhatAProviderSeesNeverIncludesTheLastFourDigits() {
        let access = CardAccess(allowed: true, brand: .visa, last4: nil, expired: false)
        XCTAssertEqual(access.cardTitle, "Visa")
        XCTAssertEqual(CardAccess(allowed: true, brand: .visa, last4: "4242", expired: false).cardTitle, "Visa ending 4242")
        XCTAssertNil(CardAccess.none.cardTitle)
    }

    // MARK: The agreement

    func testTheAgreementNamesTheCreatorTheCardAndTheLimits() {
        let visa = card(.visa, "4242")
        let words = CardConsent.paragraphs(creator: "Dana Lens", card: visa).joined(separator: " ")
        XCTAssertTrue(words.contains("Dana Lens will be able to charge the remaining balance of your bookings with them to your Visa ending 4242"))
        XCTAssertTrue(words.contains("once you've confirmed you have your files"))
        XCTAssertTrue(words.contains("can't charge anything else"))
        XCTAssertTrue(words.contains("never see your card number"))
        XCTAssertTrue(words.contains("stop this at any time"))
        XCTAssertEqual(CardConsent.title(creator: "Dana Lens"), "Let Dana Lens charge your card?")
        XCTAssertEqual(CardConsent.button(creator: "Dana Lens"), "Allow Dana Lens")
    }
}

// MARK: - The on-device backend

/// Cards, permissions and charges against the on-device backend, on a clock the tests move by hand. The same rules are
/// tested in Postgres by `supabase/tests/card_rules.py`.
final class CardBackendTests: XCTestCase {
    private var root: URL!
    private var clock: ManualClock!
    private var backend: LocalBackend!
    private var dana: (id: UUID, package: ServicePackage)!

    // Monday 4 Jan 2027, 8:00 in Chicago. The shoot below is Friday 22 Jan at 10:00.
    private let start = TestClock.date(2027, 1, 4, 8, 0)
    private let friday = TestClock.date(2027, 1, 22, 10, 0)
    private let client = UUID()
    private let stranger = UUID()
    private static let files = "https://files.example.com/final"

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-cards-\(UUID().uuidString)")
        let clock = ManualClock(start)
        self.clock = clock
        backend = LocalBackend(root: root, clock: { clock.now })
        dana = try await makeCreator()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    // MARK: Helpers

    private func makeCreator(handle: String = "dana-lens", name: String = "Dana Lens") async throws -> (id: UUID, package: ServicePackage) {
        let session = try await backend.signInWithApple(
            AppleCredential(userID: "apple-\(handle)", identityToken: "t", rawNonce: "n", fullName: nil, email: nil)
        )
        _ = try await backend.saveProfile(CreatorProfile(
            id: session.userID, handle: handle, displayName: name, bio: "", specialties: [.portraits],
            location: nil, avatarURL: nil, createdAt: Date(), updatedAt: Date()
        ), avatarJPEG: nil)
        _ = try await backend.saveAvailability(AvailabilitySettings.standard(timeZone: TestClock.timeZone), for: session.userID)
        let template = try await ContractFixtures.equip(backend, creatorID: session.userID)
        let saved = try await backend.savePackage(ServicePackage(
            id: UUID(), creatorID: session.userID, name: "Portrait session", summary: "", category: .portraits,
            priceCents: 200_000, currencyCode: "USD", durationMinutes: 60, deliverables: ["30 edited photos"], turnaroundDays: 7,
            depositCents: 50_000, addOns: [], isPublished: true, position: 0, createdAt: Date(), updatedAt: Date(),
            contractTemplateID: template.id, cancellationPolicy: .moderate
        ))
        return (session.userID, saved[0])
    }

    @discardableResult
    private func book(_ creator: (id: UUID, package: ServicePackage)? = nil, at date: Date? = nil, pay: Bool = true) async throws -> SignedBooking {
        let creator = creator ?? dana!
        let request = BookingRequest(creatorID: creator.id, packageID: creator.package.id, addOnIDs: [], startAt: date ?? friday, notes: "")
        return try await ContractFixtures.signedBooking(backend, request, clientID: client, name: "Sam Client", pay: pay)
    }

    @discardableResult
    private func addCard() async throws -> SavedCard {
        guard case .added(let card) = try await backend.beginAddingCard(for: client) else {
            XCTFail("A demo card is added on the spot")
            throw SlateError.cardNotFound
        }
        return card
    }

    private func expectError<T>(_ expected: SlateError, file: StaticString = #filePath, line: UInt = #line, _ work: () async throws -> T) async {
        do {
            _ = try await work()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SlateError, expected, file: file, line: line)
        }
    }

    /// The shoot is over and the client has confirmed their files: the balance is payable.
    private func payable(_ signed: SignedBooking, creator: (id: UUID, package: ServicePackage)? = nil) async throws {
        clock.set(signed.booking.endAt.addingTimeInterval(3600))
        _ = try await backend.shareDelivery(bookingID: signed.booking.id, link: Self.files, note: "", by: (creator ?? dana!).id)
        _ = try await backend.confirmReceipt(bookingID: signed.booking.id, by: client)
    }

    private func balancePayments(_ id: UUID) async throws -> [Payment] {
        try await backend.loadPayments(for: client).filter { $0.bookingID == id && $0.kind == .balance }
    }

    // MARK: Cards

    func testDemoCardsAreAddedOneAtATimeUpToTheLimit() async throws {
        let empty = try await backend.loadCards(for: client)
        XCTAssertTrue(empty.isEmpty)
        var added: [SavedCard] = []
        for _ in 0..<CardRules.maxCards { added.append(try await addCard()) }

        XCTAssertEqual(added.map(\.last4), ["4242", "4444", "0005", "1117", "0004"])
        XCTAssertEqual(Set(added.map(\.id)).count, CardRules.maxCards)
        XCTAssertTrue(added.allSatisfy { !$0.isExpired(at: clock.now) && $0.expYear == 2030 }, "Three years out")
        let stored = try await backend.loadCards(for: client)
        XCTAssertEqual(stored.map(\.id), added.map(\.id))

        await expectError(.tooManyCards(limit: CardRules.maxCards)) { try await backend.beginAddingCard(for: client) }
        let other = try await backend.loadCards(for: stranger)
        XCTAssertTrue(other.isEmpty, "Cards belong to one person")
    }

    func testSyncingChangesNothingOnDevice() async throws {
        let card = try await addCard()
        let synced = try await backend.syncCards(for: client)
        XCTAssertEqual(synced, [card])
    }

    func testRemovingACardTakesItsPermissionsWithIt() async throws {
        let visa = try await addCard()
        let mastercard = try await addCard()
        try await book()
        try await backend.allowCreator(dana.id, cardID: visa.id, consentVersion: CardConsent.version, for: client)

        try await backend.removeCard(mastercard.id, for: client)
        let keptPermissions = try await backend.loadCardPermissions(for: client)
        XCTAssertEqual(keptPermissions.count, 1, "The other card's permission stays")

        try await backend.removeCard(visa.id, for: client)
        let cards = try await backend.loadCards(for: client)
        let permissions = try await backend.loadCardPermissions(for: client)
        XCTAssertTrue(cards.isEmpty)
        XCTAssertTrue(permissions.isEmpty)
        await expectError(.cardNotFound) { try await backend.removeCard(visa.id, for: client) }
        await expectError(.cardNotFound) { try await backend.removeCard(mastercard.id, for: stranger) }
    }

    // MARK: Allowing a creator

    func testAllowingNeedsTheRightWordingAYourOwnCardAndABooking() async throws {
        let card = try await addCard()
        await expectError(.cardConsentOutdated) { try await backend.allowCreator(dana.id, cardID: card.id, consentVersion: 0, for: client) }
        await expectError(.cardConsentOutdated) { try await backend.allowCreator(dana.id, cardID: card.id, consentVersion: CardRules.consentVersion + 1, for: client) }
        await expectError(.cardNotFound) { try await backend.allowCreator(dana.id, cardID: UUID(), consentVersion: CardConsent.version, for: client) }
        await expectError(.cardNotFound) { try await backend.allowCreator(dana.id, cardID: card.id, consentVersion: CardConsent.version, for: stranger) }
        await expectError(.noBookingWithCreator) { try await backend.allowCreator(dana.id, cardID: card.id, consentVersion: CardConsent.version, for: client) }

        try await book(pay: false) // held, still counts
        try await backend.allowCreator(dana.id, cardID: card.id, consentVersion: CardConsent.version, for: client)
        let permissions = try await backend.loadCardPermissions(for: client)
        XCTAssertEqual(permissions.map(\.creatorID), [dana.id])
        XCTAssertEqual(permissions.first?.creatorName, "Dana Lens")
        XCTAssertEqual(permissions.first?.cardTitle, "Visa ending 4242")
        XCTAssertEqual(permissions.first?.allowedAt, clock.now)
    }

    func testACancelledBookingIsNotAReasonToAllowAnyone() async throws {
        let card = try await addCard()
        let signed = try await book()
        _ = try await backend.cancelBooking(signed.booking.id, by: client)
        await expectError(.noBookingWithCreator) { try await backend.allowCreator(dana.id, cardID: card.id, consentVersion: CardConsent.version, for: client) }
    }

    func testAllowingAgainWithAnotherCardReplacesTheFirst() async throws {
        let visa = try await addCard()
        let mastercard = try await addCard()
        try await book()
        try await backend.allowCreator(dana.id, cardID: visa.id, consentVersion: CardConsent.version, for: client)
        try await backend.allowCreator(dana.id, cardID: mastercard.id, consentVersion: CardConsent.version, for: client)

        let permissions = try await backend.loadCardPermissions(for: client)
        XCTAssertEqual(permissions.count, 1)
        XCTAssertEqual(permissions.first?.cardID, mastercard.id)
    }

    func testStoppingIsImmediateAndHarmlessTwice() async throws {
        let card = try await addCard()
        try await book()
        try await backend.allowCreator(dana.id, cardID: card.id, consentVersion: CardConsent.version, for: client)

        try await backend.stopAllowingCreator(dana.id, for: client)
        try await backend.stopAllowingCreator(dana.id, for: client)
        let permissions = try await backend.loadCardPermissions(for: client)
        XCTAssertTrue(permissions.isEmpty)
        try await backend.stopAllowingCreator(dana.id, for: stranger)
    }

    func testAnExpiredCardCannotBeAllowed() async throws {
        let card = try await addCard()
        try await book()
        clock.set(TestClock.date(2031, 3, 1, 9, 0))
        await expectError(.cardExpired) { try await backend.allowCreator(dana.id, cardID: card.id, consentVersion: CardConsent.version, for: client) }
    }

    // MARK: What a booking says

    func testWhatABookingSaysDependsOnWhoAsks() async throws {
        let card = try await addCard()
        let signed = try await book()
        let id = signed.booking.id

        let before = try await backend.cardAccess(bookingID: id, for: client)
        XCTAssertEqual(before, CardAccess.none)

        try await backend.allowCreator(dana.id, cardID: card.id, consentVersion: CardConsent.version, for: client)
        let asClient = try await backend.cardAccess(bookingID: id, for: client)
        XCTAssertEqual(asClient, CardAccess(allowed: true, brand: .visa, last4: "4242", expired: false))
        let asCreator = try await backend.cardAccess(bookingID: id, for: dana.id)
        XCTAssertEqual(asCreator, CardAccess(allowed: true, brand: .visa, last4: nil, expired: false), "The creator never learns the last four")

        await expectError(.bookingNotFound) { try await backend.cardAccess(bookingID: id, for: stranger) }
        await expectError(.bookingNotFound) { try await backend.cardAccess(bookingID: UUID(), for: client) }

        clock.set(TestClock.date(2031, 3, 1, 9, 0))
        let later = try await backend.cardAccess(bookingID: id, for: dana.id)
        XCTAssertTrue(later.expired)
    }

    // MARK: Charging

    func testTheCreatorCanChargeTheBalanceOnlyOnceItIsPayable() async throws {
        let card = try await addCard()
        let signed = try await book()
        let id = signed.booking.id
        try await backend.allowCreator(dana.id, cardID: card.id, consentVersion: CardConsent.version, for: client)

        await expectError(.paymentNotDue) { try await backend.chargeSavedCard(bookingID: id, by: dana.id) }
        clock.set(signed.booking.endAt.addingTimeInterval(3600))
        _ = try await backend.shareDelivery(bookingID: id, link: Self.files, note: "", by: dana.id)
        await expectError(.paymentNotDue) { try await backend.chargeSavedCard(bookingID: id, by: dana.id) }
        let nothingYet = try await balancePayments(id)
        XCTAssertTrue(nothingYet.isEmpty, "A permission is not a way round the client's confirmation")

        _ = try await backend.confirmReceipt(bookingID: id, by: client)
        let charge = try await backend.chargeSavedCard(bookingID: id, by: dana.id)
        XCTAssertEqual(charge.status, .succeeded)

        let paid = try await balancePayments(id)
        XCTAssertEqual(paid.count, 1)
        XCTAssertEqual(paid.first?.amountCents, 150_000, "The balance: the total less the deposit. Nothing in the call could name another amount.")
        XCTAssertEqual(paid.first?.status, .succeeded)
        XCTAssertEqual(paid.first?.id, charge.paymentID)
        let bookings = try await backend.loadBookings(for: client)
        XCTAssertEqual(bookings.first { $0.id == id }?.status, .completed)

        await expectError(.paymentNotDue) { try await backend.chargeSavedCard(bookingID: id, by: dana.id) }
        let still = try await balancePayments(id)
        XCTAssertEqual(still.count, 1, "Nothing is charged twice")
    }

    func testNobodyElseCanCharge() async throws {
        let card = try await addCard()
        let signed = try await book()
        let id = signed.booking.id
        try await payable(signed)

        await expectError(.noCardAccess) { try await backend.chargeSavedCard(bookingID: id, by: dana.id) }
        try await backend.allowCreator(dana.id, cardID: card.id, consentVersion: CardConsent.version, for: client)
        await expectError(.bookingNotFound) { try await backend.chargeSavedCard(bookingID: id, by: client) }
        await expectError(.bookingNotFound) { try await backend.chargeSavedCard(bookingID: id, by: stranger) }
        await expectError(.bookingNotFound) { try await backend.chargeSavedCard(bookingID: UUID(), by: dana.id) }
        let untouched = try await balancePayments(id)
        XCTAssertTrue(untouched.isEmpty)
    }

    func testAPermissionForOneCreatorIsNoPermissionForAnother() async throws {
        let card = try await addCard()
        let maya = try await makeCreator(handle: "maya-chen", name: "Maya Chen")
        try await book()
        let withMaya = try await book(maya, at: friday.addingTimeInterval(-86_400)) // Thursday: she is open Monday to Friday
        try await backend.allowCreator(dana.id, cardID: card.id, consentVersion: CardConsent.version, for: client)

        clock.set(withMaya.booking.endAt.addingTimeInterval(3600))
        _ = try await backend.shareDelivery(bookingID: withMaya.booking.id, link: Self.files, note: "", by: maya.id)
        _ = try await backend.confirmReceipt(bookingID: withMaya.booking.id, by: client)
        await expectError(.noCardAccess) { try await backend.chargeSavedCard(bookingID: withMaya.booking.id, by: maya.id) }
    }

    func testStoppingAccessStopsTheChargeAndRemovingTheCardDoesToo() async throws {
        let card = try await addCard()
        let signed = try await book()
        let id = signed.booking.id
        try await payable(signed)

        try await backend.allowCreator(dana.id, cardID: card.id, consentVersion: CardConsent.version, for: client)
        try await backend.stopAllowingCreator(dana.id, for: client)
        await expectError(.noCardAccess) { try await backend.chargeSavedCard(bookingID: id, by: dana.id) }

        try await backend.allowCreator(dana.id, cardID: card.id, consentVersion: CardConsent.version, for: client)
        try await backend.removeCard(card.id, for: client)
        await expectError(.noCardAccess) { try await backend.chargeSavedCard(bookingID: id, by: dana.id) }
        let cardAccess = try await backend.cardAccess(bookingID: id, for: dana.id)
        XCTAssertEqual(cardAccess, CardAccess.none)
    }

    func testAnExpiredCardCannotBeCharged() async throws {
        let card = try await addCard()
        let signed = try await book()
        let id = signed.booking.id
        try await payable(signed)
        try await backend.allowCreator(dana.id, cardID: card.id, consentVersion: CardConsent.version, for: client)

        clock.set(TestClock.date(2031, 3, 1, 9, 0))
        await expectError(.cardExpired) { try await backend.chargeSavedCard(bookingID: id, by: dana.id) }
        let untouched = try await balancePayments(id)
        XCTAssertTrue(untouched.isEmpty)
    }

    func testAChargeBeforeTheDepositIsPaidIsRefused() async throws {
        let card = try await addCard()
        let held = try await book(pay: false)
        try await backend.allowCreator(dana.id, cardID: card.id, consentVersion: CardConsent.version, for: client)
        await expectError(.paymentNotDue) { try await backend.chargeSavedCard(bookingID: held.booking.id, by: dana.id) }
    }
}

// MARK: - A company

/// At a company, whoever can manage the booking can charge; a Creator only on their own; a Viewer can look, not charge.
final class CardCompanyTests: TeamTestCase {
    private func settle(_ signed: SignedBooking, client: UUID, by owner: UUID) async throws {
        clock.set(signed.booking.endAt.addingTimeInterval(3600))
        _ = try await backend.shareDelivery(bookingID: signed.booking.id, link: "https://files.example.com/final", note: "", by: owner)
        _ = try await backend.confirmReceipt(bookingID: signed.booking.id, by: client)
    }

    func testOnlyPeopleWhoCanManageTheBookingCanCharge() async throws {
        let company = try await makeCompany()
        let client = UUID()
        guard case .added(let card) = try await backend.beginAddingCard(for: client) else { return XCTFail("A demo card") }

        // Four bookings, each charged by a different person; Theo's is assigned to Theo, the others to Jun.
        let forOwner = try await book(company, at: wednesday(9), member: company.jun, client: client)
        let forAdmin = try await book(company, at: wednesday(11), member: company.jun, client: client)
        let forManager = try await book(company, at: wednesday(13), member: company.jun, client: client)
        let forTheo = try await book(company, at: wednesday(10), member: company.theo, client: client)
        try await backend.allowCreator(company.org.id, cardID: card.id, consentVersion: CardConsent.version, for: client)
        // In the order the shoots happened, so the clock only moves forward.
        for signed in [forOwner, forTheo, forAdmin, forManager] { try await settle(signed, client: client, by: company.owner) }

        // Who may look, who may charge.
        let viewerSees = try await backend.cardAccess(bookingID: forOwner.booking.id, for: company.viewer)
        XCTAssertEqual(viewerSees, CardAccess(allowed: true, brand: .visa, last4: nil, expired: false))
        await expectError(.bookingNotFound) { try await backend.chargeSavedCard(bookingID: forOwner.booking.id, by: company.viewer) }
        await expectError(.bookingNotFound) { try await backend.chargeSavedCard(bookingID: forTheo.booking.id, by: company.jun) }
        await expectError(.bookingNotFound) { try await backend.chargeSavedCard(bookingID: forOwner.booking.id, by: UUID()) }

        let byOwner = try await backend.chargeSavedCard(bookingID: forOwner.booking.id, by: company.owner)
        let byAdmin = try await backend.chargeSavedCard(bookingID: forAdmin.booking.id, by: company.admin)
        let byManager = try await backend.chargeSavedCard(bookingID: forManager.booking.id, by: company.manager)
        let byTheo = try await backend.chargeSavedCard(bookingID: forTheo.booking.id, by: company.theo)
        XCTAssertEqual([byOwner, byAdmin, byManager, byTheo].map(\.status), Array(repeating: .succeeded, count: 4))

        let payments = try await backend.loadPayments(for: client).filter { $0.kind == .balance && $0.status == .succeeded }
        XCTAssertEqual(payments.count, 4)
        XCTAssertTrue(payments.allSatisfy { $0.amountCents == 150_000 })
    }

    func testThePermissionIsForTheCompanyNotForAPerson() async throws {
        let company = try await makeCompany()
        let client = UUID()
        guard case .added(let card) = try await backend.beginAddingCard(for: client) else { return XCTFail("A demo card") }
        _ = try await book(company, at: wednesday(9), member: company.jun, client: client)

        await expectError(.noBookingWithCreator) { try await backend.allowCreator(company.jun, cardID: card.id, consentVersion: CardConsent.version, for: client) }
        try await backend.allowCreator(company.org.id, cardID: card.id, consentVersion: CardConsent.version, for: client)
        let permissions = try await backend.loadCardPermissions(for: client)
        XCTAssertEqual(permissions.first?.creatorName, "Northlight Films")
    }
}

// MARK: - The app model

@MainActor
final class CardFlowTests: XCTestCase {
    private var root: URL!
    private var clock: ManualClock!
    private var backend: LocalBackend!
    private var model: AppModel!
    private var dana: CreatorProfile!
    private var package: ServicePackage!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-cardflow-\(UUID().uuidString)")
        clock = ManualClock(Date())
        let clock = self.clock!
        backend = LocalBackend(root: root, clock: { clock.now })
        model = AppModel(backend: backend, authorizer: ScriptedAuthorizer(), widget: RecordingWidgetPublisher())
        model.clock = { clock.now }
        try await makeCreator()
        await model.signInAsDemo() // The person who will be booking.
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private func makeCreator() async throws {
        let session = try await backend.signInWithApple(
            AppleCredential(userID: "creator-apple", identityToken: "t", rawNonce: "n", fullName: nil, email: nil)
        )
        dana = try await backend.saveProfile(CreatorProfile(
            id: session.userID, handle: "dana-lens", displayName: "Dana Lens", bio: "", specialties: [.portraits],
            location: nil, avatarURL: nil, createdAt: Date(), updatedAt: Date()
        ), avatarJPEG: nil)
        _ = try await backend.saveAvailability(AvailabilitySettings.standard(timeZone: TestClock.timeZone), for: session.userID)
        let template = try await ContractFixtures.equip(backend, creatorID: session.userID)
        let id = UUID()
        let saved = try await backend.savePackage(ServicePackage(
            id: id, creatorID: session.userID, name: "Half day", summary: "", category: nil,
            priceCents: 200_000, currencyCode: "USD", durationMinutes: 120, deliverables: [], turnaroundDays: 14,
            depositCents: 50_000, addOns: [], isPublished: true, position: 0, createdAt: Date(), updatedAt: Date(),
            contractTemplateID: template.id, cancellationPolicy: .flexible
        ))
        package = try XCTUnwrap(saved.first { $0.id == id })
    }

    /// The signed-in person books Dana, through the booking screen, and pays the deposit.
    private func bookDana() async throws -> Booking {
        let screen = BookingModel(creator: dana, package: package, signerName: "Sam Client")
        await screen.load(using: model)
        screen.select(screen.days[2].slots.first!)
        let ok = await screen.submit(using: model)
        XCTAssertTrue(ok)
        return try XCTUnwrap(screen.confirmed)
    }

    /// Delivery is the creator's act, so the charge tests book the demo person's own package (on-device allows that).
    private func ownBooking() async throws -> Booking {
        let userID = try XCTUnwrap(model.session?.userID)
        _ = try await backend.saveProfile(CreatorProfile(
            id: userID, handle: "demo-studio", displayName: "Demo Studio", bio: "", specialties: [.portraits],
            location: nil, avatarURL: nil, createdAt: Date(), updatedAt: Date()
        ), avatarJPEG: nil)
        _ = try await backend.saveAvailability(AvailabilitySettings.standard(timeZone: TestClock.timeZone), for: userID)
        let template = try await ContractFixtures.equip(backend, creatorID: userID)
        let own = try await backend.savePackage(ServicePackage(
            id: UUID(), creatorID: userID, name: "My session", summary: "", category: nil,
            priceCents: 200_000, currencyCode: "USD", durationMinutes: 60, deliverables: [], turnaroundDays: 7,
            depositCents: 50_000, addOns: [], isPublished: true, position: 0, createdAt: Date(), updatedAt: Date(),
            contractTemplateID: template.id
        ))[0]
        let loaded = try await backend.loadProfile(for: userID)
        let screen = BookingModel(creator: try XCTUnwrap(loaded), package: own, signerName: "Demo Person")
        await screen.load(using: model)
        screen.select(screen.days[2].slots.first!)
        let ok = await screen.submit(using: model)
        XCTAssertTrue(ok)
        return try XCTUnwrap(screen.confirmed)
    }

    // MARK: Cards

    func testCardsAreAddedShownAndStopAtTheLimit() async {
        XCTAssertTrue(model.cards.isEmpty)
        for _ in 0..<CardRules.maxCards {
            let address = await model.beginAddingCard()
            XCTAssertNil(address, "On-device the card is added on the spot")
        }
        XCTAssertEqual(model.cards.count, CardRules.maxCards)
        XCTAssertEqual(model.cards.first?.title, "Visa ending 4242")
        XCTAssertFalse(model.canAddCard)
        XCTAssertNil(model.alert)

        _ = await model.beginAddingCard()
        XCTAssertEqual(model.alert?.message, SlateError.tooManyCards(limit: CardRules.maxCards).errorDescription)
        XCTAssertEqual(model.cards.count, CardRules.maxCards)
    }

    func testAllowingACreatorShowsThemAndRemovingTheCardEndsIt() async throws {
        _ = await model.beginAddingCard()
        let card = try XCTUnwrap(model.cards.first)
        XCTAssertTrue(model.creatorsToAllow.isEmpty, "Nobody booked yet")

        _ = try await bookDana()
        await model.reloadMoney()
        XCTAssertEqual(model.creatorsToAllow.map(\.name), ["Dana Lens"])

        let allowed = await model.allowCreator(dana.id, with: card)
        XCTAssertTrue(allowed)
        XCTAssertEqual(model.cardPermissions.map(\.creatorName), ["Dana Lens"])
        XCTAssertTrue(model.creatorsToAllow.isEmpty, "Already allowed")

        let removed = await model.removeCard(card)
        XCTAssertTrue(removed)
        XCTAssertTrue(model.cards.isEmpty)
        XCTAssertTrue(model.cardPermissions.isEmpty, "The permission went with the card")
    }

    func testStoppingAccessIsImmediate() async throws {
        _ = await model.beginAddingCard()
        let card = try XCTUnwrap(model.cards.first)
        _ = try await bookDana()
        _ = await model.allowCreator(dana.id, with: card)
        let permission = try XCTUnwrap(model.cardPermissions.first)

        let stopped = await model.stopAllowing(permission)
        XCTAssertTrue(stopped)
        XCTAssertTrue(model.cardPermissions.isEmpty)
        XCTAssertEqual(model.creatorsToAllow.map(\.name), ["Dana Lens"], "They can be allowed again")
    }

    func testAllowingACreatorYouHaveNotBookedSaysSo() async throws {
        _ = await model.beginAddingCard()
        let card = try XCTUnwrap(model.cards.first)
        let allowed = await model.allowCreator(dana.id, with: card)
        XCTAssertFalse(allowed)
        XCTAssertEqual(model.alert?.message, SlateError.noBookingWithCreator.errorDescription)
        XCTAssertTrue(model.cardPermissions.isEmpty)
    }

    // MARK: On a booking

    func testASavedCardPaysTheBalanceOnceTheFilesAreConfirmed() async throws {
        _ = await model.beginAddingCard()
        let card = try XCTUnwrap(model.cards.first)
        let booking = try await ownBooking()
        let userID = try XCTUnwrap(model.session?.userID)
        XCTAssertEqual(model.paymentSummary(for: booking).phase, .depositPaid)

        _ = await model.allowCreator(userID, with: card)
        await model.refreshCardAccess(for: booking)
        XCTAssertEqual(model.cardAccessByBooking[booking.id]?.allowed, true)
        XCTAssertEqual(CardRules.chargeState(access: model.cardAccessByBooking[booking.id] ?? .none, phase: .depositPaid), .waiting)

        let early = await model.chargeSavedCard(for: booking)
        XCTAssertEqual(early, .failed(SlateError.paymentNotDue.errorDescription ?? ""), "Not until the client has confirmed their files")

        clock.advance(by: 10 * 86_400)
        await model.reloadMoney()
        let started = try XCTUnwrap(model.bookings.first { $0.id == booking.id })
        let shared = await model.shareDelivery(started, link: "https://files.example.com/final", note: "")
        XCTAssertTrue(shared)
        let delivered = try XCTUnwrap(model.bookings.first { $0.id == booking.id })
        let confirmed = await model.confirmReceipt(delivered)
        XCTAssertTrue(confirmed)
        let ready = try XCTUnwrap(model.bookings.first { $0.id == booking.id })
        XCTAssertEqual(model.paymentSummary(for: ready).phase, .balanceDue)
        XCTAssertEqual(CardRules.chargeState(access: model.cardAccessByBooking[booking.id] ?? .none, phase: .balanceDue), .ready)

        let outcome = await model.chargeSavedCard(for: ready)
        XCTAssertEqual(outcome, .confirmed)
        let after = try XCTUnwrap(model.bookings.first { $0.id == booking.id })
        XCTAssertEqual(after.status, .completed)
        XCTAssertEqual(model.paymentSummary(for: after).phase, .paidInFull)
        XCTAssertFalse(model.isPaying)
    }

    func testChargingWithoutAPermissionFailsInWords() async throws {
        let booking = try await ownBooking()
        clock.advance(by: 10 * 86_400)
        await model.reloadMoney()
        let started = try XCTUnwrap(model.bookings.first { $0.id == booking.id })
        _ = await model.shareDelivery(started, link: "https://files.example.com/final", note: "")
        let delivered = try XCTUnwrap(model.bookings.first { $0.id == booking.id })
        _ = await model.confirmReceipt(delivered)
        let ready = try XCTUnwrap(model.bookings.first { $0.id == booking.id })

        let outcome = await model.chargeSavedCard(for: ready)
        XCTAssertEqual(outcome, .failed(SlateError.noCardAccess.errorDescription ?? ""))
        XCTAssertEqual(outcome.message, SlateError.noCardAccess.errorDescription)
    }

    func testSigningOutForgetsTheCards() async {
        _ = await model.beginAddingCard()
        XCTAssertFalse(model.cards.isEmpty)
        await model.signOut()
        XCTAssertTrue(model.cards.isEmpty)
        XCTAssertTrue(model.cardPermissions.isEmpty)
        XCTAssertTrue(model.cardAccessByBooking.isEmpty)
    }
}

// MARK: - The server's answers

/// The Supabase backend against what the database really returns. `Fixtures/card_rows.json` is written by
/// `supabase/tests/card_rules.py --dump`, and that script fails if the database stops matching it.
final class CardRowDecodingTests: XCTestCase {
    private var rows: [String: Any] = [:]

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "card_rows", withExtension: "json"), "card_rows.json is missing from the test bundle")
        rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// Postgres writes microseconds; Foundation's ISO 8601 parser is only promised milliseconds, so trim them.
    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            let trimmed = text.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: trimmed) { return date }
            if let date = ISO8601DateFormatter().date(from: trimmed) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a date: \(text)"))
        }
        return decoder
    }

    private func load<T: Decodable>(_ key: String, _ type: T.Type = T.self) throws -> T {
        let value = try XCTUnwrap(rows[key], "\(key) is missing from card_rows.json")
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        return try decoder().decode(type, from: data)
    }

    func testACardRow() throws {
        let row: SupabaseBackend.CardRow = try load("card")
        let card = try row.card()
        XCTAssertEqual(card.brand, .visa)
        XCTAssertEqual(card.last4, "4242")
        XCTAssertEqual(card.expMonth, 8)
        XCTAssertEqual(card.title, "Visa ending 4242")
    }

    func testAPermissionRow() throws {
        let row: SupabaseBackend.CardGrantRow = try load("grant")
        let permission = try row.permission()
        XCTAssertEqual(permission.creatorName, "Carol Chen")
        XCTAssertEqual(permission.handle, "carol-c")
        XCTAssertEqual(permission.cardTitle, "Visa ending 4242")
    }

    func testWhatABookingSaysToTheClientTheCreatorAndNobody() throws {
        let client = try load("access_client", SupabaseBackend.CardAccessRow.self).access()
        XCTAssertEqual(client, CardAccess(allowed: true, brand: .visa, last4: "4242", expired: false))
        let creator = try load("access_creator", SupabaseBackend.CardAccessRow.self).access()
        XCTAssertEqual(creator, CardAccess(allowed: true, brand: .visa, last4: nil, expired: false))
        let none = try load("access_none", SupabaseBackend.CardAccessRow.self).access()
        XCTAssertEqual(none, CardAccess.none)
    }

    func testTheAppAsksOnlyForColumnsItMayRead() {
        let asked = SupabaseBackend.cardColumns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(Set(asked), ["id", "brand", "last4", "exp_month", "exp_year", "created_at"])
        XCTAssertFalse(SupabaseBackend.cardColumns.contains("stripe"), "Stripe's reference never reaches the phone")
        XCTAssertFalse(SupabaseBackend.cardColumns.contains("*"))
    }
}

// MARK: - Errors and links

final class CardErrorMappingTests: XCTestCase {
    private struct Said: Error, CustomStringConvertible {
        var description: String
    }

    func testTheFunctionsAnswersBecomeWords() {
        func map(_ token: String) -> SlateError { SupabaseBackend.paymentError(fromFunctionBody: Data(#"{"error":"\#(token)"}"#.utf8)) }
        XCTAssertEqual(map("card_declined"), .cardDeclined)
        XCTAssertEqual(map("authentication_required"), .cardNeedsApproval)
        XCTAssertEqual(map("no_card_access"), .noCardAccess)
        XCTAssertEqual(map("card_expired"), .cardExpired)
        XCTAssertEqual(map("card_not_found"), .cardNotFound)
        XCTAssertEqual(map("too_many_cards"), .tooManyCards(limit: CardRules.maxCards))
        XCTAssertEqual(map("balance_not_due"), .paymentNotDue)
        XCTAssertEqual(map("already_paid"), .alreadyPaid)
        XCTAssertEqual(map("payment_processing"), .paymentProcessing)
        XCTAssertEqual(map("something_new"), .paymentUnavailable)
    }

    func testTheDatabasesRefusalsBecomeWords() {
        func map(_ text: String) -> SlateError? { SupabaseBackend.mapCardError(Said(description: text)) as? SlateError }
        XCTAssertEqual(map("PostgrestError: card_not_found"), .cardNotFound, "Not mistaken for a missing booking")
        XCTAssertEqual(map("PostgrestError: card_expired"), .cardExpired)
        XCTAssertEqual(map("PostgrestError: consent_outdated"), .cardConsentOutdated)
        XCTAssertEqual(map("PostgrestError: no_booking_with_creator"), .noBookingWithCreator)
        XCTAssertEqual(map("PostgrestError: too_many_cards"), .tooManyCards(limit: CardRules.maxCards))
        XCTAssertEqual(map("PostgrestError: not_found"), .bookingNotFound)
        XCTAssertEqual(map("PostgrestError: not_signed_in"), .notSignedIn)
    }

    func testTheLinkBackFromStripesCardPage() {
        XCTAssertEqual(AppLink(url: URL(string: "slate://cards/return")!), .cardsReturn)
        XCTAssertEqual(AppLink(url: URL(string: "slate://cards/cancel")!), .cardsReturn)
    }

    func testEveryCardErrorHasWordsForAPerson() {
        let errors: [SlateError] = [
            .tooManyCards(limit: 5), .cardNotFound, .cardExpired, .noCardAccess, .noBookingWithCreator,
            .cardConsentOutdated, .cardDeclined, .cardNeedsApproval,
        ]
        for error in errors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "\(error)")
        }
        XCTAssertTrue(SlateError.tooManyCards(limit: 5).errorDescription?.contains("5") == true)
    }
}
