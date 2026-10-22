import Foundation

/// Holds, payments, cancellation refunds and delivery for the on-device backend.
///
/// Nothing here moves money: a "payment" is a record that the person tapped to pay. The state changes
/// follow the same rules as the SQL functions in `…_payments.sql` (a deposit confirms a held booking, the
/// balance completes it, a cancellation refunds according to the policy), so the whole flow can be tried
/// with no server, and the same tests describe both.
extension LocalBackend {
    nonisolated var paymentsAreSimulated: Bool { true }

    var paymentsURL: URL { root.appendingPathComponent("payments.json") }

    func readPayments() -> [Payment] {
        read([Payment].self, from: paymentsURL) ?? []
    }

    func writePayments(_ payments: [Payment]) throws {
        try write(payments, to: paymentsURL)
    }

    // MARK: - Holds

    /// Gives up holds whose deposit wasn't paid in time: the time is freed, the contract voided.
    @discardableResult
    func expireLapsedHolds() throws -> Int {
        let now = self.now
        var bookings = readBookings()
        var lapsed: Set<UUID> = []
        for index in bookings.indices where bookings[index].status == .held {
            if let expires = bookings[index].holdExpiresAt, expires <= now {
                bookings[index].status = .expired
                lapsed.insert(bookings[index].id)
            }
        }
        guard !lapsed.isEmpty else { return 0 }

        try write(bookings, to: bookingsURL)

        var contracts = readContracts()
        for index in contracts.indices where lapsed.contains(contracts[index].bookingID) && contracts[index].status == .pending {
            contracts[index].status = .voided
        }
        try write(contracts, to: contractsURL)

        var payments = readPayments()
        for index in payments.indices where lapsed.contains(payments[index].bookingID) && payments[index].status == .pending && payments[index].kind != .refund {
            payments[index].status = .canceled
        }
        try writePayments(payments)
        return lapsed.count
    }

    func expireHolds() async throws {
        try expireLapsedHolds()
    }

    // MARK: - Reading

    func loadPayments(for userID: UUID) async throws -> [Payment] {
        let mine = Set(readBookings().filter { $0.creatorID == userID || $0.clientID == userID }.map(\.id))
        return readPayments().filter { mine.contains($0.bookingID) }.sorted { $0.createdAt < $1.createdAt }
    }

    func loadPaymentAccount(for creatorID: UUID) async throws -> PaymentAccount { .simulated }

    func beginPaymentAccountSetup(for creatorID: UUID) async throws -> PaymentAccountSetup { .ready(.simulated) }

    func refreshPaymentAccount(for creatorID: UUID) async throws -> PaymentAccount { .simulated }

    // MARK: - Paying

    func preparePayment(bookingID: UUID, kind: PaymentKind, by userID: UUID) async throws -> PaymentIntentInfo {
        try expireLapsedHolds()
        guard kind != .refund else { throw SlateError.paymentNotDue }
        guard let booking = readBookings().first(where: { $0.id == bookingID }), booking.clientID == userID else {
            throw SlateError.bookingNotFound
        }
        var payments = readPayments()
        let mine = payments.filter { $0.bookingID == bookingID }

        let amount: Int
        switch kind {
        case .deposit:
            if booking.status == .expired { throw SlateError.holdExpired }
            guard booking.status == .held else { throw SlateError.paymentNotDue }
            amount = booking.depositCents
        case .balance:
            guard booking.status == .confirmed, booking.deliveredAt != nil else { throw SlateError.paymentNotDue }
            if booking.depositCents > 0, !mine.contains(where: { $0.kind == .deposit && $0.status == .succeeded }) {
                throw SlateError.paymentNotDue
            }
            amount = booking.totalCents - booking.depositCents
        case .refund:
            throw SlateError.paymentNotDue
        }
        guard amount > 0 else { throw SlateError.paymentNotDue }
        if mine.contains(where: { $0.kind == kind && $0.status == .succeeded }) { throw SlateError.alreadyPaid }

        // A second tap reuses the payment already waiting.
        if let waiting = mine.first(where: { $0.kind == kind && $0.status == .pending }) {
            return PaymentIntentInfo(paymentID: waiting.id, clientSecret: nil, amountCents: waiting.amountCents, currencyCode: waiting.currencyCode, kind: kind)
        }
        let payment = Payment(
            id: UUID(), bookingID: bookingID, kind: kind, refundOf: nil, amountCents: amount,
            currencyCode: booking.currencyCode, status: .pending, method: nil, failureMessage: nil,
            createdAt: now, paidAt: nil
        )
        payments.append(payment)
        try writePayments(payments)
        return PaymentIntentInfo(paymentID: payment.id, clientSecret: nil, amountCents: amount, currencyCode: booking.currencyCode, kind: kind)
    }

    /// What Stripe's webhook does in the real system: the payment went through, so the booking moves on.
    func completeSimulatedPayment(_ paymentID: UUID) async throws {
        var payments = readPayments()
        guard let paymentIndex = payments.firstIndex(where: { $0.id == paymentID }), payments[paymentIndex].kind != .refund else {
            throw SlateError.paymentNotDue
        }
        if payments[paymentIndex].status == .succeeded { return } // Reporting it twice changes nothing.

        var bookings = readBookings()
        guard let bookingIndex = bookings.firstIndex(where: { $0.id == payments[paymentIndex].bookingID }) else {
            throw SlateError.bookingNotFound
        }
        let now = Date(timeIntervalSince1970: self.now.timeIntervalSince1970.rounded(.down))
        let payment = payments[paymentIndex]

        payments[paymentIndex].status = .succeeded
        payments[paymentIndex].paidAt = now
        payments[paymentIndex].method = .simulated
        payments[paymentIndex].failureMessage = nil

        var confirm = false
        var complete = false
        var refundNeeded = false
        switch (payment.kind, bookings[bookingIndex].status) {
        case (.deposit, .held):
            confirm = true
        case (.deposit, .expired):
            // Paid just after the hold ran out. If nobody has taken the time, honour it.
            let mine = bookings[bookingIndex]
            let taken = bookings.contains {
                $0.id != mine.id && $0.creatorID == mine.creatorID
                    && $0.effectiveStatus(at: now).blocksTime && IntervalMath.overlaps($0.blockedRange, mine.blockedRange)
            }
            if taken { refundNeeded = true } else { confirm = true }
        case (.deposit, .confirmed), (.deposit, .completed), (.balance, .completed):
            break
        case (.balance, .confirmed):
            complete = true
        default:
            refundNeeded = true // The booking was cancelled while this was being paid: give it all back.
        }

        if confirm {
            bookings[bookingIndex].status = .confirmed
            bookings[bookingIndex].holdExpiresAt = nil
            try executeContract(bookingID: bookings[bookingIndex].id, creatorID: bookings[bookingIndex].creatorID, at: now)
        }
        if complete {
            bookings[bookingIndex].status = .completed
        }
        if refundNeeded {
            payments.append(Payment(
                id: UUID(), bookingID: payment.bookingID, kind: .refund, refundOf: payment.id, amountCents: payment.amountCents,
                currencyCode: payment.currencyCode, status: .pending, method: .simulated, failureMessage: nil, createdAt: now, paidAt: nil
            ))
        }
        try write(bookings, to: bookingsURL)
        try writePayments(payments)

        // Money that stayed (not one handed straight back) is worth a line in the conversation.
        if confirm || complete {
            try? appendSystemMessage(
                payment.kind == .deposit ? .depositPaid : .balancePaid, bookingID: payment.bookingID,
                data: MessageEventData(amountCents: payment.amountCents, currency: payment.currencyCode), at: now
            )
        }
        if confirm { try? appendSystemMessage(.contractSigned, bookingID: payment.bookingID, at: now) }
    }

    /// Adds the creator's saved signature and completes the contract.
    private func executeContract(bookingID: UUID, creatorID: UUID, at date: Date) throws {
        var contracts = readContracts()
        guard let index = contracts.firstIndex(where: { $0.bookingID == bookingID }), contracts[index].status != .executed else { return }
        guard let creatorSignature = read(CreatorSignature.self, from: signatureURL(creatorID)) else { throw SlateError.creatorNotReady }
        contracts[index] = Self.executed(contracts[index], with: creatorSignature, at: date)
        try write(contracts, to: contractsURL)
    }

    // MARK: - Cancelling

    private func quote(for booking: Booking, payments: [Payment], byCreator: Bool, now: Date) -> RefundQuote {
        let mine = payments.filter { $0.bookingID == booking.id }
        let paid = mine.filter { $0.kind != .refund && $0.status == .succeeded }.reduce(0) { $0 + $1.amountCents }
        let returned = mine.filter { $0.kind == .refund && ($0.status == .pending || $0.status == .succeeded) }.reduce(0) { $0 + $1.amountCents }
        return RefundQuote.make(
            paidCents: paid - returned,
            policy: booking.cancellationPolicy,
            hoursBefore: booking.startAt.timeIntervalSince(now) / 3600,
            byCreator: byCreator,
            currencyCode: booking.currencyCode
        )
    }

    func refundQuote(bookingID: UUID, for userID: UUID) async throws -> RefundQuote {
        try expireLapsedHolds()
        let now = self.now
        guard let booking = readBookings().first(where: { $0.id == bookingID }),
              booking.creatorID == userID || booking.clientID == userID,
              booking.canCancel(at: now)
        else { throw SlateError.notCancellable }
        return quote(for: booking, payments: readPayments(), byCreator: booking.creatorID == userID, now: now)
    }

    func cancelBooking(_ id: UUID, by userID: UUID) async throws -> CancellationResult {
        try expireLapsedHolds()
        let now = Date(timeIntervalSince1970: self.now.timeIntervalSince1970.rounded(.down))
        var bookings = readBookings()
        guard let index = bookings.firstIndex(where: { $0.id == id }),
              bookings[index].creatorID == userID || bookings[index].clientID == userID,
              bookings[index].canCancel(at: now)
        else { throw SlateError.notCancellable }

        var payments = readPayments()
        let figures = quote(for: bookings[index], payments: payments, byCreator: bookings[index].creatorID == userID, now: now)

        bookings[index].status = .cancelled
        bookings[index].cancelledAt = now
        bookings[index].cancelledByID = userID
        bookings[index].holdExpiresAt = nil

        var contracts = readContracts()
        for position in contracts.indices where contracts[position].bookingID == id && (contracts[position].status == .pending || contracts[position].status == .executed) {
            contracts[position].status = .voided
        }
        for position in payments.indices where payments[position].bookingID == id && payments[position].status == .pending && payments[position].kind != .refund {
            payments[position].status = .canceled
        }

        // The refund is recorded as owed; `settleRefunds` is what sends it.
        let mine = payments.filter { $0.bookingID == id }
        for part in PaymentRules.refundAllocation(refundCents: figures.refundCents, payments: mine) {
            guard let source = mine.first(where: { $0.id == part.paymentID }) else { continue }
            payments.append(Payment(
                id: UUID(), bookingID: id, kind: .refund, refundOf: source.id, amountCents: part.cents,
                currencyCode: source.currencyCode, status: .pending, method: source.method, failureMessage: nil,
                createdAt: now, paidAt: nil
            ))
        }

        try write(bookings, to: bookingsURL)
        try write(contracts, to: contractsURL)
        try writePayments(payments)
        try? appendSystemMessage(
            .cancelled, bookingID: id,
            data: MessageEventData(refundCents: figures.refundCents, currency: bookings[index].currencyCode, byCreator: bookings[index].creatorID == userID),
            at: now
        )
        return CancellationResult(booking: bookings[index], refundCents: figures.refundCents, percent: figures.percent)
    }

    /// On-device there is no card to send money back to, so every owed refund is simply marked as returned.
    func settleRefunds(bookingID: UUID) async throws {
        let now = self.now
        var payments = readPayments()
        var changed = false
        for index in payments.indices where payments[index].bookingID == bookingID && payments[index].kind == .refund && payments[index].status == .pending {
            payments[index].status = .succeeded
            payments[index].paidAt = now
            changed = true
        }
        if changed { try writePayments(payments) }
    }

    // MARK: - After the shoot

    func markDelivered(bookingID: UUID, by creatorID: UUID) async throws -> Booking {
        let now = Date(timeIntervalSince1970: self.now.timeIntervalSince1970.rounded(.down))
        var bookings = readBookings()
        guard let index = bookings.firstIndex(where: { $0.id == bookingID }), bookings[index].creatorID == creatorID else {
            throw SlateError.bookingNotFound
        }
        guard bookings[index].canMarkDelivered(at: now) else { throw SlateError.notDeliverable }

        bookings[index].deliveredAt = now
        // With nothing left to pay, delivery finishes the booking.
        if bookings[index].balanceCents == 0 { bookings[index].status = .completed }
        try write(bookings, to: bookingsURL)
        try? appendSystemMessage(
            .delivered, bookingID: bookingID,
            data: MessageEventData(balanceCents: bookings[index].balanceCents, currency: bookings[index].currencyCode), at: now
        )
        return bookings[index]
    }
}
