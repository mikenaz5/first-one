import XCTest
@testable import Slate

// MARK: - Refund rules

final class RefundRulesTests: XCTestCase {
    private struct Fixture: Decodable {
        struct PercentCase: Decodable { var policy: String; var hours: Double; var percent: Int }
        struct AmountCase: Decodable { var paidCents: Int; var percent: Int; var refundCents: Int }
        var percent: [PercentCase]
        var refunds: [AmountCase]
    }

    private func loadFixture() throws -> Fixture {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: "refund_golden", withExtension: "json"),
            "refund_golden.json is missing from the test bundle"
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Fixture.self, from: Data(contentsOf: url))
    }

    /// `supabase/tests/booking_rules.py` checks the same file against Postgres, so the phone and the server
    /// can't disagree about what a cancellation returns.
    func testThePhoneAndTheServerAgreeOnEveryRefund() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.percent.count, 20)
        for item in fixture.percent {
            let policy = try XCTUnwrap(CancellationPolicy(rawValue: item.policy))
            XCTAssertEqual(policy.refundPercent(hoursBefore: item.hours), item.percent, "\(item.policy) at \(item.hours)h")
        }
        for item in fixture.refunds {
            XCTAssertEqual(RefundQuote.refundCents(paidCents: item.paidCents, percent: item.percent), item.refundCents,
                           "\(item.percent)% of \(item.paidCents)")
        }
    }

    func testAQuoteFollowsThePolicyUnlessTheCreatorIsCancelling() {
        let client = RefundQuote.make(paidCents: 50_000, policy: .strict, hoursBefore: 100, byCreator: false, currencyCode: "USD")
        XCTAssertEqual(client.percent, 0)
        XCTAssertEqual(client.refundCents, 0)
        XCTAssertEqual(client.keptCents, 50_000)

        let creator = RefundQuote.make(paidCents: 50_000, policy: .strict, hoursBefore: 100, byCreator: true, currencyCode: "USD")
        XCTAssertEqual(creator.percent, 100)
        XCTAssertEqual(creator.refundCents, 50_000)
        XCTAssertEqual(creator.keptCents, 0)
    }

    func testRefundsRoundDownToWholeCents() {
        XCTAssertEqual(RefundQuote.refundCents(paidCents: 33_333, percent: 50), 16_666)
        XCTAssertEqual(RefundQuote.refundCents(paidCents: 1, percent: 99), 0)
        XCTAssertEqual(RefundQuote.refundCents(paidCents: -5, percent: 100), 0, "Never a negative refund")
        XCTAssertEqual(RefundQuote.refundCents(paidCents: 100, percent: 250), 100, "Never more than was paid")
    }

    func testTheDialogSaysExactlyWhatWillHappen() {
        func quote(_ paid: Int, _ policy: CancellationPolicy, _ hours: Double, creator: Bool = false) -> RefundQuote {
            RefundQuote.make(paidCents: paid, policy: policy, hoursBefore: hours, byCreator: creator, currencyCode: "USD")
        }
        XCTAssertTrue(quote(0, .moderate, 100).explanation.contains("Nothing has been paid"))
        XCTAssertTrue(quote(50_000, .moderate, 200).explanation.contains("all $500 back"))
        XCTAssertTrue(quote(50_000, .moderate, 200).explanation.contains("8 days before the shoot"))
        XCTAssertTrue(quote(50_000, .flexible, 30).explanation.contains("30 hours before the shoot"))
        XCTAssertTrue(quote(50_000, .moderate, 100).explanation.contains("50% back: $250 of the $500 you paid"))
        XCTAssertTrue(quote(50_000, .moderate, 100).explanation.contains("$250 stays with the creator"))
        XCTAssertTrue(quote(50_000, .strict, 100).explanation.contains("no refund this close to the shoot"))
        XCTAssertTrue(quote(50_000, .strict, 100, creator: true).explanation.contains("because you're cancelling"))
    }

    // MARK: Splitting a refund across payments

    private func payment(_ kind: PaymentKind, _ cents: Int, paidMinutesAgo: Double, status: PaymentRecordStatus = .succeeded, refundOf: UUID? = nil) -> Payment {
        Payment(
            id: UUID(), bookingID: UUID(), kind: kind, refundOf: refundOf, amountCents: cents, currencyCode: "USD",
            status: status, method: .applePay, failureMessage: nil,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000 - paidMinutesAgo * 60),
            paidAt: Date(timeIntervalSince1970: 1_800_000_000 - paidMinutesAgo * 60)
        )
    }

    func testMoneyComesBackFromTheNewestPaymentFirst() {
        let deposit = payment(.deposit, 50_000, paidMinutesAgo: 100)
        let balance = payment(.balance, 150_000, paidMinutesAgo: 10)
        let parts = PaymentRules.refundAllocation(refundCents: 100_000, payments: [deposit, balance])
        XCTAssertEqual(parts.map(\.paymentID), [balance.id])
        XCTAssertEqual(parts.map(\.cents), [100_000])

        let all = PaymentRules.refundAllocation(refundCents: 200_000, payments: [deposit, balance])
        XCTAssertEqual(all.map(\.paymentID), [balance.id, deposit.id])
        XCTAssertEqual(all.map(\.cents), [150_000, 50_000])
    }

    func testARefundNeverTakesMoreFromAPaymentThanItHolds() {
        let deposit = payment(.deposit, 50_000, paidMinutesAgo: 100)
        let balance = payment(.balance, 150_000, paidMinutesAgo: 10)
        let already = payment(.refund, 100_000, paidMinutesAgo: 5, status: .pending, refundOf: balance.id)
        let parts = PaymentRules.refundAllocation(refundCents: 120_000, payments: [deposit, balance, already])
        XCTAssertEqual(parts.map(\.cents).reduce(0, +), 100_000, "Only 50,000 + 50,000 is left to give back")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: parts.map { ($0.paymentID, $0.cents) }), [balance.id: 50_000, deposit.id: 50_000])
    }

    func testFailedAndWaitingPaymentsAreNotRefundable() {
        let waiting = payment(.deposit, 50_000, paidMinutesAgo: 1, status: .pending)
        let failed = payment(.balance, 50_000, paidMinutesAgo: 1, status: .failed)
        XCTAssertTrue(PaymentRules.refundAllocation(refundCents: 10_000, payments: [waiting, failed]).isEmpty)
        XCTAssertTrue(PaymentRules.refundAllocation(refundCents: 0, payments: [payment(.deposit, 100, paidMinutesAgo: 1)]).isEmpty)
    }

    func testTheHoldIsFifteenMinutesLikeTheServer() {
        XCTAssertEqual(PaymentRules.holdMinutes, 15)
    }
}

// MARK: - Bookings and what to show

final class PaymentSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let bookingID = UUID()

    private func booking(
        _ status: BookingStatus, deposit: Int = 50_000, total: Int = 200_000,
        hold: Date? = nil, delivered: Date? = nil, startsIn hours: Double = 100
    ) -> Booking {
        Booking(
            id: bookingID, creatorID: UUID(), clientID: UUID(), creatorName: "Dana Lens", clientName: "Sam Client",
            packageID: nil, packageName: "Portrait session", addOns: [],
            startAt: now.addingTimeInterval(hours * 3600), endAt: now.addingTimeInterval(hours * 3600 + 3600),
            blockedUntil: now.addingTimeInterval(hours * 3600 + 5400), timeZoneID: "America/Chicago", currencyCode: "USD",
            totalCents: total, depositCents: deposit, status: status, notes: "", createdAt: now,
            holdExpiresAt: hold, deliveredAt: delivered
        )
    }

    private func payment(_ kind: PaymentKind, _ status: PaymentRecordStatus, _ cents: Int, refundOf: UUID? = nil, message: String? = nil, minutes: Double = 0) -> Payment {
        Payment(
            id: UUID(), bookingID: bookingID, kind: kind, refundOf: refundOf, amountCents: cents, currencyCode: "USD",
            status: status, method: .applePay, failureMessage: message,
            createdAt: now.addingTimeInterval(minutes * 60), paidAt: status == .succeeded ? now : nil
        )
    }

    private func summary(_ booking: Booking, _ payments: [Payment] = [], as viewer: PaymentSummary.Viewer = .client) -> PaymentSummary {
        PaymentSummary.make(booking: booking, payments: payments, viewer: viewer, now: now)
    }

    // MARK: Before the shoot

    func testHeldWithNothingPaidAsksForTheDeposit() {
        let held = booking(.held, hold: now.addingTimeInterval(600))
        let client = summary(held)
        XCTAssertEqual(client.phase, .depositDue)
        XCTAssertEqual(client.dueNowCents, 50_000)
        XCTAssertEqual(client.headline, "Deposit due")
        XCTAssertTrue(client.detail?.contains("Pay $500 to confirm") == true)
        XCTAssertEqual(client.tone, .warning)

        let creator = summary(held, as: .creator)
        XCTAssertEqual(creator.phase, .depositDue)
        XCTAssertTrue(creator.detail?.contains("Waiting for the client") == true)
    }

    func testAFailedAttemptSaysSoAndKeepsTheDepositDue() {
        let held = booking(.held, hold: now.addingTimeInterval(600))
        let result = summary(held, [payment(.deposit, .failed, 50_000, message: "Your card was declined.")])
        XCTAssertEqual(result.phase, .depositFailed)
        XCTAssertEqual(result.dueNowCents, 50_000)
        XCTAssertTrue(result.detail?.contains("Your card was declined.") == true)
    }

    func testAHoldThatRanOutIsExpiredEvenBeforeTheServerSaysSo() {
        let lapsed = booking(.held, hold: now.addingTimeInterval(-1))
        XCTAssertEqual(summary(lapsed).phase, .holdExpired)
        XCTAssertEqual(summary(lapsed).dueNowCents, 0)
        XCTAssertEqual(summary(booking(.expired)).phase, .holdExpired)
    }

    func testAfterTheDepositTheBalanceIsDueOnDelivery() {
        let confirmed = booking(.confirmed)
        let result = summary(confirmed, [payment(.deposit, .succeeded, 50_000)])
        XCTAssertEqual(result.phase, .depositPaid)
        XCTAssertEqual(result.tone, .success)
        XCTAssertTrue(result.detail?.contains("$1,500") == true)
        XCTAssertEqual(result.dueNowCents, 0, "Nothing is due until it's delivered")
    }

    func testNoDepositMeansEverythingIsDueAfterDelivery() {
        let result = summary(booking(.confirmed, deposit: 0))
        XCTAssertEqual(result.phase, .noDepositRequired)
        XCTAssertTrue(result.detail?.contains("$2,000") == true)
    }

    func testADepositThatCoversEverythingIsPaidInFull() {
        XCTAssertEqual(summary(booking(.confirmed, deposit: 200_000), [payment(.deposit, .succeeded, 200_000)]).phase, .paidInFull)
    }

    // MARK: After the shoot

    func testDeliveryMakesTheBalanceDue() {
        let delivered = booking(.confirmed, delivered: now)
        let client = summary(delivered, [payment(.deposit, .succeeded, 50_000)])
        XCTAssertEqual(client.phase, .balanceDue)
        XCTAssertEqual(client.dueNowCents, 150_000)
        XCTAssertTrue(client.detail?.contains("Pay the remaining $1,500") == true)

        let creator = summary(delivered, [payment(.deposit, .succeeded, 50_000)], as: .creator)
        XCTAssertEqual(creator.phase, .balanceDue)
        XCTAssertTrue(creator.detail?.contains("Waiting for the client to pay $1,500") == true)
    }

    func testCompletedMeansPaidInFull() {
        let result = summary(booking(.completed, delivered: now), [payment(.deposit, .succeeded, 50_000), payment(.balance, .succeeded, 150_000)])
        XCTAssertEqual(result.phase, .paidInFull)
        XCTAssertEqual(result.paidCents, 200_000)
        XCTAssertTrue(result.detail?.contains("$2,000 paid") == true)
    }

    // MARK: Cancelled

    func testCancellingBeforePayingChargesNothing() {
        XCTAssertEqual(summary(booking(.cancelled)).phase, .cancelledUnpaid)
        XCTAssertEqual(summary(booking(.cancelled)).detail, "Nothing was charged.")
    }

    func testRefundsGoFromOnTheWayToDone() {
        let deposit = payment(.deposit, .succeeded, 50_000)
        let pending = summary(booking(.cancelled), [deposit, payment(.refund, .pending, 25_000, refundOf: deposit.id)])
        XCTAssertEqual(pending.phase, .refundPending)
        XCTAssertEqual(pending.refundPendingCents, 25_000)

        let done = summary(booking(.cancelled), [deposit, payment(.refund, .succeeded, 25_000, refundOf: deposit.id)])
        XCTAssertEqual(done.phase, .refunded)
        XCTAssertEqual(done.headline, "Refunded $250")
        XCTAssertTrue(done.detail?.contains("$250 was kept under the cancellation policy") == true)

        let full = summary(booking(.cancelled), [deposit, payment(.refund, .succeeded, 50_000, refundOf: deposit.id)])
        XCTAssertEqual(full.phase, .refunded)
        XCTAssertFalse(full.detail?.contains("kept") == true)
    }

    func testAFailedRefundNeedsAttention() {
        let deposit = payment(.deposit, .succeeded, 50_000)
        let result = summary(booking(.cancelled), [deposit, payment(.refund, .failed, 50_000, refundOf: deposit.id)])
        XCTAssertEqual(result.phase, .refundFailed)
        XCTAssertEqual(result.tone, .danger)
    }

    func testCancellingTooLateAfterPayingReturnsNothingAndSaysWhy() {
        let result = summary(booking(.cancelled), [payment(.deposit, .succeeded, 50_000)])
        XCTAssertEqual(result.phase, .noRefund)
        XCTAssertTrue(result.detail?.contains("$500 stays with the creator") == true)
    }

    func testOnlyThisBookingsPaymentsCount() {
        let stranger = Payment(
            id: UUID(), bookingID: UUID(), kind: .deposit, refundOf: nil, amountCents: 99_999, currencyCode: "USD",
            status: .succeeded, method: .applePay, failureMessage: nil, createdAt: now, paidAt: now
        )
        XCTAssertEqual(summary(booking(.cancelled), [stranger]).phase, .cancelledUnpaid)
    }

    // MARK: Booking helpers

    func testAHoldCountsDownAndThenIsGone() {
        let held = booking(.held, hold: now.addingTimeInterval(600))
        XCTAssertEqual(held.holdRemaining(at: now), 600)
        XCTAssertEqual(held.effectiveStatus(at: now), .held)
        XCTAssertNil(held.holdRemaining(at: now.addingTimeInterval(601)))
        XCTAssertEqual(held.effectiveStatus(at: now.addingTimeInterval(601)), .expired)
        XCTAssertNil(booking(.confirmed).holdRemaining(at: now))
    }

    func testWhichBookingsAreStillOpen() {
        let later = now.addingTimeInterval(7200 * 3600)
        XCTAssertTrue(booking(.held, hold: now.addingTimeInterval(60)).isUpcoming(at: now), "A held booking is upcoming")
        XCTAssertFalse(booking(.held, hold: now.addingTimeInterval(60)).isUpcoming(at: now.addingTimeInterval(61)), "...until its hold runs out")
        XCTAssertTrue(booking(.confirmed).isUpcoming(at: now))
        XCTAssertFalse(booking(.confirmed).isUpcoming(at: later))
        XCTAssertTrue(booking(.confirmed).needsFollowUp(at: later), "The shoot is over but nobody has delivered or paid")
        XCTAssertFalse(booking(.completed).needsFollowUp(at: later))
        XCTAssertFalse(booking(.cancelled).isOpen(at: now))
        XCTAssertFalse(booking(.expired).isOpen(at: now))
    }

    func testWhoCanCancelWhat() {
        XCTAssertTrue(booking(.confirmed).canCancel(at: now))
        XCTAssertTrue(booking(.held, hold: now.addingTimeInterval(60)).canCancel(at: now))
        XCTAssertFalse(booking(.held, hold: now.addingTimeInterval(60)).canCancel(at: now.addingTimeInterval(120)), "Nothing to cancel once the hold is gone")
        XCTAssertFalse(booking(.confirmed, startsIn: -1).canCancel(at: now), "Not once the shoot has started")
        XCTAssertFalse(booking(.completed).canCancel(at: now))
    }

    func testDeliveryCanBeMarkedOnceTheShootHasStarted() {
        XCTAssertFalse(booking(.confirmed).canMarkDelivered(at: now))
        XCTAssertTrue(booking(.confirmed, startsIn: -2).canMarkDelivered(at: now))
        XCTAssertFalse(booking(.confirmed, delivered: now, startsIn: -2).canMarkDelivered(at: now), "Only once")
        XCTAssertFalse(booking(.held, hold: now.addingTimeInterval(60), startsIn: -2).canMarkDelivered(at: now))
        XCTAssertFalse(booking(.cancelled, startsIn: -2).canMarkDelivered(at: now))
    }

    func testBookingsSavedBeforePaymentsStillLoad() throws {
        let original = booking(.confirmed, delivered: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any])
        for key in ["holdExpiresAt", "deliveredAt", "cancelledAt", "cancelledByID", "cancellationPolicy"] { object[key] = nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode(Booking.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.holdExpiresAt)
        XCTAssertNil(old.deliveredAt)
        XCTAssertNil(old.cancelledByID)
        XCTAssertEqual(old.cancellationPolicy, .moderate)
        XCTAssertEqual(old.id, original.id)
        XCTAssertEqual(old.status, .confirmed)
    }

    func testTheNewFieldsSurviveSavingAndLoading() throws {
        var original = booking(.cancelled, delivered: now)
        original.cancelledAt = now
        original.cancelledByID = UUID()
        original.cancellationPolicy = .strict
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let copy = try decoder.decode(Booking.self, from: encoder.encode(original))
        XCTAssertEqual(copy, original)
    }
}

// MARK: - Accounts, ledger lines and errors

final class PaymentAccountTests: XCTestCase {
    func testAnAccountMovesThroughStripesStages() {
        XCTAssertEqual(PaymentAccount.notConnected.state, .notConnected)
        XCTAssertFalse(PaymentAccount.notConnected.canAcceptPayments)

        let needsInfo = PaymentAccount(isConnected: true, chargesEnabled: false, payoutsEnabled: false, detailsSubmitted: false)
        XCTAssertEqual(needsInfo.state, .needsInformation)
        XCTAssertFalse(needsInfo.canAcceptPayments)

        let noBank = PaymentAccount(isConnected: true, chargesEnabled: true, payoutsEnabled: false, detailsSubmitted: true)
        XCTAssertEqual(noBank.state, .payoutsPending)
        XCTAssertTrue(noBank.canAcceptPayments, "Clients can pay as soon as charges work")

        let ready = PaymentAccount(isConnected: true, chargesEnabled: true, payoutsEnabled: true, detailsSubmitted: true)
        XCTAssertEqual(ready.state, .ready)
    }

    func testEveryStateHasWordsAndTheDemoOneSaysNothingIsReal() {
        for account in [PaymentAccount.notConnected, .simulated,
                        PaymentAccount(isConnected: true, chargesEnabled: false, payoutsEnabled: false, detailsSubmitted: false),
                        PaymentAccount(isConnected: true, chargesEnabled: true, payoutsEnabled: false, detailsSubmitted: true)] {
            XCTAssertFalse(account.title.isEmpty)
            XCTAssertFalse(account.detail.isEmpty)
        }
        XCTAssertTrue(PaymentAccount.simulated.canAcceptPayments)
        XCTAssertTrue(PaymentAccount.simulated.detail.contains("no money moves"))
    }

    func testLedgerLinesAreDescribedInPlainWords() {
        func line(_ kind: PaymentKind, _ status: PaymentRecordStatus) -> String {
            Payment(id: UUID(), bookingID: UUID(), kind: kind, refundOf: nil, amountCents: 1, currencyCode: "USD",
                    status: status, method: nil, failureMessage: nil, createdAt: Date(), paidAt: nil).statusTitle
        }
        XCTAssertEqual(line(.deposit, .succeeded), "Paid")
        XCTAssertEqual(line(.balance, .pending), "Waiting for payment")
        XCTAssertEqual(line(.deposit, .failed), "Didn't go through")
        XCTAssertEqual(line(.refund, .succeeded), "Refunded")
        XCTAssertEqual(line(.refund, .pending), "Refund on the way")
        XCTAssertEqual(line(.refund, .failed), "Refund needs attention")
        XCTAssertEqual(PaymentMethod.simulated.title, "Demo payment")
    }

    func testTheServersPaymentErrorsBecomeClearMessages() {
        func map(_ token: String) -> SlateError {
            SupabaseBackend.paymentError(fromFunctionBody: Data("{\"error\":\"\(token)\"}".utf8))
        }
        XCTAssertEqual(map("hold_expired"), .holdExpired)
        XCTAssertEqual(map("payments_not_ready"), .paymentsNotReady)
        XCTAssertEqual(map("payment_not_due"), .paymentNotDue)
        XCTAssertEqual(map("balance_not_due"), .paymentNotDue)
        XCTAssertEqual(map("nothing_due"), .paymentNotDue)
        XCTAssertEqual(map("already_paid"), .alreadyPaid)
        XCTAssertEqual(map("payment_processing"), .paymentProcessing)
        XCTAssertEqual(map("not_found"), .bookingNotFound)
        XCTAssertEqual(map("unauthorized"), .notSignedIn)
        XCTAssertEqual(map("stripe_error"), .paymentUnavailable)
        XCTAssertEqual(map("something_new"), .paymentUnavailable)
        XCTAssertEqual(SupabaseBackend.paymentError(fromFunctionBody: Data("not json".utf8)), .paymentUnavailable)
        XCTAssertEqual(SupabaseBackend.paymentError(fromFunctionBody: Data()), .paymentUnavailable)
    }

    func testEveryNewErrorExplainsItself() {
        let errors: [SlateError] = [
            .holdExpired, .paymentsNotReady, .paymentNotDue, .alreadyPaid, .paymentProcessing, .paymentUnavailable,
            .paymentsNotConfigured, .applePayUnavailable, .notDeliverable, .bookingNotFound,
        ]
        for error in errors {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty, "\(error)")
        }
    }

    func testTheSupabaseBackendMapsPaymentTokensFromTheDatabaseToo() {
        struct Failure: Error, CustomStringConvertible { let description: String }
        let cases: [(String, SlateError)] = [
            ("hold_expired", .holdExpired), ("payments_not_ready", .paymentsNotReady), ("payment_not_due", .paymentNotDue),
            ("balance_not_due", .paymentNotDue), ("already_paid", .alreadyPaid), ("not_deliverable", .notDeliverable),
        ]
        for (token, expected) in cases {
            XCTAssertEqual(SupabaseBackend.mapBookingError(Failure(description: "PostgrestError: \(token)")) as? SlateError, expected, token)
        }
    }
}
