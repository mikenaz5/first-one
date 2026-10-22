import XCTest
@testable import Slate

/// Holds, deposits, balances and refunds against the on-device backend, on a clock the tests move by hand.
/// The same rules are tested in Postgres by `supabase/tests/booking_rules.py`.
final class PaymentsBackendTests: XCTestCase {
    private var roots: [URL] = []
    private var clock: ManualClock!
    private var backend: LocalBackend!

    // Monday 4 Jan 2027, 8:00 in Chicago. The shoot below is Friday 22 Jan at 10:00, which is 434 hours later.
    private let start = TestClock.date(2027, 1, 4, 8, 0)
    private let friday = TestClock.date(2027, 1, 22, 10, 0)
    private let client = UUID()

    override func setUp() {
        super.setUp()
        (backend, clock) = newWorld()
    }

    override func tearDown() {
        for root in roots { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    // MARK: Helpers

    private func newWorld() -> (LocalBackend, ManualClock) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-payments-\(UUID().uuidString)")
        roots.append(root)
        let clock = ManualClock(start)
        return (LocalBackend(root: root, clock: { clock.now }), clock)
    }

    private struct Creator {
        var id: UUID
        var package: ServicePackage
    }

    private func makeCreator(
        in backend: LocalBackend? = nil, handle: String = "dana-lens", deposit: Int = 50_000, price: Int = 200_000,
        policy: CancellationPolicy = .moderate
    ) async throws -> Creator {
        let backend = backend ?? self.backend!
        let session = try await backend.signInWithApple(
            AppleCredential(userID: "apple-\(handle)", identityToken: "t", rawNonce: "n", fullName: nil, email: nil)
        )
        _ = try await backend.saveProfile(CreatorProfile(
            id: session.userID, handle: handle, displayName: "Dana Lens", bio: "", specialties: [.portraits],
            location: nil, avatarURL: nil, createdAt: Date(), updatedAt: Date()
        ), avatarJPEG: nil)
        _ = try await backend.saveAvailability(AvailabilitySettings.standard(timeZone: TestClock.timeZone), for: session.userID)
        let template = try await ContractFixtures.equip(backend, creatorID: session.userID)
        let saved = try await backend.savePackage(ServicePackage(
            id: UUID(), creatorID: session.userID, name: "Portrait session", summary: "", category: .portraits,
            priceCents: price, currencyCode: "USD", durationMinutes: 60, deliverables: ["30 edited photos"], turnaroundDays: 7,
            depositCents: deposit, addOns: [], isPublished: true, position: 0, createdAt: Date(), updatedAt: Date(),
            contractTemplateID: template.id, cancellationPolicy: policy
        ))
        return Creator(id: session.userID, package: saved[0])
    }

    private func request(_ creator: Creator, at date: Date) -> BookingRequest {
        BookingRequest(creatorID: creator.id, packageID: creator.package.id, addOnIDs: [], startAt: date, notes: "")
    }

    private func expectError<T>(_ expected: SlateError, file: StaticString = #filePath, line: UInt = #line, _ work: () async throws -> T) async {
        do {
            _ = try await work()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SlateError, expected, file: file, line: line)
        }
    }

    /// Books and leaves the deposit unpaid.
    private func hold(_ creator: Creator, at date: Date? = nil, client: UUID? = nil, on backend: LocalBackend? = nil) async throws -> SignedBooking {
        try await ContractFixtures.signedBooking(backend ?? self.backend, request(creator, at: date ?? friday), clientID: client ?? self.client, pay: false)
    }

    private func booking(_ id: UUID, on backend: LocalBackend? = nil) async throws -> Booking {
        let all = try await (backend ?? self.backend).loadBookings(for: client)
        return try XCTUnwrap(all.first { $0.id == id })
    }

    private func payments(_ id: UUID, kind: PaymentKind? = nil, on backend: LocalBackend? = nil) async throws -> [Payment] {
        try await (backend ?? self.backend).loadPayments(for: client)
            .filter { $0.bookingID == id && (kind == nil || $0.kind == kind) }
    }

    // MARK: Holds

    func testABookingWithADepositIsHeldForFifteenMinutesWithItsContractPending() async throws {
        let creator = try await makeCreator(policy: .strict)
        let signed = try await hold(creator)

        XCTAssertEqual(signed.booking.status, .held)
        XCTAssertEqual(signed.booking.holdExpiresAt, start.addingTimeInterval(15 * 60))
        XCTAssertEqual(signed.booking.cancellationPolicy, .strict, "The policy is snapshotted onto the booking")
        XCTAssertEqual(signed.contract.status, .pending)
        XCTAssertEqual(signed.contract.signatures.map(\.role), [.client], "The creator signs when the deposit is paid")
        XCTAssertNil(signed.contract.executedAt)
    }

    func testAHoldBlocksTheTimeUntilItRunsOut() async throws {
        let creator = try await makeCreator()
        let first = try await hold(creator)

        await expectError(.slotTaken) { try await hold(creator, client: UUID()) }
        let busy = try await backend.loadSchedule(for: creator.id, from: friday.addingTimeInterval(-86_400), to: friday.addingTimeInterval(86_400))
        XCTAssertEqual(busy.bookedRanges, [first.booking.blockedRange])

        clock.advance(by: 14 * 60)
        await expectError(.slotTaken) { try await hold(creator, client: UUID()) }

        clock.advance(by: 2 * 60) // 16 minutes in
        let freed = try await backend.loadSchedule(for: creator.id, from: friday.addingTimeInterval(-86_400), to: friday.addingTimeInterval(86_400))
        XCTAssertTrue(freed.bookedRanges.isEmpty, "The time is offered again")
        let second = try await hold(creator, client: UUID())
        XCTAssertEqual(second.booking.status, .held)
    }

    func testWhenAHoldRunsOutItsBookingExpiresItsContractIsVoidedAndItsPaymentCancelled() async throws {
        let creator = try await makeCreator()
        let held = try await hold(creator)
        _ = try await backend.preparePayment(bookingID: held.booking.id, kind: .deposit, by: client)

        clock.advance(by: 16 * 60)
        let after = try await booking(held.booking.id)
        XCTAssertEqual(after.status, .expired)
        let contract = try await backend.loadContract(bookingID: held.booking.id, for: client)
        XCTAssertEqual(contract?.status, .voided)
        let ledger = try await payments(held.booking.id)
        XCTAssertEqual(ledger.map(\.status), [.canceled])
    }

    func testAnExpiredHoldCannotBePaidAndSaysWhy() async throws {
        let creator = try await makeCreator()
        let held = try await hold(creator)
        clock.advance(by: 16 * 60)
        await expectError(.holdExpired) { try await backend.preparePayment(bookingID: held.booking.id, kind: .deposit, by: client) }
    }

    func testNoDepositMeansTheBookingIsConfirmedAtOnceWithBothSignatures() async throws {
        let creator = try await makeCreator(deposit: 0)
        let signed = try await hold(creator)
        XCTAssertEqual(signed.booking.status, .confirmed)
        XCTAssertNil(signed.booking.holdExpiresAt)
        XCTAssertEqual(signed.contract.status, .executed)
        XCTAssertEqual(signed.contract.signatures.map(\.role), [.client, .creator])
    }

    // MARK: Paying the deposit

    func testAPaymentIsOpenedForTheBookingsAmountAndOnlyForTheClient() async throws {
        let creator = try await makeCreator()
        let held = try await hold(creator)

        let info = try await backend.preparePayment(bookingID: held.booking.id, kind: .deposit, by: client)
        XCTAssertEqual(info.amountCents, 50_000)
        XCTAssertEqual(info.currencyCode, "USD")
        XCTAssertEqual(info.kind, .deposit)
        XCTAssertNil(info.clientSecret, "Pretend payments have no Stripe secret")

        let again = try await backend.preparePayment(bookingID: held.booking.id, kind: .deposit, by: client)
        XCTAssertEqual(again.paymentID, info.paymentID, "A second tap reuses the same payment")
        let ledger = try await payments(held.booking.id)
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger.first?.status, .pending)

        await expectError(.bookingNotFound) { try await backend.preparePayment(bookingID: held.booking.id, kind: .deposit, by: UUID()) }
        await expectError(.bookingNotFound) { try await backend.preparePayment(bookingID: held.booking.id, kind: .deposit, by: creator.id) }
        await expectError(.paymentNotDue) { try await backend.preparePayment(bookingID: held.booking.id, kind: .balance, by: client) }
        await expectError(.paymentNotDue) { try await backend.preparePayment(bookingID: held.booking.id, kind: .refund, by: client) }
        await expectError(.bookingNotFound) { try await backend.preparePayment(bookingID: UUID(), kind: .deposit, by: client) }
    }

    func testTheDepositConfirmsTheBookingAndCompletesTheContract() async throws {
        let creator = try await makeCreator()
        let held = try await hold(creator)
        let info = try await backend.preparePayment(bookingID: held.booking.id, kind: .deposit, by: client)

        clock.advance(by: 5 * 60)
        try await backend.completeSimulatedPayment(info.paymentID)

        let confirmed = try await booking(held.booking.id)
        XCTAssertEqual(confirmed.status, .confirmed)
        XCTAssertNil(confirmed.holdExpiresAt)

        let loaded = try await backend.loadContract(bookingID: held.booking.id, for: client)
        let contract = try XCTUnwrap(loaded)
        XCTAssertEqual(contract.status, .executed)
        XCTAssertEqual(contract.signatures.map(\.role), [.client, .creator])
        XCTAssertEqual(contract.signature(for: .creator)?.method, .onFile)
        XCTAssertNotNil(contract.executedAt)

        let ledger = try await payments(held.booking.id)
        let payment = try XCTUnwrap(ledger.first)
        XCTAssertEqual(payment.status, .succeeded)
        XCTAssertEqual(payment.method, .simulated)
        XCTAssertEqual(payment.paidAt, start.addingTimeInterval(5 * 60))
    }

    func testReportingTheSamePaymentTwiceChangesNothingAndItCannotBePaidAgain() async throws {
        let creator = try await makeCreator()
        let held = try await hold(creator)
        let info = try await backend.preparePayment(bookingID: held.booking.id, kind: .deposit, by: client)
        try await backend.completeSimulatedPayment(info.paymentID)
        let once = try await payments(held.booking.id)

        try await backend.completeSimulatedPayment(info.paymentID)
        let twice = try await payments(held.booking.id)
        XCTAssertEqual(once, twice)
        await expectError(.paymentNotDue) { try await backend.preparePayment(bookingID: held.booking.id, kind: .deposit, by: client) }
    }

    func testPayingJustAfterTheHoldEndedStillWorksIfTheTimeIsFree() async throws {
        let creator = try await makeCreator()
        let held = try await hold(creator)
        let info = try await backend.preparePayment(bookingID: held.booking.id, kind: .deposit, by: client)

        clock.advance(by: 20 * 60)
        try await backend.expireHolds()
        let expired = try await booking(held.booking.id)
        XCTAssertEqual(expired.status, .expired)

        try await backend.completeSimulatedPayment(info.paymentID)
        let revived = try await booking(held.booking.id)
        XCTAssertEqual(revived.status, .confirmed)
        let contract = try await backend.loadContract(bookingID: held.booking.id, for: client)
        XCTAssertEqual(contract?.status, .executed)
    }

    func testPayingAfterSomeoneElseTookTheTimeGivesTheMoneyBack() async throws {
        let creator = try await makeCreator()
        let held = try await hold(creator)
        let info = try await backend.preparePayment(bookingID: held.booking.id, kind: .deposit, by: client)

        clock.advance(by: 20 * 60)
        let other = try await ContractFixtures.signedBooking(backend, request(creator, at: friday), clientID: UUID())
        XCTAssertEqual(other.booking.status, .confirmed)

        try await backend.completeSimulatedPayment(info.paymentID)
        let stayed = try await booking(held.booking.id)
        XCTAssertEqual(stayed.status, .expired, "Their time is gone")
        let owed = try await payments(held.booking.id, kind: .refund)
        XCTAssertEqual(owed.map(\.amountCents), [50_000])
        XCTAssertEqual(owed.map(\.status), [.pending])

        try await backend.settleRefunds(bookingID: held.booking.id)
        let settled = try await payments(held.booking.id, kind: .refund)
        XCTAssertEqual(settled.map(\.status), [.succeeded])
    }

    func testMoneyThatArrivesForACancelledBookingIsRefunded() async throws {
        let creator = try await makeCreator()
        let held = try await hold(creator)
        let info = try await backend.preparePayment(bookingID: held.booking.id, kind: .deposit, by: client)

        let cancelled = try await backend.cancelBooking(held.booking.id, by: client)
        XCTAssertEqual(cancelled.refundCents, 0, "Nothing had been paid yet")

        try await backend.completeSimulatedPayment(info.paymentID)
        let refunds = try await payments(held.booking.id, kind: .refund)
        XCTAssertEqual(refunds.map(\.amountCents), [50_000])
        let after = try await booking(held.booking.id)
        XCTAssertEqual(after.status, .cancelled)
    }

    // MARK: After the shoot

    func testDeliveryMakesTheBalancePayableAndPayingItCompletesTheBooking() async throws {
        let creator = try await makeCreator()
        let signed = try await ContractFixtures.signedBooking(backend, request(creator, at: friday), clientID: client)
        XCTAssertEqual(signed.booking.status, .confirmed)

        await expectError(.paymentNotDue) { try await backend.preparePayment(bookingID: signed.booking.id, kind: .balance, by: client) }
        await expectError(.notDeliverable) { try await backend.markDelivered(bookingID: signed.booking.id, by: creator.id) }
        await expectError(.bookingNotFound) { try await backend.markDelivered(bookingID: signed.booking.id, by: client) }

        clock.set(friday.addingTimeInterval(2 * 3600)) // The shoot is over.
        let delivered = try await backend.markDelivered(bookingID: signed.booking.id, by: creator.id)
        XCTAssertEqual(delivered.status, .confirmed, "Still open until the balance is paid")
        XCTAssertEqual(delivered.deliveredAt, clock.now)
        await expectError(.notDeliverable) { try await backend.markDelivered(bookingID: signed.booking.id, by: creator.id) }

        let info = try await backend.preparePayment(bookingID: signed.booking.id, kind: .balance, by: client)
        XCTAssertEqual(info.amountCents, 150_000, "The total less the deposit")
        try await backend.completeSimulatedPayment(info.paymentID)

        let done = try await booking(signed.booking.id)
        XCTAssertEqual(done.status, .completed)
        let ledger = try await payments(signed.booking.id)
        XCTAssertEqual(ledger.map(\.kind), [.deposit, .balance])
        XCTAssertEqual(ledger.map(\.status), [.succeeded, .succeeded])
        await expectError(.paymentNotDue) { try await backend.preparePayment(bookingID: signed.booking.id, kind: .balance, by: client) }
        await expectError(.notCancellable) { try await backend.cancelBooking(signed.booking.id, by: client) }
    }

    func testWhenTheDepositCoversEverythingDeliveryCompletesTheBooking() async throws {
        let creator = try await makeCreator(deposit: 200_000)
        let signed = try await ContractFixtures.signedBooking(backend, request(creator, at: friday), clientID: client)
        clock.set(friday.addingTimeInterval(3600))
        let delivered = try await backend.markDelivered(bookingID: signed.booking.id, by: creator.id)
        XCTAssertEqual(delivered.status, .completed)
        await expectError(.paymentNotDue) { try await backend.preparePayment(bookingID: signed.booking.id, kind: .balance, by: client) }
    }

    func testWithNoDepositTheWholePriceIsTheBalance() async throws {
        let creator = try await makeCreator(deposit: 0)
        let signed = try await hold(creator)
        clock.set(friday.addingTimeInterval(3600))
        _ = try await backend.markDelivered(bookingID: signed.booking.id, by: creator.id)
        let info = try await backend.preparePayment(bookingID: signed.booking.id, kind: .balance, by: client)
        XCTAssertEqual(info.amountCents, 200_000)
    }

    // MARK: Cancelling

    func testCancellingRefundsByThePolicyTheClientAgreedTo() async throws {
        let cases: [(CancellationPolicy, Double, Int)] = [
            (.moderate, 200, 100), (.moderate, 100, 50), (.moderate, 10, 0),
            (.flexible, 30, 100), (.flexible, 5, 50),
            (.strict, 400, 50), (.strict, 100, 0),
        ]
        for (index, item) in cases.enumerated() {
            let (policy, hours, percent) = item
            let (backend, clock) = newWorld()
            let creator = try await makeCreator(in: backend, handle: "case-\(index)", policy: policy)
            let signed = try await ContractFixtures.signedBooking(backend, request(creator, at: friday), clientID: client)
            let label = "\(policy) \(hours)h"

            clock.set(friday.addingTimeInterval(-hours * 3600))
            let expected = 50_000 * percent / 100
            let quote = try await backend.refundQuote(bookingID: signed.booking.id, for: client)
            XCTAssertEqual(quote.percent, percent, label)
            XCTAssertEqual(quote.refundCents, expected, label)
            XCTAssertEqual(quote.paidCents, 50_000, label)
            XCTAssertEqual(quote.policy, policy, label)
            XCTAssertFalse(quote.byCreator, label)

            let result = try await backend.cancelBooking(signed.booking.id, by: client)
            XCTAssertEqual(result.percent, percent, label)
            XCTAssertEqual(result.refundCents, expected, "Cancelling refunds exactly what was quoted: \(label)")
            XCTAssertEqual(result.booking.status, .cancelled, label)
            XCTAssertEqual(result.booking.cancelledByID, client, label)
            XCTAssertEqual(result.booking.cancelledAt, clock.now, label)

            let refunds = try await payments(signed.booking.id, kind: .refund, on: backend)
            XCTAssertEqual(refunds.map(\.amountCents).reduce(0, +), expected, label)
            XCTAssertEqual(refunds.count, expected > 0 ? 1 : 0, label)
            XCTAssertTrue(refunds.allSatisfy { $0.status == .pending }, "Owed until it's sent: \(label)")

            let contract = try await backend.loadContract(bookingID: signed.booking.id, for: client)
            XCTAssertEqual(contract?.status, .voided, label)
        }
    }

    func testIfTheCreatorCancelsTheClientGetsEverythingBackWhateverThePolicy() async throws {
        let creator = try await makeCreator(policy: .strict)
        let signed = try await ContractFixtures.signedBooking(backend, request(creator, at: friday), clientID: client)
        clock.set(friday.addingTimeInterval(-10 * 3600)) // Strict policy, 10 hours out: the client alone would get nothing.

        let theirs = try await backend.refundQuote(bookingID: signed.booking.id, for: client)
        XCTAssertEqual(theirs.refundCents, 0)
        let yours = try await backend.refundQuote(bookingID: signed.booking.id, for: creator.id)
        XCTAssertTrue(yours.byCreator)
        XCTAssertEqual(yours.refundCents, 50_000)

        let result = try await backend.cancelBooking(signed.booking.id, by: creator.id)
        XCTAssertEqual(result.refundCents, 50_000)
        XCTAssertEqual(result.booking.cancelledByID, creator.id)
    }

    func testOwedRefundsAreSentOnceAndOnlyOnce() async throws {
        let creator = try await makeCreator()
        let signed = try await ContractFixtures.signedBooking(backend, request(creator, at: friday), clientID: client)
        clock.set(friday.addingTimeInterval(-100 * 3600)) // Moderate, 100 hours: half.
        let result = try await backend.cancelBooking(signed.booking.id, by: client)
        XCTAssertEqual(result.refundCents, 25_000)

        try await backend.settleRefunds(bookingID: signed.booking.id)
        let sent = try await payments(signed.booking.id, kind: .refund)
        XCTAssertEqual(sent.map(\.status), [.succeeded])
        XCTAssertEqual(sent.first?.paidAt, clock.now)

        clock.advance(by: 3600)
        try await backend.settleRefunds(bookingID: signed.booking.id)
        let again = try await payments(signed.booking.id, kind: .refund)
        XCTAssertEqual(again, sent, "Settling again changes nothing")
        await expectError(.notCancellable) { try await backend.cancelBooking(signed.booking.id, by: client) }
    }

    func testNoPaymentIsEverRefundedMoreThanItWas() async throws {
        let creator = try await makeCreator()
        let signed = try await ContractFixtures.signedBooking(backend, request(creator, at: friday), clientID: client)
        clock.set(friday.addingTimeInterval(-5 * 3600))
        _ = try await backend.cancelBooking(signed.booking.id, by: client)

        let ledger = try await payments(signed.booking.id)
        let paid = ledger.filter { $0.kind != .refund && $0.status == .succeeded }.reduce(0) { $0 + $1.amountCents }
        let refunded = ledger.filter { $0.kind == .refund }.reduce(0) { $0 + $1.amountCents }
        XCTAssertLessThanOrEqual(refunded, paid)
    }

    func testQuotesAreOnlyForThePeopleOnAnOpenBooking() async throws {
        let creator = try await makeCreator()
        let signed = try await ContractFixtures.signedBooking(backend, request(creator, at: friday), clientID: client)
        await expectError(.notCancellable) { try await backend.refundQuote(bookingID: signed.booking.id, for: UUID()) }
        await expectError(.notCancellable) { try await backend.refundQuote(bookingID: UUID(), for: client) }

        _ = try await backend.cancelBooking(signed.booking.id, by: client)
        await expectError(.notCancellable) { try await backend.refundQuote(bookingID: signed.booking.id, for: client) }

        let late = try await ContractFixtures.signedBooking(backend, request(creator, at: friday), clientID: client)
        clock.set(friday.addingTimeInterval(60))
        await expectError(.notCancellable) { try await backend.refundQuote(bookingID: late.booking.id, for: client) }
    }

    func testCancellingAnUnpaidHoldFreesTheTimeAndChargesNothing() async throws {
        let creator = try await makeCreator()
        let held = try await hold(creator)
        let result = try await backend.cancelBooking(held.booking.id, by: client)
        XCTAssertEqual(result.refundCents, 0)
        XCTAssertEqual(result.booking.status, .cancelled)
        let ledger = try await payments(held.booking.id, kind: .refund)
        XCTAssertTrue(ledger.isEmpty)
        let again = try await hold(creator, client: UUID())
        XCTAssertEqual(again.booking.status, .held, "The time is free again")
    }

    // MARK: Who sees what

    func testPaymentsAreVisibleToTheTwoPeopleOnTheBookingOnly() async throws {
        let creator = try await makeCreator()
        let signed = try await ContractFixtures.signedBooking(backend, request(creator, at: friday), clientID: client)
        let forClient = try await backend.loadPayments(for: client)
        let forCreator = try await backend.loadPayments(for: creator.id)
        let forStranger = try await backend.loadPayments(for: UUID())
        XCTAssertEqual(forClient.map(\.bookingID), [signed.booking.id])
        XCTAssertEqual(forCreator, forClient)
        XCTAssertTrue(forStranger.isEmpty)
    }

    func testOnDevicePaymentsAreOpenlyPretend() async throws {
        XCTAssertTrue(backend.paymentsAreSimulated)
        let creator = try await makeCreator()
        let account = try await backend.loadPaymentAccount(for: creator.id)
        XCTAssertEqual(account, .simulated)
        XCTAssertTrue(account.canAcceptPayments)
        let setup = try await backend.beginPaymentAccountSetup(for: creator.id)
        XCTAssertEqual(setup, .ready(.simulated))
        let refreshed = try await backend.refreshPaymentAccount(for: creator.id)
        XCTAssertEqual(refreshed, .simulated)
    }

    func testTheRealBackendRefusesToPretend() async throws {
        let remote = SupabaseBackend(url: URL(string: "https://example.supabase.co")!, anonKey: "anon")
        XCTAssertFalse(remote.paymentsAreSimulated)
        do {
            try await remote.completeSimulatedPayment(UUID())
            XCTFail("A real backend must never mark a payment as paid on the app's say-so")
        } catch {
            XCTAssertTrue(error is SlateError)
        }
    }

    func testAnyBookingStillBlocksTheCalendarOnlyWhileItIsHeldOrConfirmed() async throws {
        let creator = try await makeCreator()
        let first = try await hold(creator)
        _ = try await backend.cancelBooking(first.booking.id, by: client)
        let second = try await ContractFixtures.signedBooking(backend, request(creator, at: friday), clientID: UUID())
        XCTAssertEqual(second.booking.status, .confirmed)
        await expectError(.slotTaken) { try await hold(creator, client: UUID()) }
    }
}
