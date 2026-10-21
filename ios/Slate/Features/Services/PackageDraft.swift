import Foundation
import Observation

struct DeliverableRow: Identifiable, Equatable {
    let id = UUID()
    var text: String
}

/// Editable copy of a package for the form. Money is held as `Decimal` so the currency text
/// field can edit it directly, and converted to whole cents on save.
@MainActor
@Observable
final class PackageDraft {
    /// Common deposit shares offered as one-tap presets.
    static let depositPercentOptions = [0, 25, 30, 50, 100]
    static let durationPresets = [60, 120, 240, 480]
    static let turnaroundPresets = [1, 2, 3, 5, 7, 10, 14, 21, 30, 45, 60, 90]

    let original: ServicePackage

    var name: String
    var summary: String
    var category: Specialty?
    var price: Decimal?
    var deposit: Decimal?
    var durationMinutes: Int
    var turnaroundDays: Int
    var deliverables: [DeliverableRow]
    var addOns: [AddOn]
    var isPublished: Bool

    init(package: ServicePackage) {
        original = package
        name = package.name
        summary = package.summary
        category = package.category
        price = package.priceCents > 0 ? Money.decimal(cents: package.priceCents) : nil
        deposit = package.depositCents > 0 ? Money.decimal(cents: package.depositCents) : nil
        durationMinutes = package.durationMinutes
        turnaroundDays = package.turnaroundDays
        deliverables = package.deliverables.map { DeliverableRow(text: $0) }
        addOns = package.addOns
        isPublished = package.isPublished
    }

    var currencyCode: String { original.currencyCode }
    var isNew: Bool { original.name.isEmpty }

    var priceCents: Int { price.map(Money.cents(from:)) ?? 0 }
    var depositCents: Int { deposit.map(Money.cents(from:)) ?? 0 }

    /// Deposit as a whole-number percent of the price, or nil when there's no price yet.
    var depositPercent: Int? {
        guard priceCents > 0 else { return nil }
        return Int((Double(depositCents) / Double(priceCents) * 100).rounded())
    }

    /// Sets the deposit to `percent` of the price, rounded to a whole currency unit when sensible.
    func setDeposit(percent: Int) {
        guard priceCents > 0 else { return }
        if percent == 0 {
            deposit = nil
        } else {
            let cents = (priceCents * percent + 50) / 100
            deposit = Money.decimal(cents: cents)
        }
    }

    // MARK: Deliverables and add-ons

    func addDeliverable() {
        guard deliverables.count < PackageRules.deliverableLimit else { return }
        deliverables.append(DeliverableRow(text: ""))
    }

    func removeDeliverables(at offsets: IndexSet) {
        deliverables.remove(atOffsets: offsets)
    }

    var canAddDeliverable: Bool { deliverables.count < PackageRules.deliverableLimit }
    var canAddAddOn: Bool { addOns.count < PackageRules.addOnLimit }

    func upsert(_ addOn: AddOn) {
        if let index = addOns.firstIndex(where: { $0.id == addOn.id }) {
            addOns[index] = addOn
        } else {
            addOns.append(addOn)
        }
    }

    func removeAddOns(at offsets: IndexSet) {
        addOns.remove(atOffsets: offsets)
    }

    // MARK: Output

    func makePackage() -> ServicePackage {
        var package = original
        package.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        package.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        package.category = category
        package.priceCents = priceCents
        package.durationMinutes = durationMinutes
        package.turnaroundDays = turnaroundDays
        package.depositCents = depositCents
        package.deliverables = deliverables
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        package.addOns = addOns.map { addOn in
            var cleaned = addOn
            cleaned.name = addOn.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return cleaned
        }
        package.isPublished = isPublished
        return package
    }

    var problems: [PackageRules.Problem] { PackageRules.problems(in: makePackage()) }
    var canSave: Bool { problems.isEmpty }

    /// True once there's something worth warning about; stops the form shouting at an empty draft.
    var hasContent: Bool { !name.isEmpty || priceCents > 0 }

    var hasChanges: Bool {
        makePackage() != original
    }
}
