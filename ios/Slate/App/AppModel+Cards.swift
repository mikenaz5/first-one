import Foundation

/// Cards on file: the person's own cards, the creators they have allowed to charge one, and a creator's charge of a booking's
/// balance to a card the client allowed. The app only asks; the backend decides (see `SlateBackend` and
/// `…_cards_on_file.sql`), and what was paid is recorded when Stripe says so.
extension AppModel {
    // MARK: - What to show

    /// Cards that haven't passed their expiry month.
    var usableCards: [SavedCard] { cards.filter { !$0.isExpired(at: clock()) } }

    var canAddCard: Bool { CardRules.canAddAnother(to: cards.count) }

    /// Cards in the order to show them: usable ones first, newest first.
    var orderedCards: [SavedCard] { CardRules.ordered(cards, at: clock()) }

    /// The creators this person has booked and could allow to charge a card.
    var creatorsToAllow: [CardRules.Candidate] {
        guard let userID = session?.userID else { return [] }
        return CardRules.candidates(bookings: bookings, permissions: cardPermissions, userID: userID, at: clock())
    }

    // MARK: - Loading

    /// Fetches the person's cards and who they have allowed. Returns a sentence to show if it couldn't.
    @discardableResult
    func loadCards() async -> String? {
        guard let session else { return nil }
        do {
            async let latestCards = backend.loadCards(for: session.userID)
            async let latestPermissions = backend.loadCardPermissions(for: session.userID)
            let (loadedCards, loadedPermissions) = try await (latestCards, latestPermissions)
            cards = loadedCards
            cardPermissions = loadedPermissions
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Compares with Stripe: used when the cards screen opens and when the person comes back from Stripe's page, because the
    /// notice from Stripe may be a moment behind. Quiet when it can't, since what is on screen is still right.
    func syncCards() async {
        guard let session else { return }
        if let latest = try? await backend.syncCards(for: session.userID) { cards = latest }
        if let latest = try? await backend.loadCardPermissions(for: session.userID) { cardPermissions = latest }
    }

    /// `slate://cards/…`: back from the page where a card is typed.
    func cardsReturned() async {
        await syncCards()
    }

    // MARK: - Adding and removing

    /// Starts adding a card. Returns the address of Stripe's page to open, or nil when the card was added on the spot
    /// (on-device, where it is a pretend one) or couldn't be (an alert says why).
    func beginAddingCard() async -> URL? {
        guard let session else { return nil }
        do {
            switch try await backend.beginAddingCard(for: session.userID) {
            case .added:
                await loadCards()
                return nil
            case .continueOnWeb(let url):
                return url
            }
        } catch {
            show(error, title: "Couldn't add a card")
            return nil
        }
    }

    /// Removes a card, and with it every permission that used it. True when it is gone.
    @discardableResult
    func removeCard(_ card: SavedCard) async -> Bool {
        guard let session else { return false }
        do {
            try await backend.removeCard(card.id, for: session.userID)
            await loadCards()
            return true
        } catch {
            show(error, title: "Couldn't remove the card")
            return false
        }
    }

    // MARK: - Allowing a creator

    /// Allows a creator the person has booked to charge the balance of their bookings to this card. True when it is done.
    @discardableResult
    func allowCreator(_ creatorID: UUID, with card: SavedCard) async -> Bool {
        guard let session else { return false }
        do {
            try await backend.allowCreator(creatorID, cardID: card.id, consentVersion: CardConsent.version, for: session.userID)
            await loadCards()
            return true
        } catch {
            show(error, title: "Couldn't allow them")
            return false
        }
    }

    /// Stops a creator charging the card, at once. True when it is done.
    @discardableResult
    func stopAllowing(_ permission: CardPermission) async -> Bool {
        guard let session else { return false }
        do {
            try await backend.stopAllowingCreator(permission.creatorID, for: session.userID)
            await loadCards()
            return true
        } catch {
            show(error, title: "Couldn't stop it")
            return false
        }
    }

    // MARK: - On a booking

    /// What a booking says about a saved-card permission to the person looking: the client sees the card they chose, the
    /// provider side sees only that one is allowed. Nothing when it can't be asked.
    func cardAccess(for booking: Booking) async -> CardAccess {
        guard let session else { return .none }
        return (try? await backend.cardAccess(bookingID: booking.id, for: session.userID)) ?? .none
    }

    /// Fetches what a booking says about a saved-card permission, and, for its client, their cards (so the screen can offer
    /// to allow the creator).
    func refreshCardAccess(for booking: Booking) async {
        guard let session else { return }
        if booking.clientID == session.userID, cards.isEmpty { await loadCards() }
        cardAccessByBooking[booking.id] = await cardAccess(for: booking)
    }

    /// A creator charges the balance of a booking to the card its client allowed. Waits for the money to be recorded, as
    /// any payment does. The amount is the booking's: nothing here chooses it.
    @discardableResult
    func chargeSavedCard(for booking: Booking) async -> PaymentOutcome {
        guard let session, !isPaying else { return .cancelled }
        isPaying = true
        defer { isPaying = false }
        do {
            _ = try await backend.chargeSavedCard(bookingID: booking.id, by: session.userID)
            guard await waitForPayment(bookingID: booking.id, kind: .balance) else { return .processing }
            return .confirmed
        } catch {
            await reloadMoney()
            return .failed(error.localizedDescription)
        }
    }
}
