import XCTest
@testable import Slate

// MARK: - A store that sells what a test tells it to

@MainActor
final class FakePlanStore: PlanStore {
    var canBuy = true
    var outcome: PurchaseOutcome = .cancelled
    var purchaseError: Error?
    var held: [SignedPurchase] = []
    var restoreError: Error?
    /// What happened, in order: "buy", "finish", "restore".
    private(set) var events: [String] = []
    private(set) var bought: [(offer: PlanOffer, company: UUID)] = []
    private(set) var finished: [UInt64] = []

    func listings(for offers: [PlanOffer]) async throws -> [PlanListing] {
        offers.map { PlanListing(offer: $0, price: "$\($0.seats)", period: "month", trial: nil) }
    }

    func purchase(_ offer: PlanOffer, forCompany id: UUID) async throws -> PurchaseOutcome {
        events.append("buy")
        bought.append((offer, id))
        if let purchaseError { throw purchaseError }
        return outcome
    }

    func currentPurchases(for offers: [PlanOffer]) async -> [SignedPurchase] { held }

    func restore() async throws {
        events.append("restore")
        if let restoreError { throw restoreError }
    }

    func finish(_ purchase: SignedPurchase) async {
        events.append("finish")
        finished.append(purchase.transactionID)
    }

    func updates() -> AsyncStream<SignedPurchase> { AsyncStream { $0.finish() } }
}

private func purchase(_ id: UInt64, company: UUID?, product: String = "com.slateproapp.app.company.team5") -> SignedPurchase {
    SignedPurchase(transactionID: id, productID: product, signedTransaction: "jws-\(id)", signedRenewalInfo: nil, companyID: company)
}

// MARK: - Which step fits a team

final class PlanRulesTests: XCTestCase {
    private let offers = PlanOffer.standard

    func testTheStepsAreFiveToTwentyFiveInFives() {
        XCTAssertEqual(offers.map(\.seats), [5, 10, 15, 20, 25])
        XCTAssertEqual(offers.map(\.productID).first, "com.slateproapp.app.company.team5")
        XCTAssertEqual(Set(offers.map(\.productID)).count, offers.count, "Every step is its own product")
    }

    func testTheSmallestStepThatCoversTheTeam() {
        XCTAssertEqual(PlanRules.smallest(covering: 1, in: offers)?.seats, 5)
        XCTAssertEqual(PlanRules.smallest(covering: 5, in: offers)?.seats, 5)
        XCTAssertEqual(PlanRules.smallest(covering: 6, in: offers)?.seats, 10)
        XCTAssertEqual(PlanRules.smallest(covering: 25, in: offers)?.seats, 25)
        XCTAssertNil(PlanRules.smallest(covering: 26, in: offers), "Nothing covers more than the biggest step")
    }

    func testStepsAboveWhatTheCompanyHas() {
        XCTAssertEqual(PlanRules.steps(above: 5, in: offers).map(\.seats), [10, 15, 20, 25])
        XCTAssertEqual(PlanRules.steps(above: 0, in: offers).map(\.seats), [5, 10, 15, 20, 25])
        XCTAssertEqual(PlanRules.steps(above: 25, in: offers), [])
    }

    func testOffersAreOrderedWhateverOrderTheyArriveIn() {
        let shuffled = [offers[3], offers[0], offers[4], offers[1], offers[2]]
        XCTAssertEqual(PlanRules.ordered(shuffled).map(\.seats), [5, 10, 15, 20, 25])
        XCTAssertEqual(PlanRules.smallest(covering: 11, in: shuffled)?.seats, 15)
    }

    func testTheStepToSuggestIsAlwaysBiggerThanWhatTheCompanyHas() {
        XCTAssertEqual(PlanRules.suggestion(people: 3, covered: nil, in: offers)?.seats, 5, "No plan yet: the first step that fits")
        XCTAssertEqual(PlanRules.suggestion(people: 5, covered: 5, in: offers)?.seats, 10, "Full: the next step")
        XCTAssertEqual(PlanRules.suggestion(people: 5, covered: 10, in: offers)?.seats, 15, "Never smaller than what it has")
        XCTAssertEqual(PlanRules.suggestion(people: 12, covered: 5, in: offers)?.seats, 15, "A team over its plan skips to one that fits")
        XCTAssertNil(PlanRules.suggestion(people: 25, covered: 25, in: offers))
    }

    func testAProductIsFoundById() {
        XCTAssertEqual(PlanRules.offer(forProduct: "com.slateproapp.app.company.team15", in: offers)?.seats, 15)
        XCTAssertNil(PlanRules.offer(forProduct: "com.example.other", in: offers))
    }

    func testACompanyIsFullWhenMembersAndInvitesFillThePlan() {
        func counts(used: Int, pending: Int) -> SeatCounts { SeatCounts(used: used, pending: pending, billed: 5, minimum: 5, maximum: 5) }
        XCTAssertTrue(PlanRules.isFull(counts(used: 5, pending: 0)))
        XCTAssertTrue(PlanRules.isFull(counts(used: 4, pending: 1)), "An open invite takes a place")
        XCTAssertTrue(PlanRules.isFull(counts(used: 7, pending: 0)), "Over its limit is full too")
        XCTAssertFalse(PlanRules.isFull(counts(used: 3, pending: 1)))
    }

    func testTheStepsTheAppShipsWithAreTheOnesTheDatabaseShipsWith() throws {
        // Reads the migration: a step added in one place and not the other would offer people something that can't be recorded.
        let migration = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("supabase/migrations/20261107000000_apple_plans.sql")
        guard let text = try? String(contentsOf: migration, encoding: .utf8) else {
            throw XCTSkip("The migrations are not next to the tests (this runs from a checkout)")
        }
        for offer in offers {
            let pattern = "\\('\(NSRegularExpression.escapedPattern(for: offer.productID))',\\s*\(offer.seats),"
            XCTAssertNotNil(text.range(of: pattern, options: .regularExpression),
                            "\(offer.productID) should cover \(offer.seats) people in apple_plans")
        }
    }
}

// MARK: - Buying

@MainActor
final class PlanPurchaserTests: XCTestCase {
    private let company = UUID()
    private let other = UUID()
    private let offer = PlanOffer.standard[0]

    private struct Refused: Error {}

    private func purchaser(_ store: FakePlanStore, record: @escaping (SignedPurchase) async throws -> Void) -> PlanPurchaser {
        PlanPurchaser(store: store, record: record)
    }

    func testAPurchaseIsPaidThenRecordedThenFinished() async throws {
        let store = FakePlanStore()
        store.outcome = .purchased(purchase(1, company: company))
        var log: [String] = []
        let buyer = purchaser(store) { _ in log.append("record") }
        let outcome = try await buyer.buy(offer, forCompany: company)
        XCTAssertEqual(outcome, .recorded)
        XCTAssertEqual(store.events, ["buy", "finish"])
        XCTAssertEqual(log, ["record"])
        XCTAssertEqual(store.bought.first?.company, company, "The purchase is tied to the company")
        XCTAssertEqual(store.bought.first?.offer, offer)
        XCTAssertEqual(store.finished, [1])
    }

    func testFinishingWaitsForTheServer() async throws {
        let store = FakePlanStore()
        store.outcome = .purchased(purchase(1, company: company))
        var finishedWhenRecording: [UInt64]?
        let buyer = purchaser(store) { _ in finishedWhenRecording = store.finished }
        _ = try await buyer.buy(offer, forCompany: company)
        XCTAssertEqual(finishedWhenRecording, [], "Nothing is finished before the server has the purchase")
    }

    func testAPurchaseTheServerRefusesIsLeftUnfinishedSoApplePassesItBack() async {
        let store = FakePlanStore()
        store.outcome = .purchased(purchase(1, company: company))
        let buyer = purchaser(store) { _ in throw Refused() }
        do {
            _ = try await buyer.buy(offer, forCompany: company)
            XCTFail("The error should reach the caller")
        } catch {
            XCTAssertTrue(error is Refused)
        }
        XCTAssertEqual(store.finished, [], "A payment that wasn't recorded must not be finished")
    }

    func testBackingOutAndWaitingForApprovalRecordNothing() async throws {
        let store = FakePlanStore()
        var recorded = 0
        let buyer = purchaser(store) { _ in recorded += 1 }
        store.outcome = .cancelled
        let cancelled = try await buyer.buy(offer, forCompany: company)
        XCTAssertEqual(cancelled, .cancelled)
        store.outcome = .pending
        let pending = try await buyer.buy(offer, forCompany: company)
        XCTAssertEqual(pending, .pending)
        XCTAssertEqual(recorded, 0)
        XCTAssertEqual(store.finished, [])
    }

    func testAStoreFailureReachesTheCaller() async {
        let store = FakePlanStore()
        store.purchaseError = SlateError.billingUnavailable
        let buyer = purchaser(store) { _ in XCTFail("Nothing was bought") }
        do {
            _ = try await buyer.buy(offer, forCompany: company)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? SlateError, .billingUnavailable)
        }
    }

    func testSendingOnlyTakesThisCompanysPurchases() async {
        let store = FakePlanStore()
        var sent: [UInt64] = []
        let buyer = purchaser(store) { sent.append($0.transactionID) }
        let taken = await buyer.send(
            [purchase(1, company: company), purchase(2, company: other), purchase(3, company: nil)], forCompany: company
        )
        XCTAssertEqual(taken, 2)
        XCTAssertEqual(sent, [1, 3], "Another company's purchase isn't sent as this one's")
        XCTAssertEqual(store.finished, [1, 3])
    }

    func testSendingKeepsGoingPastOneThatFailsAndLeavesItUnfinished() async {
        let store = FakePlanStore()
        let buyer = purchaser(store) { if $0.transactionID == 1 { throw Refused() } }
        let taken = await buyer.send([purchase(1, company: company), purchase(2, company: company)], forCompany: company)
        XCTAssertEqual(taken, 1)
        XCTAssertEqual(store.finished, [2])
    }

    func testAStoreThatSellsNothingSaysSo() async {
        let store = InertPlanStore()
        XCTAssertFalse(store.canBuy)
        do {
            _ = try await store.listings(for: PlanOffer.standard)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? SlateError, .billingUnavailable)
        }
        let held = await store.currentPurchases(for: PlanOffer.standard)
        XCTAssertTrue(held.isEmpty)
    }

    // MARK: What the server answered

    func testTheServersAnswerBecomesSomethingAPersonCanActOn() {
        XCTAssertEqual(SupabaseBackend.mapPurchaseFailure(status: 404, body: #"{"error":"not_found"}"#), .notAllowed)
        XCTAssertEqual(SupabaseBackend.mapPurchaseFailure(status: 409, body: #"{"error":"plan_exists"}"#), .planAlreadyUsed)
        XCTAssertEqual(SupabaseBackend.mapPurchaseFailure(status: 409, body: #"{"error":"transaction_in_use"}"#), .planAlreadyUsed)
        for body in [#"{"error":"invalid_transaction"}"#, #"{"error":"wrong_company"}"#, #"{"error":"unknown_product"}"#,
                     #"{"error":"apple_not_configured"}"#, #"{"error":"server_error"}"#, ""] {
            XCTAssertEqual(SupabaseBackend.mapPurchaseFailure(status: 400, body: body), .planNotConfirmed,
                           "Apple took the money, so this is never a plain failure: \(body)")
        }
    }
}

// MARK: - The app's side, against the on-device backend

@MainActor
final class CompanyPlanAppModelTests: XCTestCase {
    private var root: URL!
    private var backend: LocalBackend!
    private var store: FakePlanStore!
    private var model: AppModel!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("slate-plan-app-\(UUID().uuidString)")
        backend = LocalBackend(root: root)
        store = FakePlanStore()
        model = AppModel(backend: backend, planStore: store)
        await model.signInAsDemo()
        let draft = ProfileDraft()
        draft.displayName = "Maya Chen"
        draft.handle = "mayachen"
        draft.specialties = [.weddings]
        try await model.completeOnboarding(draft: draft, portfolio: [])
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    private func makeCompany() async throws -> Organization {
        try await model.createCompany(
            OrganizationDraft(name: "Northlight Films", handle: "northlight", legalName: "Northlight Films LLC",
                              legalAddress: "410 Congress Ave, Austin", bio: "", specialties: [.weddings]),
            location: nil, avatarJPEG: nil
        )
    }

    func testTheStepsOnOfferComeFromTheConfigSmallestFirst() {
        XCTAssertEqual(model.planOffers.map(\.seats), [5, 10, 15, 20, 25])
        XCTAssertEqual(TeamConfig.standard.seatMinimum, model.planOffers.first?.seats, "The smallest plan covers the minimum team")
    }

    func testTheOwnerBuysThePlan() async throws {
        XCTAssertFalse(model.canBuyPlan, "No company yet")
        _ = try await makeCompany()
        XCTAssertTrue(model.canBuyPlan)
    }

    func testBuyingForACompanyThatDoesNotExistIsRefused() async {
        do {
            _ = try await model.buyPlan(PlanOffer.standard[0])
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? SlateError, .notFound)
        }
        XCTAssertEqual(store.events, [], "Nothing was bought")
    }

    func testAPurchaseTheOnDeviceBackendCannotRecordIsNotFinished() async throws {
        let company = try await makeCompany()
        store.outcome = .purchased(purchase(7, company: company.id))
        do {
            _ = try await model.buyPlan(PlanOffer.standard[0])
            XCTFail("On-device mode has no server to record a plan")
        } catch {
            XCTAssertEqual(error as? SlateError, .billingUnavailable)
        }
        XCTAssertEqual(store.bought.first?.company, company.id)
        XCTAssertEqual(store.finished, [], "A payment nobody recorded stays open")
    }

    func testBackingOutOfThePurchaseChangesNothing() async throws {
        _ = try await makeCompany()
        store.outcome = .cancelled
        let outcome = try await model.buyPlan(PlanOffer.standard[0])
        XCTAssertEqual(outcome, .cancelled)
    }

    func testListingsComeFromTheStoreForTheStepsOnOffer() async throws {
        let listings = try await model.loadPlanListings()
        XCTAssertEqual(listings.map(\.offer.seats), [5, 10, 15, 20, 25])
    }

    func testOnDeviceModeNeverQuietlySyncsOrListens() async throws {
        _ = try await makeCompany()
        store.held = [purchase(9, company: model.activeAccount.companyID)]
        await model.syncPlanWithStore()
        XCTAssertEqual(store.finished, [], "There is no server to tell")
        model.startListeningForPurchases()
        XCTAssertNil(model.purchaseListener)
    }
}
