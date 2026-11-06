import Foundation

// MARK: - The plan on offer

/// One step of the company plan: a subscription product in App Store Connect and the number of people it covers.
/// Apple's subscriptions can't be bought by quantity, so a bigger team buys a bigger step (SPEC D6, D7). The database holds
/// the real list (`apple_plans`) and the app asks for it, so a step can be added or changed without a new release (the
/// price and the free trial are set in App Store Connect, never here).
struct PlanOffer: Codable, Equatable, Hashable, Identifiable {
    var productID: String
    /// How many people a company on this step can have, counting open invites.
    var seats: Int

    var id: String { productID }

    /// The steps the database ships with. Used on a device with no server, and until the app has asked.
    static let standard: [PlanOffer] = [5, 10, 15, 20, 25].map {
        PlanOffer(productID: "com.slateproapp.app.company.team\($0)", seats: $0)
    }
}

/// Which step fits a team. Pure, so it is tested without a store or a screen.
enum PlanRules {
    /// Smallest first.
    static func ordered(_ offers: [PlanOffer]) -> [PlanOffer] {
        offers.sorted { $0.seats < $1.seats }
    }

    /// The smallest step that covers this many people, or nil when even the biggest doesn't.
    static func smallest(covering people: Int, in offers: [PlanOffer]) -> PlanOffer? {
        ordered(offers).first { $0.seats >= people }
    }

    /// Steps that cover more people than `seats`, smallest first.
    static func steps(above seats: Int, in offers: [PlanOffer]) -> [PlanOffer] {
        ordered(offers).filter { $0.seats > seats }
    }

    static func offer(forProduct productID: String, in offers: [PlanOffer]) -> PlanOffer? {
        offers.first { $0.productID == productID }
    }

    /// The step to suggest for a company with `people` on it (members and open invites) that wants room for one more,
    /// and that already has a plan covering `covered` people (nil if it has none). Never smaller than what it has.
    static func suggestion(people: Int, covered: Int?, in offers: [PlanOffer]) -> PlanOffer? {
        smallest(covering: max(people, covered ?? 0) + 1, in: offers)
    }

    /// True when no one more fits the plan the company is on.
    static func isFull(_ seats: SeatCounts) -> Bool { seats.remaining == 0 }
}

// MARK: - The store

/// What the store says about one step: the price as the person will see it, and the free trial if they would get one.
struct PlanListing: Equatable, Identifiable {
    var offer: PlanOffer
    /// Apple's formatted price, such as "$5.99".
    var price: String
    /// "month", "year"...
    var period: String
    /// Such as "1 week free", only for an Apple Account that is eligible for the introductory offer.
    var trial: String?

    var id: String { offer.productID }
}

/// A purchase exactly as Apple signed it. The app never decides what it means: the server checks Apple's signature and
/// records the plan, and only then does the company have one.
struct SignedPurchase: Equatable {
    var transactionID: UInt64
    var productID: String
    var signedTransaction: String
    /// Apple's signed word on whether it renews, when it is to hand.
    var signedRenewalInfo: String?
    /// The company the purchase was made for: the id the app put on it, which Apple signs in.
    var companyID: UUID?
}

enum PurchaseOutcome: Equatable {
    case purchased(SignedPurchase)
    /// Waiting for someone else to approve it (Ask to Buy) or for the bank.
    case pending
    case cancelled
}

/// Where plans are bought. The real one is StoreKit (`StoreKitPlanStore`); tests and previews use a stand-in.
@MainActor
protocol PlanStore {
    /// False when this device can't buy things (restricted, or a stand-in).
    var canBuy: Bool { get }
    /// The steps the store knows, with price and trial, smallest first.
    func listings(for offers: [PlanOffer]) async throws -> [PlanListing]
    /// Starts the purchase with Apple's own sheet, tied to the company by its id.
    func purchase(_ offer: PlanOffer, forCompany id: UUID) async throws -> PurchaseOutcome
    /// The subscriptions this Apple Account holds now, for the given steps.
    func currentPurchases(for offers: [PlanOffer]) async -> [SignedPurchase]
    /// Asks the App Store to look again (Restore Purchases).
    func restore() async throws
    /// Tells Apple the purchase has been dealt with. Until then Apple keeps handing it back.
    func finish(_ purchase: SignedPurchase) async
    /// Purchases that arrive on their own: a renewal, one made on another device, one that was waiting for approval.
    func updates() -> AsyncStream<SignedPurchase>
}

/// A store that sells nothing: on-device mode, previews and tests that don't care.
@MainActor
struct InertPlanStore: PlanStore {
    var canBuy: Bool { false }
    func listings(for offers: [PlanOffer]) async throws -> [PlanListing] { throw SlateError.billingUnavailable }
    func purchase(_ offer: PlanOffer, forCompany id: UUID) async throws -> PurchaseOutcome { throw SlateError.billingUnavailable }
    func currentPurchases(for offers: [PlanOffer]) async -> [SignedPurchase] { [] }
    func restore() async throws {}
    func finish(_ purchase: SignedPurchase) async {}
    func updates() -> AsyncStream<SignedPurchase> { AsyncStream { $0.finish() } }
}

// MARK: - Buying, in the order that never loses a payment

/// Apple takes the money, then the server hears what Apple signed, and only then is the purchase finished. If the server
/// can't be reached, the purchase is left unfinished, so Apple hands it back (through `updates()` and the next launch) and
/// it is sent again, instead of a company that paid being left without a plan.
@MainActor
struct PlanPurchaser {
    enum Outcome: Equatable {
        /// Bought and recorded.
        case recorded
        case pending
        case cancelled
    }

    let store: any PlanStore
    /// Hands one purchase to the server. Throws if the server doesn't accept it.
    let record: (SignedPurchase) async throws -> Void

    func buy(_ offer: PlanOffer, forCompany id: UUID) async throws -> Outcome {
        switch try await store.purchase(offer, forCompany: id) {
        case .purchased(let purchase):
            try await record(purchase)
            await store.finish(purchase)
            return .recorded
        case .pending:
            return .pending
        case .cancelled:
            return .cancelled
        }
    }

    /// Sends the server every purchase in `purchases` that belongs to this company (or names none, which is only the case
    /// for one made before the company id was put on purchases). Returns how many the server took.
    @discardableResult
    func send(_ purchases: [SignedPurchase], forCompany id: UUID) async -> Int {
        var taken = 0
        for purchase in purchases where purchase.companyID == nil || purchase.companyID == id {
            do {
                try await record(purchase)
                await store.finish(purchase)
                taken += 1
            } catch {
                continue
            }
        }
        return taken
    }
}
