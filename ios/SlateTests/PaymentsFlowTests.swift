import XCTest
@testable import Slate

/// A payment sheet the test controls: it answers with whatever it is told to, in order.
@MainActor
final class ScriptedAuthorizer: PaymentAuthorizer {
    var script: [Result<PaymentAuthorization, Error>]
    private(set) var requests: [PaymentRequestDetails] = []

    init(_ script: [Result<PaymentAuthorization, Error>] = []) { self.script = script }

    func authorize(_ request: PaymentRequestDetails) async throws -> PaymentAuthorization {
        requests.append(request)
        return script.isEmpty ? .paid : try script.removeFirst().get()
    }
}

/// The booking sheet's pay step and the money actions on a booking, end to end against the on-device backend.
@MainActor
final class PaymentsFlowTests: XCTestCase {
    private var root: URL!
    private var clock: ManualClock!
    private var backend: LocalBackend!
    private var authorizer: ScriptedAuthorizer!
    private var model: AppModel!
    private var creator: CreatorProfile!
    private var package: ServicePackage!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-flow-\(UUID().uuidString)")
        // Real time, so the booking screen's own idea of "now" and the backend's agree; the clock is only moved to cross thresholds.
        clock = ManualClock(Date())
        let clock = self.clock!
        backend = LocalBackend(root: root, clock: { clock.now })
        authorizer = ScriptedAuthorizer()
        model = AppModel(backend: backend, authorizer: authorizer)
        try await makeCreator()
        await model.signInAsDemo() // The person who will be booking.
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private func makeCreator(policy: CancellationPolicy = .flexible, deposit: Int = 50_000) async throws {
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
            depositCents: deposit, addOns: [], isPublished: true, position: 0, createdAt: Date(), updatedAt: Date(),
            contractTemplateID: template.id, cancellationPolicy: policy
        ))
        package = try XCTUnwrap(saved.first { $0.id == packageID })
    }

    /// A booking screen on a day at least two days out, so the flexible policy's 24 hours can't be crossed mid-test.
    private func loaded() async -> BookingModel {
        let screen = BookingModel(creator: creator, package: package, signerName: "Sam Client")
        await screen.load(using: model)
        screen.select(screen.days[2].slots.first!)
        return screen
    }

    // MARK: Signing and paying

    func testSigningThenPayingConfirmsTheBookingAndFinishesTheContract() async {
        let screen = await loaded()
        let ok = await screen.submit(using: model)

        XCTAssertTrue(ok)
        XCTAssertNil(screen.heldBooking)
        let confirmed = screen.confirmed
        XCTAssertEqual(confirmed?.status, .confirmed)
        XCTAssertEqual(screen.signedContract?.status, .executed)
        XCTAssertEqual(screen.signedContract?.signatures.map(\.role), [.client, .creator])
        XCTAssertEqual(authorizer.requests.count, 1)
        XCTAssertEqual(authorizer.requests.first?.info.amountCents, 50_000)
        XCTAssertEqual(authorizer.requests.first?.info.kind, .deposit)
        XCTAssertTrue(authorizer.requests.first?.label.contains("Deposit") == true)

        let summary = confirmed.map { model.paymentSummary(for: $0) }
        XCTAssertEqual(summary?.phase, .depositPaid)
        XCTAssertEqual(model.payments.filter { $0.kind == .deposit && $0.status == .succeeded }.count, 1)
    }

    func testClosingThePaymentSheetLeavesTheTimeHeldAndTheDepositCanBePaidLater() async throws {
        authorizer.script = [.success(.cancelled)]
        let screen = await loaded()
        let ok = await screen.submit(using: model)

        XCTAssertFalse(ok)
        XCTAssertNil(screen.confirmed)
        let held = try XCTUnwrap(screen.heldBooking)
        XCTAssertEqual(held.status, .held)
        XCTAssertNotNil(screen.payNotice)
        XCTAssertEqual(model.paymentSummary(for: held).phase, .depositDue)
        XCTAssertEqual(model.canPay(held), .deposit, "They can pay from the Bookings tab too")

        await screen.payDeposit(using: model)
        XCTAssertNil(screen.heldBooking)
        XCTAssertEqual(screen.confirmed?.id, held.id)
        XCTAssertNil(screen.payNotice)
        XCTAssertEqual(screen.signedContract?.status, .executed)
    }

    func testAPaymentThatFailsExplainsWhyAndCanBeRetried() async {
        authorizer.script = [.failure(SlateError.applePayUnavailable)]
        let screen = await loaded()
        let ok = await screen.submit(using: model)

        XCTAssertFalse(ok)
        XCTAssertEqual(screen.payNotice, SlateError.applePayUnavailable.errorDescription)
        XCTAssertNotNil(screen.heldBooking, "Their time is still held")

        await screen.payDeposit(using: model)
        XCTAssertNotNil(screen.confirmed)
    }

    func testReleasingAHeldTimeFreesItWithoutChargingAnything() async throws {
        authorizer.script = [.success(.cancelled)]
        let screen = await loaded()
        await screen.submit(using: model)
        let held = try XCTUnwrap(screen.heldBooking)
        let slot = held.startAt

        await screen.abandonHold(using: model)

        XCTAssertNil(screen.heldBooking)
        XCTAssertNil(screen.confirmed)
        XCTAssertEqual(model.bookings.first { $0.id == held.id }?.status, .cancelled)
        XCTAssertTrue(model.payments.filter { $0.bookingID == held.id }.allSatisfy { $0.kind != .refund })
        XCTAssertTrue(screen.days.flatMap(\.slots).contains { $0.start == slot }, "The time is offered again")
    }

    func testIfTheHoldRunsOutTheBookingShowsAsExpiredAndPayingIsRefused() async throws {
        authorizer.script = [.success(.cancelled)]
        let screen = await loaded()
        await screen.submit(using: model)
        let held = try XCTUnwrap(screen.heldBooking)

        clock.advance(by: 16 * 60)
        await model.reloadMoney()
        let expired = try XCTUnwrap(model.bookings.first { $0.id == held.id })
        XCTAssertEqual(expired.status, .expired)
        XCTAssertEqual(model.paymentSummary(for: expired).phase, .holdExpired)
        XCTAssertNil(model.canPay(expired))

        let outcome = await model.pay(.deposit, for: expired)
        XCTAssertEqual(outcome, .failed(SlateError.holdExpired.errorDescription ?? ""))
    }

    func testABookingWithNoDepositNeverAsksForPayment() async throws {
        try await makeCreator(deposit: 0)
        let screen = await loaded()
        let ok = await screen.submit(using: model)
        XCTAssertTrue(ok)
        XCTAssertTrue(authorizer.requests.isEmpty)
        XCTAssertEqual(screen.confirmed?.status, .confirmed)
        XCTAssertEqual(screen.signedContract?.status, .executed)
    }

    // MARK: Delivery and the balance

    /// Delivery is the creator's act, so these tests book the demo person's own package (on-device allows that).
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
        let loadedProfile = try await backend.loadProfile(for: userID)
        let profile = try XCTUnwrap(loadedProfile)
        let screen = BookingModel(creator: profile, package: own, signerName: "Demo Person")
        await screen.load(using: model)
        let ok = await screen.submit(using: model)
        XCTAssertTrue(ok)
        return try XCTUnwrap(screen.confirmed)
    }

    func testAfterTheShootTheCreatorDeliversAndThePersonPaysTheBalance() async throws {
        let booking = try await ownBooking()
        XCTAssertNil(model.canPay(booking), "Nothing is due until it's delivered")

        clock.set(booking.endAt.addingTimeInterval(3600))
        await model.markDelivered(booking)
        let delivered = try XCTUnwrap(model.bookings.first { $0.id == booking.id })
        XCTAssertNotNil(delivered.deliveredAt)
        XCTAssertEqual(model.paymentSummary(for: delivered, now: clock.now).phase, .balanceDue)
        XCTAssertEqual(model.canPay(delivered, now: clock.now), .balance)

        let outcome = await model.pay(.balance, for: delivered)
        XCTAssertEqual(outcome, .confirmed)
        let done = try XCTUnwrap(model.bookings.first { $0.id == booking.id })
        XCTAssertEqual(done.status, .completed)
        XCTAssertEqual(model.paymentSummary(for: done, now: clock.now).phase, .paidInFull)
        XCTAssertEqual(authorizer.requests.last?.info.amountCents, 150_000)
    }

    // MARK: Cancelling

    func testCancellingRefundsByThePolicyAndShowsIt() async throws {
        let screen = await loaded()
        await screen.submit(using: model)
        let booking = try XCTUnwrap(screen.confirmed)

        let quote = await model.refundQuote(for: booking)
        XCTAssertEqual(quote?.percent, 100, "Flexible policy, more than a day ahead")
        XCTAssertEqual(quote?.refundCents, 50_000)

        let result = await model.cancel(booking)
        XCTAssertEqual(result?.refundCents, 50_000)
        let after = try XCTUnwrap(model.bookings.first { $0.id == booking.id })
        XCTAssertEqual(after.status, .cancelled)
        let summary = model.paymentSummary(for: after)
        XCTAssertEqual(summary.phase, .refunded, "The refund was sent straight away")
        XCTAssertEqual(summary.refundedCents, 50_000)
        XCTAssertEqual(summary.headline, "Refunded $500")
    }

    func testARefundThatWasntSentIsRetriedLater() async throws {
        let screen = await loaded()
        await screen.submit(using: model)
        let booking = try XCTUnwrap(screen.confirmed)
        // Cancel straight on the backend, as if the app had been closed before it could send the refund.
        _ = try? await backend.cancelBooking(booking.id, by: model.session!.userID)
        await model.reloadMoney()
        let waiting = try XCTUnwrap(model.bookings.first { $0.id == booking.id })
        XCTAssertEqual(model.paymentSummary(for: waiting).phase, .refundPending)

        await model.settlePendingRefunds()
        let settled = try XCTUnwrap(model.bookings.first { $0.id == booking.id })
        XCTAssertEqual(model.paymentSummary(for: settled).phase, .refunded)
    }

    // MARK: Wiring

    func testThePaymentSheetMatchesTheBackend() {
        XCTAssertTrue(PaymentAuthorizerFactory.make(for: backend) is SimulatedPaymentAuthorizer, "On-device payments are pretend")
        let remote = SupabaseBackend(url: URL(string: "https://example.supabase.co")!, anonKey: "anon")
        let authorizer = PaymentAuthorizerFactory.make(for: remote)
        if AppConfig.stripe == nil {
            XCTAssertTrue(authorizer is UnconfiguredPaymentAuthorizer, "A server build with no Stripe keys says so instead of failing oddly")
        }
        XCTAssertFalse(authorizer is SimulatedPaymentAuthorizer, "A real backend never gets pretend payments")
    }

    func testAnUnconfiguredBuildRefusesWithAClearMessage() async {
        let unconfigured = UnconfiguredPaymentAuthorizer()
        let details = PaymentRequestDetails(
            info: PaymentIntentInfo(paymentID: UUID(), clientSecret: "pi_x_secret", amountCents: 100, currencyCode: "USD", kind: .deposit),
            label: "Deposit", countryCode: "US"
        )
        do {
            _ = try await unconfigured.authorize(details)
            XCTFail("Should refuse")
        } catch {
            XCTAssertEqual(error as? SlateError, .paymentsNotConfigured)
        }
    }

    func testCreatorsAreAlwaysReadyToTakePretendPayments() async throws {
        await model.refreshPaymentAccount()
        XCTAssertEqual(model.paymentAccount, .simulated)
        XCTAssertTrue(model.canTakePayments)
        let url = await model.setUpPayments()
        XCTAssertNil(url, "Nothing to open: on-device setup is instant")
    }
}
