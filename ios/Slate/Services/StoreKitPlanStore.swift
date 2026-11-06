import Foundation
import StoreKit

/// The real store: StoreKit 2, Apple's purchase sheet. It pays with Apple Pay, a card in Wallet or Apple Account balance,
/// and Slate Pro never sees a card.
///
/// Each purchase is made with the company's id as the "account token", which Apple signs into the purchase, so the server can
/// tell which company a purchase is for and refuses one made for another. A purchase stays unfinished until the server has
/// recorded it, so a payment is never lost to a dropped connection: Apple hands it back through `updates()`.
///
/// This has been built against Apple's documentation and run only with StoreKit's local test file (`Config/SlatePlans.storekit`)
/// and TestFlight; see `docs/APP_STORE.md` for trying it.
@MainActor
final class StoreKitPlanStore: PlanStore {
    /// Purchases made or delivered that the server hasn't confirmed yet, by transaction id.
    private var unfinished: [UInt64: Transaction] = [:]

    var canBuy: Bool { AppStore.canMakePayments }

    func listings(for offers: [PlanOffer]) async throws -> [PlanListing] {
        let products = try await Product.products(for: offers.map(\.productID))
        var listings: [PlanListing] = []
        for product in products {
            guard let offer = offers.first(where: { $0.productID == product.id }) else { continue }
            var trial: String?
            if let info = product.subscription, let intro = info.introductoryOffer, intro.paymentMode == .freeTrial {
                let eligible = await info.isEligibleForIntroOffer
                if eligible { trial = "\(Self.describe(intro.period)) free" }
            }
            listings.append(PlanListing(
                offer: offer, price: product.displayPrice,
                period: Self.unit(product.subscription?.subscriptionPeriod), trial: trial
            ))
        }
        return listings.sorted { $0.offer.seats < $1.offer.seats }
    }

    func purchase(_ offer: PlanOffer, forCompany id: UUID) async throws -> PurchaseOutcome {
        guard let product = try await Product.products(for: [offer.productID]).first else {
            throw SlateError.billingUnavailable
        }
        let result = try await product.purchase(options: [.appAccountToken(id)])
        switch result {
        case .success(let verification):
            guard case .verified(let transaction) = verification else {
                // Apple's own check of its signature on the device failed. Nothing was bought as far as we can tell.
                throw SlateError.planNotConfirmed
            }
            unfinished[transaction.id] = transaction
            return .purchased(SignedPurchase(
                transactionID: transaction.id, productID: transaction.productID,
                signedTransaction: verification.jwsRepresentation,
                signedRenewalInfo: await Self.renewalInfo(for: product),
                companyID: transaction.appAccountToken
            ))
        case .pending:
            return .pending
        case .userCancelled:
            return .cancelled
        @unknown default:
            return .cancelled
        }
    }

    func currentPurchases(for offers: [PlanOffer]) async -> [SignedPurchase] {
        let ids = Set(offers.map(\.productID))
        var found: [SignedPurchase] = []
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement,
                  ids.contains(transaction.productID), transaction.revocationDate == nil else { continue }
            found.append(SignedPurchase(
                transactionID: transaction.id, productID: transaction.productID,
                signedTransaction: entitlement.jwsRepresentation, signedRenewalInfo: nil,
                companyID: transaction.appAccountToken
            ))
        }
        return found
    }

    func restore() async throws {
        try await AppStore.sync()
    }

    func finish(_ purchase: SignedPurchase) async {
        if let transaction = unfinished.removeValue(forKey: purchase.transactionID) {
            await transaction.finish()
        }
    }

    func updates() -> AsyncStream<SignedPurchase> {
        AsyncStream { continuation in
            let listener = Task { [weak self] in
                for await update in Transaction.updates {
                    guard case .verified(let transaction) = update else { continue }
                    self?.unfinished[transaction.id] = transaction
                    continuation.yield(SignedPurchase(
                        transactionID: transaction.id, productID: transaction.productID,
                        signedTransaction: update.jwsRepresentation, signedRenewalInfo: nil,
                        companyID: transaction.appAccountToken
                    ))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in listener.cancel() }
        }
    }

    // MARK: Words

    /// Apple's signed word on whether the subscription renews, when it can be had.
    private static func renewalInfo(for product: Product) async -> String? {
        guard let statuses = try? await product.subscription?.status, let status = statuses.first else { return nil }
        return status.renewalInfo.jwsRepresentation
    }

    static func describe(_ period: Product.SubscriptionPeriod) -> String {
        let count = period.value
        switch period.unit {
        case .day: return count == 1 ? "1 day" : "\(count) days"
        case .week: return count == 1 ? "1 week" : "\(count) weeks"
        case .month: return count == 1 ? "1 month" : "\(count) months"
        case .year: return count == 1 ? "1 year" : "\(count) years"
        @unknown default: return "\(count)"
        }
    }

    static func unit(_ period: Product.SubscriptionPeriod?) -> String {
        guard let period else { return "month" }
        switch period.unit {
        case .day: return "day"
        case .week: return "week"
        case .month: return "month"
        case .year: return "year"
        @unknown default: return "month"
        }
    }
}
