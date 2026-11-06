import Foundation

/// The company plan, bought with Apple's purchase sheet. See `PlanPurchaser` for the order things happen in (Apple takes the
/// money, the server hears what Apple signed, only then is the purchase finished) and SPEC D6 and D7 for what a plan is.
extension AppModel {
    /// The steps on offer, smallest first.
    var planOffers: [PlanOffer] { PlanRules.ordered(teamConfig.plans) }

    /// Only the Owner buys and manages the company's plan.
    var canBuyPlan: Bool { organization?.can(.billingManage) == true }

    /// True right after a company is made, while it has no working plan: the plan sheet is offered. Never in on-device mode,
    /// where no plan is needed, and never to someone who can't buy.
    var shouldOfferPlan: Bool {
        guard let plan = organization?.plan else { return false }
        return plan.required && !plan.isOK && canBuyPlan && planStore.canBuy
    }

    /// The steps with the price and free trial Apple will show this person.
    func loadPlanListings() async throws -> [PlanListing] {
        try await planStore.listings(for: planOffers)
    }

    /// Buys `offer` for the company on screen. Returns once the server has recorded it (or the person backed out, or it is
    /// waiting for approval). On an error the purchase, if Apple took the money, is kept and sent again later.
    func buyPlan(_ offer: PlanOffer) async throws -> PlanPurchaser.Outcome {
        guard let company = activeAccount.companyID else { throw SlateError.notFound }
        let outcome = try await purchaser.buy(offer, forCompany: company)
        if outcome == .recorded { await reloadCompany() }
        return outcome
    }

    /// Restore Purchases: asks the App Store to look again, sends the server what this Apple Account holds for the company
    /// on screen, and says whether the company has a working plan after that.
    func restorePlan() async throws -> Bool {
        guard let company = activeAccount.companyID else { throw SlateError.notFound }
        try await planStore.restore()
        let held = await planStore.currentPurchases(for: planOffers)
        await purchaser.send(held, forCompany: company)
        await reloadCompany()
        return organization?.plan.isOK == true
    }

    /// Quietly sends the server what this Apple Account holds for the company on screen, when billing opens. This is how a
    /// renewal is noticed even if Apple's message to the server went astray.
    func syncPlanWithStore() async {
        guard let company = activeAccount.companyID, canBuyPlan, !isLocalBackend else { return }
        let held = await planStore.currentPurchases(for: planOffers)
        if await purchaser.send(held, forCompany: company) > 0 { await reloadCompany() }
    }

    // MARK: Purchases that arrive on their own

    func startListeningForPurchases() {
        guard purchaseListener == nil, !isLocalBackend else { return }
        let store = planStore
        purchaseListener = Task { [weak self] in
            for await purchase in store.updates() {
                guard let self else { return }
                await self.accept(update: purchase)
            }
        }
    }

    func stopListeningForPurchases() {
        purchaseListener?.cancel()
        purchaseListener = nil
    }

    /// A renewal, or a purchase that was waiting, arrived. If it is for one of this person's companies it goes to the server;
    /// if the server can't take it now it stays unfinished and Apple hands it back on the next launch.
    private func accept(update purchase: SignedPurchase) async {
        guard session != nil, let company = purchase.companyID, accounts.companies.contains(where: { $0.id == company }) else { return }
        do {
            try await sendPurchase(purchase)
            await planStore.finish(purchase)
            if company == activeAccount.companyID { await reloadCompany() }
        } catch {
            return
        }
    }

    private var purchaser: PlanPurchaser {
        PlanPurchaser(store: planStore) { [weak self] purchase in try await self?.sendPurchase(purchase) }
    }

    private func sendPurchase(_ purchase: SignedPurchase) async throws {
        guard let session else { throw SlateError.notSignedIn }
        guard let company = purchase.companyID ?? activeAccount.companyID else { throw SlateError.notFound }
        try await backend.recordApplePurchase(purchase, organizationID: company, by: session.userID)
    }
}
