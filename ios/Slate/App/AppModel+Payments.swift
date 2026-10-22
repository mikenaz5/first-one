import Foundation

extension AppModel {
    enum PaymentOutcome: Equatable {
        /// The money arrived and the booking moved on.
        case confirmed
        /// They paid, but the backend hasn't heard back from Stripe yet. It will catch up on its own.
        case processing
        /// They closed the payment sheet.
        case cancelled
        case failed(String)
    }

    /// True when payments are pretend (on-device mode). The app says so next to anything money-related.
    var paymentsAreSimulated: Bool { backend.paymentsAreSimulated }

    // MARK: - What to show

    func payments(for booking: Booking) -> [Payment] {
        payments.filter { $0.bookingID == booking.id }.sorted { $0.createdAt < $1.createdAt }
    }

    /// The booking's money as the signed-in person should see it. Whoever booked is the client, even when
    /// they are testing their own package on-device.
    func paymentSummary(for booking: Booking, now: Date = Date()) -> PaymentSummary {
        PaymentSummary.make(booking: booking, payments: payments, viewer: booking.clientID == session?.userID ? .client : .creator, now: now)
    }

    /// What the signed-in person has to pay on this booking right now, if anything.
    func canPay(_ booking: Booking, now: Date = Date()) -> PaymentKind? {
        guard booking.clientID == session?.userID else { return nil }
        switch paymentSummary(for: booking, now: now).phase {
        case .depositDue, .depositFailed: return .deposit
        case .balanceDue: return .balance
        default: return nil
        }
    }

    /// A creator needs Stripe set up before deposits can be taken. Always true on-device.
    var canTakePayments: Bool { paymentAccount?.canAcceptPayments ?? false }

    /// Whether any of the creator's packages asks for a deposit.
    var hasPackagesWithDeposit: Bool { packages.contains { $0.isPublished && $0.depositCents > 0 } }

    // MARK: - Reloading

    /// Fetches bookings, payments and contracts again, after something about money changed.
    func reloadMoney() async {
        guard let session else { return }
        if let latest = try? await backend.loadBookings(for: session.userID) { bookings = latest }
        if let latest = try? await backend.loadPayments(for: session.userID) { payments = latest }
        contractsByBooking = [:]
        bookingsChanged()
    }

    // MARK: - Paying

    /// Shows the payment sheet for a booking's deposit or balance and waits for the backend to confirm the money arrived.
    @discardableResult
    func pay(_ kind: PaymentKind, for booking: Booking) async -> PaymentOutcome {
        guard let session, !isPaying else { return .cancelled }
        isPaying = true
        defer { isPaying = false }

        do {
            let info = try await backend.preparePayment(bookingID: booking.id, kind: kind, by: session.userID)
            let request = PaymentRequestDetails(
                info: info,
                label: "\(kind.title) · \(booking.packageName)",
                countryCode: Locale.current.region?.identifier ?? "US"
            )
            switch try await authorizer.authorize(request) {
            case .cancelled:
                return .cancelled
            case .paid:
                if backend.paymentsAreSimulated {
                    try await backend.completeSimulatedPayment(info.paymentID)
                }
                guard await waitForPayment(bookingID: booking.id, kind: kind) else { return .processing }
                if let confirmed = bookings.first(where: { $0.id == booking.id }), kind == .deposit,
                   let contract = await contract(for: confirmed), contract.status == .executed {
                    afterConfirmed(confirmed, contract: contract)
                }
                return .confirmed
            }
        } catch {
            await reloadMoney()
            return .failed(error.localizedDescription)
        }
    }

    /// The webhook confirms real payments a moment after Apple Pay finishes, so look a few times.
    private func waitForPayment(bookingID: UUID, kind: PaymentKind, attempts: Int = 12) async -> Bool {
        for attempt in 0..<attempts {
            await reloadMoney()
            if let booking = bookings.first(where: { $0.id == bookingID }) {
                switch kind {
                case .deposit where booking.status == .confirmed || booking.status == .completed: return true
                case .balance where booking.status == .completed: return true
                default: break
                }
            }
            if attempt < attempts - 1 { try? await Task.sleep(for: .seconds(1)) }
        }
        return false
    }

    // MARK: - Refunds

    func refundQuote(for booking: Booking) async -> RefundQuote? {
        guard let session else { return nil }
        return try? await backend.refundQuote(bookingID: booking.id, for: session.userID)
    }

    /// Sends owed refunds for one booking to the card that paid. If that fails the refund stays owed and is retried.
    func settleRefunds(for bookingID: UUID) async {
        do {
            try await backend.settleRefunds(bookingID: bookingID)
        } catch {
            alert = ErrorAlert(
                title: "Your refund is on its way",
                message: "The booking is cancelled, but the refund couldn't be sent just now. It's recorded and will be retried automatically."
            )
        }
        await reloadMoney()
    }

    /// Quietly retries refunds that were recorded but not sent (for example if the phone was offline).
    func settlePendingRefunds() async {
        let owed = Set(payments.filter { $0.kind == .refund && $0.status == .pending }.map(\.bookingID))
        for bookingID in owed {
            try? await backend.settleRefunds(bookingID: bookingID)
        }
        if !owed.isEmpty { await reloadMoney() }
    }

    // MARK: - Stripe account

    /// Starts (or continues) getting paid. Returns an address to open when Stripe's own pages finish the job.
    func setUpPayments() async -> URL? {
        guard let session else { return nil }
        do {
            switch try await backend.beginPaymentAccountSetup(for: session.userID) {
            case .ready(let account):
                paymentAccount = account
                return nil
            case .continueOnWeb(let url):
                return url
            }
        } catch {
            show(error, title: "Couldn't set up payments")
            return nil
        }
    }

    func refreshPaymentAccount() async {
        guard let session else { return }
        if let account = try? await backend.refreshPaymentAccount(for: session.userID) {
            paymentAccount = account
        }
    }
}

extension AppModel.PaymentOutcome {
    /// What to tell the person about how paying went, or nil when there is nothing to add.
    var message: String? {
        switch self {
        case .confirmed, .cancelled:
            nil
        case .processing:
            "Your payment went through and is being confirmed. This usually takes a few seconds. Pull to refresh in a moment."
        case .failed(let reason):
            reason
        }
    }
}
