import Foundation

// MARK: - The ledger

enum PaymentKind: String, Codable, CaseIterable, Hashable {
    case deposit, balance, refund

    var title: String {
        switch self {
        case .deposit: "Deposit"
        case .balance: "Balance"
        case .refund: "Refund"
        }
    }
}

enum PaymentRecordStatus: String, Codable, Hashable {
    case pending, succeeded, failed, canceled
}

enum PaymentMethod: String, Codable, Hashable {
    case applePay = "apple_pay"
    case card
    /// A pretend payment from on-device mode. No money moved.
    case simulated

    var title: String {
        switch self {
        case .applePay: "Apple Pay"
        case .card: "Card"
        case .simulated: "Demo payment"
        }
    }
}

/// One line in a booking's money history: a deposit, a balance, or a refund. The server writes these as
/// Stripe reports what happened; the app only reads them.
struct Payment: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var bookingID: UUID
    var kind: PaymentKind
    /// For a refund, the payment it returns money from.
    var refundOf: UUID?
    var amountCents: Int
    var currencyCode: String
    var status: PaymentRecordStatus
    var method: PaymentMethod?
    var failureMessage: String?
    var createdAt: Date
    /// When a payment went through, or a refund was issued.
    var paidAt: Date?

    /// Plain words for the history list.
    var statusTitle: String {
        switch (kind, status) {
        case (.refund, .succeeded): "Refunded"
        case (.refund, .pending): "Refund on the way"
        case (.refund, .failed): "Refund needs attention"
        case (.refund, .canceled): "Cancelled"
        case (_, .succeeded): "Paid"
        case (_, .pending): "Waiting for payment"
        case (_, .failed): "Didn't go through"
        case (_, .canceled): "Cancelled"
        }
    }
}

// MARK: - A creator's Stripe account

struct PaymentAccount: Equatable {
    var isConnected: Bool
    var chargesEnabled: Bool
    var payoutsEnabled: Bool
    var detailsSubmitted: Bool
    /// On-device mode: nothing real is connected and payments are pretend.
    var isSimulated = false

    static let notConnected = PaymentAccount(isConnected: false, chargesEnabled: false, payoutsEnabled: false, detailsSubmitted: false)
    static let simulated = PaymentAccount(isConnected: true, chargesEnabled: true, payoutsEnabled: true, detailsSubmitted: true, isSimulated: true)

    enum State: Equatable {
        case notConnected
        /// Stripe needs more information before the creator can be paid.
        case needsInformation
        /// Payments work; the bank account isn't ready to receive payouts yet.
        case payoutsPending
        case ready
    }

    var state: State {
        if !isConnected { return .notConnected }
        if !chargesEnabled { return .needsInformation }
        if !payoutsEnabled { return .payoutsPending }
        return .ready
    }

    /// Clients can only pay a creator whose account accepts charges.
    var canAcceptPayments: Bool { chargesEnabled }

    var title: String {
        switch state {
        case .notConnected: "Get paid with Stripe"
        case .needsInformation: "Finish setting up payments"
        case .payoutsPending: "Add a bank account for payouts"
        case .ready: isSimulated ? "Demo payments" : "Payments are set up"
        }
    }

    var detail: String {
        switch state {
        case .notConnected: "Connect Stripe so clients can pay deposits and balances, and the money goes straight to you."
        case .needsInformation: "Stripe needs a few more details before clients can pay you."
        case .payoutsPending: "Clients can pay you, but Stripe can't send the money to your bank until you add one."
        case .ready:
            isSimulated
                ? "This version runs on your device only, so payments are pretend and no money moves."
                : "Clients can pay deposits and balances, and Stripe sends the money to your bank."
        }
    }
}

/// What starting payment setup leads to.
enum PaymentAccountSetup: Equatable {
    /// Nothing more to do (always the case on-device).
    case ready(PaymentAccount)
    /// Stripe's own pages finish the setup; open this address.
    case continueOnWeb(URL)
}

// MARK: - Paying

/// What the backend gives back to start a payment.
struct PaymentIntentInfo: Equatable {
    var paymentID: UUID
    /// What Stripe's Apple Pay sheet needs to finish the payment. Nil for a pretend payment on-device.
    var clientSecret: String?
    var amountCents: Int
    var currencyCode: String
    var kind: PaymentKind
}

// MARK: - Refunds

/// What cancelling would return, worked out the same way on the phone and on the server.
struct RefundQuote: Equatable {
    /// What has been paid and not yet refunded.
    var paidCents: Int
    var percent: Int
    var refundCents: Int
    var hoursBefore: Double
    var policy: CancellationPolicy
    /// If the creator cancels, the client always gets everything back.
    var byCreator: Bool
    var currencyCode: String

    var keptCents: Int { paidCents - refundCents }

    /// Whole cents, rounded down: the amount shown is the amount sent.
    static func refundCents(paidCents: Int, percent: Int) -> Int {
        max(0, paidCents) * min(max(percent, 0), 100) / 100
    }

    static func make(paidCents: Int, policy: CancellationPolicy, hoursBefore: Double, byCreator: Bool, currencyCode: String) -> RefundQuote {
        let percent = byCreator ? 100 : policy.refundPercent(hoursBefore: hoursBefore)
        return RefundQuote(
            paidCents: paidCents,
            percent: percent,
            refundCents: refundCents(paidCents: paidCents, percent: percent),
            hoursBefore: hoursBefore,
            policy: policy,
            byCreator: byCreator,
            currencyCode: currencyCode
        )
    }

    /// One or two sentences for the confirmation dialog, before the final tap.
    var explanation: String {
        let money = { Money.format($0, code: currencyCode) }
        if paidCents == 0 {
            return "Nothing has been paid, so nothing will be charged or refunded. The time opens up for other clients."
        }
        if byCreator {
            return "The client gets all \(money(paidCents)) back, because you're cancelling. The time opens up for other clients."
        }
        if refundCents == paidCents {
            return "You'll get all \(money(paidCents)) back, because it's \(Self.timeBefore(hoursBefore)) before the shoot. It can take a few days to reach your card."
        }
        if refundCents == 0 {
            return "Under the \(policy.title.lowercased()) cancellation policy there's no refund this close to the shoot, so the \(money(paidCents)) you paid isn't returned."
        }
        return "Under the \(policy.title.lowercased()) cancellation policy you get \(percent)% back: \(money(refundCents)) of the \(money(paidCents)) you paid. \(money(keptCents)) stays with the creator."
    }

    private static func timeBefore(_ hours: Double) -> String {
        hours >= 48 ? "\(Int(hours / 24)) days" : "\(max(1, Int(hours))) hours"
    }
}

/// What cancelling a booking did.
struct CancellationResult: Equatable {
    var booking: Booking
    var refundCents: Int
    var percent: Int
}

// MARK: - Rules shared by the on-device backend and the tests

enum PaymentRules {
    /// How long a booking is held while its deposit is paid. Mirrors `app_hold_minutes()` in SQL.
    static let holdMinutes = 15

    /// Splits a refund across the payments that funded it, newest first, never taking more from one payment
    /// than it still holds. Mirrors the loop in `cancel_booking()` in SQL.
    static func refundAllocation(refundCents: Int, payments: [Payment]) -> [(paymentID: UUID, cents: Int)] {
        var remaining = refundCents
        var parts: [(paymentID: UUID, cents: Int)] = []
        let funded = payments
            .filter { $0.kind != .refund && $0.status == .succeeded }
            .sorted { ($0.paidAt ?? $0.createdAt) > ($1.paidAt ?? $1.createdAt) }
        for payment in funded where remaining > 0 {
            let alreadyReturned = payments
                .filter { $0.kind == .refund && $0.refundOf == payment.id && ($0.status == .pending || $0.status == .succeeded) }
                .reduce(0) { $0 + $1.amountCents }
            let available = payment.amountCents - alreadyReturned
            let part = min(available, remaining)
            if part > 0 {
                parts.append((payment.id, part))
                remaining -= part
            }
        }
        return parts
    }
}

// MARK: - What to show on a booking

/// A booking's money in one glance: what has happened, what is owed now, and what comes next.
struct PaymentSummary: Equatable {
    enum Viewer { case client, creator }
    enum Tone { case neutral, success, warning, danger }

    enum Phase: Equatable {
        /// Held, waiting for the deposit.
        case depositDue
        case depositFailed
        case holdExpired
        /// Deposit paid; the balance is due once the client has confirmed they have the final files.
        case depositPaid
        case noDepositRequired
        /// The files are shared; the balance becomes payable when the client confirms.
        case awaitingConfirmation
        case balanceDue
        case paidInFull
        case cancelledUnpaid
        case refundPending
        case refunded
        case refundFailed
        case noRefund
    }

    var phase: Phase
    var paidCents: Int
    var refundedCents: Int
    var refundPendingCents: Int
    /// What the client has to pay right now (zero when nothing is due).
    var dueNowCents: Int
    var headline: String
    var detail: String?
    var symbol: String
    var tone: Tone

    static func make(booking: Booking, payments: [Payment], viewer: Viewer, now: Date) -> PaymentSummary {
        let mine = payments.filter { $0.bookingID == booking.id }
        let paid = mine.filter { $0.kind != .refund && $0.status == .succeeded }.reduce(0) { $0 + $1.amountCents }
        let refunds = mine.filter { $0.kind == .refund }
        let refunded = refunds.filter { $0.status == .succeeded }.reduce(0) { $0 + $1.amountCents }
        let pending = refunds.filter { $0.status == .pending }.reduce(0) { $0 + $1.amountCents }
        let failed = refunds.filter { $0.status == .failed }.reduce(0) { $0 + $1.amountCents }
        let depositPaid = mine.contains { $0.kind == .deposit && $0.status == .succeeded }
        let money = { (cents: Int) in Money.format(cents, code: booking.currencyCode) }

        func result(
            _ phase: Phase, _ headline: String, _ detail: String?, _ symbol: String, _ tone: Tone, due: Int = 0
        ) -> PaymentSummary {
            PaymentSummary(
                phase: phase, paidCents: paid, refundedCents: refunded, refundPendingCents: pending,
                dueNowCents: due, headline: headline, detail: detail, symbol: symbol, tone: tone
            )
        }

        switch booking.effectiveStatus(at: now) {
        case .held:
            let lastDeposit = mine.filter { $0.kind == .deposit }.max { $0.createdAt < $1.createdAt }
            if lastDeposit?.status == .failed {
                let why = lastDeposit?.failureMessage.map { " \($0)" } ?? ""
                return result(.depositFailed, "Payment didn't go through",
                              viewer == .client ? "Try again to keep your time.\(why)" : "The client's payment failed. Their time is held until the hold runs out.",
                              "exclamationmark.triangle.fill", .warning, due: booking.depositCents)
            }
            return result(.depositDue, "Deposit due",
                          viewer == .client ? "Pay \(money(booking.depositCents)) to confirm this booking." : "Waiting for the client to pay the \(money(booking.depositCents)) deposit.",
                          "creditcard", .warning, due: booking.depositCents)

        case .expired:
            return result(.holdExpired, "Hold expired", "The deposit wasn't paid in time, so nothing was charged and the time was released.", "clock.badge.xmark", .neutral)

        case .confirmed:
            if booking.receiptConfirmedAt != nil, booking.balanceCents > 0 {
                return result(.balanceDue, "Balance due",
                              viewer == .client ? "You have the files. Pay the remaining \(money(booking.balanceCents))." : "The client has the files. Waiting for them to pay \(money(booking.balanceCents)).",
                              "creditcard", .warning, due: booking.balanceCents)
            }
            if booking.deliveredAt != nil, booking.balanceCents > 0 {
                return result(.awaitingConfirmation, "Awaiting confirmation",
                              viewer == .client ? "Confirm you have your files, then pay the remaining \(money(booking.balanceCents))." : "Waiting for the client to confirm they have the files. Then they can pay the remaining \(money(booking.balanceCents)).",
                              "shippingbox", .neutral)
            }
            if booking.balanceCents == 0 {
                return result(.paidInFull, "Paid in full", "Deposit \(money(booking.depositCents)) paid.", "checkmark.circle.fill", .success)
            }
            if depositPaid {
                return result(.depositPaid, "Deposit paid", "\(money(booking.balanceCents)) is due once the final files are delivered and confirmed.", "checkmark.circle.fill", .success)
            }
            return result(.noDepositRequired, "No deposit", "\(money(booking.balanceCents)) is due once the final files are delivered and confirmed.", "creditcard", .neutral)

        case .completed:
            return result(.paidInFull, "Paid in full", "\(money(paid)) paid.", "checkmark.circle.fill", .success)

        case .cancelled:
            if failed > 0 {
                return result(.refundFailed, "Refund needs attention", "\(money(failed)) couldn't be returned automatically. It will be retried.", "exclamationmark.triangle.fill", .danger)
            }
            if pending > 0 {
                return result(.refundPending, "Refund on the way", "\(money(pending + refunded)) is being returned to the card that paid.", "arrow.uturn.backward.circle", .neutral)
            }
            if refunded > 0 {
                let kept = paid - refunded
                let tail = kept > 0 ? " \(money(kept)) was kept under the cancellation policy." : ""
                return result(.refunded, "Refunded \(money(refunded))", "Returned to the card that paid.\(tail)", "arrow.uturn.backward.circle.fill", .neutral)
            }
            if paid > 0 {
                return result(.noRefund, "No refund due", "Cancelled too close to the shoot, so \(money(paid)) stays with the creator under the cancellation policy.", "minus.circle", .neutral)
            }
            return result(.cancelledUnpaid, "Cancelled", "Nothing was charged.", "xmark.circle", .neutral)
        }
    }
}
