import Foundation

// MARK: - Cards on file
//
// A client can keep cards at Stripe and allow a creator, by name, to charge one for the balance of a booking. The app never
// holds a card number: Stripe's page collects it. What the app knows of a card is what it shows ("Visa ending 4242,
// expires 08/28") and an id of its own. Stripe's reference to the card never reaches the phone.

/// The card networks Stripe names, in the words people use. Anything else is shown as "Card".
enum CardBrand: String, Codable, Hashable, CaseIterable {
    case visa, mastercard, amex, discover, diners, jcb, unionpay, other

    /// From Stripe's word for it ("visa", "amex", "diners", "cartes_bancaires"…).
    init(stripe name: String?) {
        switch name?.lowercased() {
        case "visa": self = .visa
        case "mastercard": self = .mastercard
        case "amex": self = .amex
        case "discover": self = .discover
        case "diners", "diners_club": self = .diners
        case "jcb": self = .jcb
        case "unionpay": self = .unionpay
        default: self = .other
        }
    }

    var title: String {
        switch self {
        case .visa: "Visa"
        case .mastercard: "Mastercard"
        case .amex: "American Express"
        case .discover: "Discover"
        case .diners: "Diners Club"
        case .jcb: "JCB"
        case .unionpay: "UnionPay"
        case .other: "Card"
        }
    }
}

/// One of the person's own cards. The app can show it and ask for it to be removed; it can't charge it.
struct SavedCard: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var brand: CardBrand
    var last4: String
    var expMonth: Int
    var expYear: Int
    var addedAt: Date

    /// "Visa ending 4242".
    var title: String { "\(brand.title) ending \(last4)" }

    /// "08/28".
    var expiryText: String { String(format: "%02d/%02d", expMonth, expYear % 100) }

    func isExpired(at date: Date) -> Bool {
        CardRules.isExpired(month: expMonth, year: expYear, at: date)
    }

    /// "Expires 08/28", or "Expired 08/28" once it has.
    func detail(at date: Date) -> String {
        isExpired(at: date) ? "Expired \(expiryText)" : "Expires \(expiryText)"
    }

    /// For VoiceOver, which reads "08/28" badly: "Visa ending 4242, expires August 2028".
    func accessibilitySummary(at date: Date) -> String {
        let months = Calendar(identifier: .gregorian).monthSymbols
        let month = months.indices.contains(expMonth - 1) ? months[expMonth - 1] : "\(expMonth)"
        return "\(title), \(isExpired(at: date) ? "expired" : "expires") \(month) \(expYear)"
    }
}

/// A creator the person has allowed to charge one of their cards for the balance of a booking.
struct CardPermission: Identifiable, Codable, Equatable, Hashable {
    /// The owner of the bookings: a person, or a company.
    var creatorID: UUID
    var creatorName: String
    var handle: String?
    var cardID: UUID
    var brand: CardBrand
    var last4: String
    var expMonth: Int
    var expYear: Int
    var allowedAt: Date

    var id: UUID { creatorID }

    var cardTitle: String { "\(brand.title) ending \(last4)" }

    func isExpired(at date: Date) -> Bool {
        CardRules.isExpired(month: expMonth, year: expYear, at: date)
    }
}

/// What one booking says about the saved-card permission, for whoever is looking. The client sees the card's last four
/// digits; the provider side sees only that a card is allowed, and its brand.
struct CardAccess: Equatable {
    var allowed: Bool
    var brand: CardBrand?
    var last4: String?
    var expired: Bool

    static let none = CardAccess(allowed: false, brand: nil, last4: nil, expired: false)

    /// "Visa ending 4242" for the client, "Visa" for the provider side.
    var cardTitle: String? {
        guard let brand else { return nil }
        return last4.map { "\(brand.title) ending \($0)" } ?? brand.title
    }
}

/// What starting to add a card leads to.
enum AddCardStep: Equatable {
    /// Added on the spot (always the case on-device, where the card is a pretend one).
    case added(SavedCard)
    /// Stripe's own page collects the card; open this address.
    case continueOnWeb(URL)
}

/// What a charge to a saved card answered. The money is recorded when Stripe says so, not by this.
struct SavedCardCharge: Equatable {
    enum Status: String, Equatable {
        /// Stripe took the payment. The booking updates when its webhook arrives.
        case succeeded
        /// The bank is still working on it.
        case processing
    }

    var paymentID: UUID
    var status: Status
}

// MARK: - Rules shared with the database

enum CardRules {
    /// Cards one person can keep. Mirrors `app_card_limit()` in SQL.
    static let maxCards = 5

    /// The version of the agreement wording (`CardConsent`). Mirrors `card_consent_version()` in SQL.
    static let consentVersion = 1

    /// A card works through the last day of its expiry month, in UTC. Mirrors `card_is_expired()` in SQL, and
    /// `SlateTests/Fixtures/card_rules.json` is checked by both.
    static func isExpired(month: Int, year: Int, at date: Date) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let now = calendar.dateComponents([.year, .month], from: date)
        guard let nowYear = now.year, let nowMonth = now.month else { return false }
        return year * 12 + month < nowYear * 12 + nowMonth
    }

    static func canAddAnother(to count: Int) -> Bool { count < maxCards }

    /// Newest first, with the cards that can't be used any more last.
    static func ordered(_ cards: [SavedCard], at date: Date) -> [SavedCard] {
        cards.sorted { lhs, rhs in
            let lhsUsable = !lhs.isExpired(at: date), rhsUsable = !rhs.isExpired(at: date)
            if lhsUsable != rhsUsable { return lhsUsable }
            return lhs.addedAt != rhs.addedAt ? lhs.addedAt > rhs.addedAt : lhs.id.uuidString < rhs.id.uuidString
        }
    }

    // MARK: Who could be allowed

    /// A creator the person has booked and could allow.
    struct Candidate: Identifiable, Equatable {
        var creatorID: UUID
        var name: String
        var lastBookingAt: Date
        var id: UUID { creatorID }
    }

    /// The creators this person could allow: ones they have an active booking with (held, confirmed or completed, as the
    /// database requires), who they haven't allowed yet. Most recent booking first, one row for each.
    static func candidates(bookings: [Booking], permissions: [CardPermission], userID: UUID, at date: Date) -> [Candidate] {
        let already = Set(permissions.map(\.creatorID))
        var latest: [UUID: Candidate] = [:]
        for booking in bookings where booking.clientID == userID && booking.creatorID != userID && !already.contains(booking.creatorID) {
            switch booking.effectiveStatus(at: date) {
            case .held, .confirmed, .completed: break
            case .cancelled, .expired: continue
            }
            let candidate = Candidate(creatorID: booking.creatorID, name: booking.creatorName, lastBookingAt: booking.startAt)
            if let seen = latest[booking.creatorID], seen.lastBookingAt >= candidate.lastBookingAt { continue }
            latest[booking.creatorID] = candidate
        }
        return latest.values.sorted {
            $0.lastBookingAt != $1.lastBookingAt ? $0.lastBookingAt > $1.lastBookingAt : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: What a booking offers

    /// What the provider side sees on a booking whose client has (or hasn't) allowed a saved card.
    enum ChargeState: Equatable {
        /// Nothing to show: no permission, or the booking's money is settled or cancelled.
        case hidden
        /// Allowed, but the balance isn't payable yet (the client hasn't confirmed their files).
        case waiting
        /// The balance is payable: the saved card can be charged.
        case ready
        /// The card has expired.
        case expired
    }

    static func chargeState(access: CardAccess, phase: PaymentSummary.Phase) -> ChargeState {
        guard access.allowed else { return .hidden }
        switch phase {
        case .holdExpired, .paidInFull, .cancelledUnpaid, .refundPending, .refunded, .refundFailed, .noRefund:
            return .hidden
        case .balanceDue:
            return access.expired ? .expired : .ready
        case .depositDue, .depositFailed, .depositPaid, .noDepositRequired, .awaitingConfirmation:
            return access.expired ? .expired : .waiting
        }
    }

    /// Whether to offer the client "let {creator} charge the balance to my card" on a booking: they have a usable card,
    /// haven't allowed this creator, and there is still a balance to come.
    static func shouldOfferToAllow(access: CardAccess, phase: PaymentSummary.Phase, hasUsableCard: Bool) -> Bool {
        guard hasUsableCard, !access.allowed else { return false }
        switch phase {
        case .depositDue, .depositFailed, .depositPaid, .noDepositRequired, .awaitingConfirmation, .balanceDue: return true
        case .holdExpired, .paidInFull, .cancelledUnpaid, .refundPending, .refunded, .refundFailed, .noRefund: return false
        }
    }
}

// MARK: - The agreement

/// The words a client agrees to when they allow a creator. Changing them means a new `CardRules.consentVersion`, here and
/// in SQL, because a permission is recorded against the version of the wording the person saw.
enum CardConsent {
    static var version: Int { CardRules.consentVersion }

    static func title(creator: String) -> String { "Let \(creator) charge your card?" }

    static func paragraphs(creator: String, card: SavedCard) -> [String] {
        [
            "\(creator) will be able to charge the remaining balance of your bookings with them to your \(card.title), once you've confirmed you have your files.",
            "They can't charge anything else, and they never see your card number.",
            "You can stop this at any time in Profile.",
        ]
    }

    static func button(creator: String) -> String { "Allow \(creator)" }
}
