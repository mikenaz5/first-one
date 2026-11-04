import XCTest
@testable import Slate

/// Paying a creator directly: the creator's own payment link, and marking money received (or a refund sent) by hand. The
/// on-device backend mirrors `…_direct_charges.sql` rule for rule (`supabase/tests/direct_charge_rules.py` checks the SQL).
@MainActor
final class DirectChargeTests: XCTestCase {
    private var root: URL!
    private var backend: LocalBackend!
    private var authorizer: ScriptedAuthorizer!
    private var model: AppModel!
    private var creator: CreatorProfile!
    private var package: ServicePackage!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-direct-\(UUID().uuidString)")
        let clock = ManualClock(Date())
        backend = LocalBackend(root: root, clock: { clock.now })
        authorizer = ScriptedAuthorizer()
        model = AppModel(backend: backend, authorizer: authorizer, widget: RecordingWidgetPublisher())
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
        creator = try await backend.saveProfile(CreatorProfile(
            id: session.userID, handle: "dana-lens", displayName: "Dana Lens", bio: "", specialties: [.portraits],
            location: nil, avatarURL: nil, createdAt: Date(), updatedAt: Date()
        ), avatarJPEG: nil)
        _ = try await backend.saveAvailability(AvailabilitySettings.standard(timeZone: TestClock.timeZone), for: session.userID)
        let template = try await ContractFixtures.equip(backend, creatorID: session.userID)
        let packageID = UUID()
        let saved = try await backend.savePackage(ServicePackage(
            id: packageID, creatorID: session.userID, name: "Half day", summary: "", category: nil,
            priceCents: 200_000, currencyCode: "USD", durationMinutes: 120, deliverables: [], turnaroundDays: 14,
            depositCents: 50_000, addOns: [], isPublished: true, position: 0, createdAt: Date(), updatedAt: Date(),
            contractTemplateID: template.id, cancellationPolicy: .flexible
        ))
        package = try XCTUnwrap(saved.first { $0.id == packageID })
    }

    /// A booking that is held for its deposit: the client signed, then closed the Apple Pay sheet.
    private func heldBooking() async throws -> Booking {
        authorizer.script = [.success(.cancelled)]
        let screen = BookingModel(creator: creator, package: package, signerName: "Sam Client")
        await screen.load(using: model)
        screen.select(screen.days[2].slots.first!)
        _ = await screen.submit(using: model)
        return try XCTUnwrap(screen.heldBooking)
    }

    private func booking(_ id: UUID) async throws -> Booking {
        let session = try XCTUnwrap(model.session)
        return try XCTUnwrap(try await backend.loadBookings(for: session.userID).first { $0.id == id })
    }

    private func payments(for id: UUID) async throws -> [Payment] {
        let session = try XCTUnwrap(model.session)
        return try await backend.loadPayments(for: session.userID).filter { $0.bookingID == id }
    }

    private var link: PaymentLink { PaymentLink(url: URL(string: "https://pay.example.com/dana")!, instructions: "Zelle to dana@example.com") }

    // MARK: The rules

    func testALinkMustBeSecureAndLookReal() {
        XCTAssertEqual(PaymentLinkRules.clean(url: "  https://pay.example.com/dana \n"), "https://pay.example.com/dana")
        for bad in ["http://pay.example.com", "pay.example.com", "javascript:alert(1)", "https://localhost/x", "https://a b.example.com", ""] {
            XCTAssertNil(PaymentLinkRules.clean(url: bad), bad)
        }
    }

    func testInstructionsAreTrimmedAndCutToFit() {
        XCTAssertEqual(PaymentLinkRules.cleanInstructions("  PayPal @dana \n"), "PayPal @dana")
        XCTAssertEqual(PaymentLinkRules.cleanInstructions(String(repeating: "x", count: 500)).count, PaymentLinkRules.instructionsMaxLength)
    }

    func testAPaidDirectlyPaymentHasWordsOfItsOwn() throws {
        XCTAssertEqual(PaymentMethod.manual.title, "Paid directly")
        XCTAssertEqual(try JSONDecoder().decode(PaymentMethod.self, from: Data("\"manual\"".utf8)), .manual)
        let base = Payment(
            id: UUID(), bookingID: UUID(), kind: .refund, refundOf: UUID(), amountCents: 100, currencyCode: "USD",
            status: .pending, method: .manual, failureMessage: nil, createdAt: Date(), paidAt: nil
        )
        XCTAssertEqual(base.statusTitle, "Waiting for the creator to send it")
        var sent = base
        sent.status = .succeeded
        XCTAssertEqual(sent.statusTitle, "Refunded by the creator")
        var viaCard = base
        viaCard.method = .applePay
        XCTAssertEqual(viaCard.statusTitle, "Refund on the way", "a refund Stripe sends reads as before")
    }

    func testAPaymentIntentNamesNoAccountUntilTheServerDoes() {
        let info = PaymentIntentInfo(paymentID: UUID(), clientSecret: nil, amountCents: 1, currencyCode: "USD", kind: .deposit)
        XCTAssertNil(info.stripeAccountID)
    }

    func testOnlyACreatorIsAskedToLinkStripe() async throws {
        // Signed in as the demo account with no profile, the person is only here to book.
        XCTAssertFalse(model.canSetUpPayments)
        await model.signOut()
        XCTAssertFalse(model.canSetUpPayments, "nobody signed in is asked anything")
    }

    func testReadingThePaymentSetupFillsInTheLinkAndTheAccount() async throws {
        let owner = try XCTUnwrap(model.ownerID)
        try await backend.savePaymentLink(link, for: owner)
        await model.loadPaymentSetup()
        XCTAssertEqual(model.paymentLink, link)
        XCTAssertEqual(model.paymentAccount, .simulated, "on-device the pretend account is always ready")
    }

    func testBeingAbleToTakeCardsIsBeingReadyWhateverPayoutsSay() {
        XCTAssertEqual(PaymentAccount(isConnected: true, chargesEnabled: true, payoutsEnabled: false, detailsSubmitted: true).state, .ready)
        XCTAssertEqual(PaymentAccount.notConnected.title, "Link your Stripe account")
        XCTAssertEqual(PaymentAccount(isConnected: true, chargesEnabled: false, payoutsEnabled: false, detailsSubmitted: false).title,
                       "Finish linking your Stripe account")
    }

    // MARK: The link

    func testALinkIsKeptAndComesBack() async throws {
        try await backend.savePaymentLink(link, for: creator.id)
        let loaded = try await backend.loadPaymentLink(for: creator.id)
        XCTAssertEqual(loaded, link)
    }

    func testALongNoteIsCutNotRefused() async throws {
        try await backend.savePaymentLink(PaymentLink(url: link.url, instructions: String(repeating: "y", count: 500)), for: creator.id)
        let loaded = try await backend.loadPaymentLink(for: creator.id)
        XCTAssertEqual(loaded?.instructions.count, PaymentLinkRules.instructionsMaxLength)
    }

    func testALinkThatIsNotSecureIsRefused() async {
        let insecure = PaymentLink(url: URL(string: "http://pay.example.com/dana")!, instructions: "")
        do {
            try await backend.savePaymentLink(insecure, for: creator.id)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SlateError, .invalidPaymentLink)
        }
        let loaded = try? await backend.loadPaymentLink(for: creator.id)
        XCTAssertNil(loaded ?? nil)
    }

    func testTheLinkCanBeTakenAway() async throws {
        try await backend.savePaymentLink(link, for: creator.id)
        try await backend.savePaymentLink(nil, for: creator.id)
        let loaded = try await backend.loadPaymentLink(for: creator.id)
        XCTAssertNil(loaded)
    }

    func testTheModelSavesTidiesAndRemovesTheLink() async throws {
        // Signed in as the person who is booking, whose own account is the owner here: a good link is saved as tidied.
        let saved = await model.savePaymentLink(url: "  https://pay.example.com/dana ", instructions: "  Zelle  ")
        XCTAssertTrue(saved)
        XCTAssertEqual(model.paymentLink, PaymentLink(url: URL(string: "https://pay.example.com/dana")!, instructions: "Zelle"))
        XCTAssertTrue(model.canTakePayments, "a link is enough to take a deposit")
        let removed = await model.savePaymentLink(url: "   ", instructions: "")
        XCTAssertTrue(removed)
        XCTAssertNil(model.paymentLink)
        let refused = await model.savePaymentLink(url: "http://insecure.example.com", instructions: "")
        XCTAssertFalse(refused)
    }

    // MARK: What the client can do

    func testTheClientSeesTheLinkBesideStripe() async throws {
        try await backend.savePaymentLink(link, for: creator.id)
        let held = try await heldBooking()
        let client = try XCTUnwrap(model.session).userID

        let options = try await backend.paymentOptions(bookingID: held.id, for: client)
        XCTAssertEqual(options, PaymentOptions(stripeReady: true, link: link))
        XCTAssertEqual(options?.offersAnything, true)

        let others = try await backend.paymentOptions(bookingID: held.id, for: creator.id)
        XCTAssertNil(others, "only the booking's client is told how to pay")
    }

    func testWithNoLinkTheClientJustSeesStripe() async throws {
        let held = try await heldBooking()
        let options = try await backend.paymentOptions(bookingID: held.id, for: try XCTUnwrap(model.session).userID)
        XCTAssertEqual(options, PaymentOptions(stripeReady: true, link: nil))
    }

    // MARK: Marking a payment received

    func testMarkingTheDepositReceivedConfirmsTheBooking() async throws {
        let held = try await heldBooking()
        XCTAssertEqual(held.status, .held)

        try await backend.markPaymentReceived(bookingID: held.id, kind: .deposit, note: "Zelle", by: creator.id)

        let confirmed = try await booking(held.id)
        XCTAssertEqual(confirmed.status, .confirmed)
        let money = try await payments(for: held.id).filter { $0.kind == .deposit }
        XCTAssertEqual(money.count, 1)
        XCTAssertEqual(money.first?.status, .succeeded)
        XCTAssertEqual(money.first?.method, .manual)
        XCTAssertEqual(money.first?.amountCents, 50_000, "the amount is the booking's, not the creator's to type")
        let contract = try await backend.loadContract(bookingID: held.id, for: creator.id)
        XCTAssertEqual(contract?.status, .executed, "the contract finishes just as it does when Apple Pay pays")
    }

    func testOnlyTheCreatorCanMarkAPaymentReceived() async throws {
        let held = try await heldBooking()
        let client = try XCTUnwrap(model.session).userID
        do {
            try await backend.markPaymentReceived(bookingID: held.id, kind: .deposit, note: nil, by: client)
            XCTFail("a client can't say they paid")
        } catch {
            XCTAssertEqual(error as? SlateError, .notAllowed)
        }
        let after = try await booking(held.id)
        XCTAssertEqual(after.status, .held)
        let none = try await payments(for: held.id).filter { $0.status == .succeeded }
        XCTAssertTrue(none.isEmpty)
    }

    func testAPaymentCanOnlyBeMarkedOnce() async throws {
        let held = try await heldBooking()
        try await backend.markPaymentReceived(bookingID: held.id, kind: .deposit, note: nil, by: creator.id)
        do {
            try await backend.markPaymentReceived(bookingID: held.id, kind: .deposit, note: nil, by: creator.id)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue([SlateError.paymentNotDue, .alreadyPaid].contains(error as? SlateError), "\(error)")
        }
        let deposits = try await payments(for: held.id).filter { $0.kind == .deposit && $0.status == .succeeded }
        XCTAssertEqual(deposits.count, 1)
    }

    func testTheBalanceWaitsForTheClientToHaveTheirFiles() async throws {
        let held = try await heldBooking()
        try await backend.markPaymentReceived(bookingID: held.id, kind: .deposit, note: nil, by: creator.id)
        do {
            try await backend.markPaymentReceived(bookingID: held.id, kind: .balance, note: nil, by: creator.id)
            XCTFail("the balance isn't due yet")
        } catch {
            XCTAssertEqual(error as? SlateError, .paymentNotDue)
        }
    }

    func testAnApplePayAttemptStillOpenIsClosedWhenTheCreatorMarksItReceived() async throws {
        let held = try await heldBooking()
        let client = try XCTUnwrap(model.session).userID
        // The client had opened Apple Pay (a pending payment) and then paid the creator another way.
        _ = try await backend.preparePayment(bookingID: held.id, kind: .deposit, by: client)
        try await backend.markPaymentReceived(bookingID: held.id, kind: .deposit, note: nil, by: creator.id)

        let deposits = try await payments(for: held.id).filter { $0.kind == .deposit }
        XCTAssertEqual(deposits.filter { $0.status == .succeeded }.count, 1)
        XCTAssertEqual(deposits.filter { $0.status == .pending }.count, 0, "nothing is left waiting to be paid twice")
    }

    // MARK: Refunds of money paid directly

    func testARefundOfMoneyPaidDirectlyIsLeftForTheCreatorToSend() async throws {
        let held = try await heldBooking()
        try await backend.markPaymentReceived(bookingID: held.id, kind: .deposit, note: nil, by: creator.id)
        _ = try await backend.cancelBooking(held.id, by: creator.id)

        try await backend.settleRefunds(bookingID: held.id)
        let owed = try await payments(for: held.id).filter { $0.kind == .refund }
        XCTAssertEqual(owed.count, 1)
        XCTAssertEqual(owed.first?.method, .manual)
        XCTAssertEqual(owed.first?.status, .pending, "Slate Pro never held this money, so it can't send it back")

        let refund = try XCTUnwrap(owed.first)
        let client = try XCTUnwrap(model.session).userID
        do {
            try await backend.markRefundSent(paymentID: refund.id, by: client)
            XCTFail("the client can't say it was sent")
        } catch {
            XCTAssertEqual(error as? SlateError, .notAllowed)
        }
        try await backend.markRefundSent(paymentID: refund.id, by: creator.id)
        let after = try await payments(for: held.id).filter { $0.kind == .refund }
        XCTAssertEqual(after.first?.status, .succeeded)
    }

    func testARefundStripeSendsCannotBeMarkedByHand() async throws {
        let held = try await heldBooking()
        let client = try XCTUnwrap(model.session).userID
        let info = try await backend.preparePayment(bookingID: held.id, kind: .deposit, by: client)
        try await backend.completeSimulatedPayment(info.paymentID)
        _ = try await backend.cancelBooking(held.id, by: creator.id)
        let refund = try await payments(for: held.id).first { $0.kind == .refund }
        let id = try XCTUnwrap(refund?.id)
        do {
            try await backend.markRefundSent(paymentID: id, by: creator.id)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SlateError, .paymentNotDue)
        }
    }
}
