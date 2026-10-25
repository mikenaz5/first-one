import Foundation
import Supabase

/// Cards on file on Supabase and Stripe.
///
/// The app never holds a card number and never sees Stripe's reference to a card. A card is typed on a Stripe page
/// (`card-setup` returns its address); what is shown comes from `client_cards`, which the database lets the app read only
/// by these columns (`cardColumns`), because the table also holds Stripe's reference. Allowing and stopping a creator are
/// database functions (`card_grant`, `card_revoke`) that check the rules; removing a card is `card-remove`, which removes
/// it at Stripe first; and a creator's charge is `charge-saved-card`, which asks the database for the amount, the card and
/// whether the person may, and carries the charge out. What was paid is recorded when Stripe's webhook says so.
extension SupabaseBackend {
    /// The columns of `client_cards` the app may read. Asking for any other (or for every column) is refused.
    static let cardColumns = "id, brand, last4, exp_month, exp_year, created_at"

    // MARK: - Rows

    struct CardRow: Decodable {
        var id: String
        var brand: String
        var last4: String
        var expMonth: Int
        var expYear: Int
        var createdAt: Date

        enum CodingKeys: String, CodingKey {
            case id, brand, last4
            case expMonth = "exp_month"
            case expYear = "exp_year"
            case createdAt = "created_at"
        }

        func card() throws -> SavedCard {
            guard let id = UUID(uuidString: id) else { throw SlateError.backend("Malformed card id.") }
            return SavedCard(id: id, brand: CardBrand(stripe: brand), last4: last4, expMonth: expMonth, expYear: expYear, addedAt: createdAt)
        }
    }

    /// One row of `my_card_grants()`.
    struct CardGrantRow: Decodable {
        var creatorId: String
        var creatorName: String
        var handle: String?
        var avatarPath: String?
        var cardId: String
        var brand: String
        var last4: String
        var expMonth: Int
        var expYear: Int
        var grantedAt: Date

        enum CodingKeys: String, CodingKey {
            case handle, brand, last4
            case creatorId = "creator_id"
            case creatorName = "creator_name"
            case avatarPath = "avatar_path"
            case cardId = "card_id"
            case expMonth = "exp_month"
            case expYear = "exp_year"
            case grantedAt = "granted_at"
        }

        func permission() throws -> CardPermission {
            guard let creatorID = UUID(uuidString: creatorId), let cardID = UUID(uuidString: cardId) else {
                throw SlateError.backend("Malformed card permission.")
            }
            return CardPermission(
                creatorID: creatorID, creatorName: creatorName, handle: handle, cardID: cardID, brand: CardBrand(stripe: brand),
                last4: last4, expMonth: expMonth, expYear: expYear, allowedAt: grantedAt
            )
        }
    }

    /// What `card_access_for_booking()` answers.
    struct CardAccessRow: Decodable {
        var allowed: Bool
        var brand: String?
        var last4: String?
        var expired: Bool

        func access() -> CardAccess {
            CardAccess(allowed: allowed, brand: brand.map { CardBrand(stripe: $0) }, last4: last4, expired: expired)
        }
    }

    private struct SetupResponse: Decodable {
        var url: String
    }

    private struct SyncResponse: Decodable {
        var cards: Int
    }

    private struct ChargeResponse: Decodable {
        var paymentId: String
        var status: String

        enum CodingKeys: String, CodingKey {
            case status
            case paymentId = "payment_id"
        }
    }

    private struct CardIDRequest: Encodable {
        var cardId: String

        enum CodingKeys: String, CodingKey { case cardId = "card_id" }
    }

    private struct ChargeRequest: Encodable {
        var bookingId: String

        enum CodingKeys: String, CodingKey { case bookingId = "booking_id" }
    }

    private struct GrantParams: Encodable {
        var pCreatorId: String
        var pCardId: String
        var pConsentVersion: Int

        enum CodingKeys: String, CodingKey {
            case pCreatorId = "p_creator_id"
            case pCardId = "p_card_id"
            case pConsentVersion = "p_consent_version"
        }
    }

    private struct RevokeParams: Encodable {
        var pCreatorId: String

        enum CodingKeys: String, CodingKey { case pCreatorId = "p_creator_id" }
    }

    private struct AccessParams: Encodable {
        var pBookingId: String

        enum CodingKeys: String, CodingKey { case pBookingId = "p_booking_id" }
    }

    // MARK: - Reading

    func loadCards(for userID: UUID) async throws -> [SavedCard] {
        let rows: [CardRow] = try await client
            .from("client_cards")
            .select(Self.cardColumns)
            .eq("user_id", value: Self.key(userID))
            .order("created_at", ascending: true)
            .execute()
            .value
        return try rows.map { try $0.card() }
    }

    func loadCardPermissions(for userID: UUID) async throws -> [CardPermission] {
        let rows: [CardGrantRow] = try await client.rpc("my_card_grants").execute().value
        return try rows.map { try $0.permission() }
    }

    // MARK: - Adding and removing

    func beginAddingCard(for userID: UUID) async throws -> AddCardStep {
        let response: SetupResponse = try await callCards("card-setup")
        guard let url = URL(string: response.url) else { throw SlateError.paymentUnavailable }
        return .continueOnWeb(url)
    }

    func syncCards(for userID: UUID) async throws -> [SavedCard] {
        // Stripe is asked what the person's cards are, so a card just typed there shows up even if its webhook is late.
        let _: SyncResponse = try await callCards("card-sync")
        return try await loadCards(for: userID)
    }

    func removeCard(_ id: UUID, for userID: UUID) async throws {
        try await callCardsVoid("card-remove", body: CardIDRequest(cardId: Self.key(id)))
    }

    // MARK: - Allowing a creator

    func allowCreator(_ creatorID: UUID, cardID: UUID, consentVersion: Int, for userID: UUID) async throws {
        do {
            try await client
                .rpc("card_grant", params: GrantParams(pCreatorId: Self.key(creatorID), pCardId: Self.key(cardID), pConsentVersion: consentVersion))
                .execute()
        } catch {
            throw Self.mapCardError(error)
        }
    }

    func stopAllowingCreator(_ creatorID: UUID, for userID: UUID) async throws {
        do {
            try await client.rpc("card_revoke", params: RevokeParams(pCreatorId: Self.key(creatorID))).execute()
        } catch {
            throw Self.mapCardError(error)
        }
    }

    // MARK: - On a booking

    func cardAccess(bookingID: UUID, for userID: UUID) async throws -> CardAccess {
        do {
            let row: CardAccessRow = try await client
                .rpc("card_access_for_booking", params: AccessParams(pBookingId: Self.key(bookingID)))
                .execute()
                .value
            return row.access()
        } catch {
            throw Self.mapCardError(error)
        }
    }

    func chargeSavedCard(bookingID: UUID, by userID: UUID) async throws -> SavedCardCharge {
        let response: ChargeResponse = try await callCards("charge-saved-card", body: ChargeRequest(bookingId: Self.key(bookingID)))
        guard let paymentID = UUID(uuidString: response.paymentId), let status = SavedCardCharge.Status(rawValue: response.status) else {
            throw SlateError.backend("The charge came back without a valid payment.")
        }
        return SavedCardCharge(paymentID: paymentID, status: status)
    }

    // MARK: - Errors

    /// The card functions raise plain tokens such as `card_expired`. The card ones are checked first, because
    /// `card_not_found` would otherwise be taken for `not_found`.
    static func mapCardError(_ error: Error) -> Error {
        let text = "\(error)"
        let known: [(token: String, error: SlateError)] = [
            ("card_not_found", .cardNotFound),
            ("card_expired", .cardExpired),
            ("consent_outdated", .cardConsentOutdated),
            ("no_booking_with_creator", .noBookingWithCreator),
            ("too_many_cards", .tooManyCards(limit: CardRules.maxCards)),
            ("no_card_access", .noCardAccess),
        ]
        for entry in known where text.contains(entry.token) {
            return entry.error
        }
        return mapBookingError(error)
    }

    // MARK: - Calling Edge Functions

    private func callCards<Response: Decodable>(_ name: String) async throws -> Response {
        do {
            return try await client.functions.invoke(name)
        } catch let error as FunctionsError {
            throw Self.cardFunctionError(from: error)
        }
    }

    private func callCards<Response: Decodable>(_ name: String, body: some Encodable) async throws -> Response {
        do {
            return try await client.functions.invoke(name, options: FunctionInvokeOptions(body: body))
        } catch let error as FunctionsError {
            throw Self.cardFunctionError(from: error)
        }
    }

    private func callCardsVoid(_ name: String, body: some Encodable) async throws {
        do {
            try await client.functions.invoke(name, options: FunctionInvokeOptions(body: body))
        } catch let error as FunctionsError {
            throw Self.cardFunctionError(from: error)
        }
    }

    private static func cardFunctionError(from error: FunctionsError) -> Error {
        if case .httpError(_, let data) = error {
            return paymentError(fromFunctionBody: data)
        }
        return SlateError.paymentUnavailable
    }
}
