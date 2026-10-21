import XCTest
@testable import Slate

final class PackageRulesTests: XCTestCase {
    private func package(
        name: String = "Portrait session",
        price: Int = 20_000,
        deposit: Int = 5_000,
        duration: Int = 60,
        turnaround: Int = 7,
        deliverables: [String] = ["30 edited photos"],
        addOns: [AddOn] = []
    ) -> ServicePackage {
        ServicePackage(
            id: UUID(), creatorID: UUID(), name: name, summary: "", category: nil,
            priceCents: price, currencyCode: "USD", durationMinutes: duration,
            deliverables: deliverables, turnaroundDays: turnaround, depositCents: deposit,
            addOns: addOns, isPublished: true, position: 0, createdAt: Date(), updatedAt: Date()
        )
    }

    func testAValidPackageHasNoProblems() {
        XCTAssertEqual(PackageRules.problems(in: package()), [])
    }

    func testNameLength() {
        XCTAssertTrue(PackageRules.problems(in: package(name: "A")).contains(.nameLength))
        XCTAssertTrue(PackageRules.problems(in: package(name: "   ")).contains(.nameLength))
        XCTAssertTrue(PackageRules.problems(in: package(name: String(repeating: "x", count: 61))).contains(.nameLength))
        XCTAssertFalse(PackageRules.problems(in: package(name: "AB")).contains(.nameLength))
    }

    func testPriceMustBePositive() {
        XCTAssertTrue(PackageRules.problems(in: package(price: 0, deposit: 0)).contains(.priceInvalid))
        XCTAssertTrue(PackageRules.problems(in: package(price: -1, deposit: 0)).contains(.priceInvalid))
    }

    func testDepositCannotExceedPrice() {
        XCTAssertTrue(PackageRules.problems(in: package(price: 10_000, deposit: 10_001)).contains(.depositTooHigh))
        XCTAssertFalse(PackageRules.problems(in: package(price: 10_000, deposit: 10_000)).contains(.depositTooHigh))
        XCTAssertFalse(PackageRules.problems(in: package(price: 10_000, deposit: 0)).contains(.depositTooHigh))
    }

    func testDurationRangeAndStep() {
        XCTAssertTrue(PackageRules.problems(in: package(duration: 10)).contains(.durationInvalid))
        XCTAssertTrue(PackageRules.problems(in: package(duration: 50)).contains(.durationInvalid), "Not a multiple of 15")
        XCTAssertTrue(PackageRules.problems(in: package(duration: 1500)).contains(.durationInvalid))
        XCTAssertFalse(PackageRules.problems(in: package(duration: 15)).contains(.durationInvalid))
        XCTAssertFalse(PackageRules.problems(in: package(duration: 1440)).contains(.durationInvalid))
    }

    func testTurnaroundRange() {
        XCTAssertTrue(PackageRules.problems(in: package(turnaround: 0)).contains(.turnaroundInvalid))
        XCTAssertTrue(PackageRules.problems(in: package(turnaround: 91)).contains(.turnaroundInvalid))
        XCTAssertFalse(PackageRules.problems(in: package(turnaround: 90)).contains(.turnaroundInvalid))
    }

    func testDeliverableLimits() {
        let many = Array(repeating: "x", count: PackageRules.deliverableLimit + 1)
        XCTAssertTrue(PackageRules.problems(in: package(deliverables: many)).contains(.tooManyDeliverables))
        let long = [String(repeating: "x", count: PackageRules.deliverableLength + 1)]
        XCTAssertTrue(PackageRules.problems(in: package(deliverables: long)).contains(.deliverableTooLong))
    }

    func testAddOnRules() {
        XCTAssertTrue(PackageRules.problems(in: package(addOns: [AddOn(kind: .custom, name: "  ")])).contains(.addOnNameMissing))
        XCTAssertTrue(PackageRules.problems(in: package(addOns: [AddOn(kind: .drone, priceCents: -5)])).contains(.addOnPriceInvalid))
        XCTAssertTrue(PackageRules.problems(in: package(addOns: [AddOn(kind: .extraTime, extraMinutes: 600)])).contains(.addOnTimeInvalid))
        let tooMany = (0...PackageRules.addOnLimit).map { _ in AddOn(kind: .drone, priceCents: 100) }
        XCTAssertTrue(PackageRules.problems(in: package(addOns: tooMany)).contains(.tooManyAddOns))
        XCTAssertEqual(PackageRules.problems(in: package(addOns: [AddOn(kind: .drone, priceCents: 0)])), [], "A free add-on is allowed")
    }

    func testEveryProblemHasAMessage() {
        let problems: [PackageRules.Problem] = [
            .nameLength, .summaryTooLong, .priceInvalid, .durationInvalid, .turnaroundInvalid, .depositTooHigh,
            .tooManyDeliverables, .deliverableTooLong, .tooManyAddOns, .addOnNameMissing, .addOnPriceInvalid, .addOnTimeInvalid,
        ]
        for problem in problems { XCTAssertFalse(problem.message.isEmpty) }
    }
}

final class MoneyTests: XCTestCase {
    func testCentsFromDecimalRoundsToTheNearestCent() {
        XCTAssertEqual(Money.cents(from: Decimal(string: "19.99")!), 1999)
        XCTAssertEqual(Money.cents(from: Decimal(string: "2400")!), 240_000)
        XCTAssertEqual(Money.cents(from: Decimal(string: "24.995")!), 2500)
        XCTAssertEqual(Money.cents(from: Decimal(string: "0.004")!), 0)
        XCTAssertEqual(Money.cents(from: 0), 0)
    }

    func testDecimalAndCentsRoundTrip() {
        for cents in [0, 1, 99, 100, 1999, 240_000, 99_999_999] {
            XCTAssertEqual(Money.cents(from: Money.decimal(cents: cents)), cents)
        }
    }

    func testFormattingDropsZeroCentsOnlyForWholeAmounts() {
        let whole = Money.format(240_000, code: "USD")
        XCTAssertTrue(whole.contains("2,400") || whole.contains("2400"), whole)
        XCTAssertFalse(whole.contains(".00"), whole)
        let fraction = Money.format(240_050, code: "USD")
        XCTAssertTrue(fraction.contains("50"), fraction)
    }
}

final class TextHelpersTests: XCTestCase {
    func testTurnaroundWording() {
        XCTAssertEqual(DurationText.turnaround(days: 1), "1 day")
        XCTAssertEqual(DurationText.turnaround(days: 3), "3 days")
        XCTAssertEqual(DurationText.turnaround(days: 7), "1 week")
        XCTAssertEqual(DurationText.turnaround(days: 14), "2 weeks")
        XCTAssertEqual(DurationText.turnaround(days: 10), "10 days")
    }

    func testShortDurationIsNotEmpty() {
        for minutes in [15, 45, 60, 90, 120, 480] {
            XCTAssertFalse(DurationText.short(minutes: minutes).isEmpty)
        }
    }
}

final class PriceSummaryTests: XCTestCase {
    private func package(deposit: Int = 50_000) -> ServicePackage {
        var package = ServicePackage.sample
        package.priceCents = 200_000
        package.depositCents = deposit
        package.durationMinutes = 120
        package.turnaroundDays = 14
        package.addOns = [
            AddOn(kind: .extraTime, name: "Extra hour", priceCents: 15_000, extraMinutes: 60),
            AddOn(kind: .drone, name: "Drone footage", priceCents: 25_000, extraMinutes: 0),
            AddOn(kind: .rush, name: "Rush", priceCents: 10_000, extraMinutes: 0, turnaroundDeltaDays: -3),
        ]
        return package
    }

    func testPackageAloneUsesItsOwnPriceAndDeposit() {
        let summary = PriceSummary.make(package: package(), addOns: [])
        XCTAssertEqual(summary.totalCents, 200_000)
        XCTAssertEqual(summary.depositCents, 50_000)
        XCTAssertEqual(summary.balanceCents, 150_000)
        XCTAssertEqual(summary.durationMinutes, 120)
        XCTAssertEqual(summary.turnaroundDays, 14)
        XCTAssertEqual(summary.lines.count, 1)
    }

    func testAddOnsRaiseTheTotalButNotTheDeposit() {
        let p = package()
        let summary = PriceSummary.make(package: p, addOns: p.addOns)
        XCTAssertEqual(summary.totalCents, 200_000 + 15_000 + 25_000 + 10_000)
        XCTAssertEqual(summary.depositCents, 50_000, "Add-ons are settled in the balance")
        XCTAssertEqual(summary.balanceCents, summary.totalCents - 50_000)
        XCTAssertEqual(summary.lines.count, 4)
    }

    func testExtraTimeLengthensTheBookingAndRushShortensDelivery() {
        let p = package()
        let summary = PriceSummary.make(package: p, addOns: p.addOns)
        XCTAssertEqual(summary.durationMinutes, 180)
        XCTAssertEqual(summary.turnaroundDays, 11)
    }

    func testRushNeverGoesBelowOneDay() {
        var p = package()
        p.turnaroundDays = 2
        let rush = AddOn(kind: .rush, name: "Rush", priceCents: 1, turnaroundDeltaDays: -10)
        XCTAssertEqual(p.turnaroundDays(with: [rush]), 1)
    }

    func testDepositIsCappedAtTheTotal() {
        var p = package(deposit: 0)
        p.priceCents = 1_000
        p.depositCents = 1_000
        XCTAssertEqual(PriceSummary.make(package: p, addOns: []).depositCents, 1_000)
        p.depositCents = 5_000 // can't happen through the rules, but the summary must still be safe
        XCTAssertEqual(PriceSummary.make(package: p, addOns: []).depositCents, 1_000)
    }

    func testChosenAddOnsAreLookedUpByID() {
        let p = package()
        let ids: Set<UUID> = [p.addOns[0].id, p.addOns[2].id]
        XCTAssertEqual(p.addOns(withIDs: ids).map(\.name), ["Extra hour", "Rush"])
        XCTAssertTrue(p.addOns(withIDs: [UUID()]).isEmpty)
    }
}

@MainActor
final class PackageDraftTests: XCTestCase {
    func testNewPackageStartsEmptyAndInvalid() {
        var blank = ServicePackage.sample
        blank.name = ""
        blank.priceCents = 0
        blank.depositCents = 0
        blank.deliverables = []
        blank.addOns = []
        let draft = PackageDraft(package: blank)
        XCTAssertTrue(draft.isNew)
        XCTAssertFalse(draft.canSave)
        XCTAssertFalse(draft.hasContent)
    }

    func testPricingFlowsThroughToCents() {
        let draft = PackageDraft(package: .sample)
        draft.price = Decimal(string: "1999.99")
        draft.deposit = Decimal(string: "500")
        let made = draft.makePackage()
        XCTAssertEqual(made.priceCents, 199_999)
        XCTAssertEqual(made.depositCents, 50_000)
    }

    func testDepositPercentPresets() {
        let draft = PackageDraft(package: .sample)
        draft.price = 2000
        draft.setDeposit(percent: 25)
        XCTAssertEqual(draft.depositCents, 50_000)
        XCTAssertEqual(draft.depositPercent, 25)
        draft.setDeposit(percent: 100)
        XCTAssertEqual(draft.depositCents, 200_000)
        draft.setDeposit(percent: 0)
        XCTAssertEqual(draft.depositCents, 0)
        XCTAssertNil(draft.deposit)
    }

    func testDepositPresetsDoNothingWithoutAPrice() {
        let draft = PackageDraft(package: .sample)
        draft.price = nil
        draft.setDeposit(percent: 50)
        XCTAssertNil(draft.depositPercent)
    }

    func testBlankDeliverablesAndWhitespaceAreDropped() {
        let draft = PackageDraft(package: .sample)
        draft.deliverables = [DeliverableRow(text: "  Highlight film  "), DeliverableRow(text: "   "), DeliverableRow(text: "")]
        XCTAssertEqual(draft.makePackage().deliverables, ["Highlight film"])
    }

    func testDeliverableLimitStopsAdding() {
        let draft = PackageDraft(package: .sample)
        draft.deliverables = []
        for _ in 0..<(PackageRules.deliverableLimit + 3) { draft.addDeliverable() }
        XCTAssertEqual(draft.deliverables.count, PackageRules.deliverableLimit)
        XCTAssertFalse(draft.canAddDeliverable)
    }

    func testAddOnUpsertReplacesByID() {
        let draft = PackageDraft(package: .sample)
        var first = AddOn(kind: .drone, priceCents: 100)
        draft.addOns = []
        draft.upsert(first)
        first.priceCents = 250
        draft.upsert(first)
        XCTAssertEqual(draft.addOns.count, 1)
        XCTAssertEqual(draft.addOns[0].priceCents, 250)
    }

    func testUnchangedDraftHasNoChanges() {
        let draft = PackageDraft(package: .sample)
        XCTAssertFalse(draft.hasChanges)
        draft.name += "!"
        XCTAssertTrue(draft.hasChanges)
    }

    func testAddOnKindsComeWithSensibleDefaults() {
        XCTAssertEqual(AddOn(kind: .extraTime).extraMinutes, 60)
        XCTAssertEqual(AddOn(kind: .extraTime).name, "Extra hour")
        XCTAssertEqual(AddOn(kind: .drone).extraMinutes, 0)
        XCTAssertLessThan(AddOn(kind: .rush).turnaroundDeltaDays, 0)
        XCTAssertEqual(AddOn(kind: .custom).name, "")
    }
}
