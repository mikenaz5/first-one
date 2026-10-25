import Foundation

/// Cards on file for the on-device backend: pretend cards, and the same permissions as the database.
///
/// Nothing here holds a card number or moves money. "Add a card" makes a demo card (a made-up number's last four, an
/// expiry three years away) so the whole flow can be tried with no server: allowing a creator, stopping it, removing a
/// card, and a creator charging the balance. The rules follow `…_cards_on_file.sql` one for one: only a creator the person
/// has booked, only their own unexpired card, a charge only by whoever can manage the booking and only for the balance once
/// it is payable. A charge goes through `preparePayment` and `completeSimulatedPayment`, the on-device stand-ins for
/// `payment_prepare` and Stripe's webhook, so the amount is never chosen by the caller here either.
extension LocalBackend {
    /// What the app can show of a permission; the card's details are looked up when it is read.
    struct StoredCardPermission: Codable, Equatable {
        var creatorID: UUID
        var cardID: UUID
        var consentVersion: Int
        var allowedAt: Date
    }

    /// The demo cards on offer, in the order they are handed out.
    static let demoCards: [(brand: CardBrand, last4: String)] = [
        (.visa, "4242"), (.mastercard, "4444"), (.amex, "0005"), (.discover, "1117"), (.jcb, "0004"),
    ]

    // MARK: - Storage

    private func cardsURL(_ userID: UUID) -> URL { userDirectory(userID).appendingPathComponent("cards.json") }
    private func cardPermissionsURL(_ userID: UUID) -> URL { userDirectory(userID).appendingPathComponent("card_permissions.json") }

    func readCards(_ userID: UUID) -> [SavedCard] {
        read([SavedCard].self, from: cardsURL(userID)) ?? []
    }

    func readCardPermissions(_ userID: UUID) -> [StoredCardPermission] {
        read([StoredCardPermission].self, from: cardPermissionsURL(userID)) ?? []
    }

    // MARK: - Reading

    func loadCards(for userID: UUID) async throws -> [SavedCard] {
        readCards(userID).sorted { $0.addedAt != $1.addedAt ? $0.addedAt < $1.addedAt : $0.id.uuidString < $1.id.uuidString }
    }

    func loadCardPermissions(for userID: UUID) async throws -> [CardPermission] {
        let cards = readCards(userID)
        let bookings = readBookings().filter { $0.clientID == userID }
        return readCardPermissions(userID).compactMap { stored in
            guard let card = cards.first(where: { $0.id == stored.cardID }) else { return nil }
            return CardPermission(
                creatorID: stored.creatorID,
                creatorName: bookings.first(where: { $0.creatorID == stored.creatorID })?.creatorName ?? "Creator",
                handle: nil,
                cardID: card.id, brand: card.brand, last4: card.last4, expMonth: card.expMonth, expYear: card.expYear,
                allowedAt: stored.allowedAt
            )
        }
        .sorted { $0.allowedAt != $1.allowedAt ? $0.allowedAt > $1.allowedAt : $0.creatorName < $1.creatorName }
    }

    // MARK: - Adding and removing

    func beginAddingCard(for userID: UUID) async throws -> AddCardStep {
        var cards = readCards(userID)
        guard CardRules.canAddAnother(to: cards.count) else { throw SlateError.tooManyCards(limit: CardRules.maxCards) }

        let taken = Set(cards.map(\.last4))
        let demo = Self.demoCards.first { !taken.contains($0.last4) } ?? Self.demoCards[cards.count % Self.demoCards.count]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let today = calendar.dateComponents([.year, .month], from: now)
        let card = SavedCard(
            id: UUID(), brand: demo.brand, last4: demo.last4,
            expMonth: today.month ?? 1, expYear: (today.year ?? 2026) + 3, addedAt: now
        )
        cards.append(card)
        try write(cards, to: cardsURL(userID))
        return .added(card)
    }

    func syncCards(for userID: UUID) async throws -> [SavedCard] {
        try await loadCards(for: userID)
    }

    func removeCard(_ id: UUID, for userID: UUID) async throws {
        var cards = readCards(userID)
        guard cards.contains(where: { $0.id == id }) else { throw SlateError.cardNotFound }
        cards.removeAll { $0.id == id }
        try write(cards, to: cardsURL(userID))
        // Every permission that used the card goes with it.
        let permissions = readCardPermissions(userID).filter { $0.cardID != id }
        try write(permissions, to: cardPermissionsURL(userID))
    }

    // MARK: - Allowing a creator

    func allowCreator(_ creatorID: UUID, cardID: UUID, consentVersion: Int, for userID: UUID) async throws {
        let now = self.now
        guard consentVersion == CardRules.consentVersion else { throw SlateError.cardConsentOutdated }
        guard let card = readCards(userID).first(where: { $0.id == cardID }) else { throw SlateError.cardNotFound }
        guard !card.isExpired(at: now) else { throw SlateError.cardExpired }
        let booked = readBookings().contains { booking in
            guard booking.clientID == userID, booking.creatorID == creatorID else { return false }
            switch booking.effectiveStatus(at: now) {
            case .held, .confirmed, .completed: return true
            case .cancelled, .expired: return false
            }
        }
        guard booked else { throw SlateError.noBookingWithCreator }

        // Allowing again, with another card, replaces the first.
        var permissions = readCardPermissions(userID).filter { $0.creatorID != creatorID }
        permissions.append(StoredCardPermission(creatorID: creatorID, cardID: cardID, consentVersion: consentVersion, allowedAt: now))
        try write(permissions, to: cardPermissionsURL(userID))
    }

    func stopAllowingCreator(_ creatorID: UUID, for userID: UUID) async throws {
        let before = readCardPermissions(userID)
        let after = before.filter { $0.creatorID != creatorID }
        if after.count != before.count { try write(after, to: cardPermissionsURL(userID)) }
    }

    // MARK: - On a booking

    /// The client's card for this booking's creator, if they have allowed it.
    private func allowedCard(for booking: Booking) -> SavedCard? {
        guard let clientID = booking.clientID,
              let permission = readCardPermissions(clientID).first(where: { $0.creatorID == booking.creatorID })
        else { return nil }
        return readCards(clientID).first { $0.id == permission.cardID }
    }

    func cardAccess(bookingID: UUID, for userID: UUID) async throws -> CardAccess {
        guard let booking = readBookings().first(where: { $0.id == bookingID }) else { throw SlateError.bookingNotFound }
        let isClient = booking.clientID == userID
        guard isClient || providerAccess(userID, booking, .view) else { throw SlateError.bookingNotFound }
        guard let card = allowedCard(for: booking) else { return .none }
        return CardAccess(allowed: true, brand: card.brand, last4: isClient ? card.last4 : nil, expired: card.isExpired(at: now))
    }

    func chargeSavedCard(bookingID: UUID, by userID: UUID) async throws -> SavedCardCharge {
        try expireLapsedHolds()
        guard let booking = readBookings().first(where: { $0.id == bookingID }), providerAccess(userID, booking, .manage) else {
            throw SlateError.bookingNotFound
        }
        guard let clientID = booking.clientID, let card = allowedCard(for: booking) else { throw SlateError.noCardAccess }
        guard !card.isExpired(at: now) else { throw SlateError.cardExpired }

        // The amount, and whether the balance is payable yet, are the booking's: the same checks as any balance payment.
        let info = try await preparePayment(bookingID: bookingID, kind: .balance, by: clientID)
        try await completeSimulatedPayment(info.paymentID)
        return SavedCardCharge(paymentID: info.paymentID, status: .succeeded)
    }
}
