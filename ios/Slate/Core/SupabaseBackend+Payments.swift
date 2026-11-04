import Foundation
import Supabase

/// Payments on Supabase and Stripe.
///
/// The app never moves money or decides amounts. It reads the ledger (Row Level Security limits it to the
/// bookings the person is part of) and asks Edge Functions to act: `create-payment-intent` opens a payment for
/// the Apple Pay sheet, `process-refunds` sends owed refunds back, `connect-onboarding` sets a creator up with
/// Stripe. What actually happened comes from Stripe's webhook, so a client can't claim to have paid.
extension SupabaseBackend {
    var paymentsAreSimulated: Bool { false }

    // MARK: - Rows

    private struct PaymentRow: Decodable {
        var id: String
        var bookingId: String
        var kind: String
        var refundOf: String?
        var amountCents: Int
        var currencyCode: String
        var status: String
        var method: String?
        var failureMessage: String?
        var createdAt: Date
        var paidAt: Date?

        enum CodingKeys: String, CodingKey {
            case id, kind, status, method
            case bookingId = "booking_id"
            case refundOf = "refund_of"
            case amountCents = "amount_cents"
            case currencyCode = "currency_code"
            case failureMessage = "failure_message"
            case createdAt = "created_at"
            case paidAt = "paid_at"
        }
    }

    private struct AccountRow: Decodable {
        var chargesEnabled: Bool
        var payoutsEnabled: Bool
        var detailsSubmitted: Bool

        enum CodingKeys: String, CodingKey {
            case chargesEnabled = "charges_enabled"
            case payoutsEnabled = "payouts_enabled"
            case detailsSubmitted = "details_submitted"
        }
    }

    /// What `connect-onboarding` answers.
    private struct ConnectResponse: Decodable {
        var connected: Bool
        var chargesEnabled: Bool
        var payoutsEnabled: Bool
        var detailsSubmitted: Bool
        var url: String?

        enum CodingKeys: String, CodingKey {
            case connected, url
            case chargesEnabled = "charges_enabled"
            case payoutsEnabled = "payouts_enabled"
            case detailsSubmitted = "details_submitted"
        }

        var account: PaymentAccount {
            PaymentAccount(isConnected: connected, chargesEnabled: chargesEnabled, payoutsEnabled: payoutsEnabled, detailsSubmitted: detailsSubmitted)
        }
    }

    private struct ConnectRequest: Encodable {
        var action: String
    }

    /// What `create-payment-intent` answers. `stripe_account` is the creator's own account the payment is made on.
    private struct PaymentIntentResponse: Decodable {
        var paymentId: String
        var clientSecret: String
        var amountCents: Int
        var currency: String
        var stripeAccount: String?

        enum CodingKeys: String, CodingKey {
            case currency
            case paymentId = "payment_id"
            case clientSecret = "client_secret"
            case amountCents = "amount_cents"
            case stripeAccount = "stripe_account"
        }
    }

    /// What `payment_options` returns, and what `creator_payment_links` holds.
    private struct PaymentOptionsRow: Decodable {
        var stripeReady: Bool
        var linkUrl: String?
        var instructions: String?

        enum CodingKeys: String, CodingKey {
            case instructions
            case stripeReady = "stripe_ready"
            case linkUrl = "link_url"
        }
    }

    private struct PaymentLinkRow: Decodable {
        var url: String
        var instructions: String
    }

    private struct OptionsParams: Encodable {
        var pBookingId: String

        enum CodingKeys: String, CodingKey { case pBookingId = "p_booking_id" }
    }

    /// `p_instructions` and `p_note` have defaults in SQL, so they may be left out; `p_url` is sent empty to take a link away.
    private struct SaveLinkParams: Encodable {
        var pOwner: String
        var pUrl: String
        var pInstructions: String

        enum CodingKeys: String, CodingKey {
            case pOwner = "p_owner"
            case pUrl = "p_url"
            case pInstructions = "p_instructions"
        }
    }

    private struct MarkReceivedParams: Encodable {
        var pBookingId: String
        var pKind: String
        var pNote: String?

        enum CodingKeys: String, CodingKey {
            case pBookingId = "p_booking_id"
            case pKind = "p_kind"
            case pNote = "p_note"
        }
    }

    private struct RefundSentParams: Encodable {
        var pRefundId: String

        enum CodingKeys: String, CodingKey { case pRefundId = "p_refund_id" }
    }

    private struct PaymentIntentRequest: Encodable {
        var bookingId: String
        var kind: String

        enum CodingKeys: String, CodingKey {
            case kind
            case bookingId = "booking_id"
        }
    }

    private struct RefundRequest: Encodable {
        var bookingId: String

        enum CodingKeys: String, CodingKey { case bookingId = "booking_id" }
    }

    private struct QuoteParams: Encodable {
        var pBookingId: String

        enum CodingKeys: String, CodingKey { case pBookingId = "p_booking_id" }
    }

    private struct QuoteRow: Decodable {
        var paidCents: Int
        var percent: Int
        var refundCents: Int
        var hoursBefore: Double
        var policy: String
        var byCreator: Bool
        var currency: String

        enum CodingKeys: String, CodingKey {
            case percent, policy, currency
            case paidCents = "paid_cents"
            case refundCents = "refund_cents"
            case hoursBefore = "hours_before"
            case byCreator = "by_creator"
        }
    }

    private struct FunctionErrorBody: Decodable {
        var error: String
    }

    // MARK: - Reading

    func loadPayments(for userID: UUID) async throws -> [Payment] {
        // Row Level Security limits this to payments on the person's own bookings.
        let rows: [PaymentRow] = try await client
            .from("payments")
            .select()
            .order("created_at", ascending: true)
            .execute()
            .value
        return rows.compactMap { row in
            guard let id = UUID(uuidString: row.id),
                  let bookingID = UUID(uuidString: row.bookingId),
                  let kind = PaymentKind(rawValue: row.kind),
                  let status = PaymentRecordStatus(rawValue: row.status)
            else { return nil }
            return Payment(
                id: id,
                bookingID: bookingID,
                kind: kind,
                refundOf: row.refundOf.flatMap(UUID.init(uuidString:)),
                amountCents: row.amountCents,
                currencyCode: row.currencyCode,
                status: status,
                method: row.method.flatMap(PaymentMethod.init(rawValue:)),
                failureMessage: row.failureMessage,
                createdAt: row.createdAt,
                paidAt: row.paidAt
            )
        }
    }

    func loadPaymentAccount(for creatorID: UUID) async throws -> PaymentAccount {
        let rows: [AccountRow] = try await client
            .from("creator_payment_accounts")
            .select()
            .eq("creator_id", value: Self.key(creatorID))
            .limit(1)
            .execute()
            .value
        guard let row = rows.first else { return .notConnected }
        return PaymentAccount(isConnected: true, chargesEnabled: row.chargesEnabled, payoutsEnabled: row.payoutsEnabled, detailsSubmitted: row.detailsSubmitted)
    }

    // MARK: - Stripe Connect

    func beginPaymentAccountSetup(for creatorID: UUID) async throws -> PaymentAccountSetup {
        let response: ConnectResponse = try await call("connect-onboarding", body: ConnectRequest(action: "link"))
        if let text = response.url, let url = URL(string: text) {
            return .continueOnWeb(url)
        }
        return .ready(response.account)
    }

    func refreshPaymentAccount(for creatorID: UUID) async throws -> PaymentAccount {
        let response: ConnectResponse = try await call("connect-onboarding", body: ConnectRequest(action: "status"))
        return response.account
    }

    // MARK: - Paying

    func preparePayment(bookingID: UUID, kind: PaymentKind, by userID: UUID) async throws -> PaymentIntentInfo {
        let response: PaymentIntentResponse = try await call(
            "create-payment-intent",
            body: PaymentIntentRequest(bookingId: Self.key(bookingID), kind: kind.rawValue)
        )
        guard let paymentID = UUID(uuidString: response.paymentId) else {
            throw SlateError.backend("The payment came back without a valid id.")
        }
        return PaymentIntentInfo(
            paymentID: paymentID,
            clientSecret: response.clientSecret,
            amountCents: response.amountCents,
            currencyCode: response.currency.uppercased(),
            kind: kind,
            stripeAccountID: response.stripeAccount
        )
    }

    /// Real payments are confirmed by Stripe's webhook, never by the app.
    func completeSimulatedPayment(_ paymentID: UUID) async throws {
        throw SlateError.backend("Pretend payments only exist when the app runs on this device alone.")
    }

    // MARK: - Refunds

    func refundQuote(bookingID: UUID, for userID: UUID) async throws -> RefundQuote {
        do {
            let row: QuoteRow = try await client
                .rpc("refund_quote", params: QuoteParams(pBookingId: Self.key(bookingID)))
                .execute()
                .value
            return RefundQuote(
                paidCents: row.paidCents,
                percent: row.percent,
                refundCents: row.refundCents,
                hoursBefore: row.hoursBefore,
                policy: CancellationPolicy(rawValue: row.policy) ?? .moderate,
                byCreator: row.byCreator,
                currencyCode: row.currency
            )
        } catch {
            throw Self.mapBookingError(error)
        }
    }

    func settleRefunds(bookingID: UUID) async throws {
        try await callVoid("process-refunds", body: RefundRequest(bookingId: Self.key(bookingID)))
    }

    // MARK: - Paying another way

    func paymentOptions(bookingID: UUID, for userID: UUID) async throws -> PaymentOptions? {
        do {
            let row: PaymentOptionsRow? = try await client
                .rpc("payment_options", params: OptionsParams(pBookingId: Self.key(bookingID)))
                .execute()
                .value
            guard let row else { return nil }
            return PaymentOptions(stripeReady: row.stripeReady, link: Self.makeLink(url: row.linkUrl, instructions: row.instructions))
        } catch {
            throw Self.mapPaymentRpcError(error)
        }
    }

    func loadPaymentLink(for ownerID: UUID) async throws -> PaymentLink? {
        let rows: [PaymentLinkRow] = try await client
            .from("creator_payment_links")
            .select("url, instructions")
            .eq("creator_id", value: Self.key(ownerID))
            .limit(1)
            .execute()
            .value
        guard let row = rows.first else { return nil }
        return Self.makeLink(url: row.url, instructions: row.instructions)
    }

    func savePaymentLink(_ link: PaymentLink?, for ownerID: UUID) async throws {
        do {
            try await client.rpc("payment_link_save", params: SaveLinkParams(
                pOwner: Self.key(ownerID), pUrl: link?.url.absoluteString ?? "", pInstructions: link?.instructions ?? ""
            )).execute()
        } catch {
            throw Self.mapPaymentRpcError(error)
        }
    }

    func markPaymentReceived(bookingID: UUID, kind: PaymentKind, note: String?, by userID: UUID) async throws {
        do {
            try await client.rpc("payment_mark_received", params: MarkReceivedParams(
                pBookingId: Self.key(bookingID), pKind: kind.rawValue, pNote: note
            )).execute()
        } catch {
            throw Self.mapPaymentRpcError(error)
        }
    }

    func markRefundSent(paymentID: UUID, by userID: UUID) async throws {
        do {
            try await client.rpc("refund_mark_sent", params: RefundSentParams(pRefundId: Self.key(paymentID))).execute()
        } catch {
            throw Self.mapPaymentRpcError(error)
        }
    }

    private static func makeLink(url: String?, instructions: String?) -> PaymentLink? {
        guard let url, let address = URL(string: url) else { return nil }
        return PaymentLink(url: address, instructions: instructions ?? "")
    }

    /// The database's refusals for the pay-another-way functions, in words. Anything it doesn't know goes to the booking errors.
    static func mapPaymentRpcError(_ error: Error) -> Error {
        let text = "\(error)"
        if text.contains("invalid_link") { return SlateError.invalidPaymentLink }
        if text.contains("profile_required") { return SlateError.backend("Finish setting up your profile before adding a payment link.") }
        // A deposit marked after its hold ran out, once someone else has the time.
        if text.contains("time_taken") { return SlateError.slotTaken }
        if text.contains("invalid_kind") { return SlateError.paymentNotDue }
        if text.contains("not_found") { return SlateError.notAllowed }
        return mapBookingError(error)
    }

    // MARK: - Calling Edge Functions

    private func call<Response: Decodable>(_ name: String, body: some Encodable) async throws -> Response {
        do {
            return try await client.functions.invoke(name, options: FunctionInvokeOptions(body: body))
        } catch let error as FunctionsError {
            throw Self.paymentError(from: error)
        }
    }

    private func callVoid(_ name: String, body: some Encodable) async throws {
        do {
            try await client.functions.invoke(name, options: FunctionInvokeOptions(body: body))
        } catch let error as FunctionsError {
            throw Self.paymentError(from: error)
        }
    }

    private static func paymentError(from error: FunctionsError) -> Error {
        if case .httpError(_, let data) = error {
            return paymentError(fromFunctionBody: data)
        }
        return SlateError.paymentUnavailable
    }

    /// The payment Edge Functions answer failures with `{ "error": "<token>" }`. This turns the token into words.
    static func paymentError(fromFunctionBody data: Data) -> SlateError {
        guard let body = try? JSONDecoder().decode(FunctionErrorBody.self, from: data) else {
            return .paymentUnavailable
        }
        switch body.error {
        case "hold_expired": return .holdExpired
        case "payments_not_ready": return .paymentsNotReady
        case "payment_not_due", "balance_not_due", "nothing_due": return .paymentNotDue
        case "already_paid": return .alreadyPaid
        case "payment_processing": return .paymentProcessing
        case "not_found": return .bookingNotFound
        case "unauthorized": return .notSignedIn
        case "profile_required": return .backend("Finish setting up your profile before connecting payments.")
        // Cards on file (`_shared/cards.ts`).
        case "card_declined": return .cardDeclined
        case "authentication_required": return .cardNeedsApproval
        case "no_card_access": return .noCardAccess
        case "card_expired": return .cardExpired
        case "card_not_found": return .cardNotFound
        case "too_many_cards": return .tooManyCards(limit: CardRules.maxCards)
        default: return .paymentUnavailable
        }
    }
}
