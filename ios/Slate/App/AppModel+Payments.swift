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

    /// A creator can take a deposit once Stripe can take cards, or once there is a payment link clients can use instead.
    /// Always true for Stripe on-device.
    var canTakePayments: Bool { (paymentAccount?.canAcceptPayments ?? false) || paymentLink != nil }

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
                // Paying the balance is what unlocks the originals of delivered photos and videos.
                if kind == .balance { await loadFiles(for: booking.id) }
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
    func waitForPayment(bookingID: UUID, kind: PaymentKind, attempts: Int = 12) async -> Bool {
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

    // MARK: - Linking Stripe

    /// Whether the person on screen can link a Stripe account for what they sell: not a client, and at a company only
    /// whoever may manage its payments (the Owner).
    var canSetUpPayments: Bool { session != nil && !isClientOnly && can(.paymentsConnect) }

    /// Reads where the owner's payment setup stands (their Stripe account and any payment link) without asking Stripe.
    func loadPaymentSetup() async {
        guard let owner = ownerID else { return }
        paymentAccount = try? await backend.loadPaymentAccount(for: owner)
        paymentLink = try? await backend.loadPaymentLink(for: owner)
    }

    // MARK: - Paying another way

    /// How the booking's client can pay: with Apple Pay through Stripe, through the creator's own link, or both.
    func paymentOptions(for booking: Booking) async -> PaymentOptions? {
        guard let session else { return nil }
        return try? await backend.paymentOptions(bookingID: booking.id, for: session.userID)
    }

    /// What the person on the provider side of a booking may mark as received by hand right now, if anything.
    func kindToMarkReceived(_ booking: Booking, now: Date = Date()) -> PaymentKind? {
        guard let me = session?.userID, booking.clientID != me, isProviderSide(booking), canManage(booking) else { return nil }
        switch paymentSummary(for: booking, now: now).phase {
        case .depositDue, .depositFailed, .holdExpired: return .deposit
        case .balanceDue: return .balance
        default: return nil
        }
    }

    /// Records that money for a deposit or balance reached the creator some other way. True when it was recorded.
    @discardableResult
    func markReceived(_ kind: PaymentKind, for booking: Booking) async -> Bool {
        guard let session else { return false }
        do {
            try await backend.markPaymentReceived(bookingID: booking.id, kind: kind, note: nil, by: session.userID)
            await reloadMoney()
            return true
        } catch {
            show(error, title: "Couldn't record the payment")
            await reloadMoney()
            return false
        }
    }

    /// Whether this is a refund the creator has to send by hand, and the person may say they did.
    func canMarkRefundSent(_ payment: Payment, in booking: Booking) -> Bool {
        payment.kind == .refund && payment.status == .pending && payment.method == .manual
            && booking.clientID != session?.userID && isProviderSide(booking) && canManage(booking)
    }

    func markRefundSent(_ payment: Payment) async {
        guard let session else { return }
        do {
            try await backend.markRefundSent(paymentID: payment.id, by: session.userID)
        } catch {
            show(error, title: "Couldn't record the refund")
        }
        await reloadMoney()
    }

    func refreshPaymentLink() async {
        guard let owner = ownerID else { return }
        paymentLink = try? await backend.loadPaymentLink(for: owner)
    }

    /// Saves the link (an empty address takes it away). True when it was saved.
    func savePaymentLink(url: String, instructions: String) async -> Bool {
        guard let owner = ownerID else { return false }
        do {
            if url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await backend.savePaymentLink(nil, for: owner)
                paymentLink = nil
                return true
            }
            guard let clean = PaymentLinkRules.clean(url: url), let address = URL(string: clean) else {
                throw SlateError.invalidPaymentLink
            }
            let link = PaymentLink(url: address, instructions: PaymentLinkRules.cleanInstructions(instructions))
            try await backend.savePaymentLink(link, for: owner)
            paymentLink = link
            return true
        } catch {
            show(error, title: "Couldn't save the link")
            return false
        }
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
        guard let owner = ownerID else { return nil }
        do {
            switch try await backend.beginPaymentAccountSetup(for: owner) {
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
        guard let owner = ownerID else { return }
        if let account = try? await backend.refreshPaymentAccount(for: owner) {
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
